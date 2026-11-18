//! What the host says of the machine: the setup `synapse doctor` checks, and what each harness has
//! installed of Synapse.

use crate::cli::{CliRun, CliRunner};
use crate::dispatch::HostError;
use crate::environment::{join_paths, split_paths, Environment};
use crate::messages::{
    AppConfig, BundledSynapse, CliBinary, Counts, Diagnosis, DoctorFinding, Harness, Integration,
    IntegrationState, Integrations,
};
use std::collections::BTreeMap;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

const MARK: &str = "__SYNAPSE_PATH__";
const LOOK: Duration = Duration::from_secs(5);

/// The PATH a login shell has, or none when it cannot be had. The shell is asked as an interactive
/// login shell, the way a terminal is started, so that what its start-up files add is there; it is
/// told to mark the answer, since those files may print.
pub async fn read_login_path(shell: &str) -> Option<String> {
    let mut command = tokio::process::Command::new(shell);
    command
        // `${PATH}` in braces: `$PATH__SYNAPSE...` would be read as one variable of that name.
        .args(["-ilc", &format!("printf '%s' \"{MARK}${{PATH}}{MARK}\"")])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(LOOK, command.output())
        .await
        .ok()?
        .ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    if !output.status.success() && stdout.is_empty() {
        return None;
    }
    let start = stdout.find(MARK)?;
    let end = stdout.rfind(MARK)?;
    if end <= start {
        return None;
    }
    let path = &stdout[start + MARK.len()..end];
    (!path.is_empty()).then(|| path.to_string())
}

/// The directories of `first`, then those of `then` that are not there.
pub fn combined_path(first: Option<&str>, then: Option<&str>) -> String {
    let mut seen: Vec<&str> = Vec::new();
    for dir in split_paths(first.unwrap_or(""))
        .into_iter()
        .chain(split_paths(then.unwrap_or("")))
    {
        if !seen.contains(&dir) {
            seen.push(dir);
        }
    }
    join_paths(&seen)
}

/// The shell the user logs in with: `$SHELL`, else the system's default, zsh on macOS.
pub fn user_shell(environment: &Environment) -> String {
    environment
        .var("SHELL")
        .map(String::from)
        .unwrap_or_else(|| {
            if cfg!(target_os = "macos") {
                "/bin/zsh".into()
            } else {
                "/bin/sh".into()
            }
        })
}

/// The environment with the login shell's PATH: its directories first, then those this process had.
/// An app opened from Finder or the Dock has only the short PATH the system gives it
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), so a harness it starts would not be found; one started from a
/// terminal already has the login PATH, and is given the same directories once each.
pub fn with_login_path(environment: Environment, login: Option<&str>) -> Environment {
    let mut environment = environment;
    let own = environment.env.get("PATH").cloned();
    environment
        .env
        .insert("PATH".into(), combined_path(login, own.as_deref()));
    environment
}

type Login = Pin<Box<dyn Future<Output = Option<String>> + Send>>;

/// How the PATH of the login shell is had; the real one asks the user's shell, and a test says.
#[derive(Clone)]
pub struct LoginPath(Arc<dyn Fn() -> Login + Send + Sync>);

impl LoginPath {
    pub fn new<F, Fut>(read: F) -> LoginPath
    where
        F: Fn() -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Option<String>> + Send + 'static,
    {
        LoginPath(Arc::new(move || Box::pin(read())))
    }

    /// Asks the user's own shell; there is none to ask on Windows.
    pub fn shell(environment: &Environment) -> LoginPath {
        let shell = user_shell(environment);
        let none = cfg!(windows);
        LoginPath::new(move || {
            let shell = shell.clone();
            async move {
                if none {
                    None
                } else {
                    read_login_path(&shell).await
                }
            }
        })
    }

    pub async fn read(&self) -> Option<String> {
        (self.0)().await
    }
}

