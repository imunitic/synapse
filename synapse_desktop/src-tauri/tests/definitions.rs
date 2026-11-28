//! Definitions: a draft that is not saved is looked at among a throwaway copy of the definitions, and a
//! definition is written where definitions live. The same cases as the Node host's `preview.test.ts`
//! and `sandbox.test.ts`.

mod support;

use serde_json::json;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use support::{environment, Host};
use synapse_desktop_host::cli::{CliRun, CliRunner};
use synapse_desktop_host::definitions::{build_sandbox, preview_draft, SandboxInput};
use synapse_desktop_host::messages::{AppConfig, CliResult, DefinitionDraftKind, DraftDefinition};
use synapse_desktop_host::protocol::ErrorCode;
use tempfile::tempdir;

fn config() -> AppConfig {
    AppConfig {
        work_dir: None,
        definition_paths: vec![],
        default_harness: None,
        default_models: BTreeMap::new(),
        default_efforts: BTreeMap::new(),
        env: BTreeMap::new(),
        recent_vaults: vec![],
        terminal_folder: None,
        graph_repos: BTreeMap::new(),
    }
}

fn names(dir: &Path) -> Vec<String> {
    let mut found: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    found.sort();
    found
}

// ---------------------------------------------------------------------------------------------
// The throwaway copy
// ---------------------------------------------------------------------------------------------

struct Real {
    dir: tempfile::TempDir,
    real: PathBuf,
    other: PathBuf,
}

fn real() -> Real {
    let dir = tempdir().unwrap();
    let real = dir.path().join("real");
    let other = dir.path().join("other");
    fs::create_dir_all(&real).unwrap();
    fs::create_dir_all(&other).unwrap();
    fs::write(
        real.join("Reviewer.synapse"),
        "Agent Reviewer [Prompt => \"r\"];",
    )
    .unwrap();
    fs::write(real.join("Dev.synapse"), "Pipeline Dev { old }").unwrap();
    fs::write(real.join("notes.txt"), "not a definition").unwrap();
    fs::write(
        other.join("Elsewhere.synapse"),
        "Agent Elsewhere [Prompt => \"e\"];",
    )
    .unwrap();
    Real { dir, real, other }
}

#[test]
fn the_copy_has_the_definitions_and_the_draft_among_them() {
    let w = real();
    let (sandbox, others) = build_sandbox(&SandboxInput {
        default_dir: &w.real,
        other_dirs: std::slice::from_ref(&w.other),
        draft: ("New", "Pipeline New {}"),
        extra: None,
    })
    .unwrap();
    let env = sandbox.env(&others);
    let copy = Path::new(&env["XDG_CONFIG_HOME"]).join("synapse-pipeline");
    assert_eq!(
        names(&copy),
        ["Dev.synapse", "New.synapse", "Reviewer.synapse"]
    );
    assert_eq!(
        fs::read_to_string(copy.join("New.synapse")).unwrap(),
        "Pipeline New {}"
    );
    assert_eq!(
        names(Path::new(&env["SYNAPSE_PIPELINE_PATH"])),
        ["Elsewhere.synapse"]
    );
}

#[test]
fn the_draft_replaces_the_file_of_its_name_and_nothing_real_is_changed() {
    let w = real();
    let (sandbox, others) = build_sandbox(&SandboxInput {
        default_dir: &w.real,
        other_dirs: &[],
        draft: ("Dev", "Pipeline Dev { new }"),
        extra: None,
    })
    .unwrap();
    let copy = Path::new(&sandbox.env(&others)["XDG_CONFIG_HOME"]).join("synapse-pipeline");
    assert_eq!(
        fs::read_to_string(copy.join("Dev.synapse")).unwrap(),
        "Pipeline Dev { new }"
    );
    assert_eq!(
        fs::read_to_string(w.real.join("Dev.synapse")).unwrap(),
        "Pipeline Dev { old }"
    );
}

