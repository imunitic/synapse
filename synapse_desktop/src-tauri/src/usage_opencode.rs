//! What Opencode has cost today, read from `opencode stats --days 0 --json`. Only opencode 2.x has
//! `--json` on `stats`, so 1.x gives `unavailable` without running it. The mapper reads only the
//! top-level `cost` of `shared/examples/_usage-opencode.json`, which follows the shape opencode 2.x
//! prints. The Node host reads it alike in `server/usage-opencode.ts`, and both are tested on the
//! same fixture.

use crate::messages::Harness;
use crate::time::iso_of;
use crate::usage::{Spend, SpendPeriod, UsageKind, UsageReading, UsageState};
use crate::usage_claude::{Pending, RunOutput};
use regex::Regex;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::LazyLock;
use std::time::{Duration, SystemTime};

static VERSION: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(\d+)\.\d+\.\d+").unwrap());

pub const OPENCODE_VERSION_ARGS: [&str; 1] = ["--version"];
pub const OPENCODE_STATS_ARGS: [&str; 4] = ["stats", "--days", "0", "--json"];
pub const OPENCODE_USAGE_TIMEOUT: Duration = Duration::from_secs(15);

/// What reading Opencode's spend needs from the machine, so that a test can stand in for it.
pub trait OpencodeUsageDeps: Send + Sync {
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

/// Opencode's spend today, read now. No process is started when `opencode` is not on PATH.
pub async fn read_opencode_usage(deps: &dyn OpencodeUsageDeps) -> UsageReading {
    let Some(program) = deps.find_program("opencode") else {
        return failed(UsageState::NotInstalled, "opencode is not on PATH");
    };
    let cwd = deps.work_dir().await;

    let version = match run(
        deps,
        &program,
        &OPENCODE_VERSION_ARGS,
        &cwd,
        "opencode --version",
    )
    .await
    {
        Ok(stdout) => stdout,
        Err(reading) => return reading,
    };
    match major_version(&version) {
        None => {
            return failed(
                UsageState::Unavailable,
                "opencode --version did not print a version",
            )
        }
        Some(major) if major < 2 => {
            return failed(
                UsageState::Unavailable,
                "opencode 1.x has no stats --json; update to 2.x",
            )
        }
        Some(_) => {}
    }

    match run(deps, &program, &OPENCODE_STATS_ARGS, &cwd, "opencode stats").await {
        Ok(stats) => map_opencode_stats(&stats, deps.now()),
        Err(reading) => reading,
    }
}

/// The output of `opencode stats --json` as today's spend, from its top-level `cost`.
pub fn map_opencode_stats(json: &str, now: SystemTime) -> UsageReading {
    let Ok(stats) = serde_json::from_str::<Value>(json) else {
        return failed(UsageState::Unavailable, "opencode stats did not print JSON");
    };
    match stats.get("cost").and_then(Value::as_f64) {
        Some(cost) if cost.is_finite() && cost >= 0.0 => UsageReading {
            harness: Harness::Opencode,
            kind: UsageKind::Spend,
            windows: Vec::new(),
            spend: Some(Spend {
                amount: cost,
                period: SpendPeriod::Today,
            }),
            observed_at: Some(iso_of(now)),
            state: UsageState::Ok,
            reason: None,
        },
        _ => failed(UsageState::Unavailable, "opencode stats gave no cost"),
    }
}

/// The major number of the first `N.N.N` in the text, or `None` when there is none.
pub fn major_version(text: &str) -> Option<u64> {
    VERSION.captures(text)?.get(1)?.as_str().parse().ok()
}

/// Stdout of one run, or the reading that says why there is none.
async fn run(
    deps: &dyn OpencodeUsageDeps,
    program: &PathBuf,
    args: &[&str],
    cwd: &PathBuf,
    label: &str,
) -> Result<String, UsageReading> {
    let args = args.iter().map(|a| a.to_string()).collect();
    let output = deps
        .run(program.clone(), args, cwd.clone(), OPENCODE_USAGE_TIMEOUT)
        .await
        .map_err(|error| failed(UsageState::Unavailable, &format!("{label}: {error}")))?;
    if output.code != 0 {
        let exited = format!("{label} exited with code {}", output.code);
        let reason = match output.stderr.lines().map(str::trim).find(|l| !l.is_empty()) {
            Some(said) => format!("{exited}: {said}"),
            None => exited,
        };
        return Err(failed(UsageState::Unavailable, &reason));
    }
    Ok(output.stdout)
}

fn failed(state: UsageState, reason: &str) -> UsageReading {
    UsageReading {
        harness: Harness::Opencode,
        kind: UsageKind::Spend,
        windows: Vec::new(),
        spend: None,
        observed_at: None,
        state,
        reason: Some(reason.to_string()),
    }
}
