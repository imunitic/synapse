//! The terminal sessions the host holds: what they are started with, what a client that attaches again
//! is given, and how they end. The same cases as the Node host's `terminal.test.ts`.

use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use synapse_desktop_host::dispatch::{serve, Handlers, ServeOptions};
use synapse_desktop_host::environment::Environment;
use synapse_desktop_host::link::link_pair;
use synapse_desktop_host::protocol::{
    Capabilities, ClientMessage, ErrorCode, HostKind, HostMessage, ReplyError,
};
use synapse_desktop_host::pty::{OnEvent, Pty, PtyEvent, SpawnOptions, SpawnPty};
use synapse_desktop_host::status::LoginEnvironment;
use synapse_desktop_host::terminal::{PlanFn, Schedule, Sessions, TerminalDeps, DETACHED_TTL};
use synapse_desktop_host::terminal_bus::{terminal_handlers, terminal_stream, ChannelSink};
use synapse_desktop_host::transcripts::{
    Registration, TranscriptEvents, TranscriptWatcher, WatchFactory,
};
use tempfile::{tempdir, TempDir};
use tokio::sync::oneshot;

// ---- The fakes ------------------------------------------------------------------------------------

#[derive(Default)]
struct FakePty {
    written: Mutex<Vec<String>>,
    resized: Mutex<Vec<(u16, u16)>>,
    killed: AtomicBool,
    on_event: Mutex<Option<OnEvent>>,
}

impl FakePty {
    fn print(&self, text: &str) {
        let on_event = self.on_event.lock().unwrap().clone().unwrap();
        on_event(PtyEvent::Data(text.to_string()));
    }
    fn end(&self, code: i32) {
        let on_event = self.on_event.lock().unwrap().clone().unwrap();
        on_event(PtyEvent::Exit(code));
    }
    fn written(&self) -> Vec<String> {
        self.written.lock().unwrap().clone()
    }
    fn resized(&self) -> Vec<(u16, u16)> {
        self.resized.lock().unwrap().clone()
    }
    fn killed(&self) -> bool {
        self.killed.load(Ordering::SeqCst)
    }
}

struct Handle(Arc<FakePty>);

impl Pty for Handle {
    fn write(&self, data: &str) {
        self.0.written.lock().unwrap().push(data.to_string());
    }
    fn resize(&self, cols: u16, rows: u16) {
        self.0.resized.lock().unwrap().push((cols, rows));
    }
    fn kill(&self) {
        self.0.killed.store(true, Ordering::SeqCst);
    }
}

#[derive(Default)]
struct FakeWatcher {
    registered: Mutex<Vec<(String, Registration)>>,
    stopped: AtomicBool,
}

impl TranscriptWatcher for FakeWatcher {
    fn register(&self, id: &str, registration: Registration) {
        self.registered
            .lock()
            .unwrap()
            .push((id.to_string(), registration));
    }
    fn stop(&self) {
        self.stopped.store(true, Ordering::SeqCst);
    }
}

struct Spawned {
    file: String,
    args: Vec<String>,
    options: SpawnOptions,
}

struct Expiry {
    after: Duration,
    action: Option<Box<dyn FnOnce() + Send>>,
    cancelled: Arc<AtomicBool>,
}

struct Rig {
    dir: TempDir,
    ptys: Arc<Mutex<Vec<Arc<FakePty>>>>,
    spawned: Arc<Mutex<Vec<Spawned>>>,
    fail_spawn: Arc<AtomicBool>,
    max_terminals: Arc<AtomicUsize>,
    watchers: Arc<Mutex<Vec<Arc<FakeWatcher>>>>,
    watch_events: Arc<Mutex<Vec<TranscriptEvents>>>,
    watch_dirs: Arc<Mutex<Vec<PathBuf>>>,
    expiries: Arc<Mutex<Vec<Expiry>>>,
    /// What the login shell is said to export; none, as when it cannot be read, until a test sets it.
    login: Arc<Mutex<Option<BTreeMap<String, String>>>>,
    login_reads: Arc<AtomicUsize>,
    sessions: Sessions,
    counter: AtomicUsize,
}

