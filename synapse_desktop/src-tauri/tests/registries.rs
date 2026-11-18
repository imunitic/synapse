//! The projects and the conventions: the files Synapse keeps in the user's configuration directory.

mod support;

use serde_json::json;
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use support::environment;
use synapse_desktop_host::cli::{CliRun, CliRunner};
use synapse_desktop_host::environment::Environment;
use synapse_desktop_host::messages::{AppConfig, CliResult, ProjectList};
use synapse_desktop_host::messages::{Convention, ConventionEntry, ConventionGroup, Project};
use synapse_desktop_host::protocol::ErrorCode;
use synapse_desktop_host::registries::{
    add_convention, add_project, list_conventions, parse_json, parse_lines, remove_convention,
};
use synapse_desktop_host::registries::{load_projects, split_project, Projects};
use tempfile::{tempdir, TempDir};

fn none() -> Projects {
    Err("synapse projects is not used here".into())
}

fn project(name: &str, prefix: &str) -> Project {
    Project {
        name: name.into(),
        prefix: prefix.into(),
    }
}

fn entry(text: &str) -> ConventionEntry {
    ConventionEntry {
        text: text.into(),
        detail: None,
    }
}

// ---------------------------------------------------------------------------------------------
// The projects, as `synapse projects` says them
// ---------------------------------------------------------------------------------------------

type Calls = Arc<Mutex<Vec<Vec<String>>>>;

/// A program that answers each call with the next of `results`, and keeps what it was asked.
fn program(results: Vec<CliResult>) -> (CliRunner, Calls) {
    let calls: Calls = Arc::new(Mutex::new(vec![]));
    let kept = calls.clone();
    let queue = Arc::new(Mutex::new(
        results
            .into_iter()
            .collect::<std::collections::VecDeque<_>>(),
    ));
    let runner = CliRunner::new(move |run: CliRun| {
        kept.lock().unwrap().push(run.args.clone());
        let next = queue.lock().unwrap().pop_front();
        async move {
            Ok(next.unwrap_or(CliResult {
                code: 0,
                stdout: String::new(),
                stderr: String::new(),
            }))
        }
    });
    (runner, calls)
}

fn config() -> AppConfig {
    AppConfig {
        work_dir: None,
        definition_paths: vec![],
        default_harness: None,
        default_models: BTreeMap::new(),
        env: BTreeMap::new(),
        recent_vaults: vec![],
        terminal_folder: None,
        graph_repos: BTreeMap::new(),
    }
}

fn listing(file: Option<&str>, projects: serde_json::Value) -> CliResult {
    CliResult {
        code: 0,
        stdout: json!({ "format": "synapse-projects/v1", "file": file, "projects": projects })
            .to_string(),
        stderr: String::new(),
    }
}

fn said(code: i32, stdout: &str, stderr: &str) -> CliResult {
    CliResult {
        code,
        stdout: stdout.into(),
        stderr: stderr.into(),
    }
}

#[tokio::test]
async fn the_projects_are_asked_of_synapse_as_json_with_the_file_they_are_in() {
    let (runner, calls) = program(vec![listing(
        Some("/c/synapse-projects.conf"),
        json!([{ "name": "synapse", "prefix": "sb" }]),
    )]);
    let list = load_projects(&runner, &config()).await.unwrap();
    assert_eq!(list.projects, vec![project("synapse", "sb")]);
    assert_eq!(list.file, "/c/synapse-projects.conf");
    assert_eq!(
        calls.lock().unwrap()[0],
        vec!["projects", "--format", "json"]
    );
}

#[tokio::test]
async fn there_is_no_file_named_when_there_is_no_home_to_put_one_in() {
    let (runner, _) = program(vec![listing(None, json!([]))]);
    let list = load_projects(&runner, &config()).await.unwrap();
    assert_eq!((list.projects.len(), list.file.as_str()), (0, ""));
}

#[tokio::test]
async fn a_synapse_that_fails_or_answers_oddly_is_a_failure_of_what_the_host_depends_on() {
    let (runner, _) = program(vec![said(
        1,
        "",
        "synapse: unknown subcommand 'projects'\n",
    )]);
    let error = load_projects(&runner, &config()).await.unwrap_err();
    assert_eq!(error.code, ErrorCode::Unavailable);
    assert_eq!(error.message, "synapse: unknown subcommand 'projects'");

    let (text, _) = program(vec![said(0, "not json", "")]);
    assert_eq!(
        load_projects(&text, &config()).await.unwrap_err().code,
        ErrorCode::Unavailable
    );
    let (other, _) = program(vec![said(
        0,
        &json!({ "format": "synapse-projects/v2", "file": null, "projects": [] }).to_string(),
        "",
    )]);
    assert!(load_projects(&other, &config())
        .await
        .unwrap_err()
        .message
        .contains("does not know"));
}

