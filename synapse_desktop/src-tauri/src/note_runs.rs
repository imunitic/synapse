//! The runs of an agent on a note, a new note or a definition, which a client can watch and stop. A
//! run is known by the id the client made for it. It keeps the lines the agent printed, so a client
//! that subscribes late, or again after a drop, reads them from its cursor.

use crate::dispatch::{HostError, Push, Stop};
use crate::protocol::Cursor;
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::oneshot;

/// How long a finished run stays readable, for a subscriber that comes after it ended.
const KEEP: Duration = Duration::from_secs(60);

struct Subscriber {
    key: u64,
    /// The index of the next line this subscriber has not been given.
    next: usize,
    push: Push,
}

struct Entry {
    generation: u64,
    stop: Option<oneshot::Sender<()>>,
    lines: Vec<String>,
    subscribers: Vec<Subscriber>,
    stopped: bool,
    finished: bool,
}

#[derive(Default)]
struct Registry {
    entries: HashMap<String, Entry>,
    /// Subscribers of an id that has not started: a client watches before it sends the request.
    waiting: HashMap<String, Vec<Subscriber>>,
    counter: u64,
}

/// The lines a subscriber has not been given yet, taken while the registry is locked and pushed
/// after it is unlocked.
type Deliveries = Vec<(Push, String, Cursor)>;

fn deliver(lines: &[String], subscriber: &mut Subscriber, out: &mut Deliveries) {
    while subscriber.next < lines.len() {
        let index = subscriber.next;
        subscriber.next += 1;
        out.push((
            subscriber.push.clone(),
            lines[index].clone(),
            index as Cursor,
        ));
    }
}

fn send(deliveries: Deliveries) {
    for (push, line, cursor) in deliveries {
        push(json!({ "line": line }), Some(cursor));
    }
}

/// The registry of note runs. It is cheap to clone: the copies share the runs.
#[derive(Clone)]
pub struct NoteRuns {
    registry: Arc<Mutex<Registry>>,
    keep: Duration,
}

impl Default for NoteRuns {
    fn default() -> NoteRuns {
        NoteRuns::new()
    }
}

/// What the run that started holds: the signal to stop, and the way to publish its lines.
pub struct NoteRunHandle {
    /// Fires when the run is stopped.
    pub stop: Option<oneshot::Receiver<()>>,
    runs: NoteRuns,
    id: String,
    generation: u64,
}

impl NoteRuns {
    pub fn new() -> NoteRuns {
        NoteRuns::with_keep(KEEP)
    }

    /// A registry that keeps a finished run for `keep`; the tests make it short.
    pub fn with_keep(keep: Duration) -> NoteRuns {
        NoteRuns {
            registry: Arc::new(Mutex::new(Registry::default())),
            keep,
        }
    }

    pub fn start(&self, id: &str) -> Result<NoteRunHandle, HostError> {
        let mut registry = self.registry.lock().unwrap();
        if registry.entries.get(id).is_some_and(|e| !e.finished) {
            return Err(HostError::conflict(format!(
                "the run {id} is already running"
            )));
        }
        registry.counter += 1;
        let generation = registry.counter;
        let (sender, receiver) = oneshot::channel();
        let subscribers = registry.waiting.remove(id).unwrap_or_default();
        registry.entries.insert(
            id.to_string(),
            Entry {
                generation,
                stop: Some(sender),
                lines: vec![],
                subscribers,
                stopped: false,
                finished: false,
            },
        );
        Ok(NoteRunHandle {
            stop: Some(receiver),
            runs: self.clone(),
            id: id.to_string(),
            generation,
        })
    }

    /// Stops the run with this id; an id that is not running is ignored.
    pub fn stop(&self, id: &str) {
        let sender = {
            let mut registry = self.registry.lock().unwrap();
            match registry.entries.get_mut(id) {
                Some(entry) if !entry.finished => {
                    entry.stopped = true;
                    entry.stop.take()
                }
                _ => None,
            }
        };
        if let Some(sender) = sender {
            let _ = sender.send(());
        }
    }

    /// Gives `push` every line from the cursor on, then each new line as it is published.
    pub fn subscribe(&self, id: &str, after: Option<Cursor>, push: Push) -> Stop {
        let mut deliveries = Deliveries::new();
        let key = {
            let mut registry = self.registry.lock().unwrap();
            registry.counter += 1;
            let key = registry.counter;
            let mut subscriber = Subscriber {
                key,
                next: after.map_or(0, |c| c as usize + 1),
                push,
            };
            match registry.entries.get_mut(id) {
                Some(entry) => {
                    deliver(&entry.lines, &mut subscriber, &mut deliveries);
                    entry.subscribers.push(subscriber);
                }
                None => registry
                    .waiting
                    .entry(id.to_string())
                    .or_default()
                    .push(subscriber),
            }
            key
        };
        send(deliveries);
        let (registry, id) = (self.registry.clone(), id.to_string());
        Box::new(move || {
            let mut registry = registry.lock().unwrap();
            if let Some(list) = registry.waiting.get_mut(&id) {
                list.retain(|s| s.key != key);
            }
            if let Some(entry) = registry.entries.get_mut(&id) {
                entry.subscribers.retain(|s| s.key != key);
            }
        })
    }
}

impl NoteRunHandle {
    pub fn publish(&self, line: String) {
        let mut deliveries = Deliveries::new();
        {
            let mut registry = self.runs.registry.lock().unwrap();
            let Some(entry) = registry.entries.get_mut(&self.id) else {
                return;
            };
            if entry.generation != self.generation {
                return;
            }
            entry.lines.push(line);
            let Entry {
                lines, subscribers, ..
            } = entry;
            for subscriber in subscribers.iter_mut() {
                deliver(lines, subscriber, &mut deliveries);
            }
        }
        send(deliveries);
    }

