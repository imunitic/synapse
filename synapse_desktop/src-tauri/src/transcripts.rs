//! Following the conversation of a harness that runs in a terminal: its session file grows as the
//! session goes, and what is appended is passed on. A run is made known by a registration, one small JSON
//! file in a folder of the terminal's own, which a wrapper command or this host writes when it starts the
//! harness.

use crate::environment::Environment;
use crate::status::find_executable;
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::future::Future;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceHarness {
    Claude,
    Codex,
    Opencode,
}

/// A conversation that is being followed.
#[derive(Clone, Debug, PartialEq)]
pub struct Source {
    pub id: String,
    pub harness: SourceHarness,
    pub cwd: String,
}

/// What the watcher tells.
#[derive(Clone)]
pub struct TranscriptEvents {
    pub on_source: Arc<dyn Fn(Source) + Send + Sync>,
    /// Complete lines of a session file, in order, as they were appended.
    pub on_lines: Arc<dyn Fn(String, Vec<String>) + Send + Sync>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum RegisteredHarness {
    Claude,
    Codex,
    Opencode,
}

/// A run that is to be followed: where it started and when, and what names its file.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Registration {
    pub harness: RegisteredHarness,
    /// Claude: the id the run was started or resumed with, which names its file; none for a session
    /// resumed without its id. OpenCode: the id of the session it was started with, which
    /// `opencode session export` takes.
    pub session_id: Option<String>,
    pub cwd: String,
    /// Where the harness keeps its files: the folder of Claude.
    pub config_dir: Option<String>,
    /// The home of Codex.
    pub home: Option<String>,
    /// Epoch milliseconds.
    pub started_at: i64,
}

/// What a terminal session holds of the watcher: adding a run the host knows and not a file, and ending.
pub trait TranscriptWatcher: Send + Sync {
    fn register(&self, id: &str, registration: Registration);
    fn stop(&self);
}

type Exporting = Pin<Box<dyn Future<Output = Option<String>> + Send>>;

/// How an OpenCode session is read: it is a program to run, not a file.
pub type ExportSession = Arc<dyn Fn(Registration, String) -> Exporting + Send + Sync>;

#[derive(Clone)]
pub struct WatchOptions {
    /// The folder the registrations are written in.
    pub dir: PathBuf,
    /// The home folder of the user, where harnesses keep what a registration does not name.
    pub home: PathBuf,
    pub events: TranscriptEvents,
    pub interval: Duration,
    pub export_session: Option<ExportSession>,
    /// How often an OpenCode session is exported.
    pub export_every: Duration,
}

impl WatchOptions {
    pub fn new(dir: PathBuf, home: PathBuf, events: TranscriptEvents) -> WatchOptions {
        WatchOptions {
            dir,
            home,
            events,
            interval: Duration::from_millis(300),
            export_session: None,
            export_every: Duration::from_secs(1),
        }
    }
}

/// How a terminal session makes its watcher; the real one follows files, a test gives its own.
pub type WatchFactory = Arc<dyn Fn(WatchOptions) -> Arc<dyn TranscriptWatcher> + Send + Sync>;

/// The factory of the watchers that read the files.
pub fn file_watchers(environment: Environment) -> WatchFactory {
    Arc::new(move |mut options| {
        // OpenCode is run to read its session, with the PATH of the app's environment: the process
        // of an app opened from the Dock has only the system's short one.
        if options.export_session.is_none() {
            let environment = environment.clone();
            options.export_session = Some(Arc::new(move |registration, id| {
                Box::pin(export_opencode_session(
                    environment.clone(),
                    registration,
                    id,
                )) as Exporting
            }));
        }
        watch_transcripts(options) as Arc<dyn TranscriptWatcher>
    })
}

struct Follow {
    id: String,
    registration: Registration,
    file: Option<PathBuf>,
    offset: u64,
    /// The part of a last line that is not finished.
    partial: String,
    /// OpenCode keeps no file to follow. Each message as it was last sent, by its id.
    sent: BTreeMap<String, String>,
    exported_at: Option<Instant>,
}

const MAX_LINES: usize = 200;
const MAX_CHARS: usize = 512 * 1024;
/// A session file written a little before the registration still belongs to it.
const SLACK_MS: i64 = 2000;

/// The file of a Claude session: `<config>/projects/<folder of the project>/<id>.jsonl`, in whichever
/// folder it is.
fn claude_file(registration: &Registration, default_home: &Path) -> Option<PathBuf> {
    let id = registration.session_id.as_ref()?;
    let projects = registration
        .config_dir
        .as_ref()
        .map(PathBuf::from)
        .unwrap_or_else(|| default_home.join(".claude"))
        .join("projects");
    for folder in fs::read_dir(projects).into_iter().flatten().flatten() {
        let file = folder.path().join(format!("{id}.jsonl"));
        if file.is_file() {
            return Some(file);
        }
    }
    None
}

