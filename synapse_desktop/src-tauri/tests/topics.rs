//! What a client subscribed to a topic is told: that something under a place changed, and the events of
//! a run. The same cases as the Node host's `topics.test.ts`.

mod support;

use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use support::environment;
use synapse_desktop_host::agents::{AgentRunner, NoteSession};
use synapse_desktop_host::cli::CliRunner;
use synapse_desktop_host::dispatch::{Push, Stop};
use synapse_desktop_host::families::Context;
use synapse_desktop_host::messages::{CliResult, Harness, ModelCatalog};
use synapse_desktop_host::models::ModelStore;
use synapse_desktop_host::protocol::Topic;
use synapse_desktop_host::runs::RunStarter;
use synapse_desktop_host::status::{LoginPath, VersionOf};
use synapse_desktop_host::topics::{subscriber, TopicTiming};
use synapse_desktop_host::usage::{
    Usage, UsageKind, UsageOptions, UsageReading, UsageState,
};
use tempfile::{tempdir, TempDir};

type Seen = Arc<Mutex<Vec<(Value, Option<u64>)>>>;

struct World {
    dir: TempDir,
    context: Arc<Context>,
}

fn world() -> World {
    world_in(tempdir().unwrap())
}

fn world_in(dir: TempDir) -> World {
    std::fs::create_dir_all(dir.path().join("work/pipelines")).unwrap();
    std::fs::write(
        dir.path().join("config.json"),
        json!({ "workDir": dir.path().join("work"), "definitionPaths": [], "defaultHarness": null }).to_string(),
    )
    .unwrap();
    let vault = dir.path().join("vault").to_string_lossy().to_string();
    let context = Context {
        config_file: dir.path().join("config.json"),
        cli: CliRunner::new(move |_| {
            let settings = json!({ "settings": [{ "key": "SYNAPSE_VAULT_DIR", "value": vault }] });
            async move {
                Ok(CliResult {
                    code: 0,
                    stdout: settings.to_string(),
                    stderr: String::new(),
                })
            }
        }),
        login_path: LoginPath::new(|| async { None }),
        version_of: VersionOf::new(|_| async { None }),
        models: ModelStore::new(dir.path().join("models.json"), Arc::new(|| 0), |_| async {
            ModelCatalog {
                models: vec![],
                note: None,
                read_at: None,
            }
        }),
        agent: AgentRunner::new(|_| async { Err("not used".to_string()) }),
        note_session: NoteSession::new(|_| async { Err("not used".to_string()) }),
        note_runs: synapse_desktop_host::note_runs::NoteRuns::new(),
        runs: RunStarter::new("synapse-pipeline", Default::default()),
        bundled_roots: vec![],
        // One provider that says Codex is not installed, so that a subscription to `usage` shows
        // that it reached the usage.
        usage: Usage::new(UsageOptions::new(vec![Arc::new(|| {
            Box::pin(async {
                UsageReading {
                    harness: Harness::Codex,
                    kind: UsageKind::Limit,
                    windows: vec![],
                    spend: None,
                    observed_at: None,
                    state: UsageState::NotInstalled,
                    reason: Some("codex is not on PATH".into()),
                }
            })
        })])),
        environment: environment(
            dir.path(),
            &[("XDG_CONFIG_HOME", &dir.path().join("xdg").to_string_lossy())],
        ),
    };
    World {
        dir,
        context: Arc::new(context),
    }
}

const TIMING: TopicTiming = TopicTiming {
    debounce: Duration::from_millis(30),
    relook: Duration::from_millis(100),
    poll: Duration::from_millis(40),
};

async fn subscribed(world: &World, topic: &str, after: Option<u64>, stops: &mut Vec<Stop>) -> Seen {
    let seen: Seen = Arc::new(Mutex::new(vec![]));
    let kept = seen.clone();
    let push: Push = Arc::new(move |data, cursor| kept.lock().unwrap().push((data, cursor)));
    let start = subscriber(world.context.clone(), TIMING);
    stops.push(start(Topic::parse(topic).unwrap(), after, push).await);
    seen
}

async fn sleep(ms: u64) {
    tokio::time::sleep(Duration::from_millis(ms)).await;
}

async fn until(done: impl Fn() -> bool) {
    for _ in 0..150 {
        if done() {
            return;
        }
        sleep(20).await;
    }
    panic!("timed out");
}

