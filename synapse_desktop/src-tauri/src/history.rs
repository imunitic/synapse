//! What a harness remembers of its own use: the folders it works in and the sessions it kept, read
//! from where each keeps them. A file that is missing or cannot be read gives none.

use crate::environment::Environment;
use crate::messages::{ByHarness, PastSession, Workspace};
use crate::time::iso_of;
use serde_json::{Map, Value};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

pub const MAX_WORKSPACES: usize = 50;
/// How many sessions are listed for a harness, and how many of the newest files are looked into to
/// find them.
pub const MAX_SESSIONS: usize = 20;
pub const CANDIDATES: usize = 2 * MAX_SESSIONS;

/// The most recently used first; those with no time keep the order they came in, after.
pub fn newest_first<T: Clone>(found: &[T], used: impl Fn(&T) -> Option<&str>) -> Vec<T> {
    let mut dated: Vec<T> = found
        .iter()
        .filter(|w| used(w).is_some())
        .cloned()
        .collect();
    let undated = found.iter().filter(|w| used(w).is_none()).cloned();
    // The sort is stable, so equal times keep their order, as in the page's own.
    dated.sort_by(|a, b| used(b).unwrap_or("").cmp(used(a).unwrap_or("")));
    dated.into_iter().chain(undated).collect()
}

fn workspaces_first(found: &[Workspace]) -> Vec<Workspace> {
    newest_first(found, |w| w.last_used.as_deref())
}

fn sessions_first(found: &[PastSession]) -> Vec<PastSession> {
    newest_first(found, |s| s.last_used.as_deref())
}

/// The first words of a prompt, as a title: one line, cut at a length that fits a row.
pub fn title_of(text: &str) -> Option<String> {
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.is_empty() {
        return None;
    }
    Some(if line.chars().count() > 90 {
        format!("{}…", line.chars().take(89).collect::<String>())
    } else {
        line
    })
}

/// The start of a file, as text: at most `bytes` of it, so that a session file of many megabytes is
/// not read in full.
pub fn head(path: &Path, bytes: usize) -> String {
    let Ok(file) = fs::File::open(path) else {
        return String::new();
    };
    let mut buffer = Vec::new();
    let _ = file.take(bytes as u64).read_to_end(&mut buffer);
    String::from_utf8_lossy(&buffer).to_string()
}

