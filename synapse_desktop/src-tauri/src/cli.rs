//! Running the Synapse programs: only the subcommands listed here, never a shell.

use crate::config::is_namespace;
use crate::environment::{join_paths, split_paths};
use crate::messages::{AppConfig, CliBinary, CliResult};
use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const MAX_ARGS: usize = 32;
const MAX_ARG_LENGTH: usize = 4096;
const TIMEOUT: Duration = Duration::from_secs(30);
const MAX_OUTPUT_BYTES: usize = 8 * 1024 * 1024;

/// What `cli` may run. Starting a run is `run.start`, not a subcommand of this.
fn allowed_subcommands(binary: CliBinary) -> &'static [&'static str] {
    match binary {
        CliBinary::SynapsePipeline => &[
            "check",
            "show",
            "definitions",
            "list",
            "info",
            "changes",
            "cleanup",
        ],
        CliBinary::Synapse => &[
            "config",
            "projects",
            "status",
            "vault-list",
            "vault-read",
            "vault-search",
            "vault-search-text",
            "vault-links",
            "vault-backlinks",
            "vault-doc-map",
            "work-dir",
            "callers",
            "index",
        ],
    }
}

/// A setting's name: capitals, digits and underscores.
fn is_setting_key(text: &str) -> bool {
    let mut chars = text.chars();
    chars.next().is_some_and(|c| c.is_ascii_uppercase())
        && chars.all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
}

fn is_format(rest: &[String]) -> bool {
    rest.len() == 2 && rest[0] == "--format" && (rest[1] == "json" || rest[1] == "text")
}

/// `config list [--format json|text]`, `config set <KEY> <value>` and `config unset <KEY>`, and
/// nothing else of `synapse config`.
fn refuse_config(args: &[String]) -> Option<String> {
    let action = args.get(1).map(String::as_str);
    let rest = args.get(2..).unwrap_or(&[]);
    let refusal = |text: &str| Some(text.to_string());
    match action {
        Some("list") => {
            if rest.is_empty() || is_format(rest) {
                None
            } else {
                refusal("config list takes only --format json or text")
            }
        }
        Some("set") => {
            if rest.len() == 2 && is_setting_key(&rest[0]) {
                None
            } else {
                refusal("config set takes a setting name and a value")
            }
        }
        Some("unset") => {
            if rest.len() == 1 && is_setting_key(&rest[0]) {
                None
            } else {
                refusal("config unset takes a setting name")
            }
        }
        _ => refusal("config takes list, set or unset"),
    }
}

/// `status [--format json|text]`, and nothing else of `synapse status`.
fn refuse_status(args: &[String]) -> Option<String> {
    let rest = args.get(1..).unwrap_or(&[]);
    if rest.is_empty() || is_format(rest) {
        None
    } else {
        Some("status takes only --format json or text".into())
    }
}

fn is_field_list(text: &str) -> bool {
    (1..=200).contains(&text.len())
        && text
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ',' | '-'))
}

/// `projects [list] [--format json|text]` and `projects add <name> <prefix>`, and nothing else.
fn refuse_projects(args: &[String]) -> Option<String> {
    let rest = &args[1..];
    if rest.is_empty() || (rest.len() == 1 && rest[0] == "list") || is_format(rest) {
        return None;
    }
    if rest[0] == "list" && is_format(&rest[1..]) {
        return None;
    }
    if rest[0] == "add" {
        let ok = rest.len() == 3 && plain(rest.get(1), 64) && plain(rest.get(2), 32);
        return if ok {
            None
        } else {
            Some("projects add takes a name and a prefix".into())
        };
    }
    Some("projects takes list or add".into())
}

/// The read-only commands of the vault. `vault-list` takes nothing; each of the others takes one
/// argument that is not a flag, a note's path or a search.
fn refuse_vault(args: &[String]) -> Option<String> {
    let subcommand = args[0].as_str();
    let rest = &args[1..];
    if subcommand == "vault-list" {
        return if rest.is_empty() {
            None
        } else {
            Some("vault-list takes no arguments".into())
        };
    }
    // A search by a rule on standard input names the columns it wants back.
    if subcommand == "vault-search" {
        let ok = rest.len() == 2 && rest[0] == "--fields" && is_field_list(&rest[1]);
        return if ok {
            None
        } else {
            Some("vault-search takes only --fields and a list of fields".into())
        };
    }
    if rest.len() != 1 || rest[0].starts_with('-') || rest[0].is_empty() {
        return Some(format!(
            "{subcommand} takes one argument that is not a flag"
        ));
    }
    None
}