#[test]
fn the_copy_holds_only_the_definition_files_with_no_skills_folder_beside_them() {
    let w = real();
    fs::create_dir_all(w.real.join("skills/review-code")).unwrap();
    fs::write(w.real.join("skills/review-code/SKILL.md"), "skill text").unwrap();
    let (sandbox, others) = build_sandbox(&SandboxInput {
        default_dir: &w.real,
        other_dirs: &[],
        draft: ("New", "x"),
        extra: None,
    })
    .unwrap();
    let copy = Path::new(&sandbox.env(&others)["XDG_CONFIG_HOME"]).join("synapse-pipeline");
    assert_eq!(
        names(&copy),
        ["Dev.synapse", "New.synapse", "Reviewer.synapse"]
    );
}

#[test]
fn an_extra_file_goes_beside_the_draft_and_a_folder_that_is_not_there_has_none() {
    let w = real();
    let (sandbox, others) = build_sandbox(&SandboxInput {
        default_dir: &w.dir.path().join("missing"),
        other_dirs: &[w.dir.path().join("also-missing")],
        draft: ("Agent_One", "Agent Agent_One [Prompt => \"x\"];"),
        extra: Some(("Probe", "Pipeline Probe {}")),
    })
    .unwrap();
    let copy = Path::new(&sandbox.env(&others)["XDG_CONFIG_HOME"]).join("synapse-pipeline");
    assert_eq!(names(&copy), ["Agent_One.synapse", "Probe.synapse"]);
}

#[test]
fn the_copy_is_removed_when_it_is_dropped() {
    let w = real();
    let (sandbox, _) = build_sandbox(&SandboxInput {
        default_dir: &w.real,
        other_dirs: &[],
        draft: ("New", "x"),
        extra: None,
    })
    .unwrap();
    let root = sandbox.path().to_path_buf();
    assert!(root.is_dir());
    drop(sandbox);
    assert!(!root.exists());
}

// ---------------------------------------------------------------------------------------------
// Looking at a draft
// ---------------------------------------------------------------------------------------------

struct Seen {
    run: CliRun,
    files: Vec<String>,
    draft: Option<String>,
}

fn world() -> (tempfile::TempDir, PathBuf) {
    let dir = tempdir().unwrap();
    let defaults = dir.path().join("xdg").join("synapse-pipeline");
    fs::create_dir_all(&defaults).unwrap();
    fs::write(
        defaults.join("Reviewer.synapse"),
        "Agent Reviewer [Prompt => \"r\"];",
    )
    .unwrap();
    (dir, defaults)
}

/// A program that looks at what it would see while it is asked.
fn looking() -> (CliRunner, Arc<Mutex<Vec<Seen>>>) {
    let seen = Arc::new(Mutex::new(Vec::<Seen>::new()));
    let kept = seen.clone();
    let runner = CliRunner::new(move |run: CliRun| {
        let copy = Path::new(&run.env["XDG_CONFIG_HOME"]).join("synapse-pipeline");
        let name = run.args.get(1).cloned().unwrap_or_default();
        kept.lock().unwrap().push(Seen {
            files: names(&copy),
            draft: fs::read_to_string(copy.join(format!("{name}.synapse"))).ok(),
            run: run.clone(),
        });
        async {
            Ok(CliResult {
                code: 0,
                stdout: "{}".into(),
                stderr: String::new(),
            })
        }
    });
    (runner, seen)
}

fn draft(kind: DefinitionDraftKind, name: &str, text: &str) -> DraftDefinition {
    DraftDefinition {
        kind,
        name: name.into(),
        text: text.into(),
    }
}

#[tokio::test]
async fn a_pipeline_is_described_among_a_copy_of_the_definitions() {
    let (dir, _) = world();
    let env = environment(
        dir.path(),
        &[("XDG_CONFIG_HOME", &dir.path().join("xdg").to_string_lossy())],
    );
    let (runner, seen) = looking();
    preview_draft(
        &draft(
            DefinitionDraftKind::Pipeline,
            "New_One",
            "Pipeline New_One {}",
        ),
        &config(),
        &env,
        &runner,
        config(),
    )
    .await
    .unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].run.args, ["show", "New_One", "--format", "json"]);
    assert_eq!(seen[0].files, ["New_One.synapse", "Reviewer.synapse"]);
    assert_eq!(seen[0].draft.as_deref(), Some("Pipeline New_One {}"));
}