/// A watcher may report what happened just before it was made, which is not a change after it; this
/// waits that out and forgets it.
async fn settle(seen: &Seen) {
    sleep(400).await;
    seen.lock().unwrap().clear();
}

fn stop_all(stops: Vec<Stop>) {
    for stop in stops {
        stop();
    }
}

#[tokio::test]
async fn a_record_that_appears_under_the_work_directory_is_told_once_for_a_burst_of_writes() {
    let w = world();
    let mut stops = vec![];
    let timing = TopicTiming {
        debounce: Duration::from_millis(150),
        ..TIMING
    };
    let seen: Seen = Arc::new(Mutex::new(vec![]));
    let kept = seen.clone();
    let push: Push = Arc::new(move |data, cursor| kept.lock().unwrap().push((data, cursor)));
    stops.push(
        subscriber(w.context.clone(), timing)(Topic::parse("files.work").unwrap(), None, push)
            .await,
    );
    settle(&seen).await;
    let record = w.dir.path().join("work/pipelines/exec-1");
    std::fs::create_dir(&record).unwrap();
    std::fs::write(record.join("execution.json"), "{}").unwrap();
    std::fs::write(record.join("events.jsonl"), "").unwrap();
    until(|| !seen.lock().unwrap().is_empty()).await;
    sleep(250).await;
    assert_eq!(*seen.lock().unwrap(), vec![(json!({}), None)]);
    stop_all(stops);
}

#[tokio::test]
async fn a_note_changed_in_the_vault_is_told_and_nothing_of_the_git_folder() {
    let w = world();
    std::fs::create_dir_all(w.dir.path().join("vault/.git")).unwrap();
    let mut stops = vec![];
    let seen = subscribed(&w, "files.vault", None, &mut stops).await;
    settle(&seen).await;
    std::fs::write(w.dir.path().join("vault/.git/HEAD"), "x").unwrap();
    sleep(200).await;
    assert!(seen.lock().unwrap().is_empty());
    std::fs::write(w.dir.path().join("vault/a.md"), "# a").unwrap();
    until(|| !seen.lock().unwrap().is_empty()).await;
    stop_all(stops);
}

#[tokio::test]
async fn a_folder_made_after_the_subscription_is_taken_up_and_told_of() {
    let w = world();
    let mut stops = vec![];
    let seen = subscribed(&w, "files.vault", None, &mut stops).await;
    sleep(150).await;
    assert!(seen.lock().unwrap().is_empty());
    std::fs::create_dir(w.dir.path().join("vault")).unwrap();
    until(|| !seen.lock().unwrap().is_empty()).await;
    stop_all(stops);
}

#[tokio::test]
async fn the_definition_folders_are_watched_too() {
    let w = world();
    let definitions = w.dir.path().join("xdg/synapse-pipeline");
    std::fs::create_dir_all(&definitions).unwrap();
    let mut stops = vec![];
    let seen = subscribed(&w, "files.definitions", None, &mut stops).await;
    settle(&seen).await;
    std::fs::write(
        definitions.join("New.synapse"),
        "Agent New [Prompt => \"x\"];",
    )
    .unwrap();
    until(|| !seen.lock().unwrap().is_empty()).await;
    stop_all(stops);
}

#[tokio::test]
async fn it_stops_telling_when_it_is_ended() {
    let w = world();
    let mut stops = vec![];
    let seen = subscribed(&w, "files.work", None, &mut stops).await;
    settle(&seen).await;
    stop_all(stops);
    std::fs::write(w.dir.path().join("work/pipelines/a"), "x").unwrap();
    sleep(250).await;
    assert!(seen.lock().unwrap().is_empty());
}

// The topic of a run ------------------------------------------------------------------------------

#[cfg(unix)]
mod run {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixListener;

