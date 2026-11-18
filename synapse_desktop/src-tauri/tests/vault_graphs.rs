//! The folder of a vault, and the code graphs. The same cases as the Node host's `vault.test.ts`,
//! `graph-find.test.ts`, `graph-health.test.ts` and `graph-manage.test.ts`.

// Some cases name Unix paths; what only they use is unused on Windows.
#![cfg_attr(windows, allow(unused_imports, dead_code))]

mod support;

use serde_json::json;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use support::{environment, Host};
use synapse_desktop_host::cli::{CliRun, CliRunner};
use synapse_desktop_host::graphs::{
    check_graph_repo, find_graph_repos, graph_health, parse_findings, search_roots,
};
use synapse_desktop_host::messages::{AppConfig, CliResult, GraphCheck, GraphFinding};
use synapse_desktop_host::protocol::ErrorCode;
use synapse_desktop_host::vault::{inspect_vault, seed_vault};
use tempfile::tempdir;

/// What a program was asked: its arguments and the variables it was given.
type Asked = Arc<Mutex<Vec<(Vec<String>, BTreeMap<String, String>)>>>;

fn s(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

fn note(root: &Path, path: &str) {
    let file = root.join(path);
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(file, "# note\n").unwrap();
}

// ---------------------------------------------------------------------------------------------
// The folder of a vault
// ---------------------------------------------------------------------------------------------

#[test]
fn a_folder_that_is_not_there_and_a_file_are_not_a_vault() {
    let dir = tempdir().unwrap();
    let nowhere = inspect_vault(&s(&dir.path().join("nowhere")));
    assert!(
        !nowhere.exists
            && !nowhere.has_index
            && !nowhere.is_git
            && nowhere.notes == 0
            && !nowhere.capped
    );
    note(dir.path(), "plain.md");
    assert!(!inspect_vault(&s(&dir.path().join("plain.md"))).exists);
}

#[test]
fn the_notes_of_a_vault_are_counted_in_every_folder_and_its_index_and_git_are_found() {
    let dir = tempdir().unwrap();
    for path in [
        "Index.md",
        "designs/a.md",
        "designs/deep/b.md",
        "readme.txt",
    ] {
        note(dir.path(), path);
    }
    fs::create_dir(dir.path().join(".git")).unwrap();
    let info = inspect_vault(&s(dir.path()));
    assert!(info.exists && info.has_index && info.is_git && !info.capped);
    assert_eq!(info.notes, 3);
    assert_eq!(info.path, s(dir.path()));
}

#[test]
fn the_folders_that_start_with_a_dot_hold_no_notes_and_a_folder_without_index_or_git_has_none() {
    let dir = tempdir().unwrap();
    note(dir.path(), "a.md");
    note(dir.path(), ".obsidian/workspace.md");
    note(dir.path(), ".git/notes.md");
    let info = inspect_vault(&s(dir.path()));
    assert_eq!(info.notes, 1);
    assert!(info.exists && !info.has_index);
    fs::remove_dir_all(dir.path().join(".git")).unwrap();
    assert!(!inspect_vault(&s(dir.path())).is_git);
}

#[test]
fn a_walk_stops_after_so_many_entries() {
    let dir = tempdir().unwrap();
    for i in 0..20_001 {
        fs::write(dir.path().join(format!("{i}.md")), "x").unwrap();
    }
    let info = inspect_vault(&s(dir.path()));
    assert!(info.capped);
    assert!(info.notes <= 20_000);
}

fn template(dir: &Path) -> PathBuf {
    let path = dir.join("Index.md.template");
    fs::write(&path, "# Index\nthe template\n").unwrap();
    path
}

#[test]
fn a_folder_is_made_a_vault_with_an_index_from_the_template_where_there_is_nothing() {
    let dir = tempdir().unwrap();
    let t = template(dir.path());
    let vault = dir.path().join("a/deeper/vault");
    seed_vault(&s(&vault), Some(&t)).unwrap();
    assert_eq!(
        fs::read_to_string(vault.join("Index.md")).unwrap(),
        "# Index\nthe template\n"
    );
    assert!(inspect_vault(&s(&vault)).has_index);
}

#[test]
fn the_index_is_added_to_a_folder_that_has_notes_which_are_left_as_they_are() {
    let dir = tempdir().unwrap();
    let t = template(dir.path());
    note(dir.path(), "notes/one.md");
    seed_vault(&s(&dir.path().join("notes")), Some(&t)).unwrap();
    assert_eq!(
        fs::read_to_string(dir.path().join("notes/one.md")).unwrap(),
        "# note\n"
    );
    assert!(dir.path().join("notes/Index.md").is_file());
}

#[test]
fn the_index_of_a_vault_that_has_one_is_left_even_when_the_template_is_not_there() {
    let dir = tempdir().unwrap();
    fs::create_dir_all(dir.path().join("v")).unwrap();
    fs::write(dir.path().join("v/Index.md"), "mine\n").unwrap();
    seed_vault(&s(&dir.path().join("v")), None).unwrap();
    assert_eq!(
        fs::read_to_string(dir.path().join("v/Index.md")).unwrap(),
        "mine\n"
    );
    let t = template(dir.path());
    seed_vault(&s(&dir.path().join("v")), Some(&t)).unwrap();
    assert_eq!(
        fs::read_to_string(dir.path().join("v/Index.md")).unwrap(),
        "mine\n"
    );
}

#[test]
fn nothing_is_made_when_what_it_is_made_from_is_not_there_and_a_file_is_not_a_folder() {
    let dir = tempdir().unwrap();
    let vault = dir.path().join("new/vault");
    let error = seed_vault(&s(&vault), None).unwrap_err();
    assert_eq!(error.code, ErrorCode::Conflict);
    assert!(error.message.contains("template"));
    assert!(!vault.exists());
    let missing = dir.path().join("missing.template");
    assert!(seed_vault(&s(&vault), Some(&missing)).is_err());
    note(dir.path(), "plain.md");
    let t = template(dir.path());
    let error = seed_vault(&s(&dir.path().join("plain.md")), Some(&t)).unwrap_err();
    assert!(error.message.contains("is not a folder"));
}

#[tokio::test]
async fn through_the_host_a_path_must_be_absolute_and_a_tilde_is_the_home_folder() {
    let dir = tempdir().unwrap();
    note(dir.path(), "vault/a.md");
    let mut host = Host::new(
        environment(
            dir.path(),
            &[("XDG_CONFIG_HOME", &s(&dir.path().join("xdg")))],
        ),
        &dir.path().join("config.json"),
    )
    .await;
    let relative = host
        .ask("vault.inspect", json!({ "path": "relative/dir" }))
        .await
        .unwrap_err();
    assert_eq!(relative.0, ErrorCode::BadRequest);
    let empty = host
        .ask("vault.inspect", json!({ "path": "" }))
        .await
        .unwrap_err();
    assert_eq!(empty.0, ErrorCode::BadRequest);
    let absolute = host
        .ask(
            "vault.inspect",
            json!({ "path": s(&dir.path().join("vault")) }),
        )
        .await
        .unwrap();
    assert_eq!(
        (absolute["exists"].clone(), absolute["notes"].clone()),
        (json!(true), json!(1))
    );
    let tilde = host
        .ask("vault.inspect", json!({ "path": "~/vault" }))
        .await
        .unwrap();
    assert_eq!(tilde["path"], json!(s(&dir.path().join("vault"))));
    assert_eq!(tilde["notes"], json!(1));
    let home = host
        .ask("vault.inspect", json!({ "path": "~" }))
        .await
        .unwrap();
    assert_eq!(home["path"], json!(s(dir.path())));
}

#[tokio::test]
async fn seeding_through_the_host_uses_the_template_of_the_content_the_program_is_in() {
    let dir = tempdir().unwrap();
    // A package with the template, found by SYNAPSE_CONTENT_ROOT.
    let pkg = dir.path().join("pkg");
    fs::create_dir_all(pkg.join("skills")).unwrap();
    fs::create_dir_all(pkg.join("harness")).unwrap();
    fs::write(pkg.join("Index.md.template"), "# Index\nthe template\n").unwrap();
    let mut host = Host::new(
        environment(
            dir.path(),
            &[
                ("XDG_CONFIG_HOME", &s(&dir.path().join("xdg"))),
                ("SYNAPSE_CONTENT_ROOT", &s(&pkg)),
            ],
        ),
        &dir.path().join("config.json"),
    )
    .await;
    let target = dir.path().join("new-vault");
    let seeded = host
        .ask("vault.seed", json!({ "path": s(&target) }))
        .await
        .unwrap();
    assert_eq!(
        (seeded["exists"].clone(), seeded["hasIndex"].clone()),
        (json!(true), json!(true))
    );
    assert_eq!(
        fs::read_to_string(target.join("Index.md")).unwrap(),
        "# Index\nthe template\n"
    );

    let mut without = Host::new(
        environment(
            dir.path(),
            &[("XDG_CONFIG_HOME", &s(&dir.path().join("xdg")))],
        ),
        &dir.path().join("config2.json"),
    )
    .await;
    let refused = without
        .ask(
            "vault.seed",
            json!({ "path": s(&dir.path().join("other")) }),
        )
        .await
        .unwrap_err();
    assert_eq!(refused.0, ErrorCode::Conflict);
}

// ---------------------------------------------------------------------------------------------
// The code graphs
// ---------------------------------------------------------------------------------------------

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

fn with_repos(repos: &[(&str, &Path)], folder: Option<&Path>) -> AppConfig {
    AppConfig {
        graph_repos: repos.iter().map(|(k, v)| (k.to_string(), s(v))).collect(),
        terminal_folder: folder.map(s),
        ..config()
    }
}

/// A checkout is a folder with `.git`, a folder or, as in a worktree, a file.
fn checkout(root: &Path, name: &str, worktree: bool) -> PathBuf {
    let path = root.join(name);
    fs::create_dir_all(&path).unwrap();
    if worktree {
        fs::write(path.join(".git"), "gitdir: elsewhere").unwrap();
    } else {
        fs::create_dir(path.join(".git")).unwrap();
    }
    path
}

/// Answers `namespace --repo <path>` with the key the folder is said to be on, and keeps what it was
/// asked.
fn namespaces(keys: &[(&Path, &str)]) -> (CliRunner, Arc<Mutex<Vec<String>>>) {
    let keys: BTreeMap<String, String> = keys.iter().map(|(p, k)| (s(p), k.to_string())).collect();
    let asked = Arc::new(Mutex::new(vec![]));
    let kept = asked.clone();
    let runner = CliRunner::new(move |run: CliRun| {
        let path = run.args.get(2).cloned().unwrap_or_default();
        kept.lock().unwrap().push(path.clone());
        let result = match keys.get(&path) {
            Some(key) => CliResult {
                code: 0,
                stdout: format!("{key}\n"),
                stderr: String::new(),
            },
            None => CliResult {
                code: 1,
                stdout: String::new(),
                stderr: "not a repository".into(),
            },
        };
        async move { Ok(result) }
    });
    (runner, asked)
}

#[tokio::test]
async fn the_checkout_of_a_graph_is_looked_for_next_to_the_checkouts_already_saved_worktrees_included(
) {
    let dir = tempdir().unwrap();
    let main = checkout(dir.path(), "main", false);
    let feature = checkout(dir.path(), "feature", true);
    fs::create_dir(dir.path().join("notes")).unwrap();
    let (runner, asked) = namespaces(&[(&main, "widget@main"), (&feature, "widget@feature")]);
    let cfg = with_repos(&[("widget@main", &main)], None);
    assert_eq!(
        find_graph_repos(&runner, &cfg, "widget@feature").await,
        vec![s(&feature)]
    );
    assert_eq!(
        find_graph_repos(&runner, &cfg, "widget@main").await,
        vec![s(&main)]
    );
    assert!(find_graph_repos(&runner, &cfg, "widget@gone")
        .await
        .is_empty());
    // A folder that is not a checkout is never asked.
    assert!(!asked.lock().unwrap().iter().any(|p| p.ends_with("notes")));
}

#[tokio::test]
async fn every_checkout_on_the_namespace_is_listed_in_order_and_the_terminal_folder_is_looked_in() {
    let dir = tempdir().unwrap();
    let b = checkout(dir.path(), "b", false);
    let a = checkout(dir.path(), "a", false);
    let (runner, _) = namespaces(&[(&a, "widget@main"), (&b, "widget@main")]);
    assert_eq!(
        find_graph_repos(
            &runner,
            &with_repos(&[("widget@main", &a)], None),
            "widget@main"
        )
        .await,
        vec![s(&a), s(&b)]
    );
    let projects = tempdir().unwrap();
    let one = checkout(projects.path(), "one", false);
    let (runner, _) = namespaces(&[(&one, "widget@main")]);
    assert_eq!(
        find_graph_repos(
            &runner,
            &with_repos(&[], Some(projects.path())),
            "widget@main"
        )
        .await,
        vec![s(&one)]
    );
    assert!(find_graph_repos(&runner, &config(), "widget@main")
        .await
        .is_empty());
    assert!(search_roots(&config()).is_empty());
}

#[cfg(unix)]
#[test]
fn the_roots_are_the_folders_of_the_saved_checkouts_and_the_terminal_folder_when_it_is_a_path() {
    let cfg = AppConfig {
        graph_repos: BTreeMap::from([
            ("a@main".to_string(), "/code/a".to_string()),
            ("b@main".to_string(), "/code/b".to_string()),
        ]),
        terminal_folder: Some("/home/me".into()),
        ..config()
    };
    assert_eq!(
        search_roots(&cfg),
        [PathBuf::from("/code"), PathBuf::from("/home/me")]
    );
    let relative = AppConfig {
        terminal_folder: Some("relative".into()),
        ..config()
    };
    assert!(search_roots(&relative).is_empty());
}

#[tokio::test]
async fn a_folder_is_asked_for_its_namespace_and_one_that_is_not_a_folder_says_so() {
    let dir = tempdir().unwrap();
    let (runner, _) = namespaces(&[(dir.path(), "synapse@main")]);
    let found = check_graph_repo(&runner, &config(), &s(dir.path())).await;
    assert_eq!(
        (found.key.as_deref(), found.error),
        (Some("synapse@main"), None)
    );
    let missing = check_graph_repo(&runner, &config(), &s(&dir.path().join("gone"))).await;
    assert_eq!(missing.key, None);
    assert!(missing.error.unwrap().contains("is not a folder"));
    let relative = check_graph_repo(&runner, &config(), "relative").await;
    assert!(relative.error.unwrap().contains("is not a folder"));
    // A folder the program says nothing of has no namespace, with its words when it said some.
    let other = tempdir().unwrap();
    let said = check_graph_repo(&runner, &config(), &s(other.path())).await;
    assert_eq!(said.error.as_deref(), Some("not a repository"));
}

#[test]
fn the_rows_of_a_check_are_a_node_a_tab_and_what_is_wrong_and_nothing_when_nothing_is() {
    assert_eq!(
        parse_findings("Node A\tchanged\nNode B\n\n"),
        vec![
            GraphFinding {
                node: "Node A".into(),
                reason: "changed".into()
            },
            GraphFinding {
                node: "Node B".into(),
                reason: String::new()
            },
        ]
    );
    assert!(parse_findings("").is_empty());
}

#[tokio::test]
async fn the_health_of_a_graph_is_three_checks_run_on_the_repository_and_a_failure_is_not_a_clean_graph(
) {
    let seen: Asked = Arc::new(Mutex::new(vec![]));
    let kept = seen.clone();
    let runner = CliRunner::new(move |run: CliRun| {
        kept.lock()
            .unwrap()
            .push((run.args.clone(), run.env.clone()));
        let result = match run.args.last().map(String::as_str) {
            Some("stale") => CliResult {
                code: 0,
                stdout: "Node A\tchanged\n".into(),
                stderr: String::new(),
            },
            Some("drift") => CliResult {
                code: 1,
                stdout: String::new(),
                stderr: "no commit\n".into(),
            },
            _ => CliResult {
                code: 0,
                stdout: String::new(),
                stderr: String::new(),
            },
        };
        async move { Ok(result) }
    });
    let health = graph_health(&runner, &config(), "synapse@main", "/repo").await;
    assert_eq!(
        health.stale,
        GraphCheck::Found {
            ok: true,
            findings: vec![GraphFinding {
                node: "Node A".into(),
                reason: "changed".into()
            }]
        }
    );
    assert_eq!(
        health.drift,
        GraphCheck::Failed {
            ok: false,
            error: "no commit".into()
        }
    );
    assert_eq!(
        health.grounding,
        GraphCheck::Found {
            ok: true,
            findings: vec![]
        }
    );
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 3);
    assert!(seen.iter().all(
        |(args, env)| args[..3] == ["query", "--namespace", "synapse@main"]
            && env["SYNAPSE_REPO_ROOT"] == "/repo"
    ));
}

