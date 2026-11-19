//! What the host says of the machine: the doctor's findings, the PATH of the login shell, and what
//! each harness has installed of Synapse.

// Some cases need a Unix shell or socket; what only they use is unused on Windows.
#![cfg_attr(windows, allow(unused_imports, dead_code))]

mod support;

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use support::environment;
use synapse_desktop_host::cli::{CliRun, CliRunner};
use synapse_desktop_host::environment::Environment;
use synapse_desktop_host::messages::{
    AppConfig, CliResult, FindingStatus, Harness, IntegrationState, Integrations,
};
use synapse_desktop_host::protocol::ErrorCode;
use synapse_desktop_host::status::{
    combined_path, compare_versions, diagnose, harness_environment, hook_of, inspect_integrations,
    parse_login_environment, read_login_environment, read_login_path, user_shell, version_in,
    with_login_path, LoginPath, VersionOf,
};
use tempfile::tempdir;

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

// ---------------------------------------------------------------------------------------------
// The PATH of a login shell
// ---------------------------------------------------------------------------------------------

#[cfg(unix)]
mod login {
    use super::*;

    fn shell(dir: &Path, body: &str) -> String {
        let path = dir.join("shell");
        support::executable(&path, &format!("#!/bin/sh\n{body}\n"));
        path.to_string_lossy().to_string()
    }

    #[tokio::test]
    async fn is_what_the_shell_prints_between_the_marks_whatever_its_start_up_files_print() {
        let dir = tempdir().unwrap();
        let path = shell(
            dir.path(),
            r#"echo "welcome"; printf '%s' "__SYNAPSE_PATH__/opt/a:/opt/b__SYNAPSE_PATH__"; echo " bye""#,
        );
        assert_eq!(
            read_login_path(&path).await.as_deref(),
            Some("/opt/a:/opt/b")
        );
    }

    #[tokio::test]
    async fn is_asked_as_an_interactive_login_shell_so_that_what_its_start_up_files_add_is_there() {
        let dir = tempdir().unwrap();
        let path = shell(
            dir.path(),
            r#"case "$1" in -ilc) printf '%s' "__SYNAPSE_PATH__/ok__SYNAPSE_PATH__";; esac"#,
        );
        assert_eq!(read_login_path(&path).await.as_deref(), Some("/ok"));
    }