#[tokio::test]
async fn a_project_is_added_through_synapse_which_checks_it_and_the_projects_are_listed_after() {
    let (runner, calls) = program(vec![
        said(0, "/c/synapse-projects.conf\n", ""),
        listing(
            Some("/c/synapse-projects.conf"),
            json!([{ "name": "thing", "prefix": "tg" }]),
        ),
    ]);
    let list = add_project(&runner, &config(), "thing", "tg")
        .await
        .unwrap();
    assert_eq!(list.projects, vec![project("thing", "tg")]);
    let calls = calls.lock().unwrap();
    assert_eq!(calls[0], vec!["projects", "add", "thing", "tg"]);
    assert_eq!(calls.len(), 2);
}

#[tokio::test]
async fn a_refusal_is_what_synapse_said_without_its_name_in_front_and_nothing_is_listed_after() {
    let (runner, calls) = program(vec![said(
        1,
        "",
        "synapse-projects: thing is already a project, with the prefix tg.\n",
    )]);
    let error = add_project(&runner, &config(), "thing", "other")
        .await
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::Conflict);
    assert_eq!(
        error.message,
        "thing is already a project, with the prefix tg."
    );
    assert_eq!(calls.lock().unwrap().len(), 1);

    let (silent, _) = program(vec![said(1, "", "")]);
    assert_eq!(
        add_project(&silent, &config(), "a", "b")
            .await
            .unwrap_err()
            .message,
        "synapse projects failed"
    );
}

// ---------------------------------------------------------------------------------------------
// The conventions
// ---------------------------------------------------------------------------------------------

struct World {
    dir: TempDir,
    xdg: PathBuf,
}

impl World {
    fn new() -> World {
        let dir = tempdir().unwrap();
        let xdg = dir.path().join("xdg");
        fs::create_dir_all(xdg.join("synapse")).unwrap();
        World { dir, xdg }
    }

    fn environment(&self) -> Environment {
        environment(
            self.dir.path(),
            &[("XDG_CONFIG_HOME", &self.xdg.to_string_lossy())],
        )
    }

    fn file(&self, name: &str) -> PathBuf {
        self.xdg.join("synapse").join(name)
    }

    fn card(&self, id: &str) -> Convention {
        list_conventions(&self.environment(), &none())
            .conventions
            .into_iter()
            .find(|c| c.id == id)
            .unwrap_or_else(|| panic!("no card {id}"))
    }
}

#[test]
fn every_file_synapse_keeps_is_listed_once_each_in_a_group_also_when_it_is_not_there_yet() {
    let world = World::new();
    let list = list_conventions(&world.environment(), &none()).conventions;
    let mut ids: Vec<&str> = list.iter().map(|c| c.id.as_str()).collect();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), list.len());
    let mut groups: Vec<String> = list
        .iter()
        .map(|c| serde_json::to_value(&c.group).unwrap().to_string())
        .collect();
    groups.sort();
    groups.dedup();
    assert_eq!(groups.len(), 3);
    let tags = world.card("tags");
    assert_eq!(
        tags.file,
        world.file("synapse-tag-vocabulary.conf").to_string_lossy()
    );
    assert!(!tags.exists && tags.editable && tags.entries.is_empty() && tags.problem.is_none());
    assert_eq!(tags.group, ConventionGroup::Vault);
}

#[test]
fn a_file_of_lines_has_the_lines_that_are_not_blank_and_not_comments_trimmed() {
    assert_eq!(
        parse_lines("# note\n\n  alpha \nbeta\n   # later\n\r\n"),
        vec!["alpha", "beta"]
    );
    let world = World::new();
    fs::write(
        world.file("synapse-prompt-stopwords.conf"),
        "# words\nthe\n\nand\n",
    )
    .unwrap();
    let card = world.card("stopwords");
    assert!(card.exists);
    assert_eq!(card.entries, vec![entry("the"), entry("and")]);
}