fn rig() -> Rig {
    let dir = tempdir().unwrap();
    std::fs::write(
        dir.path().join("config.json"),
        json!({
            "workDir": "/work", "definitionPaths": [], "defaultHarness": null,
            "env": { "FROM_APP": "yes" }, "recentVaults": [], "graphRepos": {}
        })
        .to_string(),
    )
    .unwrap();
    let ptys: Arc<Mutex<Vec<Arc<FakePty>>>> = Default::default();
    let spawned: Arc<Mutex<Vec<Spawned>>> = Default::default();
    let fail_spawn = Arc::new(AtomicBool::new(false));
    let (p, s, f) = (ptys.clone(), spawned.clone(), fail_spawn.clone());
    let spawn: SpawnPty = Arc::new(move |file, args, options, on_event| {
        if f.load(Ordering::SeqCst) {
            return Err("no such program".into());
        }
        s.lock().unwrap().push(Spawned {
            file: file.into(),
            args: args.to_vec(),
            options,
        });
        let pty = Arc::new(FakePty::default());
        *pty.on_event.lock().unwrap() = Some(on_event);
        p.lock().unwrap().push(pty.clone());
        Ok(Box::new(Handle(pty)))
    });
    let plan: PlanFn = Arc::new(|kind| {
        Box::pin(async move {
            Ok(synapse_desktop_host::inject::SessionPlan {
                command: format!("{kind:?}").to_lowercase(),
                args: vec!["--injected".into()],
                env: BTreeMap::from([("PLAN_ENV".to_string(), "p".to_string())]),
                loaded: true,
                note: "loaded for this session".into(),
            })
        })
    });
    let watchers: Arc<Mutex<Vec<Arc<FakeWatcher>>>> = Default::default();
    let watch_events: Arc<Mutex<Vec<TranscriptEvents>>> = Default::default();
    let watch_dirs: Arc<Mutex<Vec<PathBuf>>> = Default::default();
    let (w, e, d) = (watchers.clone(), watch_events.clone(), watch_dirs.clone());
    let watch: WatchFactory = Arc::new(move |options| {
        let watcher = Arc::new(FakeWatcher::default());
        w.lock().unwrap().push(watcher.clone());
        e.lock().unwrap().push(options.events.clone());
        d.lock().unwrap().push(options.dir.clone());
        watcher
    });
    let expiries: Arc<Mutex<Vec<Expiry>>> = Default::default();
    let x = expiries.clone();
    let schedule: Schedule = Arc::new(move |action, after| {
        let cancelled = Arc::new(AtomicBool::new(false));
        x.lock().unwrap().push(Expiry {
            after,
            action: Some(action),
            cancelled: cancelled.clone(),
        });
        Box::new(move || cancelled.store(true, Ordering::SeqCst))
    });
    let login: Arc<Mutex<Option<BTreeMap<String, String>>>> = Default::default();
    let login_reads = Arc::new(AtomicUsize::new(0));
    let (l, r) = (login.clone(), login_reads.clone());
    let login_environment = LoginEnvironment::new(move || {
        r.fetch_add(1, Ordering::SeqCst);
        let captured = l.lock().unwrap().clone();
        async move { captured }
    });
    let max_terminals = Arc::new(AtomicUsize::new(8));
    let env: BTreeMap<String, String> = [
        ("PATH", "/usr/bin"),
        ("INHERITED", "i"),
        ("CLAUDE_EFFORT", "high"),
        ("CLAUDECODE", "1"),
        ("CLAUDE_CODE_CHILD_SESSION", "1"),
        ("CLAUDE_CODE_MESSAGING_TOKEN", "secret"),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect();
    let sessions = Sessions::new(TerminalDeps {
        environment: Environment {
            env,
            home: dir.path().to_path_buf(),
        },
        config_file: dir.path().join("config.json"),
        spawn,
        plan,
        max_terminals: max_terminals.clone(),
        sessions_root: dir.path().join("sessions"),
        watch,
        schedule,
        login_environment,
    });
    Rig {
        dir,
        ptys,
        spawned,
        fail_spawn,
        max_terminals,
        watchers,
        watch_events,
        watch_dirs,
        expiries,
        login,
        login_reads,
        sessions,
        counter: AtomicUsize::new(0),
    }
}

// ---- A client -------------------------------------------------------------------------------------

type Replies = Arc<Mutex<HashMap<String, oneshot::Sender<HostMessage>>>>;

struct Client {
    out: Mutex<Option<tokio::sync::mpsc::UnboundedSender<ClientMessage>>>,
    replies: Replies,
    streams: Arc<Mutex<HashMap<String, Vec<Value>>>>,
    ids: AtomicUsize,
}

fn connect(rig: &Rig, owner: &str) -> Client {
    let (mut client, host) = link_pair();
    let sink = ChannelSink::sink(host.outgoing.clone());
    let mut handlers = Handlers::new();
    terminal_handlers(
        &mut handlers,
        rig.sessions.clone(),
        owner.to_string(),
        sink.clone(),
    );
    let mut options = ServeOptions::new(
        handlers,
        Capabilities {
            host: HostKind::Fake,
            shell: true,
            install_actions: false,
        },
    );
    options.on_stream = Some(terminal_stream(
        rig.sessions.clone(),
        owner.to_string(),
        sink.clone(),
    ));
    let (sessions, closing) = (rig.sessions.clone(), sink);
    options.on_close = Some(Arc::new(move || sessions.detach_all(&closing)));
    serve(host, options);
    let replies: Replies = Default::default();
    let streams: Arc<Mutex<HashMap<String, Vec<Value>>>> = Default::default();
    let (r, s) = (replies.clone(), streams.clone());
    tokio::spawn(async move {
        while let Some(message) = client.incoming.recv().await {
            match message {
                HostMessage::Reply { ref id, .. } => {
                    if let Some(tx) = r.lock().unwrap().remove(id) {
                        let _ = tx.send(message);
                    }
                }
                HostMessage::Stream { session, data } => {
                    s.lock()
                        .unwrap()
                        .entry(session)
                        .or_default()
                        .push(Value::Object(data));
                }
                _ => {}
            }
        }
    });
    Client {
        out: Mutex::new(Some(client.outgoing)),
        replies,
        streams,
        ids: AtomicUsize::new(0),
    }
}

impl Client {
    async fn request(&self, name: &str, params: Value) -> Result<Value, ReplyError> {
        let id = format!("r{}", self.ids.fetch_add(1, Ordering::SeqCst));
        let (tx, rx) = oneshot::channel();
        self.replies.lock().unwrap().insert(id.clone(), tx);
        self.out
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .send(ClientMessage::Request {
                id,
                name: name.into(),
                params,
            })
            .unwrap();
        match tokio::time::timeout(Duration::from_secs(5), rx)
            .await
            .expect("an answer")
            .unwrap()
        {
            HostMessage::Reply {
                result,
                error: None,
                ..
            } => Ok(result.unwrap_or(Value::Null)),
            HostMessage::Reply {
                error: Some(error), ..
            } => Err(error),
            _ => unreachable!(),
        }
    }

    fn stream(&self, session: &str, data: Value) {
        let Value::Object(data) = data else {
            panic!("an object")
        };
        if let Some(out) = self.out.lock().unwrap().as_ref() {
            let _ = out.send(ClientMessage::Stream {
                session: session.into(),
                data,
            });
        }
    }

    fn watch(&self, session: &str) -> Vec<Value> {
        self.streams
            .lock()
            .unwrap()
            .get(session)
            .cloned()
            .unwrap_or_default()
    }

    fn close(&self) {
        self.out.lock().unwrap().take();
    }
}

async fn sleep(ms: u64) {
    tokio::time::sleep(Duration::from_millis(ms)).await;
}

async fn until(done: impl Fn() -> bool) {
    for _ in 0..400 {
        if done() {
            return;
        }
        sleep(5).await;
    }
    panic!("timed out");
}

fn types(messages: &[Value]) -> Vec<String> {
    messages
        .iter()
        .map(|m| m["type"].as_str().unwrap().to_string())
        .collect()
}

impl Rig {
    fn home(&self) -> String {
        self.dir.path().to_string_lossy().to_string()
    }

    fn params(&self, fields: Value) -> (String, Value) {
        let mut params = json!({
            "session": format!("s{}", self.counter.fetch_add(1, Ordering::SeqCst) + 1),
            "title": "Terminal", "kind": "Claude", "cwd": self.home(), "cols": 100, "rows": 30
        });
        for (key, value) in fields.as_object().unwrap() {
            if value.is_null() {
                params.as_object_mut().unwrap().remove(key);
            } else {
                params[key] = value.clone();
            }
        }
        (params["session"].as_str().unwrap().to_string(), params)
    }

    async fn begin(&self, client: &Client, fields: Value) -> Result<Value, ReplyError> {
        let (_, params) = self.params(fields);
        client.request("terminal.start", params).await
    }

    fn args(&self, index: usize) -> Vec<String> {
        self.spawned.lock().unwrap()[index].args.clone()
    }

    fn pty(&self, index: usize) -> Arc<FakePty> {
        self.ptys.lock().unwrap()[index].clone()
    }

    fn spawned_count(&self) -> usize {
        self.spawned.lock().unwrap().len()
    }
}

fn refused(result: Result<Value, ReplyError>) -> ReplyError {
    result.expect_err("it is refused")
}

fn hex(text: &str, length: usize) -> bool {
    text.len() == length
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

// ---- A session started for a task -------------------------------------------------------------------

#[tokio::test]
async fn a_task_gives_the_harness_the_sentence_as_its_last_argument_after_the_session() {
    let rig = rig();
    rig.begin(&connect(&rig, "local"), json!({ "task": "rebuild-diff" }))
        .await
        .unwrap();
    let args = rig.args(0);
    assert_eq!(&args[..2], ["--injected", "--session-id"]);
    assert_eq!(args.last().unwrap(), "Do a synapse rebuild diff.");
    assert_eq!(args.len(), 4);
}

#[tokio::test]
async fn a_task_gives_opencode_the_sentence_after_prompt_and_codex_it_as_its_last_argument() {
    let rig = rig();
    let client = connect(&rig, "local");
    rig.begin(
        &client,
        json!({ "kind": "Opencode", "task": "rebuild-full" }),
    )
    .await
    .unwrap();
    assert_eq!(
        rig.args(0)[rig.args(0).len() - 2..],
        ["--prompt", "Do a synapse rebuild full."]
    );
    rig.begin(&client, json!({ "kind": "Codex", "task": "init" }))
        .await
        .unwrap();
    assert_eq!(rig.args(1).last().unwrap(), "Do a synapse init.");
}

#[tokio::test]
async fn a_task_is_refused_for_a_shell_and_for_a_task_that_is_not_known() {
    let rig = rig();
    let client = connect(&rig, "local");
    let error = refused(
        rig.begin(&client, json!({ "kind": "Shell", "task": "init" }))
            .await,
    );
    assert_eq!(error.code, ErrorCode::BadRequest);
    assert_eq!(error.message, "a shell has no task to start");
    let error = refused(rig.begin(&client, json!({ "task": "rm -rf" })).await);
    assert_eq!(error.code, ErrorCode::BadRequest);
    assert_eq!(rig.spawned_count(), 0);
}

// ---- An interactive run of a pipeline ----------------------------------------------------------------

#[tokio::test]
async fn a_run_starts_the_pipeline_with_an_id_of_its_own_which_the_page_is_told() {
    let rig = rig();
    let info = rig
        .begin(
            &connect(&rig, "local"),
            json!({ "kind": "Pipeline", "pipeline": "Develop_Review_Loop" }),
        )
        .await
        .unwrap();
    let id = info["executionId"].as_str().unwrap().to_string();
    assert!(id.starts_with("exec-") && hex(&id[5..], 8));
    let args = rig.args(0);
    assert_eq!(
        &args[..4],
        ["--injected", "run", "Develop_Review_Loop", "--interactive"]
    );
    assert_eq!(&args[4..6], ["--id".to_string(), id]);
    assert!(!args.contains(&"--input".to_string()));
}

#[tokio::test]
async fn a_run_gets_its_input_in_a_file() {
    let rig = rig();
    rig.begin(
        &connect(&rig, "local"),
        json!({ "kind": "Pipeline", "pipeline": "Dev", "input": { "task": "add a flag" } }),
    )
    .await
    .unwrap();
    let args = rig.args(0);
    let file = &args[args.iter().position(|a| a == "--input").unwrap() + 1];
    assert!(file.starts_with(
        &rig.dir
            .path()
            .join("sessions")
            .to_string_lossy()
            .to_string()
    ));
    let text = std::fs::read_to_string(file).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&text).unwrap(),
        json!({ "task": "add a flag" })
    );
}