/// How much of the end of a session file is read to see the folder its last lines were written in.
const TAIL_BYTES: u64 = 256 * 1024;

/// Whether a line near the end of the file was written by a run in `cwd`.
fn written_in(path: &Path, cwd: &str) -> bool {
    let Ok(mut file) = fs::File::open(path) else {
        return false;
    };
    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
    if file
        .seek(SeekFrom::Start(size.saturating_sub(TAIL_BYTES)))
        .is_err()
    {
        return false;
    }
    let mut buffer = Vec::new();
    let _ = file.take(TAIL_BYTES).read_to_end(&mut buffer);
    String::from_utf8_lossy(&buffer).lines().rev().any(|line| {
        serde_json::from_str::<serde_json::Value>(line)
            .is_ok_and(|value| value["cwd"].as_str() == Some(cwd))
    })
}

/// The file of a Claude session resumed without its id (`--continue`, the picker, a name): of the
/// session files of every project, one written to since the run started, that no other run here has,
/// and whose last lines were written in the run's folder. The newest of them, when there are more.
fn resumed_claude_file(
    registration: &Registration,
    default_home: &Path,
    taken: &BTreeSet<PathBuf>,
) -> Option<PathBuf> {
    let projects = registration
        .config_dir
        .as_ref()
        .map(PathBuf::from)
        .unwrap_or_else(|| default_home.join(".claude"))
        .join("projects");
    let mut found: Vec<(PathBuf, i64)> = Vec::new();
    for folder in fs::read_dir(projects).into_iter().flatten().flatten() {
        for entry in fs::read_dir(folder.path()).into_iter().flatten().flatten() {
            let file = entry.path();
            if file.extension().is_none_or(|e| e != "jsonl") || taken.contains(&file) {
                continue;
            }
            let Ok(info) = entry.metadata() else {
                continue;
            };
            let modified = info.modified().map(millis).unwrap_or(0);
            if !info.is_file() || modified < registration.started_at - SLACK_MS {
                continue;
            }
            if written_in(&file, &registration.cwd) {
                found.push((file, modified));
            }
        }
    }
    found.sort_by_key(|(_, modified)| std::cmp::Reverse(*modified));
    found.into_iter().next().map(|(file, _)| file)
}

fn first_line(path: &Path) -> String {
    let Ok(file) = fs::File::open(path) else {
        return String::new();
    };
    let mut buffer = Vec::new();
    let _ = file.take(64 * 1024).read_to_end(&mut buffer);
    String::from_utf8_lossy(&buffer)
        .split('\n')
        .next()
        .unwrap_or("")
        .to_string()
}

/// The newest day folders of the sessions of a Codex home, as paths.
fn recent_days(sessions: &Path) -> Vec<PathBuf> {
    let sorted = |dir: &Path| -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
            .collect();
        names.sort();
        names.reverse();
        names
    };
    let mut days = Vec::new();
    for year in sorted(sessions) {
        for month in sorted(&sessions.join(&year)) {
            for day in sorted(&sessions.join(&year).join(&month)) {
                days.push(sessions.join(&year).join(&month).join(day));
                if days.len() >= 3 {
                    return days;
                }
            }
        }
    }
    days
}

fn millis(time: std::time::SystemTime) -> i64 {
    crate::time::millis(time)
}

/// The rollout file of a Codex session that started where and when the run did, and that no other run
/// has.
fn codex_file(
    registration: &Registration,
    default_home: &Path,
    taken: &BTreeSet<PathBuf>,
) -> Option<PathBuf> {
    let sessions = registration
        .home
        .as_ref()
        .map(PathBuf::from)
        .unwrap_or_else(|| default_home.join(".codex"))
        .join("sessions");
    let mut found: Vec<(PathBuf, i64)> = Vec::new();
    for day in recent_days(&sessions) {
        for entry in fs::read_dir(&day).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.starts_with("rollout-") || !name.ends_with(".jsonl") {
                continue;
            }
            let file = entry.path();
            if taken.contains(&file) {
                continue;
            }
            let Ok(info) = fs::metadata(&file) else {
                continue;
            };
            let modified = info.modified().map(millis).unwrap_or(0);
            if modified < registration.started_at - SLACK_MS {
                continue;
            }
            // A file that is not begun is looked at again.
            let Ok(meta) = serde_json::from_str::<serde_json::Value>(&first_line(&file)) else {
                continue;
            };
            if meta["payload"]["cwd"].as_str() == Some(registration.cwd.as_str()) {
                let born = info.created().map(millis).unwrap_or(modified);
                found.push((file, born));
            }
        }
    }
    found.sort_by_key(|(_, born)| *born);
    found.into_iter().next().map(|(file, _)| file)
}