/// A search term or a path: one argument that is not a flag.
fn plain(arg: Option<&String>, max: usize) -> bool {
    arg.is_some_and(|a| !a.is_empty() && !a.starts_with('-') && a.len() <= max)
}

/// The reads of a graph's local files, always of one namespace named by `--namespace`:
/// `callers <name> [--all]`, `index lookup <path>` and `index nodes|paths|unassigned`; and
/// `work-dir --list` or `--root`.
fn refuse_graph(args: &[String]) -> Option<String> {
    let subcommand = args[0].as_str();
    let rest = &args[1..];
    let named = |at: usize| {
        rest.len() == at + 2 && rest[at] == "--namespace" && is_namespace(&rest[at + 1])
    };
    match subcommand {
        "work-dir" => {
            if rest.len() == 1 && (rest[0] == "--list" || rest[0] == "--root") {
                None
            } else {
                Some("work-dir takes only --list or --root".into())
            }
        }
        "callers" => {
            let all = rest.get(1).is_some_and(|a| a == "--all");
            let ok = plain(rest.first(), 512) && named(if all { 2 } else { 1 });
            if ok {
                None
            } else {
                Some("callers takes a name, --all and --namespace <repo>@<branch>".into())
            }
        }
        _ => {
            // `index`
            let action = rest.first().map(String::as_str);
            let more = rest.get(1..).unwrap_or(&[]);
            match action {
                Some("lookup") => {
                    let ok = plain(more.first(), 4096)
                        && more.len() == 3
                        && more[1] == "--namespace"
                        && is_namespace(&more[2]);
                    if ok {
                        None
                    } else {
                        Some("index lookup takes a path and --namespace <repo>@<branch>".into())
                    }
                }
                Some(action @ ("nodes" | "paths" | "unassigned")) => {
                    if more.len() == 2 && more[0] == "--namespace" && is_namespace(&more[1]) {
                        None
                    } else {
                        Some(format!("index {action} takes --namespace <repo>@<branch>"))
                    }
                }
                _ => Some("index takes lookup, nodes, paths or unassigned".into()),
            }
        }
    }
}

fn name_of(binary: CliBinary) -> &'static str {
    match binary {
        CliBinary::SynapsePipeline => "synapse-pipeline",
        CliBinary::Synapse => "synapse",
    }
}

/// The reason the call is refused, or none when it may run.
pub fn refuse_cli(binary: CliBinary, args: &[String]) -> Option<String> {
    let Some(subcommand) = args.first() else {
        return Some("a subcommand is required".into());
    };
    if !allowed_subcommands(binary).contains(&subcommand.as_str()) {
        return Some(format!("{} {subcommand} is not allowed", name_of(binary)));
    }
    if args.len() > MAX_ARGS {
        return Some("too many arguments".into());
    }
    if args
        .iter()
        .any(|a| a.chars().count() > MAX_ARG_LENGTH || a.contains('\0'))
    {
        return Some("an argument is too long or holds a NUL".into());
    }
    if binary != CliBinary::Synapse {
        return None;
    }
    match subcommand.as_str() {
        "status" => refuse_status(args),
        "projects" => refuse_projects(args),
        s if s.starts_with("vault-") => refuse_vault(args),
        "work-dir" | "callers" | "index" => refuse_graph(args),
        _ => refuse_config(args),
    }
}

/// One run of a program.
#[derive(Clone, Debug)]
pub struct CliRun {
    pub binary: CliBinary,
    pub args: Vec<String>,
    pub stdin: Option<String>,
    pub config: AppConfig,
    /// Variables set after the others, to point the program somewhere else.
    pub env: BTreeMap<String, String>,
    /// The folder to run in, for the commands that work on the repository there.
    pub cwd: Option<String>,
}

impl CliRun {
    pub fn new(binary: CliBinary, args: &[&str], config: AppConfig) -> CliRun {
        CliRun {
            binary,
            args: args.iter().map(|a| a.to_string()).collect(),
            stdin: None,
            config,
            env: BTreeMap::new(),
            cwd: None,
        }
    }
}