#[tokio::test]
async fn the_program_is_pointed_at_the_copy_only_and_the_copy_is_removed_after() {
    let (dir, defaults) = world();
    let real_xdg = dir.path().join("xdg");
    let env = environment(
        dir.path(),
        &[("XDG_CONFIG_HOME", &real_xdg.to_string_lossy())],
    );
    let (runner, seen) = looking();
    preview_draft(
        &draft(DefinitionDraftKind::Pipeline, "P", "x"),
        &config(),
        &env,
        &runner,
        config(),
    )
    .await
    .unwrap();
    let seen = seen.lock().unwrap();
    let copy = &seen[0].run.env["XDG_CONFIG_HOME"];
    assert_ne!(Path::new(copy), real_xdg);
    assert!(copy.contains("synapse-desktop-draft-"));
    assert_eq!(seen[0].run.config.work_dir, None);
    assert!(seen[0].run.config.definition_paths.is_empty());
    // Removed once the program has answered, and the real files are as they were.
    assert!(!Path::new(copy).exists());
    assert_eq!(names(&defaults), ["Reviewer.synapse"]);
}

#[tokio::test]
async fn a_pipeline_that_stands_for_the_others_is_checked_when_the_draft_is_a_system_or_an_agent() {
    let (dir, _) = world();
    let env = environment(
        dir.path(),
        &[("XDG_CONFIG_HOME", &dir.path().join("xdg").to_string_lossy())],
    );
    let (runner, seen) = looking();
    preview_draft(
        &draft(
            DefinitionDraftKind::Agent,
            "Tester",
            "Agent Tester [Prompt => ];",
        ),
        &config(),
        &env,
        &runner,
        config(),
    )
    .await
    .unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].run.args[0], "check");
    let probe = &seen[0].run.args[1];
    assert!(
        regex::Regex::new(r"^Draft_Probe_[0-9a-f]{6}$")
            .unwrap()
            .is_match(probe),
        "{probe}"
    );
    assert!(seen[0].files.contains(&"Tester.synapse".to_string()));
    assert!(seen[0].files.iter().any(|f| f.starts_with("Draft_Probe_")));
}

// ---------------------------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------------------------

async fn host(dir: &Path) -> Host {
    Host::new(
        environment(
            dir,
            &[("XDG_CONFIG_HOME", &dir.join("xdg").to_string_lossy())],
        ),
        &dir.join("config.json"),
    )
    .await
}

