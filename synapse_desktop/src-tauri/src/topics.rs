//! What the host tells a client that subscribed to a topic: that something under a place changed, and the
//! events of a run as they are written. A subscription is made when the client asks and ended with its
//! connection.

use crate::agents::vault_dir_of;
use crate::cli::CliRun;
use crate::dispatch::{Push, Stop};
use crate::environment::{definition_dirs, existing_dirs};
use crate::families::Context;
use crate::messages::{CliBinary, RunRequest};
use crate::protocol::{Cursor, Topic};
use crate::runs::{ask_run, socket_path};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde_json::{json, Value};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Notify;

/// How the subscriptions are timed; the tests make them short.
#[derive(Clone, Copy, Debug)]
pub struct TopicTiming {
    /// How long changes are gathered before the client is told.
    pub debounce: Duration,
    /// How often the places are looked up again, since a work directory can be set or a vault chosen
    /// while the client is subscribed.
    pub relook: Duration,
    /// How often a run is asked for its new events.
    pub poll: Duration,
}

impl Default for TopicTiming {
    fn default() -> TopicTiming {
        TopicTiming {
            debounce: Duration::from_millis(250),
            relook: Duration::from_secs(10),
            poll: Duration::from_secs(1),
        }
    }
}

/// Folders that change without the notes or the runs changing.
fn ignored(path: &Path, roots: &[PathBuf]) -> bool {
    let relative = roots
        .iter()
        .find_map(|root| path.strip_prefix(root).ok())
        .unwrap_or(path);
    relative.components().any(|c| {
        let name = c.as_os_str().to_string_lossy();
        name == ".git" || name == ".obsidian"
    })
}

async fn place_dirs(place: &str, context: &Context) -> Vec<String> {
    let Ok(config) = crate::config::load_config(&context.config_file, &context.environment) else {
        return vec![];
    };
    match place {
        "work" => {
            let records: Vec<PathBuf> = config
                .work_dir
                .iter()
                .map(|w| Path::new(w).join("pipelines"))
                .collect();
            existing_dirs(&records)
        }
        "definitions" => existing_dirs(&definition_dirs(
            &config.definition_paths,
            &context.environment,
        )),
        "vault" => {
            let run = CliRun::new(
                CliBinary::Synapse,
                &["config", "list", "--format", "json"],
                config,
            );
            match context.cli.run(run).await {
                Ok(settings) => match vault_dir_of(&settings.stdout) {
                    Some(vault) => existing_dirs(&[PathBuf::from(vault)]),
                    None => vec![],
                },
                Err(_) => vec![],
            }
        }
        _ => vec![],
    }
}

/// The watchers of one subscription to a place, which are made again when the folders of the place
/// change.
struct Place {
    watchers: Vec<RecommendedWatcher>,
    key: Option<Vec<String>>,
}

