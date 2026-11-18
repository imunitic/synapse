//! Following the conversation of a harness in a terminal: the session file that grows, and what is
//! appended is passed on. The same cases as the Node host's `transcripts.test.ts`.

mod support;

use filetime::{set_file_mtime, FileTime};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use synapse_desktop_host::time::millis;
use synapse_desktop_host::transcripts::{
    changed_messages, watch_transcripts, FileWatcher, RegisteredHarness, Registration, Source,
    SourceHarness, TranscriptEvents, TranscriptWatcher, WatchOptions,
};
use tempfile::{tempdir, TempDir};

type Lines = Arc<Mutex<BTreeMap<String, Vec<String>>>>;
type Sources = Arc<Mutex<Vec<Source>>>;

struct Rig {
    dir: TempDir,
    home: PathBuf,
    sessions: PathBuf,
    sources: Sources,
    lines: Lines,
    watcher: Arc<FileWatcher>,
}

fn events(sources: &Sources, lines: &Lines) -> TranscriptEvents {
    let (s, l) = (sources.clone(), lines.clone());
    TranscriptEvents {
        on_source: Arc::new(move |source| s.lock().unwrap().push(source)),
        on_lines: Arc::new(move |id, batch| l.lock().unwrap().entry(id).or_default().extend(batch)),
    }
}

fn options(rig_dir: &Path, sources: &Sources, lines: &Lines) -> WatchOptions {
    let mut options = WatchOptions::new(
        rig_dir.join("sessions"),
        rig_dir.join("home"),
        events(sources, lines),
    );
    // The tests look when they say.
    options.interval = Duration::from_secs(1_000_000);
    options
}

async fn rig() -> Rig {
    let dir = tempdir().unwrap();
    fs::create_dir_all(dir.path().join("sessions")).unwrap();
    let (sources, lines): (Sources, Lines) = Default::default();
    let watcher = watch_transcripts(options(dir.path(), &sources, &lines));
    Rig {
        home: dir.path().join("home"),
        sessions: dir.path().join("sessions"),
        dir,
        sources,
        lines,
        watcher,
    }
}

impl Rig {
    fn register(&self, name: &str, registration: Value) {
        fs::write(self.sessions.join(name), registration.to_string()).unwrap();
    }

    fn claude_file(&self, id: &str, project: &str) -> PathBuf {
        self.home
            .join(".claude/projects")
            .join(project)
            .join(format!("{id}.jsonl"))
    }

    fn lines_of(&self, id: &str) -> Vec<String> {
        self.lines
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .unwrap_or_default()
    }

    fn sources(&self) -> Vec<Source> {
        self.sources.lock().unwrap().clone()
    }
}

fn put(file: &Path, text: &str) {
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(file, text).unwrap();
}

fn append(file: &Path, text: &str) {
    let mut handle = fs::OpenOptions::new().append(true).open(file).unwrap();
    handle.write_all(text.as_bytes()).unwrap();
}

fn now() -> i64 {
    millis(std::time::SystemTime::now())
}

fn source(id: &str, harness: SourceHarness, cwd: &str) -> Source {
    Source {
        id: id.into(),
        harness,
        cwd: cwd.into(),
    }
}

fn claude(id: &str) -> Value {
    json!({ "harness": "claude", "sessionId": id, "cwd": "/work", "startedAt": now() })
}

#[tokio::test]
async fn a_claude_session_is_made_known_when_registered_and_followed_once_its_file_is_there() {
    let rig = rig().await;
    rig.register("claude-a.json", claude("aaa"));
    rig.watcher.poll().await;
    assert_eq!(
        rig.sources(),
        vec![source("aaa", SourceHarness::Claude, "/work")]
    );
    assert!(rig.lines.lock().unwrap().is_empty());

    // The file of a session begins when the first prompt is sent.
    put(&rig.claude_file("aaa", "-work"), "{\"n\":1}\n{\"n\":2}\n");
    rig.watcher.poll().await;
    assert_eq!(rig.lines_of("aaa"), ["{\"n\":1}", "{\"n\":2}"]);
}

#[tokio::test]
async fn only_what_was_appended_is_passed_on_and_the_end_of_a_half_written_line_is_waited_for() {
    let rig = rig().await;
    rig.register("claude-a.json", claude("aaa"));
    let file = rig.claude_file("aaa", "-work");
    put(&file, "{\"n\":1}\n{\"n\"");
    rig.watcher.poll().await;
    assert_eq!(rig.lines_of("aaa"), ["{\"n\":1}"]);

    append(&file, ":2}\n{\"n\":3}\n");
    rig.watcher.poll().await;
    assert_eq!(rig.lines_of("aaa"), ["{\"n\":1}", "{\"n\":2}", "{\"n\":3}"]);
    rig.watcher.poll().await;
    assert_eq!(rig.lines_of("aaa").len(), 3);
}

