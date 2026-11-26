//! How much of Claude's limits is used, read from the text `claude -p /usage --output-format json`
//! prints. That text is not a promised interface, so a wording that does not match gives
//! `Unavailable`, never a wrong number. The Node host reads it alike in `server/usage-claude.ts`,
//! and both are tested on the same fixtures.

use crate::messages::Harness;
use crate::time::{iso_millis, iso_of, millis};
use crate::usage::{UsageKind, UsageReading, UsageState, UsageWindow};
use jiff::civil::{Date, DateTime};
use jiff::tz::TimeZone;
use jiff::Timestamp;
use regex::Regex;
use serde_json::Value;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::LazyLock;
use std::time::{Duration, SystemTime};
use tokio::io::AsyncReadExt;

static WINDOW_LINE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(.+?): (\d+(?:\.\d+)?)% used · resets (.+) \(([^)]+)\)$").unwrap()
});
static RESET_TEXT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?:([A-Z][a-z]{2}) (\d{1,2}) at )?(\d{1,2})(?::(\d{2}))?(am|pm)$").unwrap()
});
const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/// The windows that count toward the bar item's colour and figure.
const DECIDING: [&str; 2] = ["Current session", "Current week (all models)"];

/// The arguments Claude is run with, and how long a read may take; one takes about 4 seconds. The
/// session is not saved: a read every few minutes would otherwise leave a session in Claude's list
/// each time.
pub const CLAUDE_USAGE_ARGS: [&str; 5] = [
    "-p",
    "/usage",
    "--output-format",
    "json",
    "--no-session-persistence",
];
pub const CLAUDE_USAGE_TIMEOUT: Duration = Duration::from_secs(30);

/// What a program that ran printed, and its exit code.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunOutput {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

pub type Pending<T> = Pin<Box<dyn Future<Output = T> + Send>>;

/// What reading Claude's usage needs from the machine, so that a test can stand in for it.
pub trait ClaudeUsageDeps: Send + Sync {
    /// The program of that name on the host's PATH.
    fn find_program(&self, name: &str) -> Option<PathBuf>;
    /// Runs a program in `cwd`; an error when it cannot be started or takes longer than `timeout`.
    fn run(
        &self,
        program: PathBuf,
        args: Vec<String>,
        cwd: PathBuf,
        timeout: Duration,
    ) -> Pending<Result<RunOutput, String>>;
    fn work_dir(&self) -> Pending<PathBuf>;
    fn now(&self) -> SystemTime;
}

/// Claude's usage, read now. No process is started when `claude` is not on PATH, and the person's
/// Claude settings are neither read nor written: the program itself answers.
pub async fn read_claude_usage(deps: &dyn ClaudeUsageDeps) -> UsageReading {
    let Some(program) = deps.find_program("claude") else {
        return UsageReading {
            state: UsageState::NotInstalled,
            ..unavailable("claude is not on PATH")
        };
    };
    let args = CLAUDE_USAGE_ARGS.iter().map(|a| a.to_string()).collect();
    let cwd = deps.work_dir().await;
    let output = match deps.run(program, args, cwd, CLAUDE_USAGE_TIMEOUT).await {
        Ok(output) => output,
        Err(error) => return unavailable(&format!("claude /usage: {error}")),
    };
    if output.code != 0 {
        let exited = format!("claude /usage exited with code {}", output.code);
        return match output.stderr.lines().map(str::trim).find(|l| !l.is_empty()) {
            Some(said) => unavailable(&format!("{exited}: {said}")),
            None => unavailable(&exited),
        };
    }
    parse_claude_usage(&output.stdout, deps.now())
}

