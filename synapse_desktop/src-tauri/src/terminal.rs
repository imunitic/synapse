//! The terminal sessions of the host. A session is held here and not by a connection: a client that is
//! gone leaves it running, and one that attaches later gets the screen as the program drew it and then
//! what the program prints. A session ends when its program has exited and its tab is closed, or when no
//! client has been attached to it for `DETACHED_TTL`.

use crate::cli::cli_environment;
use crate::config::load_config;
use crate::dispatch::HostError;
use crate::environment::{expand_home, Environment};
use crate::inject::{plan_session, plan_shell, InjectDeps, SessionPlan};
use crate::messages::{Harness, TerminalInfo, TerminalKind, TerminalStartParams, TerminalTask};
use crate::pty::{EndSignal, OnEvent, Pty, PtyEvent, SpawnOptions, SpawnPty};
use crate::screen::Screen;
use crate::status::{harness_environment, LoginEnvironment};
use crate::transcripts::{
    RegisteredHarness, Registration, Source, SourceHarness, TranscriptEvents, TranscriptWatcher,
    WatchFactory, WatchOptions,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// A session with no client attached for this long is ended. A fixed value.
pub const DETACHED_TTL: Duration = Duration::from_secs(12 * 60 * 60);

/// What of a conversation is kept to give a client that attaches again.
const MAX_TRANSCRIPT_LINES: usize = 5000;

// ---------------------------------------------------------------------------------------------
// What a session says on its stream, and what a client says to it
// ---------------------------------------------------------------------------------------------

/// What the host sends on a session's stream. A snapshot is the screen and its scrollback as the program
/// drew them, sent when a client attaches and before any output that follows.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum TerminalHostStream {
    Snapshot {
        data: String,
    },
    Output {
        data: String,
    },
    TranscriptSource {
        id: String,
        harness: String,
        cwd: String,
    },
    Transcript {
        id: String,
        lines: Vec<String>,
    },
    Exit {
        code: i32,
    },
}

/// What the page sends on a session's stream.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum TerminalClientStream {
    Input { data: String },
    Resize { cols: u16, rows: u16 },
}

/// Where a session's output goes: one for each connection that is attached to it.
pub trait Sink: Send + Sync {
    fn send(&self, session: &str, message: TerminalHostStream);
}

fn same_sink(a: &Arc<dyn Sink>, b: &Arc<dyn Sink>) -> bool {
    std::ptr::eq(Arc::as_ptr(a) as *const (), Arc::as_ptr(b) as *const ())
}

// ---------------------------------------------------------------------------------------------
// Starting a program
// ---------------------------------------------------------------------------------------------

/// What a harness sets for the programs it starts, which tells one of them that it is inside another
/// session, and how to reach that session. A terminal of the app is a session of its own, so it does not
/// have them.
const OF_ANOTHER_SESSION: [&str; 9] = [
    "CLAUDECODE",
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_SESSION_ATTENDED",
    "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_EXECPATH",
    "CLAUDE_PID",
];

type Planning = Pin<Box<dyn Future<Output = Result<SessionPlan, String>> + Send>>;

/// How the program is started for a kind of session.
pub type PlanFn = Arc<dyn Fn(TerminalKind) -> Planning + Send + Sync>;

/// An interactive run is `synapse-pipeline` itself, whose harnesses use the terminal it is given.
fn plan_pipeline() -> SessionPlan {
    SessionPlan {
        command: "synapse-pipeline".into(),
        args: vec![],
        env: BTreeMap::new(),
        loaded: false,
        note: String::new(),
    }
}

/// The plans of the programs themselves, with Synapse loaded from the folders `deps` names.
pub fn default_plan(deps: InjectDeps) -> PlanFn {
    Arc::new(move |kind| {
        let deps = deps.clone();
        Box::pin(async move {
            if kind == TerminalKind::Pipeline {
                return Ok(plan_pipeline());
            }
            tokio::task::spawn_blocking(move || match kind {
                TerminalKind::Shell => plan_shell(&deps).map(|shell| shell.plan),
                TerminalKind::Claude => plan_session(Harness::Claude, &deps),
                TerminalKind::Codex => plan_session(Harness::Codex, &deps),
                _ => plan_session(Harness::Opencode, &deps),
            })
            .await
            .map_err(|e| e.to_string())?
            .map_err(|e| e.to_string())
        })
    })
}

