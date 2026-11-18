//! What a host does with one connection: it says what it can do, answers each request by calling the
//! handler of the message, and tells the clients subscribed to a topic what happens there. This is
//! `shared/dispatch.ts` for the Rust host.

use crate::link::HostLink;
use crate::messages::{Validate, NAMES};
use crate::protocol::{
    Capabilities, ClientMessage, Cursor, ErrorCode, HostMessage, StreamData, Topic,
    PROTOCOL_VERSION,
};
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc::UnboundedSender;

/// A refusal or failure with the code it is answered with.
#[derive(Debug, Clone, PartialEq)]
pub struct HostError {
    pub code: ErrorCode,
    pub message: String,
}

impl HostError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> HostError {
        HostError {
            code,
            message: message.into(),
        }
    }

    pub fn bad_request(message: impl Into<String>) -> HostError {
        HostError::new(ErrorCode::BadRequest, message)
    }

    pub fn not_found(message: impl Into<String>) -> HostError {
        HostError::new(ErrorCode::NotFound, message)
    }

    pub fn forbidden(message: impl Into<String>) -> HostError {
        HostError::new(ErrorCode::Forbidden, message)
    }

    pub fn conflict(message: impl Into<String>) -> HostError {
        HostError::new(ErrorCode::Conflict, message)
    }

    pub fn unavailable(message: impl Into<String>) -> HostError {
        HostError::new(ErrorCode::Unavailable, message)
    }

    pub fn internal(message: impl Into<String>) -> HostError {
        HostError::new(ErrorCode::Internal, message)
    }
}

type Future_<T> = Pin<Box<dyn Future<Output = T> + Send>>;
type Handler = Arc<dyn Fn(Value) -> Future_<Result<Value, HostError>> + Send + Sync>;

/// The handler of each request a host answers.
#[derive(Default, Clone)]
pub struct Handlers {
    by_name: HashMap<&'static str, Handler>,
}

impl Handlers {
    pub fn new() -> Handlers {
        Handlers::default()
    }

    /// Answers `name` with `handler`, to which the parameters are given as the type the message takes.
    /// Parameters that are not that type are refused before the handler sees them.
    pub fn on<P, R, F, Fut>(&mut self, name: &'static str, handler: F)
    where
        P: DeserializeOwned + Validate + Send + 'static,
        R: Serialize + Send + 'static,
        F: Fn(P) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<R, HostError>> + Send + 'static,
    {
        assert!(NAMES.contains(&name), "there is no message {name}");
        let handler = Arc::new(handler);
        self.by_name.insert(
            name,
            Arc::new(move |params: Value| -> Future_<Result<Value, HostError>> {
                let parsed: Result<P, _> = serde_json::from_value(params);
                match parsed {
                    Err(error) => Box::pin(async move {
                        Err(HostError::bad_request(format!(
                            "invalid parameters: {error}"
                        )))
                    }),
                    Ok(parsed) if parsed.check().is_err() => {
                        let why = parsed.check().unwrap_err();
                        Box::pin(async move {
                            Err(HostError::bad_request(format!("invalid parameters: {why}")))
                        })
                    }
                    Ok(parsed) => {
                        let running = handler(parsed);
                        Box::pin(async move {
                            let result = running.await?;
                            serde_json::to_value(result)
                                .map_err(|error| HostError::internal(error.to_string()))
                        })
                    }
                }
            }),
        );
    }

    fn get(&self, name: &str) -> Option<&Handler> {
        self.by_name.get(name)
    }
}

/// Gives the events of a subscription to the clients: an event of a topic that has a cursor goes
/// with it.
pub type Push = Arc<dyn Fn(Value, Option<Cursor>) + Send + Sync>;

/// What ends a subscription.
pub type Stop = Box<dyn FnOnce() + Send>;

type Subscribe = Arc<dyn Fn(Topic, Option<Cursor>, Push) -> Future_<Stop> + Send + Sync>;
type OnStream = Arc<dyn Fn(String, StreamData) + Send + Sync>;
type MayWatch = Arc<dyn Fn(&Topic) -> bool + Send + Sync>;
type Report = Arc<dyn Fn(&str) + Send + Sync>;

pub struct ServeOptions {
    pub handlers: Handlers,
    pub capabilities: Capabilities,
    /// Whether a client may subscribe to a topic; every topic when absent.
    pub may_watch: Option<MayWatch>,
    /// What a subscription to a topic starts, called for the first subscription of a connection to a
    /// topic with the cursor of the last event the client has, and ended when the client unsubscribes
    /// or the connection closes.
    pub subscribe: Option<Subscribe>,
    /// A message of a stream, from the client.
    pub on_stream: Option<OnStream>,
    /// What a failure that is not a refusal comes to; the client is told it was internal.
    pub report: Option<Report>,
    /// Called when the connection closes.
    pub on_close: Option<Arc<dyn Fn() + Send + Sync>>,
}

impl ServeOptions {
    pub fn new(handlers: Handlers, capabilities: Capabilities) -> ServeOptions {
        ServeOptions {
            handlers,
            capabilities,
            may_watch: None,
            subscribe: None,
            on_stream: None,
            report: None,
            on_close: None,
        }
    }
}

struct Inner {
    out: UnboundedSender<HostMessage>,
    subscribed: Mutex<HashSet<Topic>>,
}

/// What a host holds of one connection once it is served.
#[derive(Clone)]
pub struct Connection {
    inner: Arc<Inner>,
}

impl Connection {
    /// Tells the clients subscribed to the topic. An event of a topic that has a cursor goes with it.
    pub fn publish(&self, topic: &Topic, data: Value, cursor: Option<Cursor>) {
        if self.watching(topic) {
            let _ = self.inner.out.send(HostMessage::Event {
                topic: topic.clone(),
                cursor,
                data,
            });
        }
    }

