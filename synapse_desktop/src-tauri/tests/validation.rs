//! The rules of the parameters beyond their types, as the Node host's schemas have them: a request that
//! breaks one is refused before its handler sees it. Each case starts from the shared example of its
//! message and changes one member.

mod support;

use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::Path;
use support::examples;
use synapse_desktop_host::config::{load_stored, merged};
use synapse_desktop_host::messages::{check_params, AppConfigPatch, Harness};
use synapse_desktop_host::protocol::Topic;

fn example(name: &str) -> Value {
    examples()
        .into_iter()
        .find(|e| e.name == name)
        .unwrap()
        .params
}

/// The example of `name` with `member` set, which a rule refuses.
fn refused(name: &str, member: &str, value: Value) {
    let mut params = example(name);
    params[member] = value.clone();
    assert!(
        check_params(name, &params).is_err(),
        "{name}.{member} = {value} was accepted"
    );
}

fn allowed(name: &str, member: &str, value: Value) {
    let mut params = example(name);
    params[member] = value.clone();
    assert!(
        check_params(name, &params).is_ok(),
        "{name}.{member} = {value} was refused"
    );
}

#[test]
fn every_example_keeps_to_the_rules() {
    for example in examples() {
        assert_eq!(
            check_params(&example.name, &example.params),
            Ok(()),
            "{}",
            example.name
        );
    }
}

#[test]
fn the_names_of_a_definition_a_run_and_a_graph_are_of_the_form_a_path_cannot_be_made_of() {
    for name in ["../x", "a b", "", "1abc", "a/b"] {
        let draft = json!({ "kind": "pipeline", "name": name, "text": "x" });
        refused("definition.preview", "draft", draft);
    }
    for name in ["../escape", "has space"] {
        let item = json!({ "mode": "create", "kind": "definition", "name": name, "text": "x" });
        assert!(check_params("definition.write", &item).is_err(), "{name}");
    }
    // A skill is no definition: the kind is not known.
    let skill = json!({ "mode": "create", "kind": "skill", "name": "do-it", "text": "x" });
    assert!(check_params("definition.write", &skill).is_err());
    allowed("run.stop", "executionId", json!("exec-0a1b2c3d"));
    for id in ["../x", "", "a b", "x".repeat(65).as_str()] {
        refused("run.stop", "executionId", json!(id));
    }
    refused("run.start", "pipeline", json!("1Bad"));
    refused("run.start", "pipeline", json!("has space"));
    for namespace in ["../x@main", "a@b/c", "a@", "@b", "nobranch"] {
        refused("graph.health", "namespace", json!(namespace));
    }
    allowed("graph.health", "namespace", json!("synapse@main"));
}

#[test]
fn a_long_text_a_long_prompt_and_an_empty_one_are_refused() {
    let long = "x".repeat(200_001);
    let edit = |prompt: &str| json!({ "kind": "note-edit", "path": "a.md", "prompt": prompt });
    assert!(check_params("agent.run", &edit("")).is_err());
    assert!(check_params("agent.run", &edit(&"x".repeat(20_001))).is_err());
    assert!(check_params("agent.run", &edit("fix it")).is_ok());
    refused("note.restore", "before", json!(long));
    refused("note.restore", "path", json!(""));
    refused(
        "definition.preview",
        "draft",
        json!({ "kind": "pipeline", "name": "P", "text": long }),
    );
}

#[test]
fn a_model_that_a_command_line_could_take_for_a_flag_is_refused() {
    let note =
        |model: &str| json!({ "kind": "note", "what": "note", "prompt": "x", "model": model });
    for model in ["--dangerously-skip-permissions", "-m", "a b", "a;b"] {
        assert!(check_params("agent.run", &note(model)).is_err(), "{model}");
    }
    assert!(check_params("agent.run", &note("sonnet[1m]")).is_ok());
}

#[test]
fn a_codex_default_of_extreme_is_refused() {
    let stored = load_stored(Path::new("/no/such/config.json")).unwrap();
    let patch = |harness: Harness, effort: &str| AppConfigPatch {
        default_efforts: Some(BTreeMap::from([(harness, effort.to_string())])),
        ..AppConfigPatch::default()
    };
    let refused = merged(
        stored.clone(),
        patch(Harness::Codex, "extreme"),
        Path::new("/h"),
    );
    assert!(refused
        .unwrap_err()
        .message
        .contains("Codex does not offer effort 'extreme'"));
    let kept = merged(stored, patch(Harness::Codex, "minimal"), Path::new("/h")).unwrap();
    assert_eq!(kept.default_efforts[&Harness::Codex], "minimal");
}

#[test]
fn a_request_effort_that_is_not_a_variant_name_is_refused() {
    let note =
        |effort: &str| json!({ "kind": "note", "what": "note", "prompt": "x", "effort": effort });
    for effort in ["--effort", "-high", "a#b", "a b", ""] {
        assert!(
            check_params("agent.run", &note(effort)).is_err(),
            "{effort:?}"
        );
    }
    assert!(check_params("agent.run", &note("high")).is_ok());
}

#[test]
fn the_lists_of_a_generation_request_are_held_to_a_thousand() {
    let many: Vec<Value> = (0..1001)
        .map(|i| json!({ "name": format!("D{i}"), "kind": "agent" }))
        .collect();
    let request = json!({
        "kind": "definition", "what": "pipeline", "prompt": "x", "definitions": many,
    });
    assert!(check_params("agent.run", &request).is_err());
    let bad_name = json!({
        "kind": "definition", "what": "prompt", "prompt": "x",
        "definitions": [{ "name": "Bad Name", "kind": "prompt" }],
    });
    assert!(check_params("agent.run", &bad_name).is_err());
}