fn files(place: String, push: Push, context: Arc<Context>, timing: TopicTiming) -> Stop {
    let stopped = Arc::new(AtomicBool::new(false));
    let changed = Arc::new(Notify::new());
    let state = Arc::new(Mutex::new(Place {
        watchers: vec![],
        key: None,
    }));

    // The changes are gathered for a moment, then the client is told once.
    {
        let (stopped, changed, push) = (stopped.clone(), changed.clone(), push.clone());
        let told = place.clone();
        tokio::spawn(async move {
            loop {
                changed.notified().await;
                // The client is told once the changes have stopped for a moment.
                while tokio::time::timeout(timing.debounce, changed.notified())
                    .await
                    .is_ok()
                {}
                if stopped.load(Ordering::SeqCst) {
                    return;
                }
                eprintln!("SYNAPSE-WATCH push {told}");
                push(json!({}), None);
            }
        });
    }

    let look = {
        let (stopped, changed, state, context) = (
            stopped.clone(),
            changed.clone(),
            state.clone(),
            context.clone(),
        );
        move || {
            let (stopped, changed, state, context, place) = (
                stopped.clone(),
                changed.clone(),
                state.clone(),
                context.clone(),
                place.clone(),
            );
            async move {
                let dirs = place_dirs(&place, &context).await;
                if stopped.load(Ordering::SeqCst) {
                    return;
                }
                let first = {
                    let held = state.lock().unwrap();
                    if held.key.as_ref() == Some(&dirs) {
                        return;
                    }
                    held.key.is_none()
                };
                let roots: Vec<PathBuf> = dirs.iter().map(PathBuf::from).collect();
                let mut watchers = Vec::new();
                for dir in &dirs {
                    let (changed, roots) = (changed.clone(), roots.clone());
                    let made =
                        notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                            // TEMPORARY: diagnosing the Linux watcher in CI.
                            if let Err(error) = &event {
                                eprintln!("SYNAPSE-WATCH error {error:?}");
                            }
                            if let Ok(event) = event {
                                // Reading a file is not a change. On Linux every open and
                                // close is an Access event, so a client that reads what it is
                                // told of would be told again, without end.
                                if matches!(event.kind, notify::EventKind::Access(_)) {
                                    return;
                                }
                                eprintln!("SYNAPSE-WATCH event {:?} {:?}", event.kind, event.paths);
                                if event.paths.iter().any(|p| !ignored(p, &roots))
                                    || event.paths.is_empty()
                                {
                                    changed.notify_one();
                                }
                            }
                        });
                    match made {
                        Ok(mut watcher) => {
                            match watcher.watch(Path::new(dir), RecursiveMode::Recursive) {
                                Ok(()) => {
                                    eprintln!("SYNAPSE-WATCH watching {dir}");
                                    watchers.push(watcher);
                                }
                                Err(error) => {
                                    eprintln!("SYNAPSE-WATCH watch failed {dir} {error:?}")
                                }
                            }
                        }
                        Err(error) => eprintln!("SYNAPSE-WATCH watcher failed {dir} {error:?}"),
                    }
                }
                {
                    let mut held = state.lock().unwrap();
                    held.watchers = watchers;
                    held.key = Some(dirs);
                }
                // What a client shows may be from before the folder was there.
                if !first {
                    changed.notify_one();
                }
            }
        }
    };
    let look = Arc::new(look);
    {
        let (look, stopped) = (look.clone(), stopped.clone());
        tokio::spawn(async move {
            look().await;
            loop {
                tokio::time::sleep(timing.relook).await;
                if stopped.load(Ordering::SeqCst) {
                    return;
                }
                look().await;
            }
        });
    }
    Box::new(move || {
        stopped.store(true, Ordering::SeqCst);
        changed.notify_one();
        state.lock().unwrap().watchers.clear();
    })
}

/// The events of a run, each with its own sequence number as its cursor.
fn run(
    id: String,
    after: Option<Cursor>,
    push: Push,
    context: Arc<Context>,
    timing: TopicTiming,
) -> Stop {
    let stopped = Arc::new(AtomicBool::new(false));
    let flag = stopped.clone();
    tokio::spawn(async move {
        let mut cursor = after;
        while !flag.load(Ordering::SeqCst) {
            if let Ok(config) =
                crate::config::load_config(&context.config_file, &context.environment)
            {
                if let Some(work_dir) = &config.work_dir {
                    let path =
                        socket_path(&Path::new(work_dir).join("pipelines"), &id, cfg!(windows));
                    let request = RunRequest::Events { after: cursor };
                    // A run that is not listening is over, or has not started: it is asked again.
                    if let Ok(answer) = ask_run(&path, &request).await {
                        if answer.ok {
                            for event in events_of(answer.result.unwrap_or(Value::Null)) {
                                let Some(sequence) = event.get("sequence").and_then(Value::as_u64)
                                else {
                                    continue;
                                };
                                if flag.load(Ordering::SeqCst) {
                                    return;
                                }
                                push(event, Some(sequence));
                                cursor = Some(cursor.map_or(sequence, |c| c.max(sequence)));
                            }
                        }
                    }
                }
            }
            tokio::time::sleep(timing.poll).await;
        }
    });
    Box::new(move || stopped.store(true, Ordering::SeqCst))
}

/// The events an answer holds: a list, or an object that has one.
fn events_of(result: Value) -> Vec<Value> {
    match result {
        Value::Array(list) => list,
        Value::Object(map) => match map.get("events") {
            Some(Value::Array(list)) => list.clone(),
            _ => vec![],
        },
        _ => vec![],
    }
}

type Starting = Pin<Box<dyn Future<Output = Stop> + Send>>;

/// What the host starts for a subscription to a topic.
pub fn subscriber(
    context: Arc<Context>,
    timing: TopicTiming,
) -> Arc<dyn Fn(Topic, Option<Cursor>, Push) -> Starting + Send + Sync> {
    Arc::new(move |topic, after, push| {
        let context = context.clone();
        Box::pin(async move {
            let name = topic.as_str().to_string();
            if name == "usage" {
                return context.usage.subscribe(Arc::new(move |event| {
                    push(serde_json::to_value(event).unwrap_or(Value::Null), None)
                }));
            }
            if let Some(id) = name.strip_prefix("note-run.") {
                return context.note_runs.subscribe(id, after, push);
            }
            match name.strip_prefix("files.") {
                Some(place) => files(place.to_string(), push, context, timing),
                None => run(
                    name["run.".len()..].to_string(),
                    after,
                    push,
                    context,
                    timing,
                ),
            }
        })
    })
}