#[tokio::test]
async fn a_preview_through_the_host_asks_the_program_and_refuses_a_name_that_could_name_a_path() {
    let (dir, _) = world();
    let mut host = host(dir.path()).await;
    let ok = host
        .ask(
            "definition.preview",
            json!({ "draft": { "kind": "pipeline", "name": "P", "text": "x" } }),
        )
        .await
        .unwrap();
    assert_eq!(ok, json!({ "code": 0, "stdout": "ok", "stderr": "" }));
    assert_eq!(host.calls.lock().unwrap().len(), 1);
    for name in ["../x", "a b", "", "1abc", "a/b"] {
        let error = host
            .ask(
                "definition.preview",
                json!({ "draft": { "kind": "pipeline", "name": name, "text": "x" } }),
            )
            .await
            .unwrap_err();
        assert_eq!(error.0, ErrorCode::BadRequest, "{name:?}");
        assert!(error.1.contains("invalid parameters"));
    }
    assert_eq!(host.calls.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn a_definition_is_made_in_the_default_folder_and_never_replaces_a_file() {
    let (dir, defaults) = world();
    let mut host = host(dir.path()).await;
    let made = host
        .ask("definition.write", json!({ "mode": "create", "kind": "definition", "name": "Fresh", "text": "Agent Fresh [Prompt => \"x\"];" }))
        .await
        .unwrap();
    assert_eq!(
        made,
        json!({ "path": defaults.join("Fresh.synapse").to_string_lossy() })
    );
    assert_eq!(
        fs::read_to_string(defaults.join("Fresh.synapse")).unwrap(),
        "Agent Fresh [Prompt => \"x\"];"
    );

    let taken = host
        .ask(
            "definition.write",
            json!({ "mode": "create", "kind": "definition", "name": "Reviewer", "text": "x" }),
        )
        .await
        .unwrap_err();
    assert_eq!(taken.0, ErrorCode::Conflict);
    assert_eq!(
        fs::read_to_string(defaults.join("Reviewer.synapse")).unwrap(),
        "Agent Reviewer [Prompt => \"r\"];"
    );
}

#[tokio::test]
async fn a_prompt_is_made_as_a_definition_file_and_the_kind_skill_is_refused() {
    let (dir, defaults) = world();
    let mut host = host(dir.path()).await;
    let text = "Prompt Do_It [Description => \"Does it.\", Prompt => \"Do it.\"];\n";
    let made = host
        .ask(
            "definition.write",
            json!({ "mode": "create", "kind": "definition", "name": "Do_It", "text": text }),
        )
        .await
        .unwrap();
    assert_eq!(
        made,
        json!({ "path": defaults.join("Do_It.synapse").to_string_lossy() })
    );
    assert_eq!(
        fs::read_to_string(defaults.join("Do_It.synapse")).unwrap(),
        text
    );
    let skill = host
        .ask(
            "definition.write",
            json!({ "mode": "create", "kind": "skill", "name": "do-it", "text": "x" }),
        )
        .await
        .unwrap_err();
    assert_eq!(skill.0, ErrorCode::BadRequest);
    assert!(!defaults.join("skills").exists());
}

#[tokio::test]
async fn names_that_are_not_the_form_of_a_definition_are_refused_so_that_none_can_name_a_path() {
    let (dir, defaults) = world();
    let mut host = host(dir.path()).await;
    let bad = [
        ("definition", "../escape"),
        ("definition", "has space"),
        ("definition", "-a"),
    ];
    for (kind, name) in bad {
        let error = host
            .ask(
                "definition.write",
                json!({ "mode": "create", "kind": kind, "name": name, "text": "x" }),
            )
            .await
            .unwrap_err();
        assert_eq!(error.0, ErrorCode::BadRequest, "{kind} {name}");
    }
    assert_eq!(names(&defaults), ["Reviewer.synapse"]);
}

fn put(dir: &Path, sub: &str, name: &str, text: &str) -> String {
    let folder = dir.join(sub);
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join(name), text).unwrap();
    folder.join(name).to_string_lossy().to_string()
}

#[tokio::test]
async fn the_text_of_a_definition_is_replaced_when_the_file_is_as_it_was_read() {
    let (dir, _) = world();
    let mut host = host(dir.path()).await;
    let path = put(
        dir.path(),
        "xdg/synapse-pipeline",
        "Old.synapse",
        "Agent Old [Prompt => \"a\"];",
    );
    host.ask(
        "definition.write",
        json!({ "mode": "replace", "path": path, "previous": "Agent Old [Prompt => \"a\"];", "text": "Agent Old [Prompt => \"b\"];" }),
    )
    .await
    .unwrap();
    assert_eq!(
        fs::read_to_string(&path).unwrap(),
        "Agent Old [Prompt => \"b\"];"
    );
}

#[tokio::test]
async fn it_is_refused_when_the_file_has_changed_since_it_was_read() {
    let (dir, _) = world();
    let mut host = host(dir.path()).await;
    let path = put(
        dir.path(),
        "xdg/synapse-pipeline",
        "Old.synapse",
        "changed elsewhere",
    );
    let error = host
        .ask(
            "definition.write",
            json!({ "mode": "replace", "path": path, "previous": "what was read", "text": "x" }),
        )
        .await
        .unwrap_err();
    assert_eq!(error.0, ErrorCode::Conflict);
    assert_eq!(fs::read_to_string(&path).unwrap(), "changed elsewhere");
}

#[tokio::test]
async fn a_skill_file_is_not_saved_nor_anything_else_nor_anything_outside_the_folders() {
    let (dir, _) = world();
    let mut host = host(dir.path()).await;
    let skill = put(
        dir.path(),
        "xdg/synapse-pipeline/skills/a-skill",
        "SKILL.md",
        "one",
    );
    let error = host
        .ask(
            "definition.write",
            json!({ "mode": "replace", "path": skill, "previous": "one", "text": "two" }),
        )
        .await
        .unwrap_err();
    assert_eq!(error.0, ErrorCode::BadRequest);
    assert_eq!(fs::read_to_string(&skill).unwrap(), "one");

    // Not a definition: a file of the records of a run, or any other.
    let other = put(dir.path(), "xdg/synapse-pipeline", "notes.txt", "x");
    let error = host
        .ask(
            "definition.write",
            json!({ "mode": "replace", "path": other, "previous": "x", "text": "y" }),
        )
        .await
        .unwrap_err();
    assert_eq!(error.0, ErrorCode::BadRequest);

    // A definition file where definitions do not live.
    let outside = put(dir.path(), "elsewhere", "Evil.synapse", "x");
    let error = host
        .ask(
            "definition.write",
            json!({ "mode": "replace", "path": outside, "previous": "x", "text": "y" }),
        )
        .await
        .unwrap_err();
    assert_eq!(error.0, ErrorCode::Forbidden);
    assert_eq!(fs::read_to_string(&outside).unwrap(), "x");
}

#[tokio::test]
async fn a_definition_file_is_removed_and_a_skill_file_is_not() {
    let (dir, _) = world();
    let mut host = host(dir.path()).await;
    let old = put(dir.path(), "xdg/synapse-pipeline", "Old.synapse", "x");
    let kept = put(dir.path(), "xdg/synapse-pipeline", "Kept.synapse", "y");
    host.ask("definition.write", json!({ "mode": "delete", "path": old }))
        .await
        .unwrap();
    assert!(!Path::new(&old).exists());
    assert!(Path::new(&kept).exists());

    let skill = put(
        dir.path(),
        "xdg/synapse-pipeline/skills/a-skill",
        "SKILL.md",
        "one",
    );
    let error = host
        .ask(
            "definition.write",
            json!({ "mode": "delete", "path": skill }),
        )
        .await
        .unwrap_err();
    assert_eq!(error.0, ErrorCode::BadRequest);
    assert_eq!(fs::read_to_string(&skill).unwrap(), "one");
}

#[tokio::test]
async fn only_a_definition_where_definitions_live_is_removed() {
    let (dir, _) = world();
    let mut host = host(dir.path()).await;

    let stray = put(
        dir.path(),
        "xdg/synapse-pipeline/not-skills/a-skill",
        "SKILL.md",
        "one",
    );
    let error = host
        .ask(
            "definition.write",
            json!({ "mode": "delete", "path": stray }),
        )
        .await
        .unwrap_err();
    assert_eq!(error.0, ErrorCode::BadRequest);

    let other = put(dir.path(), "xdg/synapse-pipeline", "notes.txt", "x");
    let error = host
        .ask(
            "definition.write",
            json!({ "mode": "delete", "path": other }),
        )
        .await
        .unwrap_err();
    assert_eq!(error.0, ErrorCode::BadRequest);

    let outside = put(dir.path(), "elsewhere", "Evil.synapse", "x");
    let error = host
        .ask(
            "definition.write",
            json!({ "mode": "delete", "path": outside }),
        )
        .await
        .unwrap_err();
    assert_eq!(error.0, ErrorCode::Forbidden);

    for path in [&stray, &other, &outside] {
        assert!(Path::new(path).exists());
    }
}
