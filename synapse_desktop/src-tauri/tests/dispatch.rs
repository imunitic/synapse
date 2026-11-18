//! What the dispatcher does with a connection: it says what the host can do, answers each request
//! with the handler of its message, and carries events and streams. The same cases as the Node
//! host's `shared/bus.test.ts`.

mod support;

use serde_json::{json, Map, Value};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use support::{examples, same};
use synapse_desktop_host::dispatch::{serve, Connection, Handlers, HostError, ServeOptions};
use synapse_desktop_host::link::{link_pair, ClientLink};
use synapse_desktop_host::messages::{answer_with, Entries, PathParams, Text};
use synapse_desktop_host::protocol::{
    Capabilities, ClientMessage, ErrorCode, HostKind, HostMessage, ReplyError, Topic,
    PROTOCOL_VERSION,
};
use tokio::time::timeout;

/// What a subscription was started with: the topic and the cursor it was given.
type Started = Arc<Mutex<Vec<(String, Option<u64>)>>>;

fn capabilities() -> Capabilities {
    Capabilities {
        host: HostKind::Fake,
        shell: true,
        install_actions: false,
    }
}

async fn next(client: &mut ClientLink) -> HostMessage {
    timeout(Duration::from_secs(2), client.incoming.recv())
        .await
        .expect("a message arrives")
        .expect("the connection is open")
}

fn request(client: &ClientLink, id: &str, name: &str, params: Value) {
    client
        .outgoing
        .send(ClientMessage::Request {
            id: id.into(),
            name: name.into(),
            params,
        })
        .unwrap();
}

fn topic(name: &str) -> Topic {
    Topic::parse(name).unwrap()
}

/// A connection to a host with these handlers, past its `hello`.
async fn connected(handlers: Handlers) -> (ClientLink, Connection) {
    let (mut client, host) = link_pair();
    let connection = serve(host, ServeOptions::new(handlers, capabilities()));
    assert!(matches!(next(&mut client).await, HostMessage::Hello { .. }));
    (client, connection)
}

fn files() -> Handlers {
    let mut handlers = Handlers::new();
    handlers.on::<PathParams, Text, _, _>("fs.read", |params| async move {
        match params.path.as_str() {
            "/missing" => Err(HostError::not_found("no such file")),
            "/boom" => Err(HostError::internal("secret detail")),
            path => Ok(Text {
                text: format!("text of {path}"),
            }),
        }
    });
    handlers
        .on::<PathParams, Entries, _, _>("fs.list", |_| async { Ok(Entries { entries: vec![] }) });
    handlers.on::<serde_json::Value, (), _, _>("run.stop", |_| async { Ok(()) });
    handlers
}

fn reply_result(message: HostMessage) -> Value {
    match message {
        HostMessage::Reply {
            result: Some(result),
            error: None,
            ..
        } => result,
        other => panic!("not a result: {other:?}"),
    }
}

fn reply_error(message: HostMessage) -> ReplyError {
    match message {
        HostMessage::Reply {
            error: Some(error),
            result: None,
            ..
        } => error,
        other => panic!("not an error: {other:?}"),
    }
}

#[tokio::test]
async fn says_what_it_can_do_first() {
    let (mut client, host) = link_pair();
    serve(host, ServeOptions::new(Handlers::new(), capabilities()));
    match next(&mut client).await {
        HostMessage::Hello {
            protocol,
            capabilities: said,
        } => {
            assert_eq!(protocol, PROTOCOL_VERSION);
            assert_eq!(said, capabilities());
        }
        other => panic!("not a hello: {other:?}"),
    }
}

#[tokio::test]
async fn answers_every_example_request_with_its_example_result() {
    let mut handlers = Handlers::new();
    let all = examples();
    for example in &all {
        let name: &'static str = synapse_desktop_host::messages::NAMES
            .iter()
            .find(|n| **n == example.name)
            .unwrap();
        answer_with(&mut handlers, name, example.result.clone());
    }
    let (mut client, _connection) = connected(handlers).await;
    for (index, example) in all.iter().enumerate() {
        let id = format!("r{index}");
        request(&client, &id, &example.name, example.params.clone());
        let message = next(&mut client).await;
        let HostMessage::Reply { id: replied, .. } = &message else {
            panic!("not a reply")
        };
        assert_eq!(replied, &id);
        let result = reply_result(message);
        assert!(same(&result, &example.result), "{}: {result}", example.name);
    }
}