#[tokio::test]
async fn the_file_is_found_in_whichever_project_folder_it_is_and_two_sessions_are_not_mixed_up() {
    let rig = rig().await;
    rig.register("claude-a.json", claude("aaa"));
    rig.register("claude-b.json", claude("bbb"));
    put(&rig.claude_file("aaa", "-one"), "{\"from\":\"a\"}\n");
    put(&rig.claude_file("bbb", "-two"), "{\"from\":\"b\"}\n");
    rig.watcher.poll().await;
    assert_eq!(rig.lines_of("aaa"), ["{\"from\":\"a\"}"]);
    assert_eq!(rig.lines_of("bbb"), ["{\"from\":\"b\"}"]);
}

#[tokio::test]
async fn the_folder_a_registration_names_is_used_for_claude() {
    let rig = rig().await;
    let elsewhere = rig.dir.path().join("config");
    let mut registration = claude("aaa");
    registration["configDir"] = json!(elsewhere.to_string_lossy());
    rig.register("claude-a.json", registration);
    put(&elsewhere.join("projects/-w/aaa.jsonl"), "{\"ok\":true}\n");
    rig.watcher.poll().await;
    assert_eq!(rig.lines_of("aaa"), ["{\"ok\":true}"]);
}

#[tokio::test]
async fn a_file_that_was_replaced_is_read_from_its_start() {
    let rig = rig().await;
    rig.register("claude-a.json", claude("aaa"));
    let file = rig.claude_file("aaa", "-work");
    put(&file, "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n");
    rig.watcher.poll().await;
    fs::write(&file, "{\"n\":9}\n").unwrap();
    rig.watcher.poll().await;
    assert_eq!(
        rig.lines_of("aaa"),
        ["{\"n\":1}", "{\"n\":2}", "{\"n\":3}", "{\"n\":9}"]
    );
}

// Codex -------------------------------------------------------------------------------------------

fn rollout(rig: &Rig, day: &str, name: &str, cwd: &str, mtime_ms: i64) -> PathBuf {
    let file = rig
        .home
        .join(".codex/sessions/2026/11")
        .join(day)
        .join(format!("rollout-{name}.jsonl"));
    put(
        &file,
        &format!(
            "{}\n",
            json!({ "type": "session_meta", "payload": { "cwd": cwd } })
        ),
    );
    set_file_mtime(&file, FileTime::from_unix_time(mtime_ms / 1000, 0)).unwrap();
    file
}

fn codex(started: i64) -> Value {
    json!({ "harness": "codex", "cwd": "/work", "startedAt": started })
}

#[tokio::test]
async fn a_codex_session_is_the_rollout_file_that_began_where_and_when_the_run_did() {
    let rig = rig().await;
    let started = now();
    let wrong = rollout(&rig, "07", "wrong", "/elsewhere", started + 1000);
    let old = rollout(&rig, "07", "old", "/work", started - 600_000);
    let mine = rollout(&rig, "07", "mine", "/work", started + 1000);
    rig.register("codex-1.json", codex(started));
    rig.watcher.poll().await;
    assert_eq!(
        rig.sources(),
        vec![source("codex-1", SourceHarness::Codex, "/work")]
    );
    let first = json!({ "type": "session_meta", "payload": { "cwd": "/work" } }).to_string();
    assert_eq!(rig.lines_of("codex-1"), [first]);

    append(&mine, "{\"type\":\"response_item\"}\n");
    append(&wrong, "{\"x\":1}\n");
    append(&old, "{\"x\":2}\n");
    rig.watcher.poll().await;
    assert_eq!(rig.lines_of("codex-1").len(), 2);
    assert_eq!(rig.lines_of("codex-1")[1], "{\"type\":\"response_item\"}");
}

#[tokio::test]
async fn two_runs_in_one_folder_get_a_file_each_and_a_file_that_is_not_there_yet_is_waited_for() {
    let rig = rig().await;
    let started = now();
    rollout(&rig, "07", "first", "/work", started + 1000);
    rollout(&rig, "07", "second", "/work", started + 2000);
    rig.register("codex-1.json", codex(started));
    rig.watcher.poll().await;
    rig.register("codex-2.json", codex(started));
    rig.watcher.poll().await;
    let mut names: Vec<String> = rig.lines.lock().unwrap().keys().cloned().collect();
    names.sort();
    assert_eq!(names, ["codex-1", "codex-2"]);
    assert_eq!(rig.lines_of("codex-1").len(), 1);
    assert_eq!(rig.lines_of("codex-2").len(), 1);

    let late = self::rig().await;
    late.register("codex-1.json", codex(started));
    late.watcher.poll().await;
    assert!(late.lines.lock().unwrap().is_empty());
    rollout(&late, "07", "late", "/work", started + 1000);
    late.watcher.poll().await;
    assert_eq!(late.lines_of("codex-1").len(), 1);
}