    #[tokio::test]
    async fn is_the_path_the_shell_expands_from_the_command_it_is_given() {
        let dir = tempdir().unwrap();
        // A shell that runs its command with a PATH of its own, as a login shell would have.
        let path = shell(dir.path(), r#"PATH=/opt/real:/opt/path; shift; eval "$1""#);
        assert_eq!(
            read_login_path(&path).await.as_deref(),
            Some("/opt/real:/opt/path")
        );
    }

    #[tokio::test]
    async fn is_nothing_when_the_shell_says_nothing_fails_or_is_not_there() {
        let dir = tempdir().unwrap();
        assert_eq!(
            read_login_path(&shell(dir.path(), "echo nothing")).await,
            None
        );
        assert_eq!(read_login_path(&shell(dir.path(), "exit 3")).await, None);
        let missing = dir
            .path()
            .join("no-such-shell")
            .to_string_lossy()
            .to_string();
        assert_eq!(read_login_path(&missing).await, None);
    }
}

// ---------------------------------------------------------------------------------------------
// The environment of a login shell, for a harness
// ---------------------------------------------------------------------------------------------

fn variables(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

#[cfg(unix)]
mod login_environment {
    use super::*;

    fn shell(dir: &Path, body: &str) -> String {
        let path = dir.join("shell");
        support::executable(&path, &format!("#!/bin/sh\n{body}\n"));
        path.to_string_lossy().to_string()
    }

    #[tokio::test]
    async fn is_what_env_prints_in_the_shell_whatever_its_start_up_files_print() {
        let dir = tempdir().unwrap();
        // A shell whose start-up files print and export, then run the command it is given.
        let path = shell(
            dir.path(),
            r#"[ "$1" = -ilc ] || exit 9; echo "welcome"; export FROM_RC='two
lines'; shift; eval "$1"; echo " bye""#,
        );
        let got = read_login_environment(&path).await.expect("an environment");
        assert_eq!(got.get("FROM_RC").map(String::as_str), Some("two\nlines"));
        assert!(got.contains_key("PATH"));
    }

    #[tokio::test]
    async fn is_nothing_when_the_shell_says_nothing_fails_or_is_not_there() {
        let dir = tempdir().unwrap();
        assert_eq!(
            read_login_environment(&shell(dir.path(), "echo nothing")).await,
            None
        );
        assert_eq!(
            read_login_environment(&shell(dir.path(), "exit 3")).await,
            None
        );
        let missing = dir.path().join("no-such-shell");
        assert_eq!(
            read_login_environment(&missing.to_string_lossy()).await,
            None
        );
    }
}

#[test]
fn the_login_environment_is_the_entries_between_the_marks_each_ended_by_nul() {
    let got = parse_login_environment(
        "hello\n__SYNAPSE_ENV__A=1\0B=x=y\0C=two\nlines\0EMPTY=\0not an entry\0=nameless\0__SYNAPSE_ENV__bye",
    );
    assert_eq!(
        got,
        Some(variables(&[
            ("A", "1"),
            ("B", "x=y"),
            ("C", "two\nlines"),
            ("EMPTY", ""),
        ]))
    );
    assert_eq!(parse_login_environment("A=1\0"), None);
    assert_eq!(parse_login_environment("__SYNAPSE_ENV__A=1\0"), None);
    assert_eq!(
        parse_login_environment("__SYNAPSE_ENV____SYNAPSE_ENV__"),
        None
    );
}

#[test]
fn a_harness_has_the_login_environment_without_the_shells_own_and_its_path_first() {
    let separator = if cfg!(windows) { ";" } else { ":" };
    let join = |parts: &[&str]| parts.join(separator);
    let own = variables(&[
        ("PATH", &join(&["/app/bundled", "/usr/bin"])),
        ("ONLY_APP", "a"),
    ]);
    let captured = variables(&[
        ("PATH", &join(&["/opt/homebrew/bin", "/usr/bin"])),
        ("FROM_RC", "r"),
        ("PWD", "/x"),
        ("OLDPWD", "/y"),
        ("SHLVL", "2"),
        ("_", "/usr/bin/env"),
        ("TERM", "dumb"),
        ("ZDOTDIR", "/z"),
        ("SYNAPSE_USER_ZDOTDIR", "/u"),
        ("SYNAPSE_SHIM_DIR", "/s"),
    ]);
    let got = harness_environment(Some(&captured), &own);
    assert_eq!(
        got,
        variables(&[
            (
                "PATH",
                &join(&["/opt/homebrew/bin", "/usr/bin", "/app/bundled"])
            ),
            ("FROM_RC", "r"),
        ])
    );
    assert_eq!(harness_environment(None, &own), own);
}

#[test]
fn the_app_takes_the_login_shell_path_first_and_keeps_its_own_directories_once() {
    let separator = if cfg!(windows) { ";" } else { ":" };
    let environment = Environment {
        env: BTreeMap::from([
            ("PATH".to_string(), ["/usr/bin", "/bin"].join(separator)),
            ("HOME".to_string(), "/home/me".to_string()),
        ]),
        home: PathBuf::from("/home/me"),
    };
    let login = ["/opt/homebrew/bin", "/usr/bin"].join(separator);
    let got = with_login_path(environment.clone(), Some(&login));
    assert_eq!(
        got.env.get("PATH").map(String::as_str),
        Some(
            ["/opt/homebrew/bin", "/usr/bin", "/bin"]
                .join(separator)
                .as_str()
        )
    );
    assert_eq!(got.env.get("HOME"), environment.env.get("HOME"));
    // Without an answer from the shell, the PATH it had.
    let alone = with_login_path(environment, None);
    assert_eq!(
        alone.env.get("PATH").map(String::as_str),
        Some(["/usr/bin", "/bin"].join(separator).as_str())
    );
}

#[test]
fn the_user_shell_is_shell_else_the_systems_default() {
    let with = |shell: Option<&str>| Environment {
        env: shell
            .map(|s| BTreeMap::from([("SHELL".to_string(), s.to_string())]))
            .unwrap_or_default(),
        home: PathBuf::from("/home/me"),
    };
    assert_eq!(
        user_shell(&with(Some("/usr/local/bin/fish"))),
        "/usr/local/bin/fish"
    );
    let default = if cfg!(target_os = "macos") {
        "/bin/zsh"
    } else {
        "/bin/sh"
    };
    assert_eq!(user_shell(&with(None)), default);
    assert_eq!(user_shell(&with(Some(""))), default);
}

#[test]
fn the_path_the_doctor_is_given_has_the_login_shell_directories_first_each_once() {
    let separator = if cfg!(windows) { ";" } else { ":" };
    let join = |parts: &[&str]| parts.join(separator);
    assert_eq!(
        combined_path(Some(&join(&["/a", "/b"])), Some(&join(&["/b", "/c"]))),
        join(&["/a", "/b", "/c"])
    );
    assert_eq!(
        combined_path(None, Some(&join(&["/x", "", "/y"]))),
        join(&["/x", "/y"])
    );
    assert_eq!(combined_path(None, None), "");
}

// ---------------------------------------------------------------------------------------------
// diagnose
// ---------------------------------------------------------------------------------------------

fn document(checks: serde_json::Value, counts: serde_json::Value) -> String {
    serde_json::json!({ "format": "synapse-doctor/v1", "checks": checks, "counts": counts })
        .to_string()
}

fn git() -> serde_json::Value {
    serde_json::json!({ "key": "git", "name": "git", "status": "ok", "detail": "git version 2", "value": "" })
}

type Calls = Arc<Mutex<Vec<(Vec<String>, BTreeMap<String, String>)>>>;

fn runner(result: CliResult) -> (CliRunner, Calls) {
    let calls: Calls = Arc::new(Mutex::new(vec![]));
    let kept = calls.clone();
    let runner = CliRunner::new(move |run: CliRun| {
        kept.lock()
            .unwrap()
            .push((run.args.clone(), run.env.clone()));
        let result = result.clone();
        async move { Ok(result) }
    });
    (runner, calls)
}

fn said(stdout: &str, stderr: &str, code: i32) -> CliResult {
    CliResult {
        code,
        stdout: stdout.into(),
        stderr: stderr.into(),
    }
}

fn login(path: Option<&'static str>) -> LoginPath {
    LoginPath::new(move || async move { path.map(String::from) })
}

#[tokio::test]
async fn the_doctor_is_asked_for_the_install_only_as_json_with_the_login_shell_path_added() {
    let counts = serde_json::json!({ "ok": 1, "warn": 0, "fail": 0 });
    let (runner, calls) = runner(said(&document(serde_json::json!([git()]), counts), "", 0));
    let env = environment(Path::new("/h"), &[("PATH", "/process/bin")]);
    let diagnosis = diagnose(config(), &runner, &login(Some("/login/bin")), &env)
        .await
        .unwrap();
    let calls = calls.lock().unwrap();
    assert_eq!(calls[0].0, vec!["doctor", "--install", "--format", "json"]);
    let separator = if cfg!(windows) { ";" } else { ":" };
    assert_eq!(
        calls[0].1["PATH"],
        // Its own PATH first, so that this host's `synapse` is asked and not another copy.
        ["/process/bin", "/login/bin"].join(separator)
    );
    assert_eq!(diagnosis.findings.len(), 1);
    assert_eq!(diagnosis.findings[0].key, "git");
    assert_eq!(diagnosis.counts.ok, 1);
}

#[tokio::test]
async fn a_failed_doctor_has_its_findings_too_which_is_exit_code_1_and_a_document() {
    let failed = serde_json::json!({ "key": "harness", "name": "harness", "status": "fail", "detail": "none", "value": "" });
    let counts = serde_json::json!({ "ok": 0, "warn": 0, "fail": 1 });
    let (runner, _) = runner(said(&document(serde_json::json!([failed]), counts), "", 1));
    let env = environment(Path::new("/h"), &[]);
    let diagnosis = diagnose(config(), &runner, &login(None), &env)
        .await
        .unwrap();
    assert_eq!(diagnosis.findings[0].status, FindingStatus::Fail);
    assert_eq!(diagnosis.counts.fail, 1);
}

#[tokio::test]
async fn it_says_what_the_program_said_when_it_printed_no_document() {
    let env = environment(Path::new("/h"), &[]);
    let (usage, _) = runner(said("", "usage: synapse doctor\n", 2));
    let error = diagnose(config(), &usage, &login(None), &env)
        .await
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::Unavailable);
    assert_eq!(error.message, "usage: synapse doctor");
    let (silent, _) = runner(said("", "", 0));
    let error = diagnose(config(), &silent, &login(None), &env)
        .await
        .unwrap_err();
    assert!(error.message.contains("printed nothing"));
}

#[tokio::test]
async fn a_document_of_a_format_it_does_not_know_is_refused() {
    let env = environment(Path::new("/h"), &[]);
    let other = serde_json::json!({ "format": "synapse-doctor/v2", "checks": [], "counts": {} });
    let (runner, _) = runner(said(&other.to_string(), "", 0));
    let error = diagnose(config(), &runner, &login(None), &env)
        .await
        .unwrap_err();
    assert!(error.message.contains("does not know"));
}

// ---------------------------------------------------------------------------------------------
// Integrations
// ---------------------------------------------------------------------------------------------

const EXE: &str = if cfg!(windows) { ".exe" } else { "" };

fn put(file: &Path, text: &str) {
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(file, text).unwrap();
}

/// A hook program and a `synapse` beside it, in `place`.
fn program(place: &Path) -> PathBuf {
    put(&place.join(format!("synapse{EXE}")), "");
    put(&place.join(format!("synapse-hook{EXE}")), "");
    place.join(format!("synapse-hook{EXE}"))
}

fn claude(hook: &Path) -> String {
    serde_json::json!({
        "hooks": {
            "Stop": [{ "hooks": [{ "type": "command", "command": "other-tool stop" }] }],
            "SessionStart": [{ "hooks": [{ "type": "command", "command": format!("{} session-start", hook.display()) }] }],
        }
    })
    .to_string()
}

struct Shape {
    dir: tempfile::TempDir,
    home: PathBuf,
}

impl Shape {
    fn new() -> Shape {
        let dir = tempdir().unwrap();
        let home = dir.path().join("home");
        fs::create_dir_all(&home).unwrap();
        Shape { dir, home }
    }