/// Runs a program with nothing on stdin, in `cwd`; an error when it cannot be started or takes
/// longer than `timeout`, and then it is killed.
pub fn run_program(
    program: PathBuf,
    args: Vec<String>,
    cwd: PathBuf,
    timeout: Duration,
) -> Pending<Result<RunOutput, String>> {
    Box::pin(async move {
        let mut child = tokio::process::Command::new(program)
            .args(args)
            .current_dir(cwd)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| e.to_string())?;
        let mut stdout = child.stdout.take().ok_or_else(|| "no stdout".to_string())?;
        let mut stderr = child.stderr.take().ok_or_else(|| "no stderr".to_string())?;
        let work = async {
            let (mut out, mut err) = (Vec::new(), Vec::new());
            let (read_out, read_err) =
                tokio::join!(stdout.read_to_end(&mut out), stderr.read_to_end(&mut err));
            read_out.and(read_err).map_err(|e| e.to_string())?;
            let status = child.wait().await.map_err(|e| e.to_string())?;
            Ok(RunOutput {
                code: status.code().unwrap_or(1),
                stdout: String::from_utf8_lossy(&out).to_string(),
                stderr: String::from_utf8_lossy(&err).to_string(),
            })
        };
        match tokio::time::timeout(timeout, work).await {
            Ok(done) => done,
            Err(_) => Err(format!("timed out after {} seconds", timeout.as_secs())),
        }
    })
}

pub fn parse_claude_usage(json: &str, now: SystemTime) -> UsageReading {
    let Ok(output) = serde_json::from_str::<Value>(json) else {
        return unavailable("claude /usage did not print JSON");
    };
    let Some(result) = output.get("result").and_then(Value::as_str) else {
        return unavailable("claude /usage printed no result");
    };
    let first_line = result.lines().map(str::trim).find(|line| !line.is_empty());
    if output.get("is_error").and_then(Value::as_bool) == Some(true) {
        return unavailable(first_line.unwrap_or("claude /usage reported an error"));
    }

    let windows: Vec<UsageWindow> = result
        .lines()
        .filter_map(|line| WINDOW_LINE.captures(line))
        .filter_map(|found| {
            let name = found[1].to_string();
            let percent = found[2].parse::<f64>().ok()?;
            Some(UsageWindow {
                resets_at: reset_time(&found[3], &found[4], now),
                decides: DECIDING.contains(&name.as_str()),
                name,
                percent,
            })
        })
        .collect();
    if windows.is_empty() {
        return unavailable(first_line.unwrap_or("claude /usage printed no limits"));
    }
    UsageReading {
        harness: Harness::Claude,
        kind: UsageKind::Limit,
        windows,
        spend: None,
        observed_at: Some(iso_of(now)),
        state: UsageState::Ok,
        reason: None,
    }
}

fn unavailable(reason: &str) -> UsageReading {
    UsageReading {
        harness: Harness::Claude,
        kind: UsageKind::Limit,
        windows: Vec::new(),
        spend: None,
        observed_at: None,
        state: UsageState::Unavailable,
        reason: Some(reason.to_string()),
    }
}

/// `Nov 28 at 5:59pm`, `Nov 28 at 5pm` or a bare `5:59pm`, read in the named zone, as an ISO time
/// in UTC. A date takes the nearest year that puts it after `now`; a bare time is today or
/// tomorrow, whichever is the nearer one after `now`. `None` when the text or the zone cannot be
/// read.
pub fn reset_time(text: &str, zone: &str, now: SystemTime) -> Option<String> {
    let found = RESET_TEXT.captures(text)?;
    let hour12: i8 = found[3].parse().ok()?;
    let minute: i8 = match found.get(4) {
        Some(m) => m.as_str().parse().ok()?,
        None => 0,
    };
    if !(1..=12).contains(&hour12) || minute > 59 {
        return None;
    }
    let hour = hour12 % 12 + if &found[5] == "pm" { 12 } else { 0 };

    let tz = TimeZone::get(zone).ok()?;
    let now_ms = millis(now);
    let today = Timestamp::from_millisecond(now_ms)
        .ok()?
        .to_zoned(tz.clone())
        .date();
    let candidates: Vec<Option<Date>> = match found.get(1) {
        None => vec![Some(today), today.tomorrow().ok()],
        Some(month_name) => {
            let month = MONTHS.iter().position(|m| *m == month_name.as_str())? as i8 + 1;
            let day: i8 = found[2].parse().ok()?;
            vec![
                Date::new(today.year(), month, day).ok(),
                Date::new(today.year() + 1, month, day).ok(),
            ]
        }
    };
    candidates.into_iter().flatten().find_map(|date| {
        let at = DateTime::from_parts(date, jiff::civil::time(hour, minute, 0, 0))
            .to_zoned(tz.clone())
            .ok()?
            .timestamp()
            .as_millisecond();
        (at > now_ms).then(|| iso_millis(at))
    })
}