/// The environment a Synapse program runs in: the work directory and the definition directories the
/// user set up in the app come before those the process already had, and the variables the user set
/// are over all of it.
pub fn cli_environment(
    base: &BTreeMap<String, String>,
    config: &AppConfig,
) -> BTreeMap<String, String> {
    let mut env = base.clone();
    if let Some(work_dir) = &config.work_dir {
        env.insert("SYNAPSE_WORK_DIR".into(), work_dir.clone());
    }
    if !config.definition_paths.is_empty() {
        let inherited = split_paths(
            base.get("SYNAPSE_PIPELINE_PATH")
                .map(String::as_str)
                .unwrap_or(""),
        );
        let all: Vec<&str> = config
            .definition_paths
            .iter()
            .map(String::as_str)
            .chain(inherited)
            .filter(|p| !p.is_empty())
            .collect();
        env.insert("SYNAPSE_PIPELINE_PATH".into(), join_paths(&all));
    }
    // The variables the user set in the app come last, so that they win.
    for (name, value) in &config.env {
        env.insert(name.clone(), value.clone());
    }
    env
}

type Run = Pin<Box<dyn Future<Output = Result<CliResult, String>> + Send>>;

/// Runs a program and says what it printed. A failure to run it at all is an error; a non-zero exit
/// is a result.
#[derive(Clone)]
pub struct CliRunner(Arc<dyn Fn(CliRun) -> Run + Send + Sync>);

impl CliRunner {
    pub fn new<F, Fut>(run: F) -> CliRunner
    where
        F: Fn(CliRun) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<CliResult, String>> + Send + 'static,
    {
        CliRunner(Arc::new(move |request| Box::pin(run(request))))
    }

    pub fn run(&self, request: CliRun) -> Run {
        (self.0)(request)
    }

    /// The runner that starts the programs, looked up on the PATH the run has.
    pub fn system(base: BTreeMap<String, String>) -> CliRunner {
        CliRunner::new(move |request| run_program(base.clone(), request))
    }
}

async fn read_capped<R: tokio::io::AsyncRead + Unpin>(mut from: R) -> Result<Vec<u8>, String> {
    let mut kept = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    loop {
        let read = from.read(&mut chunk).await.map_err(|e| e.to_string())?;
        if read == 0 {
            return Ok(kept);
        }
        kept.extend_from_slice(&chunk[..read]);
        if kept.len() > MAX_OUTPUT_BYTES {
            return Err("the output is too large".into());
        }
    }
}

async fn run_program(base: BTreeMap<String, String>, request: CliRun) -> Result<CliResult, String> {
    let name = name_of(request.binary);
    let mut env = cli_environment(&base, &request.config);
    env.extend(request.env.clone());
    let mut command = tokio::process::Command::new(name);
    command
        .args(&request.args)
        .env_clear()
        .envs(&env)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    if let Some(cwd) = &request.cwd {
        command.current_dir(cwd);
    }
    let failed = |why: String| format!("{name} could not be run: {why}");
    let mut child = command.spawn().map_err(|e| failed(e.to_string()))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| failed("no standard input".into()))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| failed("no standard output".into()))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| failed("no standard error".into()))?;
    let input = request.stdin.clone().unwrap_or_default();

    let work = async {
        // The input is written and the end of it said, while the output is read.
        let write = async move {
            let _ = stdin.write_all(input.as_bytes()).await;
            drop(stdin);
        };
        let (_, out, err) = tokio::join!(write, read_capped(stdout), read_capped(stderr));
        let status = child.wait().await.map_err(|e| e.to_string())?;
        Ok::<_, String>((status, out?, err?))
    };
    let (status, out, err) = match tokio::time::timeout(TIMEOUT, work).await {
        Ok(done) => done.map_err(failed)?,
        Err(_) => return Err(failed("it did not finish in time".into())),
    };
    let Some(code) = status.code() else {
        return Err(failed("it was ended by a signal".into()));
    };
    Ok(CliResult {
        code,
        stdout: String::from_utf8_lossy(&out).to_string(),
        stderr: String::from_utf8_lossy(&err).to_string(),
    })
}