    fn at(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }

    fn path_of(&self, name: &str) -> String {
        self.at(name).to_string_lossy().to_string()
    }
}

fn versions(known: &[(PathBuf, &str)]) -> VersionOf {
    let known: BTreeMap<PathBuf, String> = known
        .iter()
        .map(|(p, v)| (p.clone(), v.to_string()))
        .collect();
    VersionOf::new(move |program| {
        let said = known.get(&program).cloned();
        async move { said }
    })
}

#[test]
fn the_hook_of_claude_code_is_read_from_its_settings_whatever_else_is_there() {
    let s = Shape::new();
    assert_eq!(hook_of(Harness::Claude, &s.home), None);
    put(
        &s.home.join(".claude/settings.json"),
        &claude(Path::new("/opt/synapse/bin/synapse-hook")),
    );
    assert_eq!(
        hook_of(Harness::Claude, &s.home).as_deref(),
        Some("/opt/synapse/bin/synapse-hook")
    );
}

#[test]
fn the_hook_of_codex_is_read_from_its_hooks_and_of_opencode_from_its_plugin() {
    let s = Shape::new();
    put(
        &s.home.join(".codex/hooks.json"),
        &claude(Path::new("/c/bin/synapse-hook")),
    );
    assert_eq!(
        hook_of(Harness::Codex, &s.home).as_deref(),
        Some("/c/bin/synapse-hook")
    );
    put(
        &s.home.join(".config/opencode/plugin/synapse.js"),
        "const HOOK_BIN = process.env.SYNAPSE_HOOK_BIN || \"/o/bin/synapse-hook\"\n",
    );
    assert_eq!(
        hook_of(Harness::Opencode, &s.home).as_deref(),
        Some("/o/bin/synapse-hook")
    );
}

#[test]
fn no_hook_is_found_in_a_plugin_never_given_one_in_files_that_are_not_json_or_one_that_only_ends_so(
) {
    let s = Shape::new();
    put(
        &s.home.join(".config/opencode/plugin/synapse.js"),
        "const HOOK_BIN = process.env.SYNAPSE_HOOK_BIN || \"__SYNAPSE_HOOK_BIN__\"\n",
    );
    assert_eq!(hook_of(Harness::Opencode, &s.home), None);
    put(&s.home.join(".claude/settings.json"), "{ not json");
    assert_eq!(hook_of(Harness::Claude, &s.home), None);
    put(
        &s.home.join(".claude/settings.json"),
        r#"{"hooks":{"Stop":"nope"}}"#,
    );
    assert_eq!(hook_of(Harness::Claude, &s.home), None);
    put(
        &s.home.join(".claude/settings.json"),
        &claude(Path::new("/x/not-synapse-hook")),
    );
    assert_eq!(hook_of(Harness::Claude, &s.home), None);
}

fn states(result: &Integrations) -> Vec<(Harness, IntegrationState)> {
    result
        .harnesses
        .iter()
        .map(|h| (h.harness, h.state))
        .collect()
}

#[tokio::test]
async fn a_harness_is_absent_with_no_hook_and_it_says_what_the_app_would_install() {
    let s = Shape::new();
    let mine = program(&s.at("mine"));
    let env = environment(&s.home, &[("PATH", &s.path_of("mine"))]);
    let v = versions(&[(s.at("mine").join(format!("synapse{EXE}")), "1.2.0")]);
    let result = inspect_integrations(&env, &v, &[]).await;
    assert_eq!(
        result.bundled.hook.as_deref(),
        Some(mine.to_string_lossy().as_ref())
    );
    assert_eq!(result.bundled.version.as_deref(), Some("1.2.0"));
    assert_eq!(
        states(&result),
        vec![
            (Harness::Claude, IntegrationState::Absent),
            (Harness::Codex, IntegrationState::Absent),
            (Harness::Opencode, IntegrationState::Absent),
        ]
    );
}

#[tokio::test]
async fn a_harness_is_current_when_its_hook_is_the_one_of_the_synapse_the_app_has_or_its_version() {
    let s = Shape::new();
    let mine = program(&s.at("mine"));
    let other = program(&s.at("other"));
    let v = versions(&[
        (s.at("mine").join(format!("synapse{EXE}")), "1.2.0"),
        (s.at("other").join(format!("synapse{EXE}")), "1.2.0"),
    ]);
    put(&s.home.join(".claude/settings.json"), &claude(&mine));
    put(&s.home.join(".codex/hooks.json"), &claude(&other));
    let env = environment(&s.home, &[("PATH", &s.path_of("mine"))]);
    let result = inspect_integrations(&env, &v, &[]).await;
    assert_eq!(result.harnesses[0].state, IntegrationState::Current);
    assert_eq!(result.harnesses[0].version.as_deref(), Some("1.2.0"));
    assert_eq!(result.harnesses[1].state, IntegrationState::Current);
}

#[tokio::test]
async fn a_harness_is_different_when_its_hook_is_of_another_copy_of_another_version() {
    let s = Shape::new();
    program(&s.at("mine"));
    let old = program(&s.at("old"));
    let v = versions(&[
        (s.at("mine").join(format!("synapse{EXE}")), "1.2.0"),
        (s.at("old").join(format!("synapse{EXE}")), "1.0.0"),
    ]);
    put(&s.home.join(".claude/settings.json"), &claude(&old));
    let env = environment(&s.home, &[("PATH", &s.path_of("mine"))]);
    let result = inspect_integrations(&env, &v, &[]).await;
    assert_eq!(result.harnesses[0].state, IntegrationState::Different);
    assert_eq!(result.harnesses[0].version.as_deref(), Some("1.0.0"));
}

#[tokio::test]
async fn a_harness_is_broken_when_the_hook_it_names_is_not_there() {
    let s = Shape::new();
    put(
        &s.home.join(".claude/settings.json"),
        &claude(&s.at("gone/synapse-hook")),
    );
    let env = environment(&s.home, &[("PATH", "")]);
    let result = inspect_integrations(&env, &versions(&[]), &[]).await;
    assert_eq!(result.harnesses[0].state, IntegrationState::Broken);
    assert_eq!(result.harnesses[0].version, None);
}

#[tokio::test]
async fn a_harness_is_installed_when_there_is_no_synapse_of_the_apps_own_to_compare_with() {
    let s = Shape::new();
    let theirs = program(&s.at("theirs"));
    put(&s.home.join(".claude/settings.json"), &claude(&theirs));
    let env = environment(&s.home, &[("PATH", "")]);
    let result = inspect_integrations(&env, &versions(&[]), &[]).await;
    assert_eq!(result.bundled.hook, None);
    assert_eq!(result.harnesses[0].state, IntegrationState::Installed);
}

#[tokio::test]
async fn a_harness_with_a_newer_synapse_is_newer_and_its_version_is_read_from_the_npm_package() {
    let s = Shape::new();
    let mine = s.at("mine");
    program(&mine);
    let installed = program(&s.at("node_modules/@imunitic/synapse-x/bin"));
    put(
        &s.at("node_modules/@imunitic/synapse-x/package.json"),
        r#"{"name":"@imunitic/synapse-x","version":"0.18.0"}"#,
    );
    put(&s.home.join(".claude/settings.json"), &claude(&installed));
    let env = environment(&s.home, &[("PATH", &mine.to_string_lossy())]);
    let v = versions(&[(mine.join(format!("synapse{EXE}")), "0.0.0-dev")]);
    let result = inspect_integrations(&env, &v, &[]).await;
    assert_eq!(result.harnesses[0].state, IntegrationState::Newer);
    assert_eq!(result.harnesses[0].version.as_deref(), Some("0.18.0"));
}

#[tokio::test]
async fn a_package_json_that_is_not_one_of_synapses_is_not_read() {
    let s = Shape::new();
    program(&s.at("mine"));
    let installed = program(&s.at("other/bin"));
    put(
        &s.at("other/package.json"),
        r#"{"name":"something","version":"9.9.9"}"#,
    );
    put(&s.home.join(".claude/settings.json"), &claude(&installed));
    let env = environment(&s.home, &[("PATH", &s.path_of("mine"))]);
    let result = inspect_integrations(&env, &versions(&[]), &[]).await;
    assert_eq!(result.harnesses[0].state, IntegrationState::Different);
    assert_eq!(result.harnesses[0].version, None);
}

#[test]
fn versions_are_compared_by_their_numbers_a_pre_release_being_older_than_its_release() {
    assert_eq!(compare_versions("0.17.0", "0.0.0-dev"), Some(1));
    assert_eq!(compare_versions("0.0.0-dev", "0.17.0"), Some(-1));
    assert_eq!(compare_versions("1.2.3", "1.2.3"), Some(0));
    assert_eq!(compare_versions("1.10.0", "1.9.9"), Some(1));
    assert_eq!(compare_versions("1.2.3-rc1", "1.2.3"), Some(-1));
    assert_eq!(compare_versions("v2.0.0", "1.9.0"), Some(1));
    assert_eq!(compare_versions("0.0.0-dev", "0.0.0-dev"), Some(0));
    assert_eq!(compare_versions("unknown", "1.0.0"), None);
    assert_eq!(compare_versions("1.0", "1.0.0"), None);
}

#[test]
fn the_version_a_program_says_is_what_follows_its_name() {
    assert_eq!(
        version_in("synapse 3.4.5-rc1\n").as_deref(),
        Some("3.4.5-rc1")
    );
    assert_eq!(version_in("nothing"), None);
}

#[cfg(unix)]
#[tokio::test]
async fn the_program_is_run_for_its_version_and_one_that_is_not_there_has_none() {
    let dir = tempdir().unwrap();
    support::executable(
        &dir.path().join("synapse"),
        "#!/bin/sh\necho \"synapse 3.4.5-rc1\"\n",
    );
    // The app's own `synapse` says what it says.
    let env = environment(dir.path(), &[("PATH", &dir.path().to_string_lossy())]);
    let result = inspect_integrations(&env, &VersionOf::program(), &[]).await;
    assert_eq!(result.bundled.version.as_deref(), Some("3.4.5-rc1"));
    let none = environment(dir.path(), &[("PATH", "")]);
    assert_eq!(
        inspect_integrations(&none, &VersionOf::program(), &[])
            .await
            .bundled
            .version,
        None
    );
}
