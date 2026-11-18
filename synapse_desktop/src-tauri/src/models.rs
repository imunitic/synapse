//! The models a harness can be asked to use, read from the harness itself: OpenCode prints its
//! catalogue, Codex renders its own as JSON, and Claude Code names its aliases when it is asked, in a
//! session that does not call a model, what its `/model` command takes. The lists are kept on disk
//! between runs, since reading one takes seconds for some.

use crate::config::is_model_name;
use crate::environment::Environment;
use crate::messages::{Harness, ModelCatalog, ModelOption};
use crate::status::{combined_path, LoginPath};
use crate::time::iso_millis;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncReadExt;

const LOOK: Duration = Duration::from_secs(20);
const MAX_BYTES: usize = 4 * 1024 * 1024;

/// A command that was run: its exit code and what it printed.
pub struct ProgramOutput {
    pub code: i32,
    pub stdout: String,
}

type Running = Pin<Box<dyn Future<Output = ProgramOutput> + Send>>;
type RunProgram = dyn Fn(String, Vec<String>, BTreeMap<String, String>) -> Running + Send + Sync;

/// Runs a program in a folder of nothing, with the variables it is given.
#[derive(Clone)]
pub struct ProgramRunner(Arc<RunProgram>);

impl ProgramRunner {
    pub fn new<F, Fut>(run: F) -> ProgramRunner
    where
        F: Fn(String, Vec<String>, BTreeMap<String, String>) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = ProgramOutput> + Send + 'static,
    {
        ProgramRunner(Arc::new(move |program, args, env| {
            Box::pin(run(program, args, env))
        }))
    }

    pub async fn run(
        &self,
        program: &str,
        args: &[&str],
        env: &BTreeMap<String, String>,
    ) -> ProgramOutput {
        let args = args.iter().map(|a| a.to_string()).collect();
        (self.0)(program.to_string(), args, env.clone()).await
    }

    /// The programs themselves. The session runs in an empty folder, so that the settings of no
    /// project are read into it.
    pub fn system() -> ProgramRunner {
        ProgramRunner::new(|program, args, env| async move {
            let failed = ProgramOutput {
                code: 1,
                stdout: String::new(),
            };
            let mut command = tokio::process::Command::new(program);
            command
                .args(args)
                .env_clear()
                .envs(env)
                .current_dir(std::env::temp_dir())
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(true);
            let Ok(mut child) = command.spawn() else {
                return failed;
            };
            let Some(mut stdout) = child.stdout.take() else {
                return failed;
            };
            let work = async {
                let mut kept = Vec::new();
                let mut chunk = [0u8; 16 * 1024];
                loop {
                    let read = stdout.read(&mut chunk).await.ok()?;
                    if read == 0 {
                        break;
                    }
                    kept.extend_from_slice(&chunk[..read]);
                    if kept.len() > MAX_BYTES {
                        return None;
                    }
                }
                let status = child.wait().await.ok()?;
                Some((status.code().unwrap_or(1), kept))
            };
            match tokio::time::timeout(LOOK, work).await {
                Ok(Some((code, kept))) => ProgramOutput {
                    code,
                    stdout: String::from_utf8_lossy(&kept).to_string(),
                },
                _ => failed,
            }
        })
    }
}

fn colour() -> Regex {
    Regex::new("\u{1b}\\[[0-9;]*m").unwrap()
}

fn nothing() -> ModelCatalog {
    ModelCatalog {
        models: vec![],
        note: None,
        read_at: None,
    }
}

/// The models in the output of `opencode models`: a line for each, `provider/model`.
pub fn parse_opencode_models(stdout: &str) -> Vec<(String, String)> {
    let mut found: Vec<(String, String)> = Vec::new();
    for raw in colour().replace_all(stdout, "").split('\n') {
        let id = raw.trim();
        let Some(slash) = id.find('/') else { continue };
        if slash < 1
            || slash == id.len() - 1
            || id.chars().any(char::is_whitespace)
            || found.iter().any(|(seen, _)| seen == id)
        {
            continue;
        }
        found.push((id.to_string(), id[..slash].to_string()));
    }
    found
}

/// The name a provider is listed by in `opencode models` from the name `opencode auth list` shows:
/// `OpenRouter` is `openrouter`.
fn slug(name: &str) -> String {
    name.to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        .collect()
}

/// The providers OpenCode has credentials for, from `opencode auth list`: a line for each, its name
/// first and then how it is connected, with lines around them that are not providers.
pub fn connected_providers(auth_list: &str) -> BTreeSet<String> {
    let row = Regex::new(r"^([A-Za-z][A-Za-z0-9 ._-]*?)\s{2,}\S").unwrap();
    colour()
        .replace_all(auth_list, "")
        .split('\n')
        .filter_map(|raw| row.captures(raw.trim()).map(|c| slug(&c[1])))
        .collect()
}

