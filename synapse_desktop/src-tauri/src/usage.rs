//! How much of each harness's limit is used, or what it has cost today, as the host reads it and
//! publishes it on the `usage` topic. The same shape as `shared/usage.ts`. The usage is read every 5
//! minutes while a client watches, and nothing is read while none is subscribed; a provider that
//! read well once and then fails keeps its figures, marked `Stale`. The Node host does the same in
//! `server/usage.ts`.

use crate::environment::Environment;
use crate::messages::Harness;
use crate::status::{find_executable, with_login_path, LoginPath};
use crate::usage_claude::{read_claude_usage, run_program, ClaudeUsageDeps, Pending, RunOutput};
use crate::usage_codex::{read_codex_usage, spawn_codex, CodexChild, CodexUsageDeps};
use crate::usage_opencode::{read_opencode_usage, OpencodeUsageDeps};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

/// `Ok`: read just now. `Stale`: the last good figures, kept after a read failed. The other three
/// say why there is no figure at all.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum UsageState {
    Ok,
    Stale,
    NotSignedIn,
    Unavailable,
    NotInstalled,
}

/// One limit of a harness: a session, a week, the 5 hours of Codex.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    pub name: String,
    pub percent: f64,
    /// ISO 8601 UTC, `None` when the text gave none.
    pub resets_at: Option<String>,
    /// Counts toward the bar item's colour and figure.
    pub decides: bool,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum UsageKind {
    Limit,
    Spend,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum SpendPeriod {
    Today,
    Session,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Spend {
    pub amount: f64,
    pub period: SpendPeriod,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageReading {
    pub harness: Harness,
    pub kind: UsageKind,
    /// Empty for spend.
    pub windows: Vec<UsageWindow>,
    pub spend: Option<Spend>,
    /// When the figures were read; `None` when never read.
    pub observed_at: Option<String>,
    pub state: UsageState,
    /// In words, for any state but `Ok`.
    pub reason: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageEvent {
    pub readings: Vec<UsageReading>,
}

pub const USAGE_INTERVAL: Duration = Duration::from_secs(300);
pub const USAGE_NUDGE_QUIET: Duration = Duration::from_secs(30);

/// Reads one harness's usage now.
pub type Provider = Arc<dyn Fn() -> Pending<UsageReading> + Send + Sync>;
/// Given each event that is published.
pub type UsagePush = Arc<dyn Fn(UsageEvent) + Send + Sync>;

pub struct UsageOptions {
    /// Claude, Codex, Opencode, in that order.
    pub providers: Vec<Provider>,
    pub interval: Duration,
    pub nudge_quiet: Duration,
}

impl UsageOptions {
    /// The providers, with the default timing.
    pub fn new(providers: Vec<Provider>) -> UsageOptions {
        UsageOptions {
            providers,
            interval: USAGE_INTERVAL,
            nudge_quiet: USAGE_NUDGE_QUIET,
        }
    }
}

struct UsageStore {
    subscribers: BTreeMap<u64, UsagePush>,
    next_id: u64,
    last: Option<UsageEvent>,
    finished_at: Option<Instant>,
    reading: bool,
    /// The last reading of each provider that was `Ok`, kept for when a later read fails.
    good: Vec<Option<UsageReading>>,
    /// Changes whenever the reads at the interval stop, so that a timer of before ends.
    generation: u64,
    /// The runtime of the subscribers, for a nudge that comes from elsewhere.
    runtime: Option<tokio::runtime::Handle>,
}

struct UsageInner {
    providers: Vec<Provider>,
    interval: Duration,
    nudge_quiet: Duration,
    state: Mutex<UsageStore>,
}

/// The usage of the harnesses, as the clients that subscribe to `usage` are given it.
#[derive(Clone)]
pub struct Usage(Arc<UsageInner>);

impl Usage {
    pub fn new(options: UsageOptions) -> Usage {
        let good = options.providers.iter().map(|_| None).collect();
        Usage(Arc::new(UsageInner {
            providers: options.providers,
            interval: options.interval,
            nudge_quiet: options.nudge_quiet,
            state: Mutex::new(UsageStore {
                subscribers: BTreeMap::new(),
                next_id: 0,
                last: None,
                finished_at: None,
                reading: false,
                good,
                generation: 0,
                runtime: None,
            }),
        }))
    }

    /// Usage with no provider, for a host that does not read any.
    pub fn none() -> Usage {
        Usage::new(UsageOptions::new(vec![]))
    }

    /// The three providers as they read this machine: programs on the PATH of the login shell and
    /// the host's own, run in the work directory, or the home folder when none is set.
    pub fn system(environment: Environment, config_file: PathBuf, login_path: LoginPath) -> Usage {
        let machine = Arc::new(Machine {
            environment,
            config_file,
            login_path,
            path: tokio::sync::OnceCell::new(),
        });
        let claude: Provider = {
            let machine = machine.clone();
            Arc::new(move || {
                let machine = machine.clone();
                Box::pin(async move { read_claude_usage(&machine.deps().await).await })
            })
        };
        let codex: Provider = {
            let machine = machine.clone();
            Arc::new(move || {
                let machine = machine.clone();
                Box::pin(async move { read_codex_usage(&machine.deps().await).await })
            })
        };
        let opencode: Provider = Arc::new(move || {
            let machine = machine.clone();
            Box::pin(async move { read_opencode_usage(&machine.deps().await).await })
        });
        Usage::new(UsageOptions::new(vec![claude, codex, opencode]))
    }

    /// Gives `push` the last event at once, and every later one until the returned stop is called.
    /// A read starts when the last one is older than the interval.
    pub fn subscribe(&self, push: UsagePush) -> Box<dyn FnOnce() + Send> {
        let (id, last, read_now, start_timer) = {
            let mut state = self.0.state.lock().unwrap();
            state.runtime = tokio::runtime::Handle::try_current().ok();
            let id = state.next_id;
            state.next_id += 1;
            let start_timer = state.subscribers.is_empty();
            state.subscribers.insert(id, push.clone());
            let read_now = state
                .finished_at
                .is_none_or(|at| at.elapsed() >= self.0.interval);
            (id, state.last.clone(), read_now, start_timer)
        };
        if let Some(event) = last {
            push(event);
        }
        if read_now {
            self.start_read();
        }
        if start_timer {
            self.start_timer();
        }
        let usage = self.clone();
        Box::new(move || {
            let mut state = usage.0.state.lock().unwrap();
            state.subscribers.remove(&id);
            if state.subscribers.is_empty() {
                state.generation += 1;
            }
        })
    }

    /// Reads now, unless no client watches, a read is running or the last one finished under the
    /// quiet time ago.
    pub fn nudge(&self) {
        {
            let state = self.0.state.lock().unwrap();
            if state.subscribers.is_empty() || state.reading {
                return;
            }
            if state
                .finished_at
                .is_some_and(|at| at.elapsed() < self.0.nudge_quiet)
            {
                return;
            }
        }
        self.start_read();
    }

    fn spawn<F>(&self, work: F)
    where
        F: std::future::Future<Output = ()> + Send + 'static,
    {
        let runtime = tokio::runtime::Handle::try_current()
            .ok()
            .or_else(|| self.0.state.lock().unwrap().runtime.clone());
        if let Some(runtime) = runtime {
            runtime.spawn(work);
        }
    }

    fn start_timer(&self) {
        let generation = self.0.state.lock().unwrap().generation;
        let usage = self.clone();
        self.spawn(async move {
            loop {
                tokio::time::sleep(usage.0.interval).await;
                if usage.0.state.lock().unwrap().generation != generation {
                    return;
                }
                usage.read().await;
            }
        });
    }

    fn start_read(&self) {
        let usage = self.clone();
        self.spawn(async move { usage.read().await });
    }

    async fn read(&self) {
        {
            let mut state = self.0.state.lock().unwrap();
            if state.reading {
                return;
            }
            state.reading = true;
        }
        let tasks: Vec<_> = self
            .0
            .providers
            .iter()
            .map(|provider| tokio::spawn(provider()))
            .collect();
        let mut readings = Vec::with_capacity(tasks.len());
        for task in tasks {
            readings.push(task.await.ok());
        }
        let (event, subscribers) = {
            let mut state = self.0.state.lock().unwrap();
            let readings = readings
                .into_iter()
                .enumerate()
                .filter_map(|(index, reading)| {
                    reading.map(|reading| settled(&mut state.good[index], reading))
                })
                .collect();
            let event = UsageEvent { readings };
            state.last = Some(event.clone());
            state.finished_at = Some(Instant::now());
            state.reading = false;
            let subscribers: Vec<UsagePush> = state.subscribers.values().cloned().collect();
            (event, subscribers)
        };
        for push in subscribers {
            push(event.clone());
        }
    }
}

/// The reading as it is published: an `Ok` one is kept, and an `Unavailable` one after it gives
/// the kept figures as `Stale`, with the new reason. `NotSignedIn` and `NotInstalled` drop the
/// kept figures, so they never come back after a sign-out or an uninstall.
fn settled(good: &mut Option<UsageReading>, reading: UsageReading) -> UsageReading {
    if reading.state == UsageState::Ok {
        *good = Some(reading.clone());
        return reading;
    }
    if matches!(reading.state, UsageState::NotSignedIn | UsageState::NotInstalled) {
        *good = None;
    }
    match good {
        Some(kept) if reading.state == UsageState::Unavailable => UsageReading {
            state: UsageState::Stale,
            reason: reading.reason,
            ..kept.clone()
        },
        _ => reading,
    }
}

/// This machine, as the providers read it.
struct Machine {
    environment: Environment,
    config_file: PathBuf,
    login_path: LoginPath,
    /// The PATH of the login shell joined with the host's own, read once.
    path: tokio::sync::OnceCell<String>,
}

impl Machine {
    async fn deps(&self) -> SystemDeps {
        let path = self
            .path
            .get_or_init(|| async {
                let login = self.login_path.read().await;
                with_login_path(self.environment.clone(), login.as_deref())
                    .env
                    .get("PATH")
                    .cloned()
                    .unwrap_or_default()
            })
            .await
            .clone();
        let work_dir = crate::config::load_config(&self.config_file, &self.environment)
            .ok()
            .and_then(|config| config.work_dir)
            .map(PathBuf::from)
            .unwrap_or_else(|| self.environment.home.clone());
        SystemDeps { path, work_dir }
    }
}

struct SystemDeps {
    path: String,
    work_dir: PathBuf,
}

impl SystemDeps {
    fn work_dir_now(&self) -> Pending<PathBuf> {
        let work_dir = self.work_dir.clone();
        Box::pin(async move { work_dir })
    }
}

impl ClaudeUsageDeps for SystemDeps {
    fn find_program(&self, name: &str) -> Option<PathBuf> {
        find_executable(name, &self.path)
    }
    fn run(
        &self,
        program: PathBuf,
        args: Vec<String>,
        cwd: PathBuf,
        timeout: Duration,
    ) -> Pending<Result<RunOutput, String>> {
        run_program(program, args, cwd, timeout)
    }
    fn work_dir(&self) -> Pending<PathBuf> {
        self.work_dir_now()
    }
    fn now(&self) -> SystemTime {
        SystemTime::now()
    }
}

impl CodexUsageDeps for SystemDeps {
    fn find_program(&self, name: &str) -> Option<PathBuf> {
        find_executable(name, &self.path)
    }
    fn spawn(&self, program: PathBuf, args: Vec<String>) -> Result<CodexChild, String> {
        spawn_codex(program, args)
    }
    fn client_version(&self) -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }
    fn now(&self) -> SystemTime {
        SystemTime::now()
    }
}

impl OpencodeUsageDeps for SystemDeps {
    fn find_program(&self, name: &str) -> Option<PathBuf> {
        find_executable(name, &self.path)
    }
    fn run(
        &self,
        program: PathBuf,
        args: Vec<String>,
        cwd: PathBuf,
        timeout: Duration,
    ) -> Pending<Result<RunOutput, String>> {
        run_program(program, args, cwd, timeout)
    }
    fn work_dir(&self) -> Pending<PathBuf> {
        self.work_dir_now()
    }
    fn now(&self) -> SystemTime {
        SystemTime::now()
    }
}