/// How a session is made to end by itself: runs the action after the time, and returns what cancels it.
pub type Schedule =
    Arc<dyn Fn(Box<dyn FnOnce() + Send>, Duration) -> Box<dyn FnOnce() + Send> + Send + Sync>;

fn tokio_schedule() -> Schedule {
    Arc::new(|action, after| {
        let task = tokio::spawn(async move {
            tokio::time::sleep(after).await;
            action();
        });
        Box::new(move || task.abort())
    })
}

#[derive(Clone)]
pub struct TerminalDeps {
    pub environment: Environment,
    pub config_file: PathBuf,
    pub spawn: SpawnPty,
    /// How the program is started for a session.
    pub plan: PlanFn,
    pub max_terminals: Arc<AtomicUsize>,
    /// Where the registrations of the runs in a terminal are kept, a folder for each.
    pub sessions_root: PathBuf,
    /// Follows the conversations of the harnesses started in a terminal.
    pub watch: WatchFactory,
    /// The clock of the 12 hours, injected so that the tests do not wait for it.
    pub schedule: Schedule,
    /// The environment of the user's login shell, read for each harness that is started, so that what
    /// the user's start-up files export reaches it.
    pub login_environment: LoginEnvironment,
    /// Called when the program of a session exits.
    pub on_exit: Option<Arc<dyn Fn() + Send + Sync>>,
}

impl TerminalDeps {
    /// The deps of a host that runs programs on this machine.
    pub fn system(
        environment: Environment,
        config_file: PathBuf,
        inject: InjectDeps,
    ) -> TerminalDeps {
        let sessions_root = crate::inject::injected_dir(&environment)
            .join("..")
            .join("sessions");
        let watch = crate::transcripts::file_watchers(environment.clone());
        let login_environment = LoginEnvironment::shell(&environment);
        TerminalDeps {
            environment,
            config_file,
            spawn: crate::pty::system_spawn(),
            plan: default_plan(inject),
            max_terminals: Arc::new(AtomicUsize::new(8)),
            sessions_root,
            watch,
            schedule: tokio_schedule(),
            login_environment,
            on_exit: None,
        }
    }
}

fn random_hex(bytes: usize) -> String {
    let mut buffer = vec![0u8; bytes];
    getrandom::fill(&mut buffer).expect("the system gives random bytes");
    buffer.iter().map(|b| format!("{b:02x}")).collect()
}

/// A version 4 UUID, in lower case.
fn uuid() -> String {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).expect("the system gives random bytes");
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: Vec<String> = b.iter().map(|x| format!("{x:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        h[0..4].concat(),
        h[4..6].concat(),
        h[6..8].concat(),
        h[8..10].concat(),
        h[10..16].concat()
    )
}

/// A program started from the desktop has no locale unless the user's start-up files set one, and in
/// the default locale a shell and the programs in it take the bytes of a character such as an
/// umlaut for several. When none of the variables that choose the character set names UTF-8, the
/// category for it is set to it.
fn ensure_utf8_locale(env: &mut BTreeMap<String, String>) {
    let is_utf8 = |name: &str| {
        env.get(name).is_some_and(|value| {
            let value = value.to_ascii_lowercase();
            value.contains("utf-8") || value.contains("utf8")
        })
    };
    // The first of these that is set is the one that counts.
    let chosen = ["LC_ALL", "LC_CTYPE", "LANG"]
        .into_iter()
        .find(|name| env.get(*name).is_some_and(|value| !value.is_empty()));
    if chosen.is_some_and(is_utf8) {
        return;
    }
    let utf8 = if cfg!(target_os = "macos") {
        "en_US.UTF-8"
    } else {
        "C.UTF-8"
    };
    env.remove("LC_ALL");
    env.insert("LC_CTYPE".into(), utf8.into());
}