/// The provider that serves a model on OpenCode itself, which needs no credentials of the person's.
const OWN_PROVIDER: &str = "opencode";

pub fn opencode_catalog(models_output: &str, auth_output: &str) -> ModelCatalog {
    let connected = connected_providers(auth_output);
    let mut models: Vec<ModelOption> = parse_opencode_models(models_output)
        .into_iter()
        .map(|(id, provider)| ModelOption {
            available: provider == OWN_PROVIDER || connected.contains(&slug(&provider)),
            id,
            provider: Some(provider),
            detail: None,
        })
        .collect();
    // What can be used comes first, and then by name, by the code points of the names so that the
    // order is the same wherever it is read.
    models.sort_by(|a, b| b.available.cmp(&a.available).then_with(|| a.id.cmp(&b.id)));
    let usable = models.iter().filter(|m| m.available).count();
    let note = if models.is_empty() {
        Some("OpenCode listed no models.".to_string())
    } else if usable == models.len() {
        None
    } else {
        Some(format!(
            "{usable} of the {} models are of providers that are connected; the others need a login first.",
            models.len()
        ))
    };
    ModelCatalog {
        models,
        read_at: None,
        note,
    }
}

/// The aliases Claude Code takes, from the answer of its `/model` command: `Current model: X` and
/// `Usage: /model <name>. Available: a, b, c, or a full model ID.`
pub fn parse_claude_models(stdout: &str) -> (Option<String>, Vec<String>) {
    let text = colour().replace_all(stdout, "").to_string();
    let current = Regex::new(r"(?m)Current model:\s*`?([^`\n]+?)`?\s*$")
        .unwrap()
        .captures(&text)
        .map(|c| c[1].to_string());
    let list = Regex::new(r"(?m)Available:\s*(.+?)(?:,?\s*or a full model ID)?\.?\s*$")
        .unwrap()
        .captures(&text)
        .map(|c| c[1].to_string());
    let mut names: Vec<String> = Vec::new();
    for name in list.as_deref().unwrap_or("").split(',') {
        let name = name.trim();
        if is_model_name(name) && !names.iter().any(|n| n == name) {
            names.push(name.to_string());
        }
    }
    (current, names)
}

pub fn claude_catalog(stdout: &str) -> ModelCatalog {
    let (current, names) = parse_claude_models(stdout);
    let note = if names.is_empty() {
        None
    } else {
        Some(format!(
            "{}Any full model ID can be typed as well.",
            current
                .map(|c| format!("It is on {c} now. "))
                .unwrap_or_default()
        ))
    };
    ModelCatalog {
        models: names
            .into_iter()
            .map(|id| ModelOption {
                id,
                provider: None,
                available: true,
                detail: None,
            })
            .collect(),
        read_at: None,
        note,
    }
}

#[derive(Deserialize)]
struct CodexModel {
    slug: String,
    display_name: Option<String>,
    description: Option<String>,
    visibility: Option<String>,
    priority: Option<f64>,
}

#[derive(Deserialize)]
struct CodexCatalog {
    models: Vec<CodexModel>,
}

/// The models Codex lists, from its own catalogue as `codex debug models` renders it: the ones it
/// shows in its `/model`, in the order it gives them. The ones it keeps out of that list can still be
/// typed.
pub fn codex_catalog(stdout: &str) -> ModelCatalog {
    let Ok(parsed) = serde_json::from_str::<CodexCatalog>(stdout) else {
        return nothing();
    };
    let mut shown: Vec<CodexModel> = parsed
        .models
        .into_iter()
        .filter(|m| m.visibility.as_deref() == Some("list") && is_model_name(&m.slug))
        .collect();
    shown.sort_by(|a, b| {
        a.priority
            .unwrap_or(1e9)
            .partial_cmp(&b.priority.unwrap_or(1e9))
            .unwrap()
    });
    let note = (!shown.is_empty()).then(|| "Any model name can be typed as well.".to_string());
    ModelCatalog {
        models: shown
            .into_iter()
            .map(|m| {
                let detail = [m.display_name, m.description]
                    .into_iter()
                    .flatten()
                    .filter(|t| !t.is_empty())
                    .collect::<Vec<_>>()
                    .join(": ");
                ModelOption {
                    id: m.slug,
                    provider: None,
                    available: true,
                    detail: (!detail.is_empty()).then_some(detail),
                }
            })
            .collect(),
        note,
        read_at: None,
    }
}

fn name_of(harness: Harness) -> &'static str {
    match harness {
        Harness::Claude => "Claude Code",
        Harness::Codex => "Codex",
        Harness::Opencode => "OpenCode",
    }
}