#[test]
fn an_entry_goes_on_a_new_line_the_file_is_made_and_what_was_there_is_kept() {
    let world = World::new();
    let list = add_convention(&world.environment(), &none(), "tags", "alpha").unwrap();
    assert_eq!(
        list.conventions
            .iter()
            .find(|c| c.id == "tags")
            .unwrap()
            .entries,
        vec![entry("alpha")]
    );
    assert_eq!(
        fs::read_to_string(world.file("synapse-tag-vocabulary.conf")).unwrap(),
        "alpha\n"
    );

    fs::write(world.file("synapse-ignore-files.conf"), "# mine\nvendor/").unwrap();
    add_convention(&world.environment(), &none(), "ignore-files", "  dist/  ").unwrap();
    assert_eq!(
        fs::read_to_string(world.file("synapse-ignore-files.conf")).unwrap(),
        "# mine\nvendor/\ndist/\n"
    );
}

#[test]
fn an_entry_that_is_empty_several_lines_a_comment_or_already_there_is_refused() {
    let world = World::new();
    let env = world.environment();
    add_convention(&env, &none(), "tags", "alpha").unwrap();
    assert_eq!(
        add_convention(&env, &none(), "tags", "   ")
            .unwrap_err()
            .code,
        ErrorCode::Conflict
    );
    assert!(add_convention(&env, &none(), "tags", "a\nb")
        .unwrap_err()
        .message
        .contains("one line"));
    assert!(add_convention(&env, &none(), "tags", "# hidden")
        .unwrap_err()
        .message
        .contains("comment"));
    assert!(add_convention(&env, &none(), "tags", "alpha")
        .unwrap_err()
        .message
        .contains("already there"));
    assert_eq!(
        fs::read_to_string(world.file("synapse-tag-vocabulary.conf")).unwrap(),
        "alpha\n"
    );
}

#[test]
fn only_the_entry_that_is_taken_out_is_lost_comments_and_the_rest_as_they_were() {
    let world = World::new();
    fs::write(
        world.file("synapse-tag-vocabulary.conf"),
        "# keep\nalpha\n\nbeta\n# alpha\n",
    )
    .unwrap();
    let after = remove_convention(&world.environment(), &none(), "tags", "alpha").unwrap();
    assert_eq!(
        after
            .conventions
            .iter()
            .find(|c| c.id == "tags")
            .unwrap()
            .entries,
        vec![entry("beta")]
    );
    assert_eq!(
        fs::read_to_string(world.file("synapse-tag-vocabulary.conf")).unwrap(),
        "# keep\n\nbeta\n# alpha\n"
    );
}

#[test]
fn what_is_not_there_is_refused_when_taken_out_and_so_is_a_file_that_is_not_there() {
    let world = World::new();
    let env = world.environment();
    let code = |entry: &str| {
        remove_convention(&env, &none(), "tags", entry)
            .unwrap_err()
            .code
    };
    assert_eq!(code("nope"), ErrorCode::NotFound);
    fs::write(world.file("synapse-tag-vocabulary.conf"), "alpha\n").unwrap();
    assert_eq!(code("nope"), ErrorCode::NotFound);
    assert_eq!(code("# nope"), ErrorCode::NotFound);
}

fn held(world: &World, pairs: &[(&str, &str)]) -> Projects {
    Ok(ProjectList {
        projects: pairs.iter().map(|(n, p)| project(n, p)).collect(),
        file: world
            .file("synapse-projects.conf")
            .to_string_lossy()
            .to_string(),
    })
}

#[test]
fn the_projects_card_is_the_pairs_synapse_holds_as_name_prefix_and_the_file_it_names() {
    let world = World::new();
    fs::write(world.file("synapse-projects.conf"), "# mine\nsynapse=sb\n").unwrap();
    let projects = held(&world, &[("synapse", "sb")]);
    let list = list_conventions(&world.environment(), &projects);
    let card = list
        .conventions
        .iter()
        .find(|c| c.id == "projects")
        .unwrap();
    assert_eq!(card.entries, vec![entry("synapse=sb")]);
    assert_eq!(
        card.file,
        world.file("synapse-projects.conf").to_string_lossy()
    );
    assert!(card.exists && card.editable);
}