// Registrations -----------------------------------------------------------------------------------

#[tokio::test]
async fn registrations_are_read_once_one_that_is_not_one_is_ignored_and_a_run_the_host_knows_is_followed(
) {
    let rig = rig().await;
    rig.register(
        "claude-a.json",
        json!({ "harness": "claude", "sessionId": "aaa", "cwd": "/w", "startedAt": 1 }),
    );
    fs::write(rig.sessions.join("notes.json"), "not json").unwrap();
    rig.register(
        "other.json",
        json!({ "harness": "gemini", "cwd": "/w", "startedAt": 1 }),
    );
    rig.register(
        ".hidden.json",
        json!({ "harness": "claude", "sessionId": "hhh", "cwd": "/w", "startedAt": 1 }),
    );
    rig.watcher.poll().await;
    rig.watcher.poll().await;
    assert_eq!(
        rig.sources(),
        vec![source("aaa", SourceHarness::Claude, "/w")]
    );

    rig.watcher.register(
        "direct",
        Registration {
            harness: RegisteredHarness::Claude,
            session_id: Some("ddd".into()),
            cwd: "/d".into(),
            config_dir: None,
            home: None,
            started_at: 1,
        },
    );
    assert_eq!(
        rig.sources().last().unwrap(),
        &source("direct", SourceHarness::Claude, "/d")
    );
    put(&rig.claude_file("ddd", "-d"), "{\"d\":1}\n");
    rig.watcher.poll().await;
    assert_eq!(rig.lines_of("direct"), ["{\"d\":1}"]);
}

#[tokio::test]
async fn lines_are_passed_on_in_batches_that_are_not_too_big() {
    let dir = tempdir().unwrap();
    fs::create_dir_all(dir.path().join("sessions")).unwrap();
    let batches: Arc<Mutex<Vec<usize>>> = Default::default();
    let kept = batches.clone();
    let events = TranscriptEvents {
        on_source: Arc::new(|_| {}),
        on_lines: Arc::new(move |_, batch| kept.lock().unwrap().push(batch.len())),
    };
    let mut options =
        WatchOptions::new(dir.path().join("sessions"), dir.path().join("home"), events);
    options.interval = Duration::from_secs(1_000_000);
    let watcher = watch_transcripts(options);
    watcher.register(
        "big",
        Registration {
            harness: RegisteredHarness::Claude,
            session_id: Some("big".into()),
            cwd: "/d".into(),
            config_dir: None,
            home: None,
            started_at: 1,
        },
    );
    let text: String = (0..450).map(|i| format!("{{\"n\":{i}}}\n")).collect();
    put(
        &dir.path().join("home/.claude/projects/-d/big.jsonl"),
        &text,
    );
    watcher.poll().await;
    assert_eq!(*batches.lock().unwrap(), vec![200, 200, 50]);
}

// OpenCode ----------------------------------------------------------------------------------------

fn message(id: &str, content: Value) -> Value {
    json!({ "id": id, "type": "assistant", "content": content })
}

fn exported(messages: &[&Value]) -> String {
    json!({ "info": {}, "messages": messages }).to_string()
}

/// A watcher that is given the export to read, and counts how often it is asked.
fn following(
    answers: Vec<Option<String>>,
    every: Duration,
) -> (Arc<FileWatcher>, Lines, Arc<Mutex<usize>>) {
    let dir = tempdir().unwrap();
    let dir = Box::leak(Box::new(dir));
    let (sources, lines): (Sources, Lines) = Default::default();
    let asked = Arc::new(Mutex::new(0usize));
    let counted = asked.clone();
    let mut options = options(dir.path(), &sources, &lines);
    options.export_every = every;
    options.export_session = Some(Arc::new(move |_registration, id| {
        assert_eq!(id, "ses_one");
        let mut n = counted.lock().unwrap();
        let answer = answers[(*n).min(answers.len() - 1)].clone();
        *n += 1;
        Box::pin(async move { answer })
    }));
    let watcher = watch_transcripts(options);
    watcher.register(
        "ses_one",
        Registration {
            harness: RegisteredHarness::Opencode,
            session_id: Some("ses_one".into()),
            cwd: "/w".into(),
            config_dir: None,
            home: None,
            started_at: 1,
        },
    );
    (watcher, lines, asked)
}

#[tokio::test]
async fn an_opencode_session_has_its_messages_sent_as_they_come() {
    let first = message("m1", json!([{ "type": "text", "text": "one" }]));
    let second = message("m2", json!([{ "type": "text", "text": "two" }]));
    let (watcher, lines, _) = following(
        vec![
            Some(exported(&[&first])),
            Some(exported(&[&first, &second])),
        ],
        Duration::ZERO,
    );
    watcher.poll().await;
    assert_eq!(lines.lock().unwrap()["ses_one"], [first.to_string()]);
    watcher.poll().await;
    // Only the message that is new.
    assert_eq!(
        lines.lock().unwrap()["ses_one"],
        [first.to_string(), second.to_string()]
    );
}