async fn read_catalog(
    harness: Harness,
    runner: &ProgramRunner,
    env: &BTreeMap<String, String>,
) -> ModelCatalog {
    match harness {
        Harness::Opencode => {
            let (models, auth) = tokio::join!(
                runner.run("opencode", &["models"], env),
                runner.run("opencode", &["auth", "list"], env)
            );
            if models.code == 0 {
                opencode_catalog(
                    &models.stdout,
                    if auth.code == 0 { &auth.stdout } else { "" },
                )
            } else {
                nothing()
            }
        }
        Harness::Claude => {
            // A command of the session that is answered here, without a call to a model, and kept out
            // of the sessions the person has.
            let answer = runner
                .run("claude", &["-p", "/model", "--no-session-persistence"], env)
                .await;
            if answer.code == 0 {
                claude_catalog(&answer.stdout)
            } else {
                nothing()
            }
        }
        Harness::Codex => {
            let answer = runner.run("codex", &["debug", "models"], env).await;
            if answer.code == 0 {
                codex_catalog(&answer.stdout)
            } else {
                nothing()
            }
        }
    }
}

/// The models of a harness, read from it now. A list that could not be read is empty and says what to
/// do, so that a person can type a name.
pub async fn read_models(
    harness: Harness,
    runner: &ProgramRunner,
    env: &BTreeMap<String, String>,
    login: &LoginPath,
) -> ModelCatalog {
    // This host's PATH first, then the login shell's, for a harness only it can find.
    let path = combined_path(
        env.get("PATH").map(String::as_str),
        login.read().await.as_deref(),
    );
    let mut where_ = env.clone();
    where_.insert("PATH".into(), path);
    let catalog = read_catalog(harness, runner, &where_).await;
    if !catalog.models.is_empty() {
        return catalog;
    }
    ModelCatalog {
        models: vec![],
        read_at: None,
        note: Some(catalog.note.unwrap_or_else(|| {
            format!(
                "{} could not list its models. Type a name instead.",
                name_of(harness)
            )
        })),
    }
}

// ---------------------------------------------------------------------------------------------
// The models kept between runs
// ---------------------------------------------------------------------------------------------

const HARNESSES: [Harness; 3] = [Harness::Claude, Harness::Codex, Harness::Opencode];

/// How old a list may be before it is read again when it is asked for. The app reads them all anew
/// whenever it starts, so this is for an app that is left open.
pub const MAX_AGE_MS: i64 = 6 * 60 * 60 * 1000;