async fn graph_host(dir: &Path) -> Host {
    Host::new(
        environment(dir, &[("XDG_CONFIG_HOME", &s(&dir.join("xdg")))]),
        &dir.join("config.json"),
    )
    .await
}

#[tokio::test]
async fn a_graph_is_read_against_the_repository_saved_for_it_and_says_when_there_is_none() {
    let dir = tempdir().unwrap();
    let mut host = graph_host(dir.path()).await;
    let none = host
        .ask("graph.health", json!({ "namespace": "synapse@main" }))
        .await
        .unwrap_err();
    assert_eq!(none.0, ErrorCode::Conflict);
    assert!(none.1.contains("no repository"));

    host.ask(
        "config.set",
        json!({ "patch": { "graphRepos": { "synapse@main": s(dir.path()) } } }),
    )
    .await
    .unwrap();
    *host.result.lock().unwrap() = CliResult {
        code: 0,
        stdout: "Node A\tchanged\n".into(),
        stderr: String::new(),
    };
    let health = host
        .ask("graph.health", json!({ "namespace": "synapse@main" }))
        .await
        .unwrap();
    assert_eq!(
        health["stale"]["findings"],
        json!([{ "node": "Node A", "reason": "changed" }])
    );
    assert_eq!(
        host.calls.lock().unwrap().last().unwrap().env["SYNAPSE_REPO_ROOT"],
        s(dir.path())
    );

    host.ask(
        "config.set",
        json!({ "patch": { "graphRepos": { "synapse@main": s(&dir.path().join("gone")) } } }),
    )
    .await
    .unwrap();
    let gone = host
        .ask("graph.health", json!({ "namespace": "synapse@main" }))
        .await
        .unwrap_err();
    assert_eq!(gone.0, ErrorCode::Conflict);
    let bad = host
        .ask("graph.health", json!({ "namespace": "../x@y" }))
        .await
        .unwrap_err();
    assert_eq!(bad.0, ErrorCode::BadRequest);
}

