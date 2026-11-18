//! The types of the messages are read from the same example files as the Node host's, and written
//! back as they were: a field that is named differently, or is missing, or is added, fails here.

mod support;

use serde_json::{json, Value};
use support::{envelope, examples, same};
use synapse_desktop_host::messages::{roundtrip_params, roundtrip_result, NAMES};
use synapse_desktop_host::protocol::{ClientMessage, HostMessage, Topic};

#[test]
fn each_message_has_an_example_and_no_example_is_of_a_message_there_is_not() {
    let mut names: Vec<String> = examples().into_iter().map(|e| e.name).collect();
    names.sort();
    let mut known: Vec<String> = NAMES.iter().map(|n| n.to_string()).collect();
    known.sort();
    assert_eq!(names, known);
}

#[test]
fn the_parameters_and_result_of_each_example_are_read_as_their_types_and_written_back_alike() {
    for example in examples() {
        let params = roundtrip_params(&example.name, &example.params)
            .unwrap_or_else(|e| panic!("{} params: {e}", example.name));
        assert!(
            same(&params, &example.params),
            "{} params: wrote {params} for {}",
            example.name,
            example.params
        );
        let result = roundtrip_result(&example.name, &example.result)
            .unwrap_or_else(|e| panic!("{} result: {e}", example.name));
        assert!(
            same(&result, &example.result),
            "{} result: wrote {result} for {}",
            example.name,
            example.result
        );
    }
}

#[test]
fn a_parameter_of_the_wrong_kind_is_refused() {
    // The first member of each example, spoiled with a number and with a string: every type refuses
    // at least one of them.
    for example in examples() {
        let Value::Object(map) = &example.params else {
            continue;
        };
        // A member that is any JSON at all (`input`) has no wrong kind.
        let Some(first) = map.keys().find(|k| k.as_str() != "input") else {
            continue;
        };
        let refused = |spoil: Value| {
            let mut spoiled = map.clone();
            spoiled.insert(first.clone(), spoil);
            roundtrip_params(&example.name, &Value::Object(spoiled)).is_err()
        };
        assert!(
            refused(json!(42)) || refused(json!("x")),
            "{} accepted a number and a string as {first}",
            example.name
        );
    }
    assert!(roundtrip_params("fs.read", &json!({ "path": 5 })).is_err());
    assert!(roundtrip_params("fs.read", &json!(42)).is_err());
    assert!(roundtrip_params("no.such", &json!({})).is_err());
}

#[test]
fn a_result_of_another_message_is_refused() {
    let all = examples();
    let list = all.iter().find(|e| e.name == "fs.list").unwrap();
    assert!(roundtrip_result("fs.read", &list.result).is_err());
    assert!(roundtrip_result("fs.read", &Value::Null).is_err());
    // A message with nothing to say answers null, and none with something does.
    assert!(roundtrip_result("run.stop", &Value::Null).is_ok());
    assert!(roundtrip_result("run.stop", &json!(1)).is_err());
}

#[test]
fn a_client_message_of_each_kind_is_read_and_one_that_is_not_one_is_refused() {
    let envelope = envelope();
    for key in ["request", "subscribe"] {
        let text = envelope[key].to_string();
        let message = ClientMessage::parse(&text).unwrap_or_else(|| panic!("{key} is read"));
        assert!(
            same(&serde_json::to_value(message).unwrap(), &envelope[key]),
            "{key}"
        );
    }
    assert!(ClientMessage::parse(r#"{"kind":"unsubscribe","topic":"files.vault"}"#).is_some());
    assert!(
        ClientMessage::parse(r#"{"kind":"stream","session":"t1","data":{"type":"input"}}"#)
            .is_some()
    );
    assert!(ClientMessage::parse(r#"{"kind":"request","id":"","name":"x"}"#).is_none());
    assert!(ClientMessage::parse(r#"{"kind":"subscribe","topic":"files.etc"}"#).is_none());
    assert!(ClientMessage::parse(r#"{"kind":"launch"}"#).is_none());
    assert!(ClientMessage::parse("not json").is_none());
}

#[test]
fn a_host_message_of_each_kind_is_read_and_written_back_alike() {
    let envelope = envelope();
    for key in ["hello", "reply", "error", "event", "stream"] {
        let message: HostMessage =
            serde_json::from_value(envelope[key].clone()).unwrap_or_else(|e| panic!("{key}: {e}"));
        assert!(
            same(&serde_json::to_value(message).unwrap(), &envelope[key]),
            "{key}"
        );
    }
}

#[test]
fn a_reply_with_null_for_a_result_is_a_result() {
    let reply: HostMessage =
        serde_json::from_value(json!({ "kind": "reply", "id": "r", "result": null })).unwrap();
    let HostMessage::Reply { result, error, .. } = &reply else {
        panic!("not a reply")
    };
    assert_eq!(result, &Some(Value::Null));
    assert!(error.is_none());
    assert_eq!(
        serde_json::to_value(reply).unwrap(),
        json!({ "kind": "reply", "id": "r", "result": null })
    );
}

#[test]
fn the_topics_are_the_files_of_a_place_and_the_events_of_a_run() {
    for topic in [
        "files.work",
        "files.definitions",
        "files.vault",
        "run.exec-1a2b",
    ] {
        assert!(Topic::parse(topic).is_some(), "{topic}");
    }
    for topic in ["files.root", "run.", "run.a b", "anything", ""] {
        assert!(Topic::parse(topic).is_none(), "{topic}");
    }
}