#[test]
fn the_projects_card_says_why_when_synapse_cannot_be_asked() {
    let world = World::new();
    let projects: Projects = Err("synapse: unknown subcommand 'projects'".into());
    let list = list_conventions(&world.environment(), &projects);
    let card = list
        .conventions
        .iter()
        .find(|c| c.id == "projects")
        .unwrap();
    assert!(card.entries.is_empty());
    assert_eq!(
        card.problem.as_deref(),
        Some("synapse: unknown subcommand 'projects'")
    );
}

#[test]
fn a_project_written_as_a_pair_is_split_at_the_first_equal_sign() {
    assert_eq!(split_project("thing = tg"), Some(("thing", "tg")));
    assert_eq!(split_project("a=b=c"), Some(("a", "b=c")));
    assert_eq!(split_project("nopair"), None);
    assert_eq!(split_project("=x"), None);
}

#[test]
fn a_project_is_taken_out_of_the_file_synapse_names_the_rest_as_it_was() {
    let world = World::new();
    let env = world.environment();
    fs::write(
        world.file("synapse-projects.conf"),
        "# mine\nsynapse=sb\neon=ecs\n",
    )
    .unwrap();
    let projects = held(&world, &[("synapse", "sb"), ("eon", "ecs")]);
    remove_convention(&env, &projects, "projects", "eon=ecs").unwrap();
    assert_eq!(
        fs::read_to_string(world.file("synapse-projects.conf")).unwrap(),
        "# mine\nsynapse=sb\n"
    );
    // Without synapse there is no file to take it from.
    let broken: Projects = Err("no synapse".into());
    assert_eq!(
        remove_convention(&env, &broken, "projects", "synapse=sb")
            .unwrap_err()
            .code,
        ErrorCode::Unavailable
    );
}

#[test]
fn a_file_of_json_has_the_keys_of_an_object_in_order_and_the_rules_of_a_list_numbered() {
    let entries = parse_json(r#"{"ml": {"repo": "x"}, "el": "lisp"}"#).unwrap();
    assert_eq!(
        entries,
        vec![
            ConventionEntry {
                text: "ml".into(),
                detail: Some(r#"{"repo":"x"}"#.into())
            },
            ConventionEntry {
                text: "el".into(),
                detail: Some(r#""lisp""#.into())
            },
        ]
    );
    let rules = parse_json(r#"[{"match": "a"}, {"match": "b"}]"#).unwrap();
    assert_eq!(
        rules,
        vec![
            ConventionEntry {
                text: "1".into(),
                detail: Some(r#"{"match":"a"}"#.into())
            },
            ConventionEntry {
                text: "2".into(),
                detail: Some(r#"{"match":"b"}"#.into())
            },
        ]
    );
    assert_eq!(parse_json("  \n").unwrap(), vec![]);
    assert!(parse_json(r#"{"a": "#).unwrap_err().contains("not JSON"));
    assert_eq!(
        parse_json("3").unwrap_err(),
        "It is neither an object nor a list."
    );
}

#[test]
fn a_file_of_json_is_shown_with_a_problem_when_it_is_broken_and_never_changed_here() {
    let world = World::new();
    let env = world.environment();
    fs::write(
        world.file("synapse-grammars.conf"),
        r#"{"ml": {"repo": "x"}}"#,
    )
    .unwrap();
    fs::write(world.file("synapse-fence-languages.conf"), "{oops").unwrap();
    let grammars = world.card("grammars");
    assert!(!grammars.editable && grammars.problem.is_none());
    assert_eq!(
        grammars.entries,
        vec![ConventionEntry {
            text: "ml".into(),
            detail: Some(r#"{"repo":"x"}"#.into())
        }]
    );
    let fence = world.card("fence-languages");
    assert!(!fence.editable && fence.entries.is_empty());
    assert!(fence.problem.unwrap().contains("not JSON"));
    assert_eq!(
        add_convention(&env, &none(), "grammars", "x")
            .unwrap_err()
            .code,
        ErrorCode::Conflict
    );
    assert_eq!(
        remove_convention(&env, &none(), "grammars", "ml")
            .unwrap_err()
            .code,
        ErrorCode::Conflict
    );
    assert_eq!(
        fs::read_to_string(world.file("synapse-grammars.conf")).unwrap(),
        r#"{"ml": {"repo": "x"}}"#
    );
    assert_eq!(
        add_convention(&env, &none(), "nothing", "x")
            .unwrap_err()
            .code,
        ErrorCode::NotFound
    );
}