#[tokio::test]
async fn a_drop_is_planned_and_done_in_the_repository_saved_for_the_graph_and_only_on_its_own_branch(
) {
    let dir = tempdir().unwrap();
    let mut host = graph_host(dir.path()).await;
    let plan = json!({ "action": "plan", "what": "drop", "namespace": "a@main" });
    let drop = json!({ "action": "apply", "what": "drop", "namespace": "a@main" });
    assert_eq!(
        host.ask("graph.manage", plan.clone()).await.unwrap_err().0,
        ErrorCode::Conflict
    );
    let bad = host
        .ask(
            "graph.manage",
            json!({ "action": "apply", "what": "drop", "namespace": "../x@y" }),
        )
        .await
        .unwrap_err();
    assert_eq!(bad.0, ErrorCode::BadRequest);

    host.ask(
        "config.set",
        json!({ "patch": { "graphRepos": { "a@main": s(dir.path()) } } }),
    )
    .await
    .unwrap();
    *host.result.lock().unwrap() = CliResult {
        code: 0,
        stdout: "a@main\n".into(),
        stderr: String::new(),
    };
    let planned = host.ask("graph.manage", plan).await.unwrap();
    assert_eq!(planned["action"], "plan");
    {
        let calls = host.calls.lock().unwrap();
        let wipe = calls
            .iter()
            .find(|c| c.args.first().map(String::as_str) == Some("graph-wipe"))
            .unwrap();
        assert_eq!(wipe.args, ["graph-wipe", "--dry-run"]);
        assert_eq!(wipe.cwd.as_deref(), Some(s(dir.path()).as_str()));
    }
    // The folder is on another branch: nothing is dropped.
    *host.result.lock().unwrap() = CliResult {
        code: 0,
        stdout: "b@main\n".into(),
        stderr: String::new(),
    };
    let wrong = host.ask("graph.manage", drop.clone()).await.unwrap_err();
    assert_eq!(wrong.0, ErrorCode::Conflict);
    assert!(wrong.1.contains("would delete another graph"));
    assert!(!host
        .calls
        .lock()
        .unwrap()
        .iter()
        .any(|c| c.args == ["graph-wipe"]));

    // On its own branch it is done, and what the program printed is the output.
    *host.result.lock().unwrap() = CliResult {
        code: 0,
        stdout: "a@main\n".into(),
        stderr: String::new(),
    };
    let done = host.ask("graph.manage", drop).await.unwrap();
    assert_eq!(done, json!({ "action": "apply", "output": "a@main" }));
}