/// What a harness is started to do: build a code graph, rebuild what changed in it, or rebuild it from
/// scratch. The harness is given a plain sentence as its first prompt, as a person would type it, and
/// finds the skill of Synapse that it names by the skill's description.
pub fn task_args(kind: TerminalKind, task: TerminalTask) -> Vec<String> {
    if kind == TerminalKind::Shell {
        return vec![];
    }
    let sentence = match task {
        TerminalTask::Init => "Do a synapse init.",
        TerminalTask::RebuildDiff => "Do a synapse rebuild diff.",
        TerminalTask::RebuildFull => "Do a synapse rebuild full.",
    };
    // OpenCode takes the prompt as a flag and the others as the last argument.
    if kind == TerminalKind::Opencode {
        vec!["--prompt".into(), sentence.into()]
    } else {
        vec![sentence.into()]
    }
}

/// Makes a harness run that this host started known, so that its conversation is followed.
type Follow = Box<dyn FnOnce(&dyn TranscriptWatcher) + Send>;

struct Prepared {
    pty: Box<dyn Pty>,
    cwd: String,
    loaded: bool,
    note: String,
    execution_id: Option<String>,
    follow: Option<Follow>,
}

fn now_ms() -> i64 {
    crate::time::millis(std::time::SystemTime::now())
}

fn registration(
    harness: RegisteredHarness,
    session_id: Option<String>,
    cwd: &str,
    home: Option<String>,
) -> Registration {
    Registration {
        harness,
        session_id,
        cwd: cwd.to_string(),
        config_dir: None,
        home,
        started_at: now_ms(),
    }
}