    /// A run that listens, and answers `events` with those after the sequence it is asked after.
    async fn listening(w: &World, events: Vec<u64>) -> Arc<Mutex<Vec<Value>>> {
        let id = "exec-9";
        let folder = w.dir.path().join("work/pipelines").join(id);
        std::fs::create_dir_all(&folder).unwrap();
        let listener = UnixListener::bind(folder.join("execution.sock")).unwrap();
        let asked = Arc::new(Mutex::new(vec![]));
        let kept = asked.clone();
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                let (kept, events) = (kept.clone(), events.clone());
                tokio::spawn(async move {
                    let mut text = String::new();
                    let mut chunk = [0u8; 1024];
                    while !text.contains('\n') {
                        let n = stream.read(&mut chunk).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        text.push_str(&String::from_utf8_lossy(&chunk[..n]));
                    }
                    let request: Value = serde_json::from_str(text.trim()).unwrap();
                    let after = request["after"].as_i64().unwrap_or(-1);
                    kept.lock().unwrap().push(request);
                    let fresh: Vec<Value> = events
                        .iter()
                        .filter(|s| **s as i64 > after)
                        .map(|s| json!({ "sequence": s, "kind": "step.started", "step": null, "detail": null }))
                        .collect();
                    let _ = stream
                        .write_all(
                            json!({ "ok": true, "result": fresh })
                                .to_string()
                                .as_bytes(),
                        )
                        .await;
                });
            }
        });
        asked
    }

    fn short_world() -> World {
        // A Unix socket path is limited to about 100 characters, which the system temporary folder of
        // macOS can use up on its own.
        world_in(
            tempfile::Builder::new()
                .prefix("sd-")
                .tempdir_in("/tmp")
                .unwrap(),
        )
    }

    #[tokio::test]
    async fn the_events_of_a_run_come_with_their_sequence_as_the_cursor_from_the_cursor_it_is_given(
    ) {
        let w = short_world();
        let asked = listening(&w, vec![1, 2, 3]).await;
        let mut stops = vec![];
        let seen = subscribed(&w, "run.exec-9", Some(1), &mut stops).await;
        until(|| seen.lock().unwrap().len() >= 2).await;
        let cursors: Vec<Option<u64>> = seen.lock().unwrap().iter().map(|(_, c)| *c).collect();
        assert_eq!(cursors, vec![Some(2), Some(3)]);
        assert_eq!(
            asked.lock().unwrap()[0],
            json!({ "command": "events", "after": 1 })
        );
        stop_all(stops);
    }

    #[tokio::test]
    async fn it_asks_for_what_follows_the_last_event_it_gave() {
        let w = short_world();
        let asked = listening(&w, vec![0, 1]).await;
        let mut stops = vec![];
        let seen = subscribed(&w, "run.exec-9", None, &mut stops).await;
        until(|| seen.lock().unwrap().len() >= 2 && asked.lock().unwrap().len() >= 2).await;
        assert_eq!(asked.lock().unwrap()[0], json!({ "command": "events" }));
        assert_eq!(
            asked.lock().unwrap()[1],
            json!({ "command": "events", "after": 1 })
        );
        let cursors: Vec<Option<u64>> = seen.lock().unwrap().iter().map(|(_, c)| *c).collect();
        assert_eq!(cursors, vec![Some(0), Some(1)]);
        stop_all(stops);
    }

    #[tokio::test]
    async fn it_goes_on_quietly_while_the_run_is_not_listening() {
        let w = short_world();
        let mut stops = vec![];
        let seen = subscribed(&w, "run.exec-none", None, &mut stops).await;
        sleep(200).await;
        assert!(seen.lock().unwrap().is_empty());
        stop_all(stops);
    }
}

#[tokio::test]
async fn a_note_run_topic_gives_the_lines_the_run_published_from_the_cursor_on() {
    let w = world();
    let handle = w.context.note_runs.start("abc_1").unwrap();
    handle.publish("one".into());
    let mut stops = vec![];
    let seen = subscribed(&w, "note-run.abc_1", None, &mut stops).await;
    handle.publish("two".into());
    assert_eq!(
        *seen.lock().unwrap(),
        vec![
            (json!({ "line": "one" }), Some(0)),
            (json!({ "line": "two" }), Some(1))
        ]
    );
    let later = subscribed(&w, "note-run.abc_1", Some(0), &mut stops).await;
    assert_eq!(
        *later.lock().unwrap(),
        vec![(json!({ "line": "two" }), Some(1))]
    );
    stop_all(stops);
    handle.finish();
}

#[tokio::test]
async fn a_usage_subscription_reaches_the_usage_and_is_given_its_event() {
    let w = world();
    let mut stops = vec![];
    let seen = subscribed(&w, "usage", None, &mut stops).await;
    until(|| !seen.lock().unwrap().is_empty()).await;
    assert_eq!(
        seen.lock().unwrap()[0],
        (
            json!({ "readings": [{
                "harness": "Codex",
                "kind": "limit",
                "windows": [],
                "spend": null,
                "observedAt": null,
                "state": "not-installed",
                "reason": "codex is not on PATH",
            }] }),
            None
        )
    );
    stop_all(stops);
}