/// What `synapse doctor --install` says, with the harnesses looked for on the PATH of the user's login
/// shell as well as the one this host has: a program started from the desktop has the short PATH the
/// system gives it, and a terminal has the one the user's own files make.
pub async fn diagnose(
    config: AppConfig,
    runner: &CliRunner,
    login: &LoginPath,
    environment: &Environment,
) -> Result<Diagnosis, HostError> {
    // This host's PATH first, so that its own `synapse` is the one asked, not another copy the login
    // shell finds; the login shell's directories after it, for the harnesses only it can find.
    let path = combined_path(
        environment.env.get("PATH").map(String::as_str),
        login.read().await.as_deref(),
    );
    let mut run = CliRun::new(
        CliBinary::Synapse,
        &["doctor", "--install", "--format", "json"],
        config,
    );
    run.env = BTreeMap::from([("PATH".to_string(), path)]);
    let result = runner.run(run).await.map_err(HostError::unavailable)?;
    // A failure is a finding with exit code 1, and is printed all the same. Nothing printed is the
    // program not running at all.
    let Ok(json) = serde_json::from_str::<serde_json::Value>(&result.stdout) else {
        let why = if result.stderr.is_empty() {
            &result.stdout
        } else {
            &result.stderr
        };
        let why = why.trim();
        return Err(HostError::unavailable(if why.is_empty() {
            "synapse doctor printed nothing".to_string()
        } else {
            why.to_string()
        }));
    };
    let format_known = json.get("format").and_then(|f| f.as_str()) == Some("synapse-doctor/v1");
    let findings: Option<Vec<DoctorFinding>> =
        serde_json::from_value(json.get("checks").cloned().unwrap_or_default()).ok();
    let counts: Option<Counts> =
        serde_json::from_value(json.get("counts").cloned().unwrap_or_default()).ok();
    match (format_known, findings, counts) {
        (true, Some(findings), Some(counts)) => Ok(Diagnosis { findings, counts }),
        _ => Err(HostError::unavailable(
            "synapse doctor answered in a format this app does not know",
        )),
    }
}

// ---------------------------------------------------------------------------------------------
// What each harness has installed
// ---------------------------------------------------------------------------------------------

const HOOK_NAME: &str = "synapse-hook";
const EXE: &str = if cfg!(windows) { ".exe" } else { "" };

type Version = Pin<Box<dyn Future<Output = Option<String>> + Send>>;

/// The version a program says it is, or none when it cannot be run.
#[derive(Clone)]
pub struct VersionOf(Arc<dyn Fn(PathBuf) -> Version + Send + Sync>);

impl VersionOf {
    pub fn new<F, Fut>(read: F) -> VersionOf
    where
        F: Fn(PathBuf) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Option<String>> + Send + 'static,
    {
        VersionOf(Arc::new(move |program| Box::pin(read(program))))
    }

    /// Runs `program --version`.
    pub fn program() -> VersionOf {
        VersionOf::new(|program| async move {
            let mut command = tokio::process::Command::new(program);
            command
                .arg("--version")
                .stdin(std::process::Stdio::null())
                .kill_on_drop(true);
            let output = tokio::time::timeout(Duration::from_secs(5), command.output())
                .await
                .ok()?
                .ok()?;
            if !output.status.success() {
                return None;
            }
            version_in(&String::from_utf8_lossy(&output.stdout))
        })
    }

    async fn of(&self, program: PathBuf) -> Option<String> {
        (self.0)(program).await
    }
}

/// What `program --version` prints after the program's name.
pub fn version_in(stdout: &str) -> Option<String> {
    regex::Regex::new(r"(?m)^\S+ (\S+)")
        .unwrap()
        .captures(stdout)
        .map(|c| c[1].to_string())
}