/// Checks what a session is asked to be, and starts its program. `sessions_dir` is the folder the runs
/// started in the terminal are noted in.
async fn prepare(
    params: &TerminalStartParams,
    deps: &TerminalDeps,
    sessions_dir: &Path,
    on_event: OnEvent,
) -> Result<Prepared, HostError> {
    let refuse = |text: &str| HostError::bad_request(text);
    let cwd = expand_home(
        params
            .cwd
            .as_deref()
            .unwrap_or(&deps.environment.home.to_string_lossy()),
        &deps.environment.home,
    );
    if !Path::new(&cwd).is_absolute() || !Path::new(&cwd).is_dir() {
        return Err(refuse(&format!("{cwd} is not a folder")));
    }
    let kind = params.kind;
    if kind == TerminalKind::Pipeline {
        if params.pipeline.is_none() {
            return Err(refuse("an interactive run needs a pipeline"));
        }
        if params.task.is_some() || params.resume.is_some() {
            return Err(refuse("a pipeline has no task or session to resume"));
        }
    } else if params.pipeline.is_some() || params.input.is_some() {
        return Err(refuse("only an interactive run takes a pipeline"));
    }
    if params.task.is_some() && kind == TerminalKind::Shell {
        return Err(refuse("a shell has no task to start"));
    }
    if params.resume.is_some() && (kind == TerminalKind::Shell || params.task.is_some()) {
        return Err(refuse(
            "only a harness without a task has a session to resume",
        ));
    }
    let plan = (deps.plan)(kind).await.map_err(HostError::unavailable)?;
    let config = load_config(&deps.config_file, &deps.environment)?;
    let mut args = plan.args.clone();
    let mut follow: Option<Follow> = None;
    // The commands of a shell note the runs they start in this folder.
    let mut extra: BTreeMap<String, String> = BTreeMap::new();
    if kind == TerminalKind::Shell {
        extra.insert(
            "SYNAPSE_SESSIONS_DIR".into(),
            sessions_dir.to_string_lossy().to_string(),
        );
    }
    match (kind, &params.resume) {
        (TerminalKind::Claude, resume) => {
            // A session of a name of our own, so that its file is known before it exists; a session
            // that is resumed has its own, and its file is the one that grows.
            let id = resume.clone().unwrap_or_else(uuid);
            args.extend(if resume.is_none() {
                ["--session-id".to_string(), id.clone()]
            } else {
                ["--resume".to_string(), id.clone()]
            });
            let (key, cwd) = (id.clone(), cwd.clone());
            follow = Some(Box::new(move |watcher| {
                watcher.register(
                    &key,
                    registration(RegisteredHarness::Claude, Some(key.clone()), &cwd, None),
                );
            }));
        }
        (TerminalKind::Opencode, resume) => {
            // A session of an id of our own, which OpenCode makes when there is none: its messages are
            // asked for by it. The same flag continues a session that is there.
            let id = resume
                .clone()
                .unwrap_or_else(|| format!("ses_{}", random_hex(10)));
            args.extend(["--session".to_string(), id.clone()]);
            let cwd = cwd.clone();
            follow = Some(Box::new(move |watcher| {
                watcher.register(
                    &id,
                    registration(RegisteredHarness::Opencode, Some(id.clone()), &cwd, None),
                );
            }));
        }
        (TerminalKind::Codex, Some(resume)) => {
            // A resumed session goes on in its own file, which is not one that appears after the start.
            args.extend(["resume".to_string(), resume.clone()]);
        }
        (TerminalKind::Codex, None) => {
            let home = plan.env.get("CODEX_HOME").cloned();
            let cwd = cwd.clone();
            follow = Some(Box::new(move |watcher| {
                let id = format!("codex-{}", random_hex(3));
                watcher.register(
                    &id,
                    registration(RegisteredHarness::Codex, None, &cwd, home),
                );
            }));
        }
        _ => {}
    }
    if let (Some(task), true) = (params.task, kind != TerminalKind::Pipeline) {
        args.extend(task_args(kind, task));
    }
    let mut execution_id = None;
    if let (TerminalKind::Pipeline, Some(pipeline)) = (kind, &params.pipeline) {
        if config.work_dir.is_none() {
            return Err(HostError::conflict("no work directory is set"));
        }
        let id = format!("exec-{}", random_hex(4));
        args.extend([
            "run".into(),
            pipeline.clone(),
            "--interactive".into(),
            "--id".into(),
            id.clone(),
        ]);
        if let Some(name) = &params.run_name {
            args.extend(["--name".into(), name.clone()]);
        }
        // The terminal is the harness's, so the input goes in a file of this session's own.
        if let Some(input) = &params.input {
            let file = sessions_dir.join("input.json");
            std::fs::create_dir_all(sessions_dir)
                .map_err(|e| HostError::internal(e.to_string()))?;
            std::fs::write(&file, input.to_string())
                .map_err(|e| HostError::internal(e.to_string()))?;
            args.extend(["--input".into(), file.to_string_lossy().to_string()]);
        }
        execution_id = Some(id);
    }
    // A shell is the user's own and reads its start-up files itself; a harness is given what they export.
    let base = if kind == TerminalKind::Shell {
        deps.environment.env.clone()
    } else {
        let captured = deps.login_environment.read().await;
        harness_environment(captured.as_ref(), &deps.environment.env)
    };
    let mut env: BTreeMap<String, String> = cli_environment(&base, &config)
        .into_iter()
        .filter(|(name, _)| !OF_ANOTHER_SESSION.contains(&name.as_str()))
        .collect();
    env.extend(plan.env.clone());
    env.extend(extra);
    env.insert("TERM".into(), "xterm-256color".into());
    env.insert("COLORTERM".into(), "truecolor".into());
    ensure_utf8_locale(&mut env);
    let options = SpawnOptions {
        cwd: cwd.clone(),
        env,
        cols: params.cols,
        rows: params.rows,
    };
    let pty = (deps.spawn)(&plan.command, &args, options, on_event).map_err(|e| {
        HostError::unavailable(format!("{} could not be started: {e}", plan.command))
    })?;
    Ok(Prepared {
        pty,
        cwd,
        loaded: plan.loaded,
        note: plan.note,
        execution_id,
        follow,
    })
}

// ---------------------------------------------------------------------------------------------
// The sessions
// ---------------------------------------------------------------------------------------------

struct State {
    screen: Screen,
    sinks: Vec<Arc<dyn Sink>>,
    exited: Option<i32>,
    /// What the conversations followed in it said, for a client that attaches later.
    sources: BTreeMap<String, Source>,
    lines: BTreeMap<String, Vec<String>>,
    cancel_expiry: Option<Box<dyn FnOnce() + Send>>,
}

