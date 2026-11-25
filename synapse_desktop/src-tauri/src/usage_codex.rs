//! How much of Codex's rate limits is used, asked of `codex app-server` over its JSON-RPC on stdio:
//! one message per line, without the `"jsonrpc": "2.0"` field the app-server neither sends nor
//! expects. The mapper reads only the fields of `shared/examples/_usage-codex.json`, which follows
//! the app-server's `account/rateLimits/read` response. The Node host reads it alike in
//! `server/usage-codex.ts`, and both are tested on the same fixture.

use crate::messages::Harness;
use crate::time::{iso_millis, iso_of};
use crate::usage::{UsageKind, UsageReading, UsageState, UsageWindow};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::{Duration, SystemTime};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};

pub const CODEX_USAGE_ARGS: [&str; 1] = ["app-server"];
pub const CODEX_USAGE_TIMEOUT: Duration = Duration::from_secs(20);

/// The parts of a started `codex app-server` that a read uses; a test hands in streams of its own.
pub struct CodexChild {
    pub stdin: Box<dyn AsyncWrite + Unpin + Send>,
    pub stdout: Box<dyn AsyncRead + Unpin + Send>,
    pub kill: Box<dyn FnOnce() + Send>,
}

/// What reading Codex's rate limits needs from the machine, so that a test can stand in for it.
pub trait CodexUsageDeps: Send + Sync {
    /// The program of that name on the host's PATH.
    fn find_program(&self, name: &str) -> Option<PathBuf>;
    fn spawn(&self, program: PathBuf, args: Vec<String>) -> Result<CodexChild, String>;
    fn client_version(&self) -> String;
    fn now(&self) -> SystemTime;
}

/// Codex's rate limits, read now. No process is started when `codex` is not on PATH, and the one
/// started is killed once it has answered, failed or taken longer than 20 seconds.
pub async fn read_codex_usage(deps: &dyn CodexUsageDeps) -> UsageReading {
    let Some(program) = deps.find_program("codex") else {
        return failed(UsageState::NotInstalled, "codex is not on PATH");
    };
    let args = CODEX_USAGE_ARGS.iter().map(|a| a.to_string()).collect();
    let child = match deps.spawn(program, args) {
        Ok(child) => child,
        Err(error) => {
            return failed(
                UsageState::Unavailable,
                &format!("codex app-server: {error}"),
            )
        }
    };
    let CodexChild {
        mut stdin,
        stdout,
        kill,
    } = child;
    let talk = converse(&mut stdin, stdout, deps);
    let reading = match tokio::time::timeout(CODEX_USAGE_TIMEOUT, talk).await {
        Ok(reading) => reading,
        Err(_) => failed(
            UsageState::Unavailable,
            &format!(
                "codex app-server: timed out after {} seconds",
                CODEX_USAGE_TIMEOUT.as_secs()
            ),
        ),
    };
    kill();
    reading
}

async fn converse(
    stdin: &mut Box<dyn AsyncWrite + Unpin + Send>,
    stdout: Box<dyn AsyncRead + Unpin + Send>,
    deps: &dyn CodexUsageDeps,
) -> UsageReading {
    let initialize = json!({
        "method": "initialize",
        "id": 1,
        "params": { "clientInfo": { "name": "synapse-desktop", "version": deps.client_version() } },
    });
    if let Err(error) = send(stdin, &initialize).await {
        return failed(
            UsageState::Unavailable,
            &format!("codex app-server: {error}"),
        );
    }
    let mut lines = BufReader::new(stdout).lines();
    loop {
        let line = match lines.next_line().await {
            Ok(Some(line)) => line,
            Ok(None) => {
                return failed(
                    UsageState::Unavailable,
                    "codex app-server: exited before answering",
                )
            }
            Err(error) => {
                return failed(
                    UsageState::Unavailable,
                    &format!("codex app-server: {error}"),
                )
            }
        };
        let Ok(reply) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        let id = reply.get("id").and_then(Value::as_i64);
        if id != Some(1) && id != Some(2) {
            continue;
        }
        if let Some(error) = reply.get("error") {
            let text = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("codex app-server reported an error");
            return codex_error(text);
        }
        if id == Some(1) {
            let rest = [
                json!({ "method": "initialized" }),
                json!({ "method": "account/rateLimits/read", "id": 2 }),
            ];
            for message in &rest {
                if let Err(error) = send(stdin, message).await {
                    return failed(
                        UsageState::Unavailable,
                        &format!("codex app-server: {error}"),
                    );
                }
            }
        } else {
            return map_codex_rate_limits(reply.get("result").unwrap_or(&Value::Null), deps.now());
        }
    }
}