#[tokio::test]
async fn a_run_is_refused_without_a_pipeline_with_a_task_and_for_any_other_kind() {
    let rig = rig();
    for (fields, message) in [
        (
            json!({ "kind": "Pipeline" }),
            "an interactive run needs a pipeline",
        ),
        (
            json!({ "kind": "Pipeline", "pipeline": "Dev", "task": "init" }),
            "a pipeline has no task or session to resume",
        ),
        (
            json!({ "kind": "Shell", "pipeline": "Dev" }),
            "only an interactive run takes a pipeline",
        ),
    ] {
        assert_eq!(
            refused(rig.begin(&connect(&rig, "local"), fields).await).message,
            message
        );
    }
    assert_eq!(rig.spawned_count(), 0);
}

#[tokio::test]
async fn a_run_does_not_take_a_name_that_is_not_a_name() {
    let rig = rig();
    let error = refused(
        rig.begin(
            &connect(&rig, "local"),
            json!({ "kind": "Pipeline", "pipeline": "../x; rm -rf /" }),
        )
        .await,
    );
    assert_eq!(error.code, ErrorCode::BadRequest);
    assert_eq!(rig.spawned_count(), 0);
}

// ---- A session that is resumed ------------------------------------------------------------------------

#[tokio::test]
async fn a_session_is_continued_by_its_id_in_the_way_of_each_harness() {
    let rig = rig();
    let client = connect(&rig, "local");
    for (index, (kind, id, flag)) in [
        ("Claude", "abc-123", "--resume"),
        ("Opencode", "ses_abc", "--session"),
        ("Codex", "def-456", "resume"),
    ]
    .iter()
    .enumerate()
    {
        rig.begin(&client, json!({ "kind": kind, "resume": id }))
            .await
            .unwrap();
        let args = rig.args(index);
        assert_eq!(args[args.len() - 2..], [flag.to_string(), id.to_string()]);
    }
    assert!(!rig.args(0).contains(&"--session-id".to_string()));
}