/// New complete lines of the file after the offset, and where the next read starts.
fn read_more(file: &Path, follow: &mut Follow) -> std::io::Result<(Vec<String>, u64)> {
    let size = fs::metadata(file)?.len();
    if size < follow.offset {
        // The file is shorter than it was: it was replaced, and is read from its start.
        follow.offset = 0;
        follow.partial.clear();
    }
    if size == follow.offset {
        return Ok((vec![], size));
    }
    let mut handle = fs::File::open(file)?;
    handle.seek(SeekFrom::Start(follow.offset))?;
    let mut buffer = Vec::new();
    handle.take(size - follow.offset).read_to_end(&mut buffer)?;
    let text = format!("{}{}", follow.partial, String::from_utf8_lossy(&buffer));
    let mut parts: Vec<&str> = text.split('\n').collect();
    follow.partial = parts.pop().unwrap_or("").to_string();
    Ok((
        parts
            .into_iter()
            .filter(|l| !l.trim().is_empty())
            .map(String::from)
            .collect(),
        size,
    ))
}

/// The session of OpenCode as JSON, or none when it cannot be exported, as before its first message,
/// when it is not there yet.
pub async fn export_opencode_session(
    environment: Environment,
    registration: Registration,
    id: String,
) -> Option<String> {
    let path = environment.env.get("PATH").map_or("", String::as_str);
    let program = find_executable("opencode", path).unwrap_or_else(|| PathBuf::from("opencode"));
    let mut command = tokio::process::Command::new(program);
    command
        .envs(&environment.env)
        .args(["session", "export", &id, "--standalone"])
        .current_dir(&registration.cwd)
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_secs(15), command.output())
        .await
        .ok()?
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).to_string())
}

/// The messages of an exported session that are new, or are not as they were when they were last sent,
/// each as a line. `sent` is brought up to date.
pub fn changed_messages(exported: &str, sent: &mut BTreeMap<String, String>) -> Vec<String> {
    let Ok(parsed) = serde_json::from_str::<serde_json::Value>(exported) else {
        return vec![];
    };
    let Some(messages) = parsed.get("messages").and_then(|m| m.as_array()) else {
        return vec![];
    };
    let mut lines = Vec::new();
    for message in messages {
        let Some(id) = message.get("id").and_then(|i| i.as_str()) else {
            continue;
        };
        let line = message.to_string();
        if sent.get(id) == Some(&line) {
            continue;
        }
        sent.insert(id.to_string(), line.clone());
        lines.push(line);
    }
    lines
}