struct Session {
    info: TerminalInfo,
    owner: String,
    pty: Box<dyn Pty>,
    state: Mutex<State>,
    watcher: Mutex<Option<Arc<dyn TranscriptWatcher>>>,
    sessions_dir: PathBuf,
}

struct Inner {
    deps: TerminalDeps,
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    /// The sessions being started, so that two starts of one id do not both go on.
    starting: Mutex<HashSet<String>>,
}

#[derive(Clone)]
pub struct Sessions(Arc<Inner>);

fn harness_name(harness: SourceHarness) -> &'static str {
    match harness {
        SourceHarness::Claude => "Claude",
        SourceHarness::Codex => "Codex",
        SourceHarness::Opencode => "Opencode",
    }
}

impl Session {
    fn info(&self) -> TerminalInfo {
        let mut info = self.info.clone();
        info.exited = self.state.lock().unwrap().exited;
        info
    }

    fn deliver(&self, state: &State, message: TerminalHostStream) {
        for sink in &state.sinks {
            sink.send(&self.info.session, message.clone());
        }
    }
}

impl Sessions {
    pub fn new(deps: TerminalDeps) -> Sessions {
        Sessions(Arc::new(Inner {
            deps,
            sessions: Mutex::new(HashMap::new()),
            starting: Mutex::new(HashSet::new()),
        }))
    }

    fn owned(&self, id: &str, owner: &str) -> Result<Arc<Session>, HostError> {
        let session = self
            .0
            .sessions
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .ok_or_else(|| HostError::not_found(format!("there is no session {id}")))?;
        // A session belongs to the user who started it, and only that user can attach.
        if session.owner != owner {
            return Err(HostError::forbidden("the session belongs to another user"));
        }
        Ok(session)
    }

    fn destroy(&self, session: &Arc<Session>) {
        let (cancel, exited) = {
            let mut state = session.state.lock().unwrap();
            (state.cancel_expiry.take(), state.exited)
        };
        if let Some(cancel) = cancel {
            cancel();
        }
        if exited.is_none() {
            session.pty.kill();
        }
        if let Some(watcher) = session.watcher.lock().unwrap().take() {
            watcher.stop();
        }
        self.0
            .sessions
            .lock()
            .unwrap()
            .remove(&session.info.session);
        // The folder is this session's own, inside the folder of the terminals.
        if session.sessions_dir.starts_with(&self.0.deps.sessions_root)
            && session.sessions_dir != self.0.deps.sessions_root
        {
            let _ = std::fs::remove_dir_all(&session.sessions_dir);
        }
    }

    fn expire_when_unattended(&self, session: &Arc<Session>) {
        let mut state = session.state.lock().unwrap();
        if !state.sinks.is_empty() || state.cancel_expiry.is_some() {
            return;
        }
        let (sessions, target) = (self.clone(), session.clone());
        state.cancel_expiry = Some((self.0.deps.schedule)(
            Box::new(move || sessions.destroy(&target)),
            DETACHED_TTL,
        ));
    }

    /// Starts a session for `sink`, and answers what it is.
    pub async fn start(
        &self,
        params: TerminalStartParams,
        owner: &str,
        sink: Arc<dyn Sink>,
    ) -> Result<TerminalInfo, HostError> {
        let inner = &self.0;
        if inner.sessions.lock().unwrap().contains_key(&params.session)
            || !inner
                .starting
                .lock()
                .unwrap()
                .insert(params.session.clone())
        {
            return Err(HostError::conflict("the session has started already"));
        }
        let outcome = self.start_inner(&params, owner, sink).await;
        inner.starting.lock().unwrap().remove(&params.session);
        outcome
    }