async fn send(
    stdin: &mut Box<dyn AsyncWrite + Unpin + Send>,
    message: &Value,
) -> std::io::Result<()> {
    stdin.write_all(format!("{message}\n").as_bytes()).await?;
    stdin.flush().await
}

/// Starts `codex app-server` with piped stdin and stdout, its stderr ignored.
pub fn spawn_codex(program: PathBuf, args: Vec<String>) -> Result<CodexChild, String> {
    let mut child = tokio::process::Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| e.to_string())?;
    let stdin = child.stdin.take().ok_or_else(|| "no stdin".to_string())?;
    let stdout = child.stdout.take().ok_or_else(|| "no stdout".to_string())?;
    Ok(CodexChild {
        stdin: Box::new(stdin),
        stdout: Box::new(stdout),
        kill: Box::new(move || {
            let _ = child.start_kill();
        }),
    })
}

/// The response to `account/rateLimits/read` as windows: `rateLimits.primary` and
/// `rateLimits.secondary`, each present one named from its duration.
pub fn map_codex_rate_limits(result: &Value, now: SystemTime) -> UsageReading {
    let Some(rate_limits) = result.get("rateLimits").filter(|v| v.is_object()) else {
        return failed(UsageState::Unavailable, "codex gave no rateLimits");
    };
    let mut windows = Vec::new();
    for slot in ["primary", "secondary"] {
        let Some(window) = rate_limits.get(slot).filter(|v| !v.is_null()) else {
            continue;
        };
        let Some(used) = window
            .get("usedPercent")
            .and_then(Value::as_f64)
            .filter(|p| *p >= 0.0)
        else {
            return failed(
                UsageState::Unavailable,
                &format!("codex gave no usedPercent for its {slot} limit"),
            );
        };
        windows.push(UsageWindow {
            name: match window.get("windowDurationMins").and_then(Value::as_f64) {
                Some(minutes) => window_name(minutes),
                None => slot.to_string(),
            },
            percent: used,
            resets_at: window
                .get("resetsAt")
                .and_then(Value::as_f64)
                .map(|seconds| iso_millis((seconds * 1000.0).round() as i64)),
            decides: true,
        });
    }
    if windows.is_empty() {
        return failed(UsageState::Unavailable, "codex gave no rate limit windows");
    }
    UsageReading {
        harness: Harness::Codex,
        kind: UsageKind::Limit,
        windows,
        spend: None,
        observed_at: Some(iso_of(now)),
        state: UsageState::Ok,
        reason: None,
    }
}

/// `5h` for 300 minutes, `weekly` for 10080, whole hours under 48 hours and whole days from there.
pub fn window_name(minutes: f64) -> String {
    if minutes == 300.0 {
        "5h".to_string()
    } else if minutes == 10080.0 {
        "weekly".to_string()
    } else if minutes < 48.0 * 60.0 {
        format!("{}h", (minutes / 60.0).round())
    } else {
        format!("{}d", (minutes / (24.0 * 60.0)).round())
    }
}

/// An error reply: one about logging in or auth means Codex is not signed in.
fn codex_error(text: &str) -> UsageReading {
    let lower = text.to_lowercase();
    if lower.contains("login") || lower.contains("log in") || lower.contains("auth") {
        failed(UsageState::NotSignedIn, text)
    } else {
        failed(UsageState::Unavailable, text)
    }
}

fn failed(state: UsageState, reason: &str) -> UsageReading {
    UsageReading {
        harness: Harness::Codex,
        kind: UsageKind::Limit,
        windows: Vec::new(),
        spend: None,
        observed_at: None,
        state,
        reason: Some(reason.to_string()),
    }
}