#[tokio::test]
async fn answers_two_requests_in_flight_each_by_its_id() {
    let (mut client, _connection) = connected(files()).await;
    request(&client, "a", "fs.read", json!({ "path": "/a" }));
    request(&client, "b", "fs.read", json!({ "path": "/b" }));
    let mut results = std::collections::HashMap::new();
    for _ in 0..2 {
        let message = next(&mut client).await;
        let HostMessage::Reply { id, .. } = &message else {
            panic!("not a reply")
        };
        results.insert(id.clone(), reply_result(message));
    }
    assert_eq!(results["a"], json!({ "text": "text of /a" }));
    assert_eq!(results["b"], json!({ "text": "text of /b" }));
}

#[tokio::test]
async fn carries_a_refusal_with_its_code_and_hides_what_an_unexpected_failure_says() {
    let reports = Arc::new(Mutex::new(Vec::<String>::new()));
    let (mut client, host) = link_pair();
    let mut options = ServeOptions::new(files(), capabilities());
    let seen = reports.clone();
    options.report = Some(Arc::new(move |text| {
        seen.lock().unwrap().push(text.to_string())
    }));
    serve(host, options);
    next(&mut client).await;

    request(&client, "r1", "fs.read", json!({ "path": "/missing" }));
    let error = reply_error(next(&mut client).await);
    assert_eq!(
        error,
        ReplyError {
            code: ErrorCode::NotFound,
            message: "no such file".into()
        }
    );

    request(&client, "r2", "fs.read", json!({ "path": "/boom" }));
    let error = reply_error(next(&mut client).await);
    assert_eq!(error.code, ErrorCode::Internal);
    assert!(!error.message.contains("secret"));
    assert_eq!(*reports.lock().unwrap(), vec!["secret detail".to_string()]);
}