    async fn start_inner(
        &self,
        params: &TerminalStartParams,
        owner: &str,
        sink: Arc<dyn Sink>,
    ) -> Result<TerminalInfo, HostError> {
        let inner = &self.0;
        let live = inner
            .sessions
            .lock()
            .unwrap()
            .values()
            .filter(|s| s.state.lock().unwrap().exited.is_none())
            .count();
        if live + inner.starting.lock().unwrap().len()
            > inner.deps.max_terminals.load(Ordering::SeqCst)
        {
            return Err(HostError::conflict("too many terminals are open"));
        }
        // The registrations of the runs in this terminal.
        let sessions_dir = inner.deps.sessions_root.join(random_hex(6));
        let (events, mut incoming) = tokio::sync::mpsc::unbounded_channel::<PtyEvent>();
        let on_event: OnEvent = Arc::new(move |event| {
            let _ = events.send(event);
        });
        let prepared = prepare(params, &inner.deps, &sessions_dir, on_event).await?;
        let session = Arc::new(Session {
            info: TerminalInfo {
                session: params.session.clone(),
                title: params.title.clone(),
                kind: params.kind,
                cwd: prepared.cwd.clone(),
                task: params.task,
                pipeline: params.pipeline.clone(),
                execution_id: prepared.execution_id.clone(),
                loaded: prepared.loaded,
                note: prepared.note.clone(),
                exited: None,
            },
            owner: owner.to_string(),
            pty: prepared.pty,
            state: Mutex::new(State {
                screen: Screen::new(params.cols, params.rows),
                sinks: vec![sink],
                exited: None,
                sources: BTreeMap::new(),
                lines: BTreeMap::new(),
                cancel_expiry: None,
            }),
            watcher: Mutex::new(None),
            sessions_dir: sessions_dir.clone(),
        });
        inner
            .sessions
            .lock()
            .unwrap()
            .insert(params.session.clone(), session.clone());

        // What the program prints is kept on the screen and given to the clients, in order.
        {
            let (sessions, session) = (self.clone(), session.clone());
            tokio::spawn(async move {
                while let Some(event) = incoming.recv().await {
                    let mut state = session.state.lock().unwrap();
                    match event {
                        PtyEvent::Data(data) => {
                            state.screen.write(&data);
                            session.deliver(&state, TerminalHostStream::Output { data });
                        }
                        PtyEvent::Exit(code) => {
                            state.exited = Some(code);
                            let watcher = session.watcher.lock().unwrap().clone();
                            if let Some(watcher) = watcher {
                                watcher.stop();
                            }
                            session.deliver(&state, TerminalHostStream::Exit { code });
                            let unattended = state.sinks.is_empty();
                            drop(state);
                            if unattended {
                                sessions.expire_when_unattended(&session);
                            }
                            if let Some(on_exit) = &sessions.0.deps.on_exit {
                                on_exit();
                            }
                        }
                    }
                }
            });
        }

        let events = {
            let (on_source, on_lines) = (session.clone(), session.clone());
            TranscriptEvents {
                on_source: Arc::new(move |source| {
                    let mut state = on_source.state.lock().unwrap();
                    let message = TerminalHostStream::TranscriptSource {
                        id: source.id.clone(),
                        harness: harness_name(source.harness).into(),
                        cwd: source.cwd.clone(),
                    };
                    state.sources.insert(source.id.clone(), source);
                    on_source.deliver(&state, message);
                }),
                on_lines: Arc::new(move |id, lines| {
                    let mut state = on_lines.state.lock().unwrap();
                    let kept = state.lines.entry(id.clone()).or_default();
                    kept.extend(lines.iter().cloned());
                    if kept.len() > MAX_TRANSCRIPT_LINES {
                        let surplus = kept.len() - MAX_TRANSCRIPT_LINES;
                        kept.drain(..surplus);
                    }
                    on_lines.deliver(&state, TerminalHostStream::Transcript { id, lines });
                }),
            }
        };
        let watcher = (inner.deps.watch)(WatchOptions::new(
            sessions_dir,
            inner.deps.environment.home.clone(),
            events,
        ));
        *session.watcher.lock().unwrap() = Some(watcher.clone());
        if let Some(follow) = prepared.follow {
            follow(watcher.as_ref());
        }
        Ok(session.info())
    }