    /// Whether the run ended because it was stopped.
    pub fn stopped(&self) -> bool {
        let registry = self.runs.registry.lock().unwrap();
        registry
            .entries
            .get(&self.id)
            .is_some_and(|e| e.generation == self.generation && e.stopped)
    }

    /// Ends the run. Its lines stay readable for a while, then are dropped.
    pub fn finish(self) {
        {
            let mut registry = self.runs.registry.lock().unwrap();
            match registry.entries.get_mut(&self.id) {
                Some(entry) if entry.generation == self.generation && !entry.finished => {
                    entry.finished = true;
                    entry.stop = None;
                }
                _ => return,
            }
        }
        let (registry, id, generation, keep) = (
            self.runs.registry.clone(),
            self.id.clone(),
            self.generation,
            self.runs.keep,
        );
        tokio::spawn(async move {
            tokio::time::sleep(keep).await;
            let mut registry = registry.lock().unwrap();
            if registry
                .entries
                .get(&id)
                .is_some_and(|e| e.generation == generation)
            {
                registry.entries.remove(&id);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    type Seen = Arc<Mutex<Vec<(String, Option<Cursor>)>>>;

    fn collector() -> (Push, Seen) {
        let seen: Seen = Arc::new(Mutex::new(vec![]));
        let sink = seen.clone();
        let push: Push = Arc::new(move |data: Value, cursor| {
            let line = data["line"].as_str().unwrap().to_string();
            sink.lock().unwrap().push((line, cursor));
        });
        (push, seen)
    }

    fn lines(seen: &Seen) -> Vec<String> {
        seen.lock()
            .unwrap()
            .iter()
            .map(|(l, _)| l.clone())
            .collect()
    }

    #[tokio::test]
    async fn stop_fires_the_signal_and_marks_the_run_stopped() {
        let runs = NoteRuns::new();
        let mut handle = runs.start("a").unwrap();
        let mut receiver = handle.stop.take().unwrap();
        assert!(!handle.stopped());
        assert!(receiver.try_recv().is_err());
        runs.stop("a");
        assert!(handle.stopped());
        assert!(receiver.await.is_ok());
    }

    #[tokio::test]
    async fn stop_of_an_unknown_id_does_nothing() {
        let runs = NoteRuns::new();
        runs.stop("nobody");
        let handle = runs.start("a").unwrap();
        assert!(!handle.stopped());
    }

    #[tokio::test]
    async fn stop_of_a_finished_run_does_nothing() {
        let runs = NoteRuns::new();
        let handle = runs.start("a").unwrap();
        let again = runs.clone();
        handle.finish();
        again.stop("a");
        let handle = again.start("a").unwrap();
        assert!(!handle.stopped());
    }

    #[tokio::test]
    async fn a_subscriber_gets_lines_from_before_and_after_it_subscribed() {
        let runs = NoteRuns::new();
        let handle = runs.start("a").unwrap();
        handle.publish("one".into());
        let (push, seen) = collector();
        let _stop = runs.subscribe("a", None, push);
        assert_eq!(lines(&seen), ["one"]);
        handle.publish("two".into());
        assert_eq!(lines(&seen), ["one", "two"]);
        assert_eq!(seen.lock().unwrap()[1].1, Some(1));
    }

    #[tokio::test]
    async fn after_skips_the_lines_the_subscriber_has() {
        let runs = NoteRuns::new();
        let handle = runs.start("a").unwrap();
        for line in ["one", "two", "three"] {
            handle.publish(line.into());
        }
        let (push, seen) = collector();
        let _stop = runs.subscribe("a", Some(1), push);
        assert_eq!(lines(&seen), ["three"]);
    }

    #[tokio::test]
    async fn a_subscriber_before_the_start_is_attached_when_the_run_starts() {
        let runs = NoteRuns::new();
        let (push, seen) = collector();
        let _stop = runs.subscribe("a", None, push);
        let handle = runs.start("a").unwrap();
        handle.publish("one".into());
        assert_eq!(lines(&seen), ["one"]);
    }

    #[tokio::test]
    async fn ending_the_subscription_stops_the_lines() {
        let runs = NoteRuns::new();
        let handle = runs.start("a").unwrap();
        let (push, seen) = collector();
        let stop = runs.subscribe("a", None, push);
        handle.publish("one".into());
        stop();
        handle.publish("two".into());
        assert_eq!(lines(&seen), ["one"]);
    }

    #[tokio::test]
    async fn a_finished_run_is_dropped_after_the_keep_time() {
        let runs = NoteRuns::with_keep(Duration::from_millis(80));
        let handle = runs.start("a").unwrap();
        handle.publish("one".into());
        handle.finish();
        let (push, seen) = collector();
        let _early = runs.subscribe("a", None, push);
        assert_eq!(lines(&seen), ["one"]);
        tokio::time::sleep(Duration::from_millis(250)).await;
        let (push, seen) = collector();
        let _late = runs.subscribe("a", None, push);
        assert!(lines(&seen).is_empty());
    }

    #[tokio::test]
    async fn a_second_start_of_a_running_id_is_refused() {
        let runs = NoteRuns::new();
        let _handle = runs.start("a").unwrap();
        let error = runs.start("a").err().unwrap();
        assert_eq!(error.code, crate::protocol::ErrorCode::Conflict);
    }

    #[tokio::test]
    async fn an_id_can_start_again_after_it_finished() {
        let runs = NoteRuns::new();
        runs.start("a").unwrap().finish();
        assert!(runs.start("a").is_ok());
    }
}