/// A line of JSON that is not too long to be worth reading, or none.
pub fn json_line(line: &str, longest: usize) -> Option<Map<String, Value>> {
    if line.len() > longest || !line.starts_with('{') {
        return None;
    }
    match serde_json::from_str::<Value>(line).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

fn modified(path: &Path) -> Option<std::time::SystemTime> {
    fs::metadata(path).ok()?.modified().ok()
}

// ---------------------------------------------------------------------------------------------
// Claude Code
// ---------------------------------------------------------------------------------------------

/// The folders of `.claude.json` that Claude Code has been allowed to work in. Only the folder,
/// whether it was allowed and when it was last used are read: the file holds more.
pub fn claude_workspaces(text: &str) -> Vec<Workspace> {
    let Ok(Value::Object(document)) = serde_json::from_str::<Value>(text) else {
        return vec![];
    };
    let Some(Value::Object(projects)) = document.get("projects") else {
        return vec![];
    };
    let mut found = Vec::new();
    for (path, entry) in projects {
        let Value::Object(entry) = entry else {
            continue;
        };
        if entry.get("hasTrustDialogAccepted") != Some(&Value::Bool(true)) {
            continue;
        }
        let used = entry
            .get("lastSessionModified")
            .and_then(Value::as_f64)
            .map(|ms| crate::time::iso_millis(ms as i64));
        found.push(Workspace {
            path: path.clone(),
            last_used: used,
        });
    }
    workspaces_first(&found)
}

/// Where a session file says its folder is, and what it is called, from the start of the file. A
/// line that holds a whole request or a file is long and is not read.
pub fn claude_session_head(text: &str) -> (Option<String>, Option<String>) {
    let (mut cwd, mut named, mut prompt) = (None, None, None);
    for line in text.split('\n') {
        let Some(record) = json_line(line, 200_000) else {
            continue;
        };
        if cwd.is_none() {
            if let Some(Value::String(c)) = record.get("cwd") {
                cwd = Some(c.clone());
            }
        }
        let kind = record.get("type").and_then(Value::as_str);
        if kind == Some("ai-title") {
            if let Some(Value::String(t)) = record.get("aiTitle") {
                named = Some(t.clone());
            }
        }
        if kind == Some("last-prompt") {
            if let Some(Value::String(t)) = record.get("lastPrompt") {
                prompt = Some(t.clone());
            }
        }
    }
    (cwd, title_of(named.or(prompt).as_deref().unwrap_or("")))
}

/// How much of the start of a session file is read: the title is in the first few hundred kilobytes
/// of a file that can be tens of megabytes.
const CLAUDE_HEAD_BYTES: usize = 1024 * 1024;

/// The folder of the sessions of a working folder: its path with every character that is not a
/// letter or a digit made a hyphen.
pub fn project_folder_name(path: &str) -> String {
    path.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

fn claude_paths(environment: &Environment) -> (PathBuf, PathBuf) {
    let config = environment.var("CLAUDE_CONFIG_DIR");
    let file = config
        .map(PathBuf::from)
        .unwrap_or_else(|| environment.home.clone())
        .join(".claude.json");
    let projects = config
        .map(PathBuf::from)
        .unwrap_or_else(|| environment.home.join(".claude"))
        .join("projects");
    (file, projects)
}

pub fn claude_workspaces_of(environment: &Environment) -> Vec<Workspace> {
    let (file, projects) = claude_paths(environment);
    let found = claude_workspaces(&fs::read_to_string(file).unwrap_or_default());
    // A folder the file gives no time for was last used when its sessions folder last changed.
    let timed: Vec<Workspace> = found
        .into_iter()
        .map(|w| {
            if w.last_used.is_some() {
                return w;
            }
            let seen = modified(&projects.join(project_folder_name(&w.path))).map(iso_of);
            Workspace {
                last_used: seen,
                ..w
            }
        })
        .collect();
    workspaces_first(&timed)
}

pub fn claude_sessions_of(environment: &Environment) -> Vec<PastSession> {
    let (_, projects) = claude_paths(environment);
    let mut files: Vec<(String, PathBuf, std::time::SystemTime)> = Vec::new();
    for folder in fs::read_dir(&projects).into_iter().flatten().flatten() {
        for entry in fs::read_dir(folder.path()).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            let Some(id) = name.strip_suffix(".jsonl") else {
                continue;
            };
            let path = entry.path();
            if path.is_file() {
                if let Some(used) = modified(&path) {
                    files.push((id.to_string(), path, used));
                }
            }
        }
    }
    files.sort_by_key(|file| std::cmp::Reverse(file.2));
    let read: Vec<PastSession> = files
        .into_iter()
        .take(CANDIDATES)
        .filter_map(|(id, file, used)| {
            let (cwd, title) = claude_session_head(&head(&file, CLAUDE_HEAD_BYTES));
            cwd.map(|path| PastSession {
                id,
                path,
                title,
                last_used: Some(iso_of(used)),
            })
        })
        .collect();
    sessions_first(&read)
}

// ---------------------------------------------------------------------------------------------
// Codex
// ---------------------------------------------------------------------------------------------

fn toml_key_of(quoted: &str) -> Option<String> {
    if let Some(inner) = quoted.strip_prefix('\'') {
        return inner.strip_suffix('\'').map(String::from);
    }
    match serde_json::from_str::<Value>(quoted) {
        Ok(Value::String(text)) => Some(text),
        _ => None,
    }
}

/// The folders of `config.toml` that Codex trusts: a `[projects."<folder>"]` table with
/// `trust_level = "trusted"`. The file keeps no time of use, so they come the newest approved first,
/// which is the end of the file, where Codex appends.
pub fn codex_workspaces(text: &str) -> Vec<Workspace> {
    let table =
        regex::Regex::new(r#"^\[projects\.("(?:[^"\\]|\\.)*"|'[^']*')\]\s*(#.*)?$"#).unwrap();
    let trusted = regex::Regex::new(r#"^trust_level\s*=\s*["']trusted["']\s*(#.*)?$"#).unwrap();
    let mut found = Vec::new();
    let mut current: Option<String> = None;
    for raw in text.split('\n') {
        let line = raw.trim();
        if line.starts_with('[') {
            current = table.captures(line).and_then(|c| toml_key_of(&c[1]));
        } else if current.is_some() && trusted.is_match(line) {
            found.push(Workspace {
                path: current.take().unwrap(),
                last_used: None,
            });
        }
    }
    found.reverse();
    found
}

/// What a rollout file says of its session in its first lines: the id and the folder, and the first
/// prompt, which is the first message of the user that is not context the harness added (those are
/// in tags).
pub fn codex_session_head(text: &str) -> (Option<String>, Option<String>, Option<String>) {
    let (mut id, mut cwd, mut title) = (None, None, None);
    for line in text.split('\n') {
        let Some(record) = json_line(line, 500_000) else {
            continue;
        };
        let Some(Value::Object(payload)) = record.get("payload") else {
            continue;
        };
        let kind = record.get("type").and_then(Value::as_str);
        if kind == Some("session_meta") {
            if let Some(Value::String(v)) = payload.get("id") {
                id = Some(v.clone());
            }
            if let Some(Value::String(v)) = payload.get("cwd") {
                cwd = Some(v.clone());
            }
        } else if title.is_none()
            && kind == Some("response_item")
            && payload.get("type").and_then(Value::as_str) == Some("message")
            && payload.get("role").and_then(Value::as_str) == Some("user")
        {
            for part in payload
                .get("content")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                if let Some(text) = part.get("text").and_then(Value::as_str) {
                    if !text.trim_start().starts_with('<') {
                        title = title_of(text);
                        break;
                    }
                }
            }
        }
        if id.is_some() && cwd.is_some() && title.is_some() {
            break;
        }
    }
    (id, cwd, title)
}

fn names_newest_first(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    names.sort();
    names.reverse();
    names
}

/// The newest rollout files, found by their folders of year, month and day and their names, which
/// start with the time.
fn newest_rollouts(root: &Path, limit: usize) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for year in names_newest_first(root) {
        for month in names_newest_first(&root.join(&year)) {
            for day in names_newest_first(&root.join(&year).join(&month)) {
                for name in names_newest_first(&root.join(&year).join(&month).join(&day)) {
                    if !name.starts_with("rollout-") || !name.ends_with(".jsonl") {
                        continue;
                    }
                    found.push(root.join(&year).join(&month).join(&day).join(name));
                    if found.len() >= limit {
                        return found;
                    }
                }
            }
        }
    }
    found
}

const CODEX_HEAD_BYTES: usize = 512 * 1024;

fn codex_home(environment: &Environment) -> PathBuf {
    environment
        .var("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| environment.home.join(".codex"))
}

pub fn codex_workspaces_of(environment: &Environment) -> Vec<Workspace> {
    codex_workspaces(
        &fs::read_to_string(codex_home(environment).join("config.toml")).unwrap_or_default(),
    )
}

pub fn codex_sessions_of(environment: &Environment) -> Vec<PastSession> {
    let home = codex_home(environment);
    let read: Vec<PastSession> = newest_rollouts(&home.join("sessions"), CANDIDATES)
        .into_iter()
        .filter_map(|path| {
            let (id, cwd, title) = codex_session_head(&head(&path, CODEX_HEAD_BYTES));
            let (id, cwd) = (id?, cwd?);
            Some(PastSession {
                id,
                path: cwd,
                title,
                last_used: modified(&path).map(iso_of),
            })
        })
        .collect();
    sessions_first(&read)
}

// ---------------------------------------------------------------------------------------------
// OpenCode
// ---------------------------------------------------------------------------------------------

/// The table the sessions are in: `session_v2` in the versions that have it, which holds every
/// session of the older `session` table as well, else `session`.
fn session_table(db: &rusqlite::Connection) -> &'static str {
    let has: Result<i64, _> = db.query_row(
        "select 1 from sqlite_master where type = 'table' and name = 'session_v2'",
        [],
        |row| row.get(0),
    );
    if has.is_ok() {
        "session_v2"
    } else {
        "session"
    }
}

pub fn opencode_database(environment: &Environment) -> PathBuf {
    environment
        .var("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| environment.home.join(".local").join("share"))
        .join("opencode")
        .join("opencode.db")
}

fn open_read_only(path: &Path) -> Option<rusqlite::Connection> {
    if !path.exists() {
        return None;
    }
    rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).ok()
}

/// The folders OpenCode has sessions in, the most recently used first. OpenCode asks for no
/// permission to work in a folder, so its sessions are what says where it has been.
pub fn opencode_workspaces(database: &Path) -> Vec<Workspace> {
    let Some(db) = open_read_only(database) else {
        return vec![];
    };
    let sql = format!(
        "select directory, max(time_updated) as used from {} where parent_id is null group by directory order by used desc limit ?1",
        session_table(&db)
    );
    let Ok(mut statement) = db.prepare(&sql) else {
        return vec![];
    };
    let rows = statement.query_map([(MAX_WORKSPACES * 2) as i64], |row| {
        Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, Option<f64>>(1)?,
        ))
    });
    rows.map(|rows| {
        rows.flatten()
            .filter_map(|(directory, used)| {
                let path = directory.filter(|d| !d.is_empty())?;
                Some(Workspace {
                    path,
                    last_used: used.map(|ms| crate::time::iso_millis(ms as i64)),
                })
            })
            .collect()
    })
    .unwrap_or_default()
}