    /// Attaches `sink` to a session: it is sent the screen as the program drew it, and then what the
    /// program prints.
    pub fn attach(
        &self,
        id: &str,
        owner: &str,
        sink: Arc<dyn Sink>,
        cols: u16,
        rows: u16,
    ) -> Result<TerminalInfo, HostError> {
        let session = self.owned(id, owner)?;
        let cancel = session.state.lock().unwrap().cancel_expiry.take();
        if let Some(cancel) = cancel {
            cancel();
        }
        {
            // The screen is made and the sink is added under one lock, so that what the program prints
            // is either in the snapshot or after it.
            let mut state = session.state.lock().unwrap();
            if state.exited.is_none() {
                session.pty.resize(cols, rows);
                state.screen.resize(cols, rows);
            }
            state.sinks.retain(|s| !same_sink(s, &sink));
            sink.send(
                id,
                TerminalHostStream::Snapshot {
                    data: state.screen.snapshot(),
                },
            );
            for source in state.sources.values() {
                sink.send(
                    id,
                    TerminalHostStream::TranscriptSource {
                        id: source.id.clone(),
                        harness: harness_name(source.harness).into(),
                        cwd: source.cwd.clone(),
                    },
                );
            }
            for (line_id, lines) in &state.lines {
                sink.send(
                    id,
                    TerminalHostStream::Transcript {
                        id: line_id.clone(),
                        lines: lines.clone(),
                    },
                );
            }
            if let Some(code) = state.exited {
                sink.send(id, TerminalHostStream::Exit { code });
            }
            state.sinks.push(sink);
        }
        Ok(session.info())
    }

    /// Ends what a connection had attached, without ending the sessions.
    pub fn detach_all(&self, sink: &Arc<dyn Sink>) {
        let all: Vec<Arc<Session>> = self.0.sessions.lock().unwrap().values().cloned().collect();
        for session in all {
            let removed = {
                let mut state = session.state.lock().unwrap();
                let before = state.sinks.len();
                state.sinks.retain(|s| !same_sink(s, sink));
                state.sinks.len() != before
            };
            if removed {
                self.expire_when_unattended(&session);
            }
        }
    }

    /// What is typed, for a session the connection is attached to.
    pub fn input(
        &self,
        id: &str,
        owner: &str,
        sink: &Arc<dyn Sink>,
        data: &str,
    ) -> Result<(), HostError> {
        let session = self.owned(id, owner)?;
        let state = session.state.lock().unwrap();
        if state.sinks.iter().any(|s| same_sink(s, sink)) && state.exited.is_none() {
            session.pty.write(data);
        }
        Ok(())
    }

    pub fn resize(
        &self,
        id: &str,
        owner: &str,
        sink: &Arc<dyn Sink>,
        cols: u16,
        rows: u16,
    ) -> Result<(), HostError> {
        let session = self.owned(id, owner)?;
        let mut state = session.state.lock().unwrap();
        if !state.sinks.iter().any(|s| same_sink(s, sink)) || state.exited.is_some() {
            return Ok(());
        }
        session.pty.resize(cols, rows);
        state.screen.resize(cols, rows);
        Ok(())
    }

    /// Ends a session and its program.
    pub fn close(&self, id: &str, owner: &str) -> Result<(), HostError> {
        let session = self.owned(id, owner)?;
        self.destroy(&session);
        Ok(())
    }

    /// Ends every session and its process group: SIGHUP, then SIGKILL to what is left after
    /// `grace`. Returns when every session is gone.
    pub async fn shutdown(&self, grace: Duration) {
        let all: Vec<Arc<Session>> = self.0.sessions.lock().unwrap().values().cloned().collect();
        let running = |session: &Arc<Session>| session.state.lock().unwrap().exited.is_none();
        let ending: Vec<Arc<Session>> = all.iter().filter(|s| running(s)).cloned().collect();
        for session in &ending {
            session.pty.signal(EndSignal::Terminate);
        }
        let deadline = tokio::time::Instant::now() + grace;
        while ending.iter().any(running) && tokio::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        for session in ending.iter().filter(|s| running(s)) {
            session.pty.signal(EndSignal::Kill);
        }
        for session in &all {
            self.destroy(session);
        }
    }

    pub fn list(&self, owner: &str) -> Vec<TerminalInfo> {
        let mut found: Vec<TerminalInfo> = self
            .0
            .sessions
            .lock()
            .unwrap()
            .values()
            .filter(|s| s.owner == owner)
            .map(|s| s.info())
            .collect();
        found.sort_by(|a, b| a.session.cmp(&b.session));
        found
    }
}