#[tokio::test]
async fn a_resume_is_refused_for_a_shell_a_task_and_an_id_that_could_be_taken_for_a_flag() {
    let rig = rig();
    let client = connect(&rig, "local");
    refused(
        rig.begin(&client, json!({ "kind": "Shell", "resume": "abc" }))
            .await,
    );
    refused(
        rig.begin(&client, json!({ "task": "init", "resume": "abc" }))
            .await,
    );
    refused(
        rig.begin(
            &client,
            json!({ "resume": "--dangerously-skip-permissions" }),
        )
        .await,
    );
    assert_eq!(rig.spawned_count(), 0);
}

// ---- A session ------------------------------------------------------------------------------------------

#[tokio::test]
async fn a_session_takes_tilde_for_the_home_folder_and_starts_in_it_when_no_folder_is_given() {
    let rig = rig();
    let client = connect(&rig, "local");
    rig.begin(&client, json!({ "kind": "Shell", "cwd": "~" }))
        .await
        .unwrap();
    rig.begin(&client, json!({ "kind": "Shell", "cwd": null }))
        .await
        .unwrap();
    for index in 0..2 {
        let spawned = rig.spawned.lock().unwrap();
        assert_eq!(spawned[index].file, "shell");
        assert_eq!(spawned[index].options.cwd, rig.home());
    }
}

#[tokio::test]
async fn a_session_runs_the_program_the_plan_names_and_relays_what_it_prints_and_what_is_typed() {
    let rig = rig();
    let client = connect(&rig, "local");
    let info = rig
        .begin(&client, json!({ "session": "main" }))
        .await
        .unwrap();
    assert_eq!(
        info,
        json!({
            "session": "main", "title": "Terminal", "kind": "Claude", "cwd": rig.home(),
            "loaded": true, "note": "loaded for this session", "exited": null
        })
    );
    {
        let spawned = rig.spawned.lock().unwrap();
        assert_eq!(spawned.len(), 1);
        assert_eq!(spawned[0].file, "claude");
        assert_eq!(
            (spawned[0].options.cols, spawned[0].options.rows),
            (100, 30)
        );
        assert_eq!(&spawned[0].args[..2], ["--injected", "--session-id"]);
        let env = &spawned[0].options.env;
        for (name, value) in [
            ("INHERITED", "i"),
            ("FROM_APP", "yes"),
            ("PLAN_ENV", "p"),
            ("TERM", "xterm-256color"),
        ] {
            assert_eq!(env.get(name).map(String::as_str), Some(value), "{name}");
        }
    }
    rig.pty(0).print("hello");
    until(|| !client.watch("main").is_empty()).await;
    assert_eq!(
        client.watch("main"),
        vec![json!({ "type": "output", "data": "hello" })]
    );
    client.stream("main", json!({ "type": "input", "data": "ls\r" }));
    client.stream("main", json!({ "type": "resize", "cols": 120, "rows": 40 }));
    until(|| !rig.pty(0).resized().is_empty()).await;
    assert_eq!(rig.pty(0).written(), ["ls\r"]);
    assert_eq!(rig.pty(0).resized(), [(120, 40)]);
}