#[derive(Serialize, Deserialize, Clone)]
struct Entry {
    at: i64,
    models: Vec<ModelOption>,
    note: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct Stored {
    version: u8,
    harnesses: BTreeMap<Harness, Entry>,
}

/// The file is a cache, so it is in the folder of caches: `$XDG_CACHE_HOME`, else `~/.cache`.
pub fn model_cache_file(environment: &Environment) -> PathBuf {
    environment
        .var("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| environment.home.join(".cache"))
        .join("synapse-desktop")
        .join("models.json")
}

type Read =
    Arc<dyn Fn(Harness) -> Pin<Box<dyn Future<Output = ModelCatalog> + Send>> + Send + Sync>;

#[derive(Default)]
struct Gate {
    generation: u64,
    last: Option<ModelCatalog>,
}

struct Inner {
    file: PathBuf,
    now: Arc<dyn Fn() -> i64 + Send + Sync>,
    read: Read,
    entries: tokio::sync::Mutex<Option<BTreeMap<Harness, Entry>>>,
    /// A read that is going on is joined and not started again.
    gates: HashMap<Harness, tokio::sync::Mutex<Gate>>,
    /// How many reads of each harness are done, to tell a caller that waited that one finished.
    completed: HashMap<Harness, AtomicU64>,
    /// The writes of the file go one after the other, since each is of all the lists.
    writing: tokio::sync::Mutex<()>,
}

/// The models of each harness, kept on disk between runs of the app. The app answers from what it
/// kept, reads the three again in the background when it starts, and reads one again when it is old
/// or when it is asked to. A list that could not be read never replaces one that could.
#[derive(Clone)]
pub struct ModelStore(Arc<Inner>);

fn catalog_of(entry: &Entry) -> ModelCatalog {
    ModelCatalog {
        models: entry.models.clone(),
        note: entry.note.clone(),
        read_at: Some(iso_millis(entry.at)),
    }
}

impl ModelStore {
    /// A store over `file`, whose lists are read by `read`, at the times `now` says.
    pub fn new<F, Fut>(
        file: PathBuf,
        now: Arc<dyn Fn() -> i64 + Send + Sync>,
        read: F,
    ) -> ModelStore
    where
        F: Fn(Harness) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = ModelCatalog> + Send + 'static,
    {
        ModelStore(Arc::new(Inner {
            file,
            now,
            read: Arc::new(move |harness| Box::pin(read(harness))),
            entries: tokio::sync::Mutex::new(None),
            gates: HARNESSES.iter().map(|h| (*h, Default::default())).collect(),
            completed: HARNESSES.iter().map(|h| (*h, AtomicU64::new(0))).collect(),
            writing: tokio::sync::Mutex::new(()),
        }))
    }

    /// The store that reads the programs themselves, at the time of the clock.
    pub fn system(
        file: PathBuf,
        runner: ProgramRunner,
        environment: Environment,
        login: LoginPath,
    ) -> ModelStore {
        let now: Arc<dyn Fn() -> i64 + Send + Sync> =
            Arc::new(|| crate::time::millis(std::time::SystemTime::now()));
        ModelStore::new(file, now, move |harness| {
            let (runner, env, login) = (runner.clone(), environment.env.clone(), login.clone());
            async move { read_models(harness, &runner, &env, &login).await }
        })
    }

    async fn loaded(&self) -> tokio::sync::MutexGuard<'_, Option<BTreeMap<Harness, Entry>>> {
        let mut guard = self.0.entries.lock().await;
        if guard.is_none() {
            let mut entries = BTreeMap::new();
            // No file, or one that is not this: the lists are read.
            if let Ok(text) = std::fs::read_to_string(&self.0.file) {
                if let Ok(stored) = serde_json::from_str::<Stored>(&text) {
                    if stored.version == 1 {
                        entries.extend(
                            stored
                                .harnesses
                                .into_iter()
                                .filter(|(_, e)| !e.models.is_empty()),
                        );
                    }
                }
            }
            *guard = Some(entries);
        }
        guard
    }

    async fn save(&self, entries: &BTreeMap<Harness, Entry>) {
        let _turn = self.0.writing.lock().await;
        let stored = Stored {
            version: 1,
            harnesses: entries.clone(),
        };
        let temporary = PathBuf::from(format!(
            "{}.{}.tmp",
            self.0.file.display(),
            std::process::id()
        ));
        let write = || -> std::io::Result<()> {
            if let Some(dir) = self.0.file.parent() {
                std::fs::create_dir_all(dir)?;
            }
            std::fs::write(
                &temporary,
                serde_json::to_string(&stored).unwrap_or_default(),
            )?;
            std::fs::rename(&temporary, &self.0.file)
        };
        // What cannot be kept is read again next time.
        let _ = write();
    }

    /// Reads the list from the harness now. When that gives nothing, what was kept stays. A read that
    /// is going on is joined.
    pub async fn refresh(&self, harness: Harness) -> ModelCatalog {
        // A read that finishes while this one waits for its turn is the read it wanted.
        let ticket = self.0.completed[&harness].load(Ordering::SeqCst);
        let mut gate = self.0.gates[&harness].lock().await;
        if gate.generation > ticket {
            if let Some(last) = &gate.last {
                return last.clone();
            }
        }
        let catalog = (self.0.read)(harness).await;
        let answer = {
            let mut guard = self.loaded().await;
            let entries = guard.as_mut().unwrap();
            if catalog.models.is_empty() {
                // Nothing was read: what was kept is still the best there is.
                entries.get(&harness).map(catalog_of).unwrap_or(catalog)
            } else {
                let entry = Entry {
                    at: (self.0.now)(),
                    models: catalog.models,
                    note: catalog.note,
                };
                entries.insert(harness, entry.clone());
                let snapshot = entries.clone();
                drop(guard);
                self.save(&snapshot).await;
                catalog_of(&entry)
            }
        };
        gate.generation = self.0.completed[&harness].fetch_add(1, Ordering::SeqCst) + 1;
        gate.last = Some(answer.clone());
        answer
    }

    /// What is kept for the harness, at once, when something is; else what a read of it gives.
    pub async fn list(&self, harness: Harness) -> ModelCatalog {
        let kept = self.loaded().await.as_ref().unwrap().get(&harness).cloned();
        match kept {
            None => self.refresh(harness).await,
            Some(kept) => {
                // Old, it is read again behind the answer.
                if (self.0.now)() - kept.at > MAX_AGE_MS {
                    let store = self.clone();
                    tokio::spawn(async move {
                        store.refresh(harness).await;
                    });
                }
                catalog_of(&kept)
            }
        }
    }

    /// Reads the lists of all three, as the app does when it starts.
    pub async fn refresh_all(&self) {
        tokio::join!(
            self.refresh(Harness::Claude),
            self.refresh(Harness::Codex),
            self.refresh(Harness::Opencode)
        );
    }
}
