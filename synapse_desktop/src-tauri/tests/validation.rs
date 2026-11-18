//! The rules of the parameters beyond their types, as the Node host's schemas have them: a request that
//! breaks one is refused before its handler sees it. Each case starts from the shared example of its
//! message and changes one member.

mod support;

use serde_json::{json, Value};
use support::examples;
use synapse_desktop_host::messages::check_params;

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
fn the_names_of_a_definition_a_skill_a_run_and_a_graph_are_of_the_form_a_path_cannot_be_made_of() {
    for name in ["../x", "a b", "", "1abc", "a/b"] {
        let draft = json!({ "kind": "pipeline", "name": name, "text": "x" });
        refused("definition.preview", "draft", draft);
    }
    for name in ["../escape", "has space"] {
        let item = json!({ "mode": "create", "kind": "definition", "name": name, "text": "x" });
        assert!(check_params("definition.write", &item).is_err(), "{name}");
    }
    for name in ["Upper", "../x", "a--b", "-a"] {
        let item = json!({ "mode": "create", "kind": "skill", "name": name, "text": "x" });
        assert!(check_params("definition.write", &item).is_err(), "{name}");
    }
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
fn the_lists_of_a_generation_request_are_held_to_a_thousand() {
    let many: Vec<Value> = (0..1001)
        .map(|i| json!({ "name": format!("D{i}"), "kind": "agent" }))
        .collect();
    let request = json!({
        "kind": "definition", "what": "pipeline", "prompt": "x", "definitions": many, "skills": [],
    });
    assert!(check_params("agent.run", &request).is_err());
    let bad_skill = json!({
        "kind": "definition", "what": "pipeline", "prompt": "x", "definitions": [], "skills": ["Bad Skill"],
    });
    assert!(check_params("agent.run", &bad_skill).is_err());
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