/// The newest sessions of OpenCode's database, which holds a title for each.
pub fn opencode_sessions(database: &Path) -> Vec<PastSession> {
    let Some(db) = open_read_only(database) else {
        return vec![];
    };
    let sql = format!(
        "select id, directory, title, time_updated as used from {} where parent_id is null and directory <> '' order by used desc limit ?1",
        session_table(&db)
    );
    let Ok(mut statement) = db.prepare(&sql) else {
        return vec![];
    };
    let rows = statement.query_map([CANDIDATES as i64], |row| {
        Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<f64>>(3)?,
        ))
    });
    rows.map(|rows| {
        rows.flatten()
            .filter_map(|(id, directory, title, used)| {
                Some(PastSession {
                    id: id?,
                    path: directory?,
                    title: title.and_then(|t| title_of(&t)),
                    last_used: used.map(|ms| crate::time::iso_millis(ms as i64)),
                })
            })
            .collect()
    })
    .unwrap_or_default()
}

// ---------------------------------------------------------------------------------------------
// The three, as the page asks
// ---------------------------------------------------------------------------------------------

/// The folders each harness already works in, those that are still there.
pub fn list_workspaces(environment: &Environment) -> ByHarness<Workspace> {
    let present = |found: Vec<Workspace>| -> Vec<Workspace> {
        found
            .into_iter()
            .filter(|w| Path::new(&w.path).is_dir())
            .take(MAX_WORKSPACES)
            .collect()
    };
    ByHarness {
        claude: present(claude_workspaces_of(environment)),
        codex: present(codex_workspaces_of(environment)),
        opencode: present(opencode_workspaces(&opencode_database(environment))),
    }
}

/// The sessions each harness kept, those whose folder is still there to be resumed in.
pub fn list_sessions(environment: &Environment) -> ByHarness<PastSession> {
    let resumable = |found: Vec<PastSession>| -> Vec<PastSession> {
        found
            .into_iter()
            .filter(|s| Path::new(&s.path).is_dir())
            .take(MAX_SESSIONS)
            .collect()
    };
    ByHarness {
        claude: resumable(claude_sessions_of(environment)),
        codex: resumable(codex_sessions_of(environment)),
        opencode: resumable(opencode_sessions(&opencode_database(environment))),
    }
}