/// The first file of that name on PATH.
pub fn find_executable(name: &str, path_variable: &str) -> Option<PathBuf> {
    let names: Vec<String> = if cfg!(windows) {
        vec![format!("{name}.exe"), name.to_string()]
    } else {
        vec![name.to_string()]
    };
    for dir in split_paths(path_variable) {
        for file in &names {
            let candidate = Path::new(dir).join(file);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// The folder with the skills and the harness files of the `synapse` package: named by
/// `SYNAPSE_CONTENT_ROOT`, else the package the launcher on PATH belongs to, else the folders the
/// app is bundled with.
pub fn find_content_root(environment: &Environment, bundled: &[PathBuf]) -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(root) = environment.var("SYNAPSE_CONTENT_ROOT") {
        candidates.push(root.into());
    }
    if let Some(launcher) = find_executable(
        "synapse",
        environment
            .env
            .get("PATH")
            .map(String::as_str)
            .unwrap_or(""),
    ) {
        if let Ok(real) = dunce::canonicalize(launcher) {
            candidates.push(real.parent().unwrap_or(Path::new("")).join(".."));
        }
    }
    candidates.extend(bundled.iter().cloned());
    candidates
        .into_iter()
        .find(|c| c.join("skills").is_dir() && c.join("harness").is_dir())
        .and_then(|c| dunce::canonicalize(c).ok())
}

/// The folder of the `synapse-pipeline` package, with its skills.
pub fn find_pipeline_root(environment: &Environment, bundled: &[PathBuf]) -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(launcher) = find_executable(
        "synapse-pipeline",
        environment
            .env
            .get("PATH")
            .map(String::as_str)
            .unwrap_or(""),
    ) {
        if let Ok(real) = dunce::canonicalize(launcher) {
            candidates.push(real.parent().unwrap_or(Path::new("")).join(".."));
        }
    }
    candidates.extend(bundled.iter().cloned());
    candidates
        .into_iter()
        .find(|c| c.join("skills").is_dir())
        .and_then(|c| dunce::canonicalize(c).ok())
}

fn hook_in(command: &serde_json::Value) -> Option<String> {
    let program = command.as_str()?.split(' ').next()?;
    let name = program.replace('\\', "/");
    let name = name.rsplit('/').next().unwrap_or("");
    let name = name.strip_suffix(".exe").unwrap_or(name);
    (name == HOOK_NAME).then(|| program.to_string())
}

fn first_hook_of(hooks: &serde_json::Value) -> Option<String> {
    for groups in hooks.as_object()?.values() {
        for group in groups.as_array().into_iter().flatten() {
            for hook in group
                .get("hooks")
                .and_then(|h| h.as_array())
                .into_iter()
                .flatten()
            {
                if let Some(found) = hook.get("command").and_then(hook_in) {
                    return Some(found);
                }
            }
        }
    }
    None
}

/// The hook program the harness runs, as its configuration names it.
pub fn hook_of(harness: Harness, home: &Path) -> Option<String> {
    if harness == Harness::Opencode {
        let text = std::fs::read_to_string(home.join(".config/opencode/plugin/synapse.js"))
            .unwrap_or_default();
        let literal = regex::Regex::new(r#"SYNAPSE_HOOK_BIN\s*\|\|\s*("(?:[^"\\]|\\.)*")"#)
            .unwrap()
            .captures(&text)?
            .get(1)?
            .as_str()
            .to_string();
        let path: String = serde_json::from_str(&literal).ok()?;
        return (path != "__SYNAPSE_HOOK_BIN__").then_some(path);
    }
    let file = if harness == Harness::Claude {
        home.join(".claude/settings.json")
    } else {
        home.join(".codex/hooks.json")
    };
    let json: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(file).ok()?).ok()?;
    first_hook_of(json.get("hooks")?)
}

struct Parsed {
    numbers: [u64; 3],
    pre: Option<String>,
}

fn parse_version(text: &str) -> Option<Parsed> {
    let captures = regex::Regex::new(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$")
        .unwrap()
        .captures(text)?;
    let number = |i| captures.get(i).and_then(|m| m.as_str().parse().ok());
    Some(Parsed {
        numbers: [number(1)?, number(2)?, number(3)?],
        pre: captures.get(4).map(|m| m.as_str().to_string()),
    })
}

/// -1, 0 or 1 as `a` is older than, the same as or newer than `b`, or none when either is not a
/// version. A pre-release is older than its release, and `0.0.0-dev`, which is what a build from a
/// checkout says, is older than all.
pub fn compare_versions(a: &str, b: &str) -> Option<i8> {
    let (x, y) = (parse_version(a)?, parse_version(b)?);
    for i in 0..3 {
        if x.numbers[i] != y.numbers[i] {
            return Some(if x.numbers[i] < y.numbers[i] { -1 } else { 1 });
        }
    }
    Some(match (&x.pre, &y.pre) {
        (a, b) if a == b => 0,
        (None, _) => 1,
        (_, None) => -1,
        (Some(a), Some(b)) => {
            if a < b {
                -1
            } else {
                1
            }
        }
    })
}

/// The version of the Synapse a hook program belongs to: what the `synapse` beside it says, else the
/// version of the npm package it is in, which a release made before programs said their version still
/// has.
async fn installed_version(hook: &Path, version_of: &VersionOf) -> Option<String> {
    let dir = hook.parent()?;
    if let Some(said) = version_of.of(dir.join(format!("synapse{EXE}"))).await {
        return Some(said);
    }
    let manifest: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("..").join("package.json")).ok()?)
            .ok()?;
    let name = manifest.get("name")?.as_str()?;
    let version = manifest.get("version")?.as_str()?;
    name.starts_with("@imunitic/synapse-")
        .then(|| version.to_string())
}

