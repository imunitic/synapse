//! Running the Synapse programs: what is allowed, the environment they run in, and running them.

// Some cases need a Unix shell or socket; what only they use is unused on Windows.
#![cfg_attr(windows, allow(unused_imports, dead_code))]

mod support;

use std::collections::BTreeMap;
use synapse_desktop_host::cli::{cli_environment, refuse_cli, CliRun, CliRunner};
use synapse_desktop_host::messages::{
    AppConfig,
    CliBinary::{Synapse, SynapsePipeline},
};

fn args(list: &[&str]) -> Vec<String> {
    list.iter().map(|a| a.to_string()).collect()
}

fn refused(binary: synapse_desktop_host::messages::CliBinary, list: &[&str]) -> Option<String> {
    refuse_cli(binary, &args(list))
}

fn allowed(binary: synapse_desktop_host::messages::CliBinary, list: &[&str]) {
    assert_eq!(refused(binary, list), None, "{list:?}");
}

fn refuses(binary: synapse_desktop_host::messages::CliBinary, list: &[&str], about: &str) {
    let reason = refused(binary, list).unwrap_or_else(|| panic!("{list:?} was allowed"));
    assert!(
        reason.contains(about),
        "{list:?}: {reason} does not say {about}"
    );
}

fn empty_config() -> AppConfig {
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

#[test]
fn the_read_only_and_housekeeping_subcommands_of_synapse_pipeline_are_allowed() {
    for sub in [
        "check",
        "show",
        "definitions",
        "list",
        "info",
        "changes",
        "cleanup",
    ] {
        allowed(SynapsePipeline, &[sub, "x"]);
    }
    // A run is started through run.start.
    refuses(SynapsePipeline, &["run", "p"], "not allowed");
}

#[test]
fn synapse_pipeline_name_is_allowed() {
    allowed(SynapsePipeline, &["name", "synapse-001", "Fix login"]);
    allowed(SynapsePipeline, &["name", "synapse-001"]);
}

#[test]
fn of_synapse_only_config_status_and_the_read_only_commands_of_the_vault_are_allowed() {
    refuses(Synapse, &["write-node"], "not allowed");
    refuses(Synapse, &["vault-delete", "a.md"], "not allowed");
    allowed(Synapse, &["vault-list"]);
    refuses(Synapse, &["vault-list", "x"], "no arguments");
    allowed(Synapse, &["vault-read", "designs/a.md"]);
    allowed(Synapse, &["vault-search-text", "two words"]);
    allowed(Synapse, &["vault-links", "a.md"]);
    allowed(Synapse, &["vault-backlinks", "a.md"]);
    allowed(Synapse, &["vault-doc-map", "a.md"]);
    refuses(Synapse, &["vault-doc-map", "--x"], "one argument");
    refuses(Synapse, &["vault-doc-map"], "one argument");
    allowed(
        Synapse,
        &[
            "vault-search",
            "--fields",
            "frontmatter.title,frontmatter.updated",
        ],
    );
    refuses(Synapse, &["vault-search"], "only --fields");
    refuses(Synapse, &["vault-search", "--fields"], "only --fields");
    refuses(
        Synapse,
        &["vault-search", "--fields", "a b"],
        "only --fields",
    );
    refuses(
        Synapse,
        &["vault-search", "--namespace", "x@y"],
        "only --fields",
    );
    refuses(Synapse, &["vault-read"], "one argument");
    refuses(Synapse, &["vault-read", "--help"], "one argument");
    refuses(Synapse, &["vault-read", "a.md", "b.md"], "one argument");
    refuses(Synapse, &["vault-write", "a.md"], "not allowed");
    refuses(Synapse, &["vault-patch", "a.md"], "not allowed");
    allowed(Synapse, &["status"]);
    allowed(Synapse, &["status", "--format", "json"]);
    refuses(Synapse, &["status", "--format", "xml"], "only --format");
    refuses(Synapse, &["status", "extra"], "only --format");
    allowed(Synapse, &["config", "list"]);
    allowed(Synapse, &["config", "list", "--format", "json"]);
    allowed(Synapse, &["config", "set", "SYNAPSE_VAULT_DIR", "/a b"]);
    allowed(
        Synapse,
        &["config", "set", "SYNAPSE_VAULT_PUSH_EVERY", "--x"],
    );
    allowed(Synapse, &["config", "unset", "SYNAPSE_VAULT_DIR"]);
}

#[test]
fn projects_may_be_listed_and_one_added_and_nothing_else_of_it() {
    allowed(Synapse, &["projects"]);
    allowed(Synapse, &["projects", "list"]);
    allowed(Synapse, &["projects", "--format", "json"]);
    allowed(Synapse, &["projects", "list", "--format", "text"]);
    allowed(Synapse, &["projects", "add", "thing", "tg"]);
    refuses(Synapse, &["projects", "--format", "xml"], "list or add");
    refuses(Synapse, &["projects", "list", "extra"], "list or add");
    refuses(Synapse, &["projects", "remove", "thing"], "list or add");
    refuses(Synapse, &["projects", "add", "thing"], "name and a prefix");
    refuses(
        Synapse,
        &["projects", "add", "--x", "tg"],
        "name and a prefix",
    );
    refuses(
        Synapse,
        &["projects", "add", "thing", "tg", "more"],
        "name and a prefix",
    );
    refuses(SynapsePipeline, &["projects"], "not allowed");
}

#[test]
fn the_reads_of_a_graph_are_allowed_always_of_one_namespace() {
    let ns = ["--namespace", "synapse@main"];
    let with = |first: &[&'static str]| -> Vec<&'static str> {
        first.iter().copied().chain(ns.iter().copied()).collect()
    };
    allowed(Synapse, &["work-dir", "--list"]);
    allowed(Synapse, &["work-dir", "--root"]);
    refuses(Synapse, &["work-dir"], "only --list or --root");
    refuses(Synapse, &["work-dir", "--namespace", "a@b"], "only --list");
    allowed(Synapse, &with(&["callers", "Resolve"]));
    allowed(Synapse, &with(&["callers", "Resolve", "--all"]));
    refuses(Synapse, &["callers", "Resolve"], "--namespace");
    refuses(Synapse, &with(&["callers", "--all"]), "takes a name");
    refuses(Synapse, &with(&["callers", "a", "b"]), "takes a name");
    allowed(Synapse, &with(&["index", "nodes"]));
    allowed(Synapse, &with(&["index", "paths"]));
    allowed(Synapse, &with(&["index", "unassigned"]));
    allowed(Synapse, &with(&["index", "lookup", "src/a.adb"]));
    refuses(Synapse, &with(&["index", "lookup"]), "takes a path");
    refuses(Synapse, &["index", "nodes"], "--namespace");
}

#[test]
fn a_namespace_that_is_not_a_name_and_the_writes_of_the_index_are_refused() {
    for bad in [
        "../x@main",
        "a@b/c",
        "a@",
        "@b",
        "nobranch",
        "a@b c",
        "a@..\\b",
    ] {
        refuses(
            Synapse,
            &["index", "nodes", "--namespace", bad],
            "--namespace",
        );
    }
    refuses(
        Synapse,
        &["index", "build", "--namespace", "a@b"],
        "takes lookup",
    );
    refuses(
        Synapse,
        &["index", "add-unassigned", "x", "--namespace", "a@b"],
        "takes lookup",
    );
    refuses(Synapse, &["index"], "takes lookup");
    refuses(Synapse, &["tags-cache", "--dump", "x"], "not allowed");
    refuses(Synapse, &["build-refs"], "not allowed");
}

#[test]
fn the_rest_of_config_is_refused_other_actions_bad_names_wrong_counts() {
    refuses(Synapse, &["config"], "list, set or unset");
    refuses(Synapse, &["config", "frob"], "list, set or unset");
    refuses(
        Synapse,
        &["config", "list", "--format", "xml"],
        "only --format",
    );
    refuses(Synapse, &["config", "list", "extra"], "only --format");
    refuses(
        Synapse,
        &["config", "set", "lower_case", "v"],
        "name and a value",
    );
    refuses(
        Synapse,
        &["config", "set", "--help", "v"],
        "name and a value",
    );
    refuses(Synapse, &["config", "set", "SYNAPSE_X"], "name and a value");
    refuses(Synapse, &["config", "unset"], "setting name");
}

#[test]
fn a_call_with_no_subcommand_and_one_that_starts_with_a_flag_are_refused() {
    refuses(SynapsePipeline, &[], "subcommand is required");
    refuses(SynapsePipeline, &["--help"], "not allowed");
}

#[test]
fn too_many_arguments_a_long_one_and_a_nul_are_refused() {
    let many: Vec<&str> = std::iter::once("show")
        .chain(std::iter::repeat_n("a", 32))
        .collect();
    refuses(SynapsePipeline, &many, "too many");
    let long = "a".repeat(5000);
    refuses(SynapsePipeline, &["show", &long], "too long");
    refuses(
        SynapsePipeline,
        &["show", "a\0b"],
        "too long or holds a NUL",
    );
}

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

#[test]
fn the_environment_is_as_it_is_when_the_app_sets_nothing() {
    assert_eq!(
        cli_environment(&map(&[("A", "1")]), &empty_config()),
        map(&[("A", "1")])
    );
}

#[test]
fn the_work_directory_and_the_definition_folders_of_the_app_are_set_before_the_inherited() {
    let config = AppConfig {
        work_dir: Some("/w".into()),
        ..empty_config()
    };
    assert_eq!(
        cli_environment(&map(&[]), &config)["SYNAPSE_WORK_DIR"],
        "/w"
    );

    let separator = if cfg!(windows) { ";" } else { ":" };
    let inherited = ["/x", "/y"].join(separator);
    let base = map(&[("SYNAPSE_PIPELINE_PATH", inherited.as_str())]);
    let config = AppConfig {
        definition_paths: vec!["/mine".into()],
        ..empty_config()
    };
    let env = cli_environment(&base, &config);
    assert_eq!(
        env["SYNAPSE_PIPELINE_PATH"],
        ["/mine", "/x", "/y"].join(separator)
    );
    // What it was given is as it was.
    assert_eq!(base["SYNAPSE_PIPELINE_PATH"], inherited);
}

#[test]
fn the_variables_the_user_set_are_over_the_environment_and_over_what_the_app_sets() {
    let config = AppConfig {
        work_dir: Some("/w".into()),
        env: map(&[
            ("SYNAPSE_VAULT_DIR", "/mine"),
            ("SYNAPSE_WORK_DIR", "/elsewhere"),
        ]),
        ..empty_config()
    };
    let env = cli_environment(
        &map(&[("SYNAPSE_VAULT_DIR", "/inherited"), ("KEEP", "k")]),
        &config,
    );
    assert_eq!(env["SYNAPSE_VAULT_DIR"], "/mine");
    assert_eq!(env["SYNAPSE_WORK_DIR"], "/elsewhere");
    assert_eq!(env["KEEP"], "k");
}

#[cfg(unix)]
mod running {
    use super::*;

    /// A `synapse` that is this script, on a PATH of its own.
    fn fake(dir: &std::path::Path, script: &str) -> BTreeMap<String, String> {
        let path = dir.join("synapse");
        support::executable(&path, &format!("#!/bin/sh\n{script}\n"));
        map(&[("PATH", &format!("{}:/usr/bin:/bin", dir.display()))])
    }

    #[tokio::test]
    async fn runs_the_program_on_the_path_it_is_given_and_says_what_it_printed() {
        let dir = tempfile::tempdir().unwrap();
        let base = fake(
            dir.path(),
            r#"echo "out $1 $SYNAPSE_WORK_DIR"; echo err >&2"#,
        );
        let config = AppConfig {
            work_dir: Some("/w".into()),
            ..empty_config()
        };
        let run = CliRun::new(Synapse, &["status"], config);
        let result = CliRunner::system(base).run(run).await.unwrap();
        assert_eq!(result.code, 0);
        assert_eq!(result.stdout, "out status /w\n");
        assert_eq!(result.stderr, "err\n");
    }

    #[tokio::test]
    async fn gives_the_program_its_input_and_a_non_zero_exit_is_a_result() {
        let dir = tempfile::tempdir().unwrap();
        let base = fake(dir.path(), "cat; exit 3");
        let mut run = CliRun::new(Synapse, &["status"], empty_config());
        run.stdin = Some("typed in".into());
        let result = CliRunner::system(base).run(run).await.unwrap();
        assert_eq!((result.code, result.stdout.as_str()), (3, "typed in"));
    }

    #[tokio::test]
    async fn sets_what_the_run_names_over_the_rest_and_runs_in_the_folder_it_names() {
        let dir = tempfile::tempdir().unwrap();
        let base = fake(dir.path(), r#"echo "$PATH" | cut -c1-6; pwd"#);
        let mut run = CliRun::new(Synapse, &["status"], empty_config());
        run.env = map(&[("PATH", "/set/by:/usr/bin:/bin")]);
        run.cwd = Some(dir.path().to_string_lossy().to_string());
        // The program is looked for on the PATH the run sets, so it is not found where it was put.
        let missing = CliRunner::system(base.clone()).run(run.clone()).await;
        assert!(missing.is_err());

        run.env = map(&[("EXTRA", "1")]);
        let result = CliRunner::system(base).run(run).await.unwrap();
        assert!(result.stdout.lines().last().unwrap().ends_with(
            &dir.path()
                .file_name()
                .unwrap()
                .to_string_lossy()
                .to_string()
        ));
    }

    #[tokio::test]
    async fn is_an_error_when_the_program_is_not_there_or_ends_by_a_signal() {
        let dir = tempfile::tempdir().unwrap();
        let run = || CliRun::new(Synapse, &["status"], empty_config());
        let none = map(&[("PATH", &dir.path().to_string_lossy())]);
        let error = CliRunner::system(none).run(run()).await.unwrap_err();
        assert!(error.contains("could not be run"), "{error}");

        let base = fake(dir.path(), "kill -9 $$");
        let error = CliRunner::system(base).run(run()).await.unwrap_err();
        assert!(error.contains("signal"), "{error}");
    }
}