#[tokio::test]
async fn a_message_is_sent_again_whole_when_it_has_changed_and_not_when_it_has_not() {
    let early = message("m1", json!([{ "type": "text", "text": "Hel" }]));
    let later = message("m1", json!([{ "type": "text", "text": "Hello there" }]));
    let (watcher, lines, _) = following(
        vec![
            Some(exported(&[&early])),
            Some(exported(&[&early])),
            Some(exported(&[&later])),
        ],
        Duration::ZERO,
    );
    watcher.poll().await;
    watcher.poll().await;
    assert_eq!(lines.lock().unwrap()["ses_one"], [early.to_string()]);
    watcher.poll().await;
    assert_eq!(
        lines.lock().unwrap()["ses_one"],
        [early.to_string(), later.to_string()]
    );
}

#[tokio::test]
async fn it_waits_for_the_session_to_be_there_and_for_what_it_cannot_read() {
    let first = message("m1", json!([{ "type": "text", "text": "one" }]));
    let (watcher, lines, _) = following(
        vec![
            None,
            Some("not json".into()),
            Some("{\"messages\": 3}".into()),
            Some(exported(&[&first])),
        ],
        Duration::ZERO,
    );
    for _ in 0..3 {
        watcher.poll().await;
    }
    assert!(lines.lock().unwrap().is_empty());
    watcher.poll().await;
    assert_eq!(lines.lock().unwrap()["ses_one"], [first.to_string()]);
}

#[tokio::test]
async fn the_export_is_not_run_more_often_than_it_is_allowed_to() {
    let (watcher, _, asked) = following(vec![Some(exported(&[]))], Duration::from_secs(60));
    watcher.poll().await;
    watcher.poll().await;
    watcher.poll().await;
    assert_eq!(*asked.lock().unwrap(), 1);
}

#[test]
fn the_messages_that_are_new_or_differ_are_listed_in_the_order_of_the_export_by_their_id() {
    let mut sent = BTreeMap::new();
    let (a, b) = (json!({ "id": "a", "n": 1 }), json!({ "id": "b", "n": 1 }));
    assert_eq!(
        changed_messages(&json!({ "messages": [a, b] }).to_string(), &mut sent),
        [a.to_string(), b.to_string()]
    );
    let b2 = json!({ "id": "b", "n": 2 });
    let c = json!({ "id": "c" });
    assert_eq!(
        changed_messages(&json!({ "messages": [a, b2, c] }).to_string(), &mut sent),
        [b2.to_string(), c.to_string()]
    );
    // What has no id is left out, and nothing is found in what is not an export.
    assert!(changed_messages(
        "{\"messages\":[{\"x\":1},\"y\",null]}",
        &mut BTreeMap::new()
    )
    .is_empty());
    assert!(changed_messages("nope", &mut BTreeMap::new()).is_empty());
    assert!(changed_messages("{\"messages\":\"no\"}", &mut BTreeMap::new()).is_empty());
}

#[tokio::test]
async fn a_stopped_watcher_looks_no_more() {
    let rig = rig().await;
    rig.register("claude-a.json", claude("aaa"));
    rig.watcher.stop();
    rig.watcher.poll().await;
    assert!(rig.sources().is_empty());
}

// The program is a shell script.
#[cfg(unix)]
#[tokio::test]
async fn an_opencode_session_is_exported_with_the_path_of_the_environment_it_is_given() {
    use synapse_desktop_host::environment::Environment;
    use synapse_desktop_host::transcripts::export_opencode_session;

    // The program is on that PATH and not on the one of this process, as with an app opened from the
    // Dock that was given the PATH of the login shell.
    let dir = tempdir().unwrap();
    let bin = dir.path().join("bin");
    support::executable(
        &bin.join("opencode"),
        "#!/bin/sh\necho \"{\\\"messages\\\":[],\\\"args\\\":\\\"$*\\\"}\"\n",
    );
    let environment = Environment {
        env: BTreeMap::from([("PATH".to_string(), bin.to_string_lossy().to_string())]),
        home: dir.path().to_path_buf(),
    };
    let registration = Registration {
        harness: RegisteredHarness::Opencode,
        session_id: Some("ses_a".into()),
        cwd: dir.path().to_string_lossy().to_string(),
        config_dir: None,
        home: None,
        started_at: 1,
    };
    let exported = export_opencode_session(environment, registration, "ses_a".into()).await;
    assert!(exported.is_some_and(|text| text.contains("session export ses_a --standalone")));
}