fn same_file(a: &Path, b: &Path) -> bool {
    let real = |p: &Path| dunce::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
    real(a) == real(b)
}

async fn bundled(
    environment: &Environment,
    version_of: &VersionOf,
    roots: &[PathBuf],
) -> BundledSynapse {
    let path = environment
        .env
        .get("PATH")
        .map(String::as_str)
        .unwrap_or("");
    let program = find_executable("synapse", path);
    let hook = program.as_ref().map(|p| {
        p.parent()
            .unwrap_or(Path::new(""))
            .join(format!("{HOOK_NAME}{EXE}"))
    });
    let text = |p: Option<PathBuf>| p.map(|p| p.to_string_lossy().to_string());
    BundledSynapse {
        version: match &program {
            Some(program) => version_of.of(program.clone()).await,
            None => None,
        },
        hook: text(hook.filter(|h| h.is_file())),
        content_root: text(find_content_root(environment, roots)),
        pipeline_root: text(find_pipeline_root(environment, roots)),
    }
}

async fn integration(
    harness: Harness,
    have: &BundledSynapse,
    environment: &Environment,
    version_of: &VersionOf,
) -> Integration {
    let Some(hook) = hook_of(harness, &environment.home) else {
        return Integration {
            harness,
            state: IntegrationState::Absent,
            hook: None,
            version: None,
        };
    };
    if !Path::new(&hook).is_file() {
        return Integration {
            harness,
            state: IntegrationState::Broken,
            hook: Some(hook),
            version: None,
        };
    }
    let version = installed_version(Path::new(&hook), version_of).await;
    let mut state = IntegrationState::Installed;
    if let Some(have_hook) = &have.hook {
        let order = match (&version, &have.version) {
            (Some(v), Some(h)) => compare_versions(v, h),
            _ => None,
        };
        state = if same_file(Path::new(&hook), Path::new(have_hook)) || order == Some(0) {
            IntegrationState::Current
        } else if order == Some(1) {
            IntegrationState::Newer
        } else {
            IntegrationState::Different
        };
    }
    Integration {
        harness,
        state,
        hook: Some(hook),
        version,
    }
}

/// What each harness has installed of Synapse, and the Synapse this app would install. `roots` are
/// the folders the app is bundled with.
pub async fn inspect_integrations(
    environment: &Environment,
    version_of: &VersionOf,
    roots: &[PathBuf],
) -> Integrations {
    let have = bundled(environment, version_of, roots).await;
    let mut harnesses = Vec::new();
    for harness in [Harness::Claude, Harness::Codex, Harness::Opencode] {
        harnesses.push(integration(harness, &have, environment, version_of).await);
    }
    Integrations {
        bundled: have,
        harnesses,
    }
}
