//! What each harness remembers of its own use, read from where it keeps it: the folders it works in
//! and the sessions it kept. The same cases as the Node host's `history.test.ts`.

mod support;

use filetime::{set_file_mtime, FileTime};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use support::environment;
use synapse_desktop_host::history::{
    claude_session_head, claude_sessions_of, claude_workspaces, claude_workspaces_of,
    codex_session_head, codex_sessions_of, codex_workspaces, codex_workspaces_of, list_sessions,
    list_workspaces, newest_first, opencode_database, opencode_sessions, opencode_workspaces,
    project_folder_name, title_of,
};
use synapse_desktop_host::messages::{PastSession, Workspace};
use synapse_desktop_host::time::iso_millis;
use tempfile::{tempdir, TempDir};

fn folder(root: &TempDir, name: &str) -> PathBuf {
    let path = root.path().join(name);
    fs::create_dir_all(&path).unwrap();
    path
}

fn workspace(path: &str, last_used: Option<&str>) -> Workspace {
    Workspace {
        path: path.into(),
        last_used: last_used.map(String::from),
    }
}

fn at(seconds: i64) -> FileTime {
    FileTime::from_unix_time(seconds, 0)
}

/// 2026-01-01, 2026-02-01, 2026-03-01 and 2026-03-02, as seconds.
const JAN_1: i64 = 1_767_225_600;
const FEB_1: i64 = JAN_1 + 31 * 86_400;
const MAR_1: i64 = FEB_1 + 28 * 86_400;
const MAR_2: i64 = MAR_1 + 86_400;

fn iso(seconds: i64) -> String {
    iso_millis(seconds * 1000)
}

#[test]
fn times_are_written_as_iso_text_with_milliseconds() {
    assert_eq!(iso_millis(0), "1970-01-01T00:00:00.000Z");
    assert_eq!(iso_millis(3000), "1970-01-01T00:00:03.000Z");
    assert_eq!(iso(JAN_1), "2026-01-01T00:00:00.000Z");
    assert_eq!(iso(MAR_2), "2026-03-02T00:00:00.000Z");
    assert_eq!(iso_millis(1_700_000_000_123), "2023-11-14T22:13:20.123Z");
    // A leap day.
    assert_eq!(iso_millis(1_709_164_800_000), "2024-02-29T00:00:00.000Z");
}

// ---------------------------------------------------------------------------------------------
// Claude Code
// ---------------------------------------------------------------------------------------------

fn claude_file() -> String {
    json!({
        "oauthAccount": { "emailAddress": "someone@example.com" },
        "projects": {
            "/a": { "hasTrustDialogAccepted": true, "lastSessionModified": 1000 },
            "/b": { "hasTrustDialogAccepted": true, "lastSessionModified": 3000 },
            "/c": { "hasTrustDialogAccepted": false, "lastSessionModified": 9000 },
            "/d": { "hasTrustDialogAccepted": true },
            "/e": { "allowedTools": [] },
            "/f": "not an entry",
        }
    })
    .to_string()
}

#[test]
fn the_folders_claude_is_allowed_in_are_the_allowed_ones_the_newest_first_those_with_no_time_last()
{
    assert_eq!(
        claude_workspaces(&claude_file()),
        vec![
            workspace("/b", Some(&iso_millis(3000))),
            workspace("/a", Some(&iso_millis(1000))),
            workspace("/d", None),
        ]
    );
    // Nothing of the rest of the file.
    assert!(!serde_json::to_string(&claude_workspaces(&claude_file()))
        .unwrap()
        .contains("someone@example.com"));
}