#[tokio::test]
async fn refuses_parameters_that_are_not_the_messages_before_the_handler_sees_them() {
    let called = Arc::new(AtomicUsize::new(0));
    let mut handlers = Handlers::new();
    let counted = called.clone();
    handlers.on::<PathParams, Text, _, _>("fs.read", move |_| {
        counted.fetch_add(1, Ordering::SeqCst);
        async {
            Ok(Text {
                text: String::new(),
            })
        }
    });
    let (mut client, _connection) = connected(handlers).await;
    request(&client, "r1", "fs.read", json!({ "path": 42 }));
    assert_eq!(
        reply_error(next(&mut client).await).code,
        ErrorCode::BadRequest
    );
    request(&client, "r2", "fs.read", Value::Null);
    assert_eq!(
        reply_error(next(&mut client).await).code,
        ErrorCode::BadRequest
    );
    assert_eq!(called.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn says_unknown_for_a_name_that_is_not_a_message_and_unavailable_for_one_it_does_not_answer()
{
    let (mut client, _connection) = connected(files()).await;
    request(&client, "r1", "shutdown", json!({}));
    assert_eq!(
        reply_error(next(&mut client).await).code,
        ErrorCode::NotFound
    );
    request(&client, "r2", "diagnose", json!({}));
    assert_eq!(
        reply_error(next(&mut client).await).code,
        ErrorCode::Unavailable
    );
}

#[tokio::test]
async fn answers_a_message_with_nothing_to_say_with_null() {
    let (mut client, _connection) = connected(files()).await;
    request(
        &client,
        "r1",
        "run.stop",
        json!({ "executionId": "exec-1" }),
    );
    assert_eq!(reply_result(next(&mut client).await), Value::Null);
}

#[tokio::test]
async fn delivers_events_only_to_a_client_subscribed_to_the_topic() {
    let (mut client, connection) = connected(files()).await;
    client
        .outgoing
        .send(ClientMessage::Subscribe {
            topic: topic("files.vault"),
            after: None,
        })
        .unwrap();
    // The subscription is made by the time a request that follows it is answered.
    request(&client, "r1", "fs.list", json!({ "path": "/" }));
    next(&mut client).await;
    connection.publish(&topic("files.vault"), json!({ "path": "a.md" }), None);
    connection.publish(&topic("files.work"), json!({ "path": "ignored" }), None);
    request(&client, "r2", "fs.list", json!({ "path": "/" }));
    let message = next(&mut client).await;
    assert_eq!(
        message,
        HostMessage::Event {
            topic: topic("files.vault"),
            cursor: None,
            data: json!({ "path": "a.md" })
        }
    );
    assert!(matches!(next(&mut client).await, HostMessage::Reply { .. }));
}

#[tokio::test]
async fn stops_delivering_after_the_client_unsubscribes() {
    let (mut client, connection) = connected(files()).await;
    client
        .outgoing
        .send(ClientMessage::Subscribe {
            topic: topic("files.vault"),
            after: None,
        })
        .unwrap();
    client
        .outgoing
        .send(ClientMessage::Unsubscribe {
            topic: topic("files.vault"),
        })
        .unwrap();
    request(&client, "r1", "fs.list", json!({ "path": "/" }));
    next(&mut client).await;
    assert!(!connection.watching(&topic("files.vault")));
    connection.publish(&topic("files.vault"), json!(1), None);
    request(&client, "r2", "fs.list", json!({ "path": "/" }));
    assert!(matches!(next(&mut client).await, HostMessage::Reply { .. }));
}

/// A host whose subscriptions count what they started and ended, and give one event with the cursor.
fn counting(started: Started, ended: Arc<AtomicUsize>) -> ServeOptions {
    let mut options = ServeOptions::new(files(), capabilities());
    options.subscribe = Some(Arc::new(move |topic, after, push| {
        started
            .lock()
            .unwrap()
            .push((topic.as_str().to_string(), after));
        push(json!("first"), Some(7));
        let ended = ended.clone();
        Box::pin(async move {
            let stop: Box<dyn FnOnce() + Send> = Box::new(move || {
                ended.fetch_add(1, Ordering::SeqCst);
            });
            stop
        })
    }));
    options
}

async fn settle() {
    tokio::time::sleep(Duration::from_millis(50)).await;
}

#[tokio::test]
async fn starts_a_subscription_for_the_first_subscribe_to_a_topic_and_ends_it_with_unsubscribe() {
    let started = Arc::new(Mutex::new(Vec::new()));
    let ended = Arc::new(AtomicUsize::new(0));
    let (mut client, host) = link_pair();
    serve(host, counting(started.clone(), ended.clone()));
    next(&mut client).await;
    let run = topic("run.exec-1");
    client
        .outgoing
        .send(ClientMessage::Subscribe {
            topic: run.clone(),
            after: Some(3),
        })
        .unwrap();
    client
        .outgoing
        .send(ClientMessage::Subscribe {
            topic: run.clone(),
            after: None,
        })
        .unwrap();
    assert_eq!(
        next(&mut client).await,
        HostMessage::Event {
            topic: run.clone(),
            cursor: Some(7),
            data: json!("first")
        }
    );
    settle().await;
    assert_eq!(
        *started.lock().unwrap(),
        vec![("run.exec-1".to_string(), Some(3))]
    );
    assert_eq!(ended.load(Ordering::SeqCst), 0);
    client
        .outgoing
        .send(ClientMessage::Unsubscribe { topic: run })
        .unwrap();
    settle().await;
    assert_eq!(ended.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn ends_what_it_started_when_the_connection_closes() {
    let started = Arc::new(Mutex::new(Vec::new()));
    let ended = Arc::new(AtomicUsize::new(0));
    let (mut client, host) = link_pair();
    serve(host, counting(started, ended.clone()));
    next(&mut client).await;
    client
        .outgoing
        .send(ClientMessage::Subscribe {
            topic: topic("files.work"),
            after: None,
        })
        .unwrap();
    client
        .outgoing
        .send(ClientMessage::Subscribe {
            topic: topic("files.vault"),
            after: None,
        })
        .unwrap();
    settle().await;
    drop(client);
    settle().await;
    assert_eq!(ended.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn carries_the_messages_of_a_stream_both_ways() {
    let received = Arc::new(Mutex::new(Vec::<(String, Map<String, Value>)>::new()));
    let (mut client, host) = link_pair();
    let mut options = ServeOptions::new(Handlers::new(), capabilities());
    let into = received.clone();
    options.on_stream = Some(Arc::new(move |session, data| {
        into.lock().unwrap().push((session, data))
    }));
    let connection = serve(host, options);
    next(&mut client).await;

    let mut typed = Map::new();
    typed.insert("type".into(), json!("input"));
    typed.insert("data".into(), json!("ls"));
    client
        .outgoing
        .send(ClientMessage::Stream {
            session: "t1".into(),
            data: typed.clone(),
        })
        .unwrap();
    let mut printed = Map::new();
    printed.insert("type".into(), json!("output"));
    printed.insert("data".into(), json!("a b"));
    connection.stream("t1", printed.clone());
    assert_eq!(
        next(&mut client).await,
        HostMessage::Stream {
            session: "t1".into(),
            data: printed
        }
    );
    settle().await;
    assert_eq!(*received.lock().unwrap(), vec![("t1".to_string(), typed)]);
}

#[tokio::test]
async fn does_not_let_a_client_subscribe_to_a_topic_it_may_not_watch() {
    let (mut client, host) = link_pair();
    let mut options = ServeOptions::new(files(), capabilities());
    options.may_watch = Some(Arc::new(|topic| topic.as_str() != "files.vault"));
    let connection = serve(host, options);
    next(&mut client).await;
    client
        .outgoing
        .send(ClientMessage::Subscribe {
            topic: topic("files.vault"),
            after: None,
        })
        .unwrap();
    request(&client, "r1", "fs.list", json!({ "path": "/" }));
    next(&mut client).await;
    assert!(!connection.watching(&topic("files.vault")));
}