#[tokio::test]
async fn a_session_is_not_given_the_identity_of_the_session_the_host_runs_in() {
    let rig = rig();
    rig.begin(&connect(&rig, "local"), json!({})).await.unwrap();
    let spawned = rig.spawned.lock().unwrap();
    let env = &spawned[0].options.env;
    for name in [
        "CLAUDECODE",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_MESSAGING_TOKEN",
    ] {
        assert!(!env.contains_key(name), "{name}");
    }
    assert_eq!(env.get("INHERITED").map(String::as_str), Some("i"));
    assert_eq!(env.get("CLAUDE_EFFORT").map(String::as_str), Some("high"));
}

fn variables(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

#[tokio::test]
async fn a_harness_is_given_what_the_login_shell_exports_under_what_the_app_and_the_plan_set() {
    let rig = rig();
    *rig.login.lock().unwrap() = Some(variables(&[
        ("PATH", "/opt/bin:/usr/bin"),
        ("FROM_ZSHRC", "z"),
        ("PLAN_ENV", "from the shell"),
        ("FROM_APP", "from the shell"),
        ("SHLVL", "2"),
        ("PWD", "/somewhere"),
        ("CLAUDECODE", "1"),
    ]));
    rig.begin(
        &connect(&rig, "local"),
        json!({ "resume": "8d6c1e52-0f0a-4b8e-9a51-2f4c9d1e7b3a" }),
    )
    .await
    .unwrap();
    let spawned = rig.spawned.lock().unwrap();
    let env = &spawned[0].options.env;
    for (name, value) in [
        ("FROM_ZSHRC", "z"),
        ("PATH", "/opt/bin:/usr/bin"),
        ("PLAN_ENV", "p"),
        ("FROM_APP", "yes"),
        ("TERM", "xterm-256color"),
    ] {
        assert_eq!(env.get(name).map(String::as_str), Some(value), "{name}");
    }
    for name in ["SHLVL", "PWD", "CLAUDECODE", "INHERITED"] {
        assert!(!env.contains_key(name), "{name}");
    }
    assert_eq!(rig.login_reads.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_shell_is_not_given_the_login_shell_environment_since_it_reads_its_own_files() {
    let rig = rig();
    *rig.login.lock().unwrap() = Some(variables(&[("FROM_ZSHRC", "z")]));
    rig.begin(&connect(&rig, "local"), json!({ "kind": "Shell" }))
        .await
        .unwrap();
    let spawned = rig.spawned.lock().unwrap();
    assert!(!spawned[0].options.env.contains_key("FROM_ZSHRC"));
    assert_eq!(
        spawned[0].options.env.get("INHERITED").map(String::as_str),
        Some("i")
    );
    assert_eq!(rig.login_reads.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_harness_is_given_the_app_environment_when_the_login_shell_cannot_be_read() {
    let rig = rig();
    rig.begin(&connect(&rig, "local"), json!({})).await.unwrap();
    let spawned = rig.spawned.lock().unwrap();
    let env = &spawned[0].options.env;
    assert_eq!(env.get("INHERITED").map(String::as_str), Some("i"));
    assert_eq!(env.get("PATH").map(String::as_str), Some("/usr/bin"));
    assert_eq!(rig.login_reads.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_session_says_how_its_program_ended_and_is_kept_until_its_tab_is_closed() {
    let rig = rig();
    let client = connect(&rig, "local");
    rig.begin(&client, json!({ "session": "main" }))
        .await
        .unwrap();
    rig.pty(0).end(3);
    until(|| !client.watch("main").is_empty()).await;
    assert_eq!(
        client.watch("main"),
        vec![json!({ "type": "exit", "code": 3 })]
    );
    let listed = client.request("terminal.list", json!({})).await.unwrap();
    assert_eq!(listed["sessions"][0]["session"], "main");
    assert_eq!(listed["sessions"][0]["exited"], 3);
    assert!(rig.watchers.lock().unwrap()[0]
        .stopped
        .load(Ordering::SeqCst));
    client
        .request("terminal.close", json!({ "session": "main" }))
        .await
        .unwrap();
    assert_eq!(
        client.request("terminal.list", json!({})).await.unwrap()["sessions"],
        json!([])
    );
    // The program had ended: there is nothing to kill.
    assert!(!rig.pty(0).killed());
}

#[tokio::test]
async fn a_session_refuses_a_folder_that_is_not_one_a_relative_path_and_a_program_that_cannot_start(
) {
    let rig = rig();
    let client = connect(&rig, "local");
    let missing = rig.dir.path().join("missing").to_string_lossy().to_string();
    let file = rig
        .dir
        .path()
        .join("config.json")
        .to_string_lossy()
        .to_string();
    for cwd in [missing, "relative/path".to_string(), file] {
        let error = refused(rig.begin(&client, json!({ "cwd": cwd })).await);
        assert_eq!(error.code, ErrorCode::BadRequest);
        assert!(error.message.contains("not a folder"), "{}", error.message);
    }
    assert_eq!(rig.spawned_count(), 0);
    rig.fail_spawn.store(true, Ordering::SeqCst);
    let error = refused(rig.begin(&client, json!({})).await);
    assert_eq!(error.code, ErrorCode::Unavailable);
    assert!(error.message.contains("could not be started"));
}

#[tokio::test]
async fn a_session_is_not_started_twice_under_one_name() {
    let rig = rig();
    let client = connect(&rig, "local");
    rig.begin(&client, json!({ "session": "same" }))
        .await
        .unwrap();
    let error = refused(rig.begin(&client, json!({ "session": "same" })).await);
    assert_eq!(error.code, ErrorCode::Conflict);
    assert!(error.message.contains("started already"));
    assert_eq!(rig.spawned_count(), 1);
}

#[tokio::test]
async fn the_number_of_open_terminals_is_held_to_the_limit_and_a_place_is_freed_by_closing() {
    let rig = rig();
    rig.max_terminals.store(1, Ordering::SeqCst);
    let client = connect(&rig, "local");
    rig.begin(&client, json!({ "session": "first" }))
        .await
        .unwrap();
    let error = refused(rig.begin(&client, json!({})).await);
    assert_eq!(error.code, ErrorCode::Conflict);
    assert!(error.message.contains("too many"));
    client
        .request("terminal.close", json!({ "session": "first" }))
        .await
        .unwrap();
    rig.begin(&client, json!({})).await.unwrap();
}

#[tokio::test]
async fn a_session_whose_program_has_ended_is_not_counted_against_the_limit() {
    let rig = rig();
    rig.max_terminals.store(1, Ordering::SeqCst);
    let client = connect(&rig, "local");
    rig.begin(&client, json!({})).await.unwrap();
    rig.pty(0).end(0);
    until(|| rig.sessions.list("local")[0].exited.is_some()).await;
    rig.begin(&client, json!({})).await.unwrap();
}

// ---- A session that is held by the host -----------------------------------------------------------------

fn attach(session: &str, cols: u16, rows: u16) -> Value {
    json!({ "session": session, "cols": cols, "rows": rows })
}

#[tokio::test]
async fn a_session_keeps_running_when_the_connection_drops_and_a_new_connection_attaches_to_it() {
    let rig = rig();
    let first = connect(&rig, "local");
    rig.begin(&first, json!({ "session": "main" }))
        .await
        .unwrap();
    first.close();
    sleep(30).await;
    assert!(!rig.pty(0).killed());

    let second = connect(&rig, "local");
    let attached = second
        .request("terminal.attach", attach("main", 90, 20))
        .await
        .unwrap();
    assert_eq!(attached["session"], "main");
    assert_eq!(attached["kind"], "Claude");
    assert_eq!(attached["exited"], Value::Null);
    assert_eq!(rig.pty(0).resized(), [(90, 20)]);
    assert_eq!(
        second.request("terminal.list", json!({})).await.unwrap()["sessions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[tokio::test]
async fn a_client_that_attaches_is_given_the_screen_as_the_program_drew_it_then_what_it_prints() {
    let rig = rig();
    let first = connect(&rig, "local");
    rig.begin(&first, json!({ "session": "main", "cols": 20, "rows": 4 }))
        .await
        .unwrap();
    rig.pty(0).print("one\r\ntwo\r\n\x1b[31mred\x1b[0m");
    until(|| !first.watch("main").is_empty()).await;
    first.close();
    sleep(30).await;

    let second = connect(&rig, "local");
    second
        .request("terminal.attach", attach("main", 20, 4))
        .await
        .unwrap();
    until(|| !second.watch("main").is_empty()).await;
    let snapshot = second.watch("main")[0].clone();
    assert_eq!(snapshot["type"], "snapshot");
    let data = snapshot["data"].as_str().unwrap();
    assert!(data.contains("one\r\ntwo\r\n"), "{data:?}");
    assert!(data.contains("\x1b[31mred"), "{data:?}");

    rig.pty(0).print("!");
    until(|| second.watch("main").len() > 1).await;
    assert_eq!(
        second.watch("main")[1],
        json!({ "type": "output", "data": "!" })
    );
}

#[tokio::test]
async fn a_screen_drawn_on_the_alternate_screen_is_kept() {
    let rig = rig();
    let first = connect(&rig, "local");
    rig.begin(&first, json!({ "session": "main", "cols": 20, "rows": 4 }))
        .await
        .unwrap();
    rig.pty(0).print("\x1b[?1049h\x1b[2J\x1b[HALT SCREEN");
    until(|| !first.watch("main").is_empty()).await;
    let second = connect(&rig, "local");
    second
        .request("terminal.attach", attach("main", 20, 4))
        .await
        .unwrap();
    until(|| !second.watch("main").is_empty()).await;
    let data = second.watch("main")[0]["data"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(data.contains("\x1b[?1049h"), "{data:?}");
    assert!(data.contains("ALT SCREEN"), "{data:?}");
}

#[tokio::test]
async fn a_hundred_lines_above_the_screen_are_kept_and_no_more() {
    let rig = rig();
    let first = connect(&rig, "local");
    rig.begin(&first, json!({ "session": "main", "cols": 20, "rows": 4 }))
        .await
        .unwrap();
    for line in 1..=300 {
        rig.pty(0).print(&format!("line {line}\r\n"));
    }
    until(|| first.watch("main").len() == 300).await;
    let second = connect(&rig, "local");
    second
        .request("terminal.attach", attach("main", 20, 4))
        .await
        .unwrap();
    until(|| !second.watch("main").is_empty()).await;
    let data = second.watch("main")[0]["data"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(data.contains("line 300"));
    assert!(data.contains("line 200"));
    assert!(!data.contains("line 190\r"));
    assert!(!data.contains("line 1\r"));
}

#[tokio::test]
async fn an_ended_session_sends_its_exit_after_the_screen() {
    let rig = rig();
    let first = connect(&rig, "local");
    rig.begin(&first, json!({ "session": "main" }))
        .await
        .unwrap();
    rig.pty(0).print("bye");
    rig.pty(0).end(5);
    until(|| first.watch("main").len() == 2).await;
    let second = connect(&rig, "local");
    second
        .request("terminal.attach", attach("main", 80, 24))
        .await
        .unwrap();
    until(|| second.watch("main").len() >= 2).await;
    assert_eq!(types(&second.watch("main")), ["snapshot", "exit"]);
    // There is no program to resize.
    assert!(rig.pty(0).resized().is_empty());
}

#[tokio::test]
async fn a_session_belongs_to_the_user_who_started_it() {
    let rig = rig();
    let owner = connect(&rig, "ann");
    rig.begin(&owner, json!({ "session": "main" }))
        .await
        .unwrap();
    let other = connect(&rig, "bob");
    assert_eq!(
        refused(
            other
                .request("terminal.attach", attach("main", 80, 24))
                .await
        )
        .code,
        ErrorCode::Forbidden
    );
    assert_eq!(
        refused(
            other
                .request("terminal.close", json!({ "session": "main" }))
                .await
        )
        .code,
        ErrorCode::Forbidden
    );
    assert_eq!(
        other.request("terminal.list", json!({})).await.unwrap()["sessions"],
        json!([])
    );
    other.stream("main", json!({ "type": "input", "data": "rm -rf /\r" }));
    sleep(30).await;
    assert!(rig.pty(0).written().is_empty());
    assert_eq!(
        owner.request("terminal.list", json!({})).await.unwrap()["sessions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[tokio::test]
async fn typing_is_not_taken_from_a_connection_that_is_not_attached() {
    let rig = rig();
    let owner = connect(&rig, "local");
    rig.begin(&owner, json!({ "session": "main" }))
        .await
        .unwrap();
    owner.close();
    sleep(30).await;
    let second = connect(&rig, "local");
    second.stream("main", json!({ "type": "input", "data": "x" }));
    sleep(30).await;
    assert!(rig.pty(0).written().is_empty());
    second
        .request("terminal.attach", attach("main", 80, 24))
        .await
        .unwrap();
    second.stream("main", json!({ "type": "input", "data": "y" }));
    until(|| rig.pty(0).written().len() == 1).await;
    assert_eq!(rig.pty(0).written(), ["y"]);
}

#[tokio::test]
async fn a_session_that_is_not_there_is_said_not_to_be() {
    let rig = rig();
    let error = refused(
        connect(&rig, "local")
            .request("terminal.attach", attach("nope", 80, 24))
            .await,
    );
    assert_eq!(error.code, ErrorCode::NotFound);
}

#[tokio::test]
async fn a_session_ends_with_its_tab() {
    let rig = rig();
    let client = connect(&rig, "local");
    rig.begin(&client, json!({ "session": "main" }))
        .await
        .unwrap();
    client
        .request("terminal.close", json!({ "session": "main" }))
        .await
        .unwrap();
    assert!(rig.pty(0).killed());
    assert!(rig.watchers.lock().unwrap()[0]
        .stopped
        .load(Ordering::SeqCst));
    assert_eq!(
        refused(
            client
                .request("terminal.attach", attach("main", 80, 24))
                .await
        )
        .code,
        ErrorCode::NotFound
    );
}

#[tokio::test]
async fn a_session_ends_after_twelve_hours_with_no_client_attached_and_not_while_one_is() {
    let rig = rig();
    let client = connect(&rig, "local");
    rig.begin(&client, json!({ "session": "main" }))
        .await
        .unwrap();
    // A client is attached: nothing is waiting to end it.
    assert!(rig.expiries.lock().unwrap().is_empty());
    client.close();
    sleep(30).await;
    assert_eq!(rig.expiries.lock().unwrap().len(), 1);
    assert_eq!(rig.expiries.lock().unwrap()[0].after, DETACHED_TTL);
    assert_eq!(DETACHED_TTL, Duration::from_secs(12 * 3600));

    // Attaching again withdraws it, and detaching sets it again.
    let second = connect(&rig, "local");
    second
        .request("terminal.attach", attach("main", 80, 24))
        .await
        .unwrap();
    assert!(rig.expiries.lock().unwrap()[0]
        .cancelled
        .load(Ordering::SeqCst));
    second.close();
    sleep(30).await;
    assert_eq!(rig.expiries.lock().unwrap().len(), 2);
    assert!(!rig.pty(0).killed());

    let action = rig.expiries.lock().unwrap()[1].action.take().unwrap();
    action();
    assert!(rig.pty(0).killed());
    let third = connect(&rig, "local");
    assert_eq!(
        refused(
            third
                .request("terminal.attach", attach("main", 80, 24))
                .await
        )
        .code,
        ErrorCode::NotFound
    );
}

#[tokio::test]
async fn a_session_stays_while_another_client_of_it_is_attached() {
    let rig = rig();
    let first = connect(&rig, "local");
    rig.begin(&first, json!({ "session": "main" }))
        .await
        .unwrap();
    let second = connect(&rig, "local");
    second
        .request("terminal.attach", attach("main", 80, 24))
        .await
        .unwrap();
    first.close();
    sleep(30).await;
    assert!(rig.expiries.lock().unwrap().is_empty());
}

// ---- Following the conversation of a harness -----------------------------------------------------------

#[tokio::test]
async fn a_claude_tab_gets_a_session_of_its_own_and_its_file_is_followed() {
    let rig = rig();
    let client = connect(&rig, "local");
    rig.begin(&client, json!({ "session": "main" }))
        .await
        .unwrap();
    let args = rig.args(0);
    assert_eq!(args[0], "--injected");
    assert_eq!(args[1], "--session-id");
    let id = args[2].clone();
    assert_eq!(id.len(), 36);
    {
        let registered = rig.watchers.lock().unwrap()[0]
            .registered
            .lock()
            .unwrap()
            .clone();
        assert_eq!(registered.len(), 1);
        assert_eq!(registered[0].0, id);
        assert_eq!(registered[0].1.session_id.as_deref(), Some(id.as_str()));
        assert_eq!(registered[0].1.cwd, rig.home());
    }
    // What the watcher finds goes to the page.
    let events = rig.watch_events.lock().unwrap()[0].clone();
    (events.on_source)(synapse_desktop_host::transcripts::Source {
        id: id.clone(),
        harness: synapse_desktop_host::transcripts::SourceHarness::Claude,
        cwd: rig.home(),
    });
    (events.on_lines)(id.clone(), vec!["{\"a\":1}".into(), "{\"b\":2}".into()]);
    until(|| client.watch("main").len() >= 2).await;
    assert_eq!(
        client.watch("main"),
        vec![
            json!({ "type": "transcript-source", "id": id, "harness": "Claude", "cwd": rig.home() }),
            json!({ "type": "transcript", "id": id, "lines": ["{\"a\":1}", "{\"b\":2}"] }),
        ]
    );
}

#[tokio::test]
async fn a_client_that_attaches_later_is_given_all_of_it_again() {
    let rig = rig();
    let first = connect(&rig, "local");
    rig.begin(&first, json!({ "session": "main" }))
        .await
        .unwrap();
    let id = rig.args(0)[2].clone();
    let events = rig.watch_events.lock().unwrap()[0].clone();
    (events.on_source)(synapse_desktop_host::transcripts::Source {
        id: id.clone(),
        harness: synapse_desktop_host::transcripts::SourceHarness::Claude,
        cwd: rig.home(),
    });
    (events.on_lines)(id.clone(), vec!["{\"a\":1}".into()]);
    (events.on_lines)(id.clone(), vec!["{\"b\":2}".into()]);
    first.close();
    sleep(30).await;
    let second = connect(&rig, "local");
    second
        .request("terminal.attach", attach("main", 80, 24))
        .await
        .unwrap();
    until(|| second.watch("main").len() >= 3).await;
    assert_eq!(
        types(&second.watch("main")),
        ["snapshot", "transcript-source", "transcript"]
    );
    assert_eq!(
        second.watch("main")[2],
        json!({ "type": "transcript", "id": id, "lines": ["{\"a\":1}", "{\"b\":2}"] })
    );
}

#[tokio::test]
async fn a_codex_tab_is_noted_by_where_it_started() {
    let rig = rig();
    rig.begin(&connect(&rig, "local"), json!({ "kind": "Codex" }))
        .await
        .unwrap();
    let registered = rig.watchers.lock().unwrap()[0]
        .registered
        .lock()
        .unwrap()
        .clone();
    assert_eq!(registered[0].1.cwd, rig.home());
    assert_eq!(rig.args(0), ["--injected"]);
}

#[tokio::test]
async fn an_opencode_tab_gets_a_session_id_of_its_own_and_that_session_is_followed() {
    let rig = rig();
    rig.begin(&connect(&rig, "local"), json!({ "kind": "Opencode" }))
        .await
        .unwrap();
    let args = rig.args(0);
    assert_eq!(args[0], "--injected");
    assert_eq!(args[1], "--session");
    let id = args[2].clone();
    assert!(id.starts_with("ses_") && hex(&id[4..], 20), "{id}");
    let registered = rig.watchers.lock().unwrap()[0]
        .registered
        .lock()
        .unwrap()
        .clone();
    assert_eq!(registered[0].0, id);
    assert_eq!(registered[0].1.session_id.as_deref(), Some(id.as_str()));
}

#[tokio::test]
async fn a_shell_is_given_the_folder_its_commands_note_runs_in_and_follows_nothing_itself() {
    let rig = rig();
    let client = connect(&rig, "local");
    rig.begin(&client, json!({ "kind": "Shell" }))
        .await
        .unwrap();
    assert!(rig.watchers.lock().unwrap()[0]
        .registered
        .lock()
        .unwrap()
        .is_empty());
    let dir0 = rig.watch_dirs.lock().unwrap()[0].clone();
    {
        let spawned = rig.spawned.lock().unwrap();
        assert_eq!(spawned[0].args, ["--injected"]);
        assert_eq!(
            spawned[0]
                .options
                .env
                .get("SYNAPSE_SESSIONS_DIR")
                .map(String::as_str),
            Some(dir0.to_string_lossy().as_ref())
        );
    }
    assert!(dir0.starts_with(rig.dir.path().join("sessions")));
    // Each terminal has a folder of its own.
    rig.begin(&client, json!({ "kind": "Shell" }))
        .await
        .unwrap();
    assert_ne!(dir0, rig.watch_dirs.lock().unwrap()[1]);
}