#[test]
fn there_are_none_for_a_file_that_is_not_json_or_has_no_projects() {
    assert!(claude_workspaces("{ nope").is_empty());
    assert!(claude_workspaces(r#"{"projects": []}"#).is_empty());
    assert!(claude_workspaces("").is_empty());
}

#[test]
fn claude_folders_are_read_from_the_folder_claude_config_dir_names_else_the_home_folder() {
    let root = tempdir().unwrap();
    let other = folder(&root, "claude-config");
    fs::write(other.join(".claude.json"), claude_file()).unwrap();
    let named = environment(
        Path::new("/nowhere"),
        &[("CLAUDE_CONFIG_DIR", &other.to_string_lossy())],
    );
    let paths: Vec<String> = claude_workspaces_of(&named)
        .into_iter()
        .map(|w| w.path)
        .collect();
    assert_eq!(paths, vec!["/b", "/a", "/d"]);
    let home = folder(&root, "home");
    fs::write(home.join(".claude.json"), claude_file()).unwrap();
    assert_eq!(claude_workspaces_of(&environment(&home, &[])).len(), 3);
    assert!(claude_workspaces_of(&environment(Path::new("/nowhere"), &[])).is_empty());
}

#[test]
fn a_sessions_folder_is_the_path_with_everything_but_letters_and_digits_a_hyphen() {
    assert_eq!(
        project_folder_name("/Users/a/.emacs.d"),
        "-Users-a--emacs-d"
    );
    assert_eq!(
        project_folder_name("/Users/a/Development/synapse/main"),
        "-Users-a-Development-synapse-main"
    );
}

#[test]
fn a_folder_with_no_time_is_named_by_when_its_sessions_folder_last_changed() {
    let root = tempdir().unwrap();
    let home = folder(&root, "home");
    let projects = home.join(".claude/projects");
    let older = projects.join(project_folder_name("/older"));
    let newer = projects.join(project_folder_name("/newer"));
    fs::create_dir_all(&older).unwrap();
    fs::create_dir_all(&newer).unwrap();
    set_file_mtime(&older, at(JAN_1)).unwrap();
    set_file_mtime(&newer, at(MAR_1)).unwrap();
    fs::write(
        home.join(".claude.json"),
        json!({ "projects": {
            "/older": { "hasTrustDialogAccepted": true },
            "/never": { "hasTrustDialogAccepted": true },
            "/newer": { "hasTrustDialogAccepted": true },
        } })
        .to_string(),
    )
    .unwrap();
    let found = claude_workspaces_of(&environment(&home, &[]));
    let paths: Vec<&str> = found.iter().map(|w| w.path.as_str()).collect();
    assert_eq!(paths, vec!["/newer", "/older", "/never"]);
    assert_eq!(found[0].last_used.as_deref(), Some(iso(MAR_1).as_str()));
    assert_eq!(found[2].last_used, None);
}

fn line(value: Value) -> String {
    value.to_string() + "\n"
}

#[test]
fn a_claude_session_file_says_its_folder_and_the_last_title_the_harness_gave_it() {
    let text = line(json!({ "type": "file-history-snapshot" }))
        + &line(json!({ "type": "user", "cwd": "/work/one", "message": { "content": "hello" } }))
        + &line(json!({ "type": "ai-title", "aiTitle": "First title" }))
        + &line(json!({ "type": "last-prompt", "lastPrompt": "the last prompt" }))
        + &line(json!({ "type": "ai-title", "aiTitle": "Better title" }))
        + &line(json!({ "type": "user", "cwd": "/work/two" }));
    assert_eq!(
        claude_session_head(&text),
        (Some("/work/one".into()), Some("Better title".into()))
    );
}

#[test]
fn the_last_prompt_is_the_title_when_there_is_none_and_a_long_or_cut_line_is_not_read() {
    let text = line(json!({ "cwd": "/w" }))
        + &line(json!({ "type": "last-prompt", "lastPrompt": "fix\nthe   bug" }));
    assert_eq!(
        claude_session_head(&text),
        (Some("/w".into()), Some("fix the bug".into()))
    );

    let long =
        line(json!({ "type": "user", "cwd": "/in/a/long/line", "blob": "x".repeat(300_000) }));
    let cut = r#"{"type":"ai-title","aiTitle":"Cut of"#;
    assert_eq!(
        claude_session_head(&(long + &line(json!({ "cwd": "/short" })) + cut)),
        (Some("/short".into()), None)
    );
    assert_eq!(claude_session_head("not json\n"), (None, None));
}

#[test]
fn the_newest_claude_session_files_are_listed_by_the_folder_and_title_they_say() {
    let root = tempdir().unwrap();
    let home = folder(&root, "home");
    let work = folder(&root, "work-one");
    let projects = home.join(".claude/projects/-work-one");
    fs::create_dir_all(&projects).unwrap();
    let body = |title: &str| {
        line(json!({ "type": "user", "cwd": work }))
            + &line(json!({ "type": "ai-title", "aiTitle": title }))
    };
    fs::write(projects.join("aaa-111.jsonl"), body("Old one")).unwrap();
    fs::write(projects.join("bbb-222.jsonl"), body("New one")).unwrap();
    fs::write(projects.join("empty.jsonl"), "").unwrap();
    fs::write(projects.join("notes.txt"), "x").unwrap();
    set_file_mtime(projects.join("aaa-111.jsonl"), at(JAN_1)).unwrap();
    set_file_mtime(projects.join("bbb-222.jsonl"), at(FEB_1)).unwrap();
    let found = claude_sessions_of(&environment(&home, &[]));
    let path = work.to_string_lossy().to_string();
    assert_eq!(
        found,
        vec![
            PastSession {
                id: "bbb-222".into(),
                path: path.clone(),
                title: Some("New one".into()),
                last_used: Some(iso(FEB_1))
            },
            PastSession {
                id: "aaa-111".into(),
                path,
                title: Some("Old one".into()),
                last_used: Some(iso(JAN_1))
            },
        ]
    );
}

// ---------------------------------------------------------------------------------------------
// Codex
// ---------------------------------------------------------------------------------------------

fn toml() -> String {
    [
        "model = \"x\"",
        "[projects.\"/a b\"]",
        "trust_level = \"trusted\"",
        "",
        "[projects.'/lit']",
        "trust_level = \"trusted\"  # approved",
        "[projects.\"/untrusted\"]",
        "trust_level = \"untrusted\"",
        "[projects.\"/with \\\"quote\\\"\"]",
        "trust_level = \"trusted\"",
        "[other]",
        "trust_level = \"trusted\"",
    ]
    .join("\n")
}

#[test]
fn the_folders_codex_trusts_are_the_trusted_tables_the_last_one_in_the_file_first() {
    assert_eq!(
        codex_workspaces(&toml()),
        vec![
            workspace("/with \"quote\"", None),
            workspace("/lit", None),
            workspace("/a b", None)
        ]
    );
}

#[test]
fn codex_folders_are_read_from_codex_home_else_the_dot_codex_folder_of_the_home_folder() {
    let root = tempdir().unwrap();
    let home = folder(&root, "home");
    fs::create_dir_all(home.join(".codex")).unwrap();
    fs::write(home.join(".codex/config.toml"), toml()).unwrap();
    assert_eq!(codex_workspaces_of(&environment(&home, &[])).len(), 3);
    let other = folder(&root, "codex-home");
    fs::write(
        other.join("config.toml"),
        "[projects.\"/x\"]\ntrust_level = \"trusted\"\n",
    )
    .unwrap();
    let named = environment(&home, &[("CODEX_HOME", &other.to_string_lossy())]);
    assert_eq!(codex_workspaces_of(&named), vec![workspace("/x", None)]);
}

fn rollout_meta(id: &str, cwd: &str) -> String {
    line(json!({ "type": "session_meta", "payload": { "id": id, "cwd": cwd } }))
}

fn user_message(text: &str) -> String {
    line(json!({
        "type": "response_item",
        "payload": { "type": "message", "role": "user", "content": [{ "type": "input_text", "text": text }] },
    }))
}

#[test]
fn a_codex_rollout_says_its_id_its_folder_and_the_first_prompt_that_is_not_context() {
    let context = user_message("<environment_context>\n  <cwd>/work</cwd>");
    let text = rollout_meta("abc", "/work")
        + &context
        + &user_message("check the design")
        + &user_message("later");
    assert_eq!(
        codex_session_head(&text),
        (
            Some("abc".into()),
            Some("/work".into()),
            Some("check the design".into())
        )
    );
    assert_eq!(
        codex_session_head(&(rollout_meta("abc", "/work") + &context)),
        (Some("abc".into()), Some("/work".into()), None)
    );
    assert_eq!(
        codex_session_head(&user_message("hi")),
        (None, None, Some("hi".into()))
    );
    let reply = line(json!({
        "type": "response_item",
        "payload": { "type": "message", "role": "assistant", "content": [{ "text": "Sure" }] },
    }));
    assert_eq!(
        codex_session_head(&(rollout_meta("abc", "/work") + &reply)).2,
        None
    );
}

#[test]
fn the_newest_rollout_files_of_codex_are_listed_the_newest_day_first() {
    let root = tempdir().unwrap();
    let home = folder(&root, "home");
    let a = folder(&root, "a");
    let b = folder(&root, "b");
    let day = |d: &str| {
        let path = d
            .split('-')
            .fold(home.join(".codex/sessions"), |p, part| p.join(part));
        fs::create_dir_all(&path).unwrap();
        path
    };
    let rollout = |id: &str, cwd: &Path, text: &str| {
        rollout_meta(id, &cwd.to_string_lossy()) + &user_message(text)
    };
    let old = day("2026-03-01").join("rollout-2026-03-01T10-00-00-old.jsonl");
    let new = day("2026-03-02").join("rollout-2026-03-02T09-00-00-new.jsonl");
    fs::write(&old, rollout("old", &a, "older")).unwrap();
    fs::write(&new, rollout("new", &b, "newer")).unwrap();
    fs::write(
        day("2026-03-02").join("other.jsonl"),
        rollout("x", &a, "not a rollout"),
    )
    .unwrap();
    // Last used is when the file last changed.
    set_file_mtime(&old, at(MAR_1)).unwrap();
    set_file_mtime(&new, at(MAR_2)).unwrap();
    let found = codex_sessions_of(&environment(&home, &[]));
    let summary: Vec<(&str, &str, Option<&str>)> = found
        .iter()
        .map(|s| (s.id.as_str(), s.path.as_str(), s.title.as_deref()))
        .collect();
    assert_eq!(
        summary,
        vec![
            ("new", b.to_str().unwrap(), Some("newer")),
            ("old", a.to_str().unwrap(), Some("older")),
        ]
    );
    assert_eq!(found[0].last_used.as_deref(), Some(iso(MAR_2).as_str()));
}

// ---------------------------------------------------------------------------------------------
// OpenCode
// ---------------------------------------------------------------------------------------------

const COLUMNS: &str =
    "(id text primary key, parent_id text, directory text not null, time_updated integer not null)";

const ROWS: &[(&str, Option<&str>, &str, i64)] = &[
    ("1", None, "/old", 1000),
    ("2", None, "/new", 5000),
    ("3", None, "/new", 4000),
    ("4", Some("1"), "/child-only", 9000),
    ("5", None, "", 8000),
];

fn database(root: &TempDir, tables: &[&str]) -> PathBuf {
    let file = root
        .path()
        .join(format!("opencode-{}.db", tables.join("-")));
    let db = rusqlite::Connection::open(&file).unwrap();
    for table in tables {
        db.execute_batch(&format!("create table {table} {COLUMNS}"))
            .unwrap();
        for (id, parent, directory, used) in ROWS {
            db.execute(
                &format!("insert into {table} values (?1, ?2, ?3, ?4)"),
                rusqlite::params![id, parent, directory, used],
            )
            .unwrap();
        }
    }
    file
}

fn expected_folders() -> Vec<Workspace> {
    vec![
        workspace("/new", Some(&iso_millis(5000))),
        workspace("/old", Some(&iso_millis(1000))),
    ]
}

#[test]
fn opencode_folders_are_those_of_its_own_sessions_once_each_the_most_recent_first() {
    let root = tempdir().unwrap();
    assert_eq!(
        opencode_workspaces(&database(&root, &["session_v2"])),
        expected_folders()
    );
}

#[test]
fn they_are_read_from_the_older_table_by_a_version_that_has_no_session_v2() {
    let root = tempdir().unwrap();
    assert_eq!(
        opencode_workspaces(&database(&root, &["session"])),
        expected_folders()
    );
}

#[test]
fn session_v2_is_read_and_not_the_older_table_when_both_are_there() {
    let root = tempdir().unwrap();
    let file = root.path().join("both.db");
    let db = rusqlite::Connection::open(&file).unwrap();
    db.execute_batch(&format!(
        "create table session {COLUMNS}; create table session_v2 {COLUMNS};"
    ))
    .unwrap();
    db.execute("insert into session values ('1', null, '/stale', 9000)", [])
        .unwrap();
    db.execute(
        "insert into session_v2 values ('1', null, '/current', 1000)",
        [],
    )
    .unwrap();
    drop(db);
    let paths: Vec<String> = opencode_workspaces(&file)
        .into_iter()
        .map(|w| w.path)
        .collect();
    assert_eq!(paths, vec!["/current"]);
}

#[test]
fn there_are_none_when_there_is_no_database() {
    let root = tempdir().unwrap();
    assert!(opencode_workspaces(&root.path().join("missing.db")).is_empty());
    assert!(opencode_sessions(&root.path().join("missing.db")).is_empty());
}

#[test]
fn the_database_is_found_in_xdg_data_home_else_the_share_folder_of_the_home_folder() {
    let root = tempdir().unwrap();
    let data = folder(&root, "data");
    fs::create_dir_all(data.join("opencode")).unwrap();
    let source = database(&root, &["session_v2"]);
    fs::copy(&source, data.join("opencode/opencode.db")).unwrap();
    let named = environment(
        Path::new("/nowhere"),
        &[("XDG_DATA_HOME", &data.to_string_lossy())],
    );
    assert_eq!(opencode_workspaces(&opencode_database(&named)).len(), 2);
    let home = folder(&root, "home");
    fs::create_dir_all(home.join(".local/share/opencode")).unwrap();
    fs::copy(&source, home.join(".local/share/opencode/opencode.db")).unwrap();
    assert_eq!(
        opencode_workspaces(&opencode_database(&environment(&home, &[]))).len(),
        2
    );
}

#[test]
fn the_newest_top_level_sessions_of_opencode_are_listed_with_their_titles() {
    let root = tempdir().unwrap();
    let file = root.path().join("sessions.db");
    let db = rusqlite::Connection::open(&file).unwrap();
    db.execute_batch(
        "create table session_v2 (id text primary key, parent_id text, directory text not null, title text, time_updated integer not null)",
    )
    .unwrap();
    for row in [
        "('ses_1', null, '/a', 'Older', 1000)",
        "('ses_2', null, '/b', null, 5000)",
        "('ses_3', 'ses_1', '/a', 'A child', 9000)",
        "('ses_4', null, '', 'No folder', 8000)",
    ] {
        db.execute(&format!("insert into session_v2 values {row}"), [])
            .unwrap();
    }
    drop(db);
    assert_eq!(
        opencode_sessions(&file),
        vec![
            PastSession {
                id: "ses_2".into(),
                path: "/b".into(),
                title: None,
                last_used: Some(iso_millis(5000))
            },
            PastSession {
                id: "ses_1".into(),
                path: "/a".into(),
                title: Some("Older".into()),
                last_used: Some(iso_millis(1000))
            },
        ]
    );
}

// ---------------------------------------------------------------------------------------------
// The order, and the same question of every harness
// ---------------------------------------------------------------------------------------------

#[test]
fn the_newest_come_first_and_those_with_no_time_keep_their_order_after() {
    let found = vec![
        workspace("x", None),
        workspace("a", Some("2026-01-01T00:00:00.000Z")),
        workspace("y", None),
        workspace("b", Some("2026-02-01T00:00:00.000Z")),
    ];
    let paths: Vec<String> = newest_first(&found, |w| w.last_used.as_deref())
        .into_iter()
        .map(|w| w.path)
        .collect();
    assert_eq!(paths, vec!["b", "a", "x", "y"]);
}

#[test]
fn a_title_is_one_line_cut_at_a_length_that_fits_a_row() {
    assert_eq!(title_of("fix\n the   bug").as_deref(), Some("fix the bug"));
    assert_eq!(title_of("  \n "), None);
    let long = "word ".repeat(40);
    let title = title_of(&long).unwrap();
    assert_eq!(title.chars().count(), 90);
    assert!(title.ends_with('…'));
}

#[test]
fn every_harness_is_given_a_list_without_the_folders_that_are_gone() {
    let root = tempdir().unwrap();
    let home = folder(&root, "home");
    let here = folder(&root, "here");
    fs::write(
        home.join(".claude.json"),
        json!({ "projects": {
            here.to_string_lossy(): { "hasTrustDialogAccepted": true },
            root.path().join("deleted").to_string_lossy(): { "hasTrustDialogAccepted": true },
        } })
        .to_string(),
    )
    .unwrap();
    let all = list_workspaces(&environment(&home, &[]));
    assert_eq!(all.claude, vec![workspace(&here.to_string_lossy(), None)]);
    assert!(all.codex.is_empty() && all.opencode.is_empty());
}

#[test]
fn a_harness_whose_files_are_unreadable_gives_none_and_the_others_are_as_they_are() {
    let root = tempdir().unwrap();
    let home = folder(&root, "home");
    let here = folder(&root, "here");
    fs::write(home.join(".claude.json"), "{ nope").unwrap();
    fs::create_dir_all(home.join(".codex")).unwrap();
    fs::write(
        home.join(".codex/config.toml"),
        format!(
            "[projects.\"{}\"]\ntrust_level = \"trusted\"\n",
            here.display().to_string().replace('\\', "\\\\")
        ),
    )
    .unwrap();
    let all = list_workspaces(&environment(&home, &[]));
    assert!(all.claude.is_empty());
    assert_eq!(all.codex.len(), 1);
}

#[test]
fn sessions_are_listed_for_every_harness_without_those_whose_folder_is_gone_at_most_so_many() {
    let root = tempdir().unwrap();
    let home = folder(&root, "home");
    let here = folder(&root, "here");
    let projects = home.join(".claude/projects/-here");
    fs::create_dir_all(&projects).unwrap();
    for i in 0..30 {
        let cwd = if i == 0 {
            root.path().join("gone")
        } else {
            here.clone()
        };
        let file = projects.join(format!("s{i:02}.jsonl"));
        fs::write(&file, line(json!({ "type": "user", "cwd": cwd }))).unwrap();
        set_file_mtime(&file, at(JAN_1 + i * 60)).unwrap();
    }
    let all = list_sessions(&environment(&home, &[]));
    assert_eq!(all.claude.len(), 20);
    assert!(all.claude.iter().all(|s| s.path == here.to_string_lossy()));
    assert!(all.codex.is_empty() && all.opencode.is_empty());
}