    pub fn stream(&self, session: &str, data: StreamData) {
        let _ = self.inner.out.send(HostMessage::Stream {
            session: session.to_string(),
            data,
        });
    }

    /// Whether some client of this connection is subscribed to the topic.
    pub fn watching(&self, topic: &Topic) -> bool {
        self.inner.subscribed.lock().unwrap().contains(topic)
    }
}

/// Serves one connection until it closes. It sends the `hello` first, and the handlers run as tasks
/// of the runtime it is called in.
pub fn serve(link: HostLink, options: ServeOptions) -> Connection {
    let HostLink {
        mut incoming,
        outgoing,
    } = link;
    let inner = Arc::new(Inner {
        out: outgoing,
        subscribed: Mutex::new(HashSet::new()),
    });
    let _ = inner.out.send(HostMessage::Hello {
        protocol: PROTOCOL_VERSION,
        capabilities: options.capabilities.clone(),
    });
    let connection = Connection {
        inner: inner.clone(),
    };
    let options = Arc::new(options);

    tokio::spawn(async move {
        // The stoppers of what the subscriptions started, by topic.
        let stoppers: Arc<Mutex<HashMap<Topic, Stop>>> = Arc::new(Mutex::new(HashMap::new()));
        // A topic that was unsubscribed before its subscription had started is stopped as it starts.
        let cancelled: Arc<Mutex<HashSet<Topic>>> = Arc::new(Mutex::new(HashSet::new()));

        while let Some(message) = incoming.recv().await {
            match message {
                ClientMessage::Request { id, name, params } => {
                    let options = options.clone();
                    let out = inner.out.clone();
                    tokio::spawn(async move {
                        let reply = answer(&options, &id, &name, params).await;
                        let _ = out.send(reply);
                    });
                }
                ClientMessage::Subscribe { topic, after } => {
                    if let Some(may) = &options.may_watch {
                        if !may(&topic) {
                            continue;
                        }
                    }
                    let known = !inner.subscribed.lock().unwrap().insert(topic.clone());
                    if known {
                        continue;
                    }
                    cancelled.lock().unwrap().remove(&topic);
                    if let Some(subscribe) = &options.subscribe {
                        let push: Push = {
                            let out = inner.out.clone();
                            let topic = topic.clone();
                            Arc::new(move |data, cursor| {
                                let _ = out.send(HostMessage::Event {
                                    topic: topic.clone(),
                                    cursor,
                                    data,
                                });
                            })
                        };
                        let starting = subscribe(topic.clone(), after, push);
                        let stoppers = stoppers.clone();
                        let cancelled = cancelled.clone();
                        let topic = topic.clone();
                        tokio::spawn(async move {
                            let stop = starting.await;
                            if cancelled.lock().unwrap().remove(&topic) {
                                stop();
                            } else {
                                stoppers.lock().unwrap().insert(topic, stop);
                            }
                        });
                    }
                }
                ClientMessage::Unsubscribe { topic } => {
                    inner.subscribed.lock().unwrap().remove(&topic);
                    let stop = stoppers.lock().unwrap().remove(&topic);
                    match stop {
                        Some(stop) => stop(),
                        None => {
                            cancelled.lock().unwrap().insert(topic);
                        }
                    }
                }
                ClientMessage::Stream { session, data } => {
                    if let Some(on_stream) = &options.on_stream {
                        on_stream(session, data);
                    }
                }
            }
        }
        // The connection closed: what its subscriptions started ends with it, and one that is still
        // starting is ended as soon as it has.
        let stops: Vec<(Topic, Stop)> = stoppers.lock().unwrap().drain().collect();
        let started: HashSet<Topic> = stops.iter().map(|(topic, _)| topic.clone()).collect();
        for topic in inner.subscribed.lock().unwrap().drain() {
            if !started.contains(&topic) {
                cancelled.lock().unwrap().insert(topic);
            }
        }
        for (_, stop) in stops {
            stop();
        }
        if let Some(on_close) = &options.on_close {
            on_close();
        }
    });

    connection
}

async fn answer(options: &ServeOptions, id: &str, name: &str, params: Value) -> HostMessage {
    if !NAMES.contains(&name) {
        return HostMessage::error(
            id,
            ErrorCode::NotFound,
            format!("there is no message {name}"),
        );
    }
    let Some(handler) = options.handlers.get(name) else {
        return HostMessage::error(
            id,
            ErrorCode::Unavailable,
            format!("this host does not answer {name}"),
        );
    };
    match handler(params).await {
        Ok(result) => HostMessage::result(id, result),
        Err(error) => {
            if error.code == ErrorCode::Internal {
                if let Some(report) = &options.report {
                    report(&error.message);
                }
                // What an unexpected failure says is not told to the page.
                return HostMessage::error(id, ErrorCode::Internal, "internal error");
            }
            HostMessage::error(id, error.code, error.message)
        }
    }
}