fn run_input(pipeline: &str, prompt: &str) -> Value {
    json!({ "kind": "run-input", "pipeline": pipeline, "prompt": prompt })
}

#[test]
fn a_run_input_request_with_a_bad_pipeline_name_is_refused() {
    for name in ["Bad Name", "", "../x", "a/b"] {
        assert!(
            check_params("agent.run", &run_input(name, "p")).is_err(),
            "{name}"
        );
    }
}

#[test]
fn an_empty_prompt_of_a_run_input_request_is_refused() {
    assert!(check_params("agent.run", &run_input("Implement", "")).is_err());
    assert!(check_params("agent.run", &run_input("Implement", &"x".repeat(20_001))).is_err());
}

#[test]
fn a_run_id_with_a_slash_in_a_run_input_request_is_refused() {
    let mut request = run_input("Implement", "p");
    request["run"] = json!("a/b");
    assert!(check_params("agent.run", &request).is_err());
}

#[test]
fn current_json_over_the_draft_limit_in_a_run_input_request_is_refused() {
    let mut request = run_input("Implement", "p");
    request["current"] = json!("x".repeat(200_001));
    assert!(check_params("agent.run", &request).is_err());
}

#[test]
fn a_valid_run_input_request_passes() {
    let request = json!({
        "kind": "run-input", "pipeline": "Implement", "prompt": "the design note about cloning",
        "harness": "Claude", "model": "sonnet", "current": "{}", "run": "abc_1",
    });
    assert!(check_params("agent.run", &request).is_ok());
    assert!(check_params("agent.run", &run_input("Implement", "p")).is_ok());
}

#[test]
fn the_registries_the_vault_folders_and_the_terminals_have_their_limits() {
    refused("registry.add", "entry", json!("x".repeat(1001)));
    refused("registry.add", "id", json!(""));
    refused("vault.inspect", "path", json!(""));
    refused("vault.seed", "path", json!("x".repeat(4097)));
    refused("terminal.start", "session", json!("has space"));
    refused("terminal.start", "title", json!(""));
    refused("terminal.start", "cols", json!(0));
    refused("terminal.start", "rows", json!(1001));
    refused(
        "terminal.start",
        "resume",
        json!("--dangerously-skip-permissions"),
    );
    refused("terminal.attach", "session", json!(""));
    refused("terminal.close", "session", json!("../x"));
    allowed("terminal.start", "resume", json!("abc-123"));
}

#[test]
fn a_run_name_is_1_to_480_bytes_with_no_nul() {
    for message in ["run.start", "terminal.start"] {
        allowed(message, "runName", json!("Fix login"));
        allowed(message, "runName", json!("x".repeat(480)));
        refused(message, "runName", json!(""));
        refused(message, "runName", json!("x".repeat(481)));
        refused(message, "runName", json!("a\u{0}b"));
    }
}

#[test]
fn a_snapshot_must_be_a_tree_id_so_that_it_can_never_be_taken_for_an_option() {
    let tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
    let diff = |before: &str| json!({ "folder": "/work/widget", "before": before });
    assert!(check_params("changes.diff", &diff(tree)).is_ok());
    assert!(check_params("changes.diff", &diff(&"a".repeat(64))).is_ok());
    for before in ["--stat", "HEAD", "", &tree.to_uppercase(), &"a".repeat(41)] {
        assert!(
            check_params("changes.diff", &diff(before)).is_err(),
            "{before}"
        );
    }
    refused("changes.snapshot", "folder", json!(""));
    refused("changes.diff", "path", json!(""));
}

#[test]
fn a_run_id_of_an_agent_run_is_the_form_of_a_run_name_and_a_stop_needs_one() {
    let kinds = [
        json!({ "kind": "definition", "what": "pipeline", "prompt": "x", "definitions": [] }),
        json!({ "kind": "note", "what": "note", "prompt": "x" }),
        json!({ "kind": "note-edit", "path": "a.md", "prompt": "x" }),
        json!({ "kind": "run-input", "pipeline": "Implement", "prompt": "x" }),
    ];
    for kind in kinds {
        let with = |run: Value| {
            let mut params = kind.clone();
            params["run"] = run;
            params
        };
        assert!(check_params("agent.run", &with(json!("abc_1-2"))).is_ok());
        assert!(check_params("agent.run", &kind).is_ok());
        for id in ["a/b", "", "x".repeat(65).as_str()] {
            assert!(check_params("agent.run", &with(json!(id))).is_err(), "{id}");
        }
    }
    allowed("agent.stop", "run", json!("abc_1"));
    for id in ["a/b", "", "x".repeat(65).as_str()] {
        refused("agent.stop", "run", json!(id));
    }
    assert!(check_params("agent.stop", &json!({})).is_err());
}

#[test]
fn the_topic_of_the_lines_of_an_agent_run_names_a_run_id() {
    assert!(Topic::parse("note-run.abc_1").is_some());
    let long = format!("note-run.{}", "x".repeat(65));
    for topic in ["note-run.", "note-run.a/b", "note-run.a b", long.as_str()] {
        assert!(Topic::parse(topic).is_none(), "{topic}");
    }
}