fn batches(lines: &[String]) -> Vec<Vec<String>> {
    let mut result: Vec<Vec<String>> = Vec::new();
    let mut current: Vec<String> = Vec::new();
    let mut chars = 0;
    for line in lines {
        if !current.is_empty() && (current.len() >= MAX_LINES || chars + line.len() > MAX_CHARS) {
            result.push(std::mem::take(&mut current));
            chars = 0;
        }
        chars += line.len();
        current.push(line.clone());
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}

struct State {
    follows: Vec<Follow>,
    seen: BTreeSet<String>,
}

/// Follows the files of the runs that are registered.
pub struct FileWatcher {
    options: WatchOptions,
    state: Mutex<State>,
    running: tokio::sync::Mutex<()>,
    stopped: AtomicBool,
}

fn source_harness(harness: RegisteredHarness) -> SourceHarness {
    match harness {
        RegisteredHarness::Claude => SourceHarness::Claude,
        RegisteredHarness::Codex => SourceHarness::Codex,
        RegisteredHarness::Opencode => SourceHarness::Opencode,
    }
}

impl FileWatcher {
    fn add(&self, id: &str, registration: Registration) {
        let source = Source {
            id: id.to_string(),
            harness: source_harness(registration.harness),
            cwd: registration.cwd.clone(),
        };
        self.state.lock().unwrap().follows.push(Follow {
            id: id.to_string(),
            registration,
            file: None,
            offset: 0,
            partial: String::new(),
            sent: BTreeMap::new(),
            exported_at: None,
        });
        (self.options.events.on_source)(source);
    }

    fn read_registrations(&self) {
        let mut names: Vec<String> = fs::read_dir(&self.options.dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        names.sort();
        for name in names {
            if !name.ends_with(".json") || name.starts_with('.') {
                continue;
            }
            if !self.state.lock().unwrap().seen.insert(name.clone()) {
                continue;
            }
            // A file that is not a registration says nothing.
            let Ok(text) = fs::read_to_string(self.options.dir.join(&name)) else {
                continue;
            };
            let Ok(registration) = serde_json::from_str::<Registration>(&text) else {
                continue;
            };
            let id = registration
                .session_id
                .clone()
                .unwrap_or_else(|| name.trim_end_matches(".json").to_string());
            self.add(&id, registration);
        }
    }

    /// The messages of an OpenCode session that are new or have changed since the last look, which is
    /// taken no more often than the export can be run.
    async fn poll_opencode(&self, index: usize) {
        let (registration, session_id, id) = {
            let mut state = self.state.lock().unwrap();
            let follow = &mut state.follows[index];
            if follow
                .exported_at
                .is_some_and(|at| at.elapsed() < self.options.export_every)
            {
                return;
            }
            follow.exported_at = Some(Instant::now());
            let Some(session_id) = follow.registration.session_id.clone() else {
                return;
            };
            (follow.registration.clone(), session_id, follow.id.clone())
        };
        let export = self.options.export_session.clone().unwrap_or_else(|| {
            let environment = Environment::from_process();
            Arc::new(move |registration, id| {
                Box::pin(export_opencode_session(
                    environment.clone(),
                    registration,
                    id,
                )) as Exporting
            })
        });
        let Some(exported) = export(registration, session_id).await else {
            return;
        };
        if self.stopped.load(Ordering::SeqCst) {
            return;
        }
        let lines = {
            let mut state = self.state.lock().unwrap();
            changed_messages(&exported, &mut state.follows[index].sent)
        };
        for batch in batches(&lines) {
            (self.options.events.on_lines)(id.clone(), batch);
        }
    }

    /// Looks at the folder and at the files once.
    pub async fn poll(&self) {
        let Ok(_running) = self.running.try_lock() else {
            return;
        };
        if self.stopped.load(Ordering::SeqCst) {
            return;
        }
        self.read_registrations();
        let count = self.state.lock().unwrap().follows.len();
        for index in 0..count {
            if self.stopped.load(Ordering::SeqCst) {
                return;
            }
            let harness = self.state.lock().unwrap().follows[index]
                .registration
                .harness;
            if harness == RegisteredHarness::Opencode {
                self.poll_opencode(index).await;
                continue;
            }
            let (id, lines) = {
                let mut state = self.state.lock().unwrap();
                let taken: BTreeSet<PathBuf> = state
                    .follows
                    .iter()
                    .filter_map(|f| f.file.clone())
                    .collect();
                let follow = &mut state.follows[index];
                if follow.file.is_none() {
                    follow.file = if harness != RegisteredHarness::Claude {
                        codex_file(&follow.registration, &self.options.home, &taken)
                    } else if follow.registration.session_id.is_some() {
                        claude_file(&follow.registration, &self.options.home)
                    } else {
                        resumed_claude_file(&follow.registration, &self.options.home, &taken)
                    };
                }
                let Some(file) = follow.file.clone() else {
                    continue;
                };
                let Ok((lines, size)) = read_more(&file, follow) else {
                    continue;
                };
                // The offset is where this read ended, the part of a line that is not finished apart.
                follow.offset = size;
                (follow.id.clone(), lines)
            };
            for batch in batches(&lines) {
                (self.options.events.on_lines)(id.clone(), batch);
            }
        }
    }
}

impl TranscriptWatcher for FileWatcher {
    fn register(&self, id: &str, registration: Registration) {
        self.add(id, registration);
    }

    fn stop(&self) {
        self.stopped.store(true, Ordering::SeqCst);
    }
}

/// A watcher that looks at its files every `interval`, until it is stopped.
pub fn watch_transcripts(options: WatchOptions) -> Arc<FileWatcher> {
    let interval = options.interval;
    let watcher = Arc::new(FileWatcher {
        options,
        state: Mutex::new(State {
            follows: vec![],
            seen: BTreeSet::new(),
        }),
        running: tokio::sync::Mutex::new(()),
        stopped: AtomicBool::new(false),
    });
    let again = Arc::downgrade(&watcher);
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(interval).await;
            let Some(watcher) = again.upgrade() else {
                return;
            };
            if watcher.stopped.load(Ordering::SeqCst) {
                return;
            }
            watcher.poll().await;
        }
    });
    watcher
}