#[tokio::test]
async fn a_folder_with_no_namespace_and_a_wipe_that_fails_are_refused_with_why() {
    let dir = tempdir().unwrap();
    let mut host = graph_host(dir.path()).await;
    host.ask(
        "config.set",
        json!({ "patch": { "graphRepos": { "a@main": s(dir.path()) } } }),
    )
    .await
    .unwrap();
    *host.result.lock().unwrap() = CliResult {
        code: 1,
        stdout: String::new(),
        stderr: "not a git repository".into(),
    };
    let none = host
        .ask(
            "graph.manage",
            json!({ "action": "apply", "what": "drop", "namespace": "a@main" }),
        )
        .await
        .unwrap_err();
    assert_eq!(none.0, ErrorCode::Conflict);
    assert!(
        none.1.contains("has no namespace: not a git repository"),
        "{}",
        none.1
    );
}

#[tokio::test]
async fn graphs_of_branches_that_are_gone_are_planned_and_cleaned_in_the_saved_repository() {
    let dir = tempdir().unwrap();
    let mut host = graph_host(dir.path()).await;
    let plan = json!({ "action": "plan", "what": "clean", "namespace": "a@main" });
    assert_eq!(
        host.ask("graph.manage", plan.clone()).await.unwrap_err().0,
        ErrorCode::Conflict
    );
    host.ask(
        "config.set",
        json!({ "patch": { "graphRepos": { "a@main": s(dir.path()) } } }),
    )
    .await
    .unwrap();
    *host.result.lock().unwrap() = CliResult {
        code: 0,
        stdout: "would drop old@gone\n".into(),
        stderr: String::new(),
    };
    let planned = host.ask("graph.manage", plan).await.unwrap();
    assert_eq!(
        planned,
        json!({ "action": "plan", "plan": { "lines": ["would drop old@gone"] } })
    );
    let cleaned = host
        .ask(
            "graph.manage",
            json!({ "action": "apply", "what": "clean", "namespace": "a@main" }),
        )
        .await
        .unwrap();
    assert_eq!(
        cleaned,
        json!({ "action": "apply", "output": "would drop old@gone" })
    );
    let calls = host.calls.lock().unwrap();
    assert!(calls.iter().any(|c| c.args == ["graph-clean", "--dry-run"]));
    assert!(calls
        .iter()
        .any(|c| c.args == ["graph-clean"] && c.cwd.as_deref() == Some(s(dir.path()).as_str())));
}
