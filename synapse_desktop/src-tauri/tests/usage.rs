//! The usage of the harnesses: the event is read from the same example file as the Node host's and
//! written back as it was, and `usage` is a topic. The text of `claude /usage` is read from the
//! same fixtures, with the same expected readings, as `server/usage-claude.test.ts`, and the
//! rate limits of Codex from the same fixture as `server/usage-codex.test.ts`, and the spend of
//! Opencode from the same fixture as `server/usage-opencode.test.ts`.

mod support;

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use support::{same, usage_event};
use synapse_desktop_host::messages::Harness;
use synapse_desktop_host::protocol::Topic;
use synapse_desktop_host::usage::{
    Provider, Spend, SpendPeriod, Usage, UsageEvent, UsageKind, UsageOptions, UsageReading,
    UsageState, UsageWindow,
};
use synapse_desktop_host::usage_claude::{
    parse_claude_usage, read_claude_usage, reset_time, ClaudeUsageDeps, Pending, RunOutput,
};
use synapse_desktop_host::usage_codex::{
    map_codex_rate_limits, read_codex_usage, window_name, CodexChild, CodexUsageDeps,
};
use synapse_desktop_host::usage_opencode::{
    major_version, map_opencode_stats, read_opencode_usage, OpencodeUsageDeps,
};

#[test]
fn the_usage_event_example_is_read_as_its_type_and_written_back_alike() {
    let example = usage_event();
    let event: UsageEvent = serde_json::from_value(example.clone()).expect("the example is read");
    let written = serde_json::to_value(&event).unwrap();
    assert!(same(&written, &example), "wrote {written} for {example}");
}

#[test]
fn usage_is_a_topic_and_nothing_under_it_is() {
    assert!(Topic::parse("usage").is_some());
    assert!(Topic::parse("usage.x").is_none());
}

fn fixture(name: &str) -> String {
    let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../shared/examples");
    std::fs::read_to_string(dir.join(name)).expect("the fixture is there")
}

/// The point in time of an ISO text in UTC with milliseconds, such as `2026-11-25T16:00:00.000Z`.
fn at(iso: &str) -> SystemTime {
    let ts: jiff::Timestamp = iso.parse().unwrap();
    UNIX_EPOCH + Duration::from_millis(ts.as_millisecond() as u64)
}

fn window(name: &str, percent: f64, resets_at: Option<&str>, decides: bool) -> UsageWindow {
    UsageWindow {
        name: name.to_string(),
        percent,
        resets_at: resets_at.map(str::to_string),
        decides,
    }
}

#[test]
fn every_limit_line_of_the_seen_claude_output_is_a_window() {
    let reading = parse_claude_usage(
        &fixture("_usage-claude.json"),
        at("2026-11-25T16:00:00.000Z"),
    );
    assert_eq!(
        reading,
        UsageReading {
            harness: Harness::Claude,
            kind: UsageKind::Limit,
            windows: vec![
                window(
                    "Current session",
                    13.0,
                    Some("2026-11-25T18:09:00.000Z"),
                    true
                ),
                window(
                    "Current week (all models)",
                    14.0,
                    Some("2026-11-28T16:59:00.000Z"),
                    true
                ),
                window(
                    "Current week (Fable)",
                    0.0,
                    Some("2026-11-28T17:00:00.000Z"),
                    false
                ),
            ],
            spend: None,
            observed_at: Some("2026-11-25T16:00:00.000Z".to_string()),
            state: UsageState::Ok,
            reason: None,
        }
    );
}

#[test]
fn claude_output_with_no_limit_line_is_unavailable_with_its_first_line() {
    let reading = parse_claude_usage(
        &fixture("_usage-claude-nomatch.json"),
        at("2026-11-25T16:00:00.000Z"),
    );
    assert_eq!(reading.state, UsageState::Unavailable);
    assert!(reading.windows.is_empty());
    assert_eq!(reading.observed_at, None);
    assert_eq!(
        reading.reason.as_deref(),
        Some("Usage is only available for subscription plans.")
    );
}

#[test]
fn claude_output_that_is_not_json_or_an_error_is_unavailable() {
    let now = at("2026-11-25T16:00:00.000Z");
    let reading = parse_claude_usage("not json", now);
    assert_eq!(reading.state, UsageState::Unavailable);
    assert_eq!(
        reading.reason.as_deref(),
        Some("claude /usage did not print JSON")
    );
    let reading = parse_claude_usage(r#"{"is_error":true,"result":"\nNot logged in\n"}"#, now);
    assert_eq!(reading.state, UsageState::Unavailable);
    assert_eq!(reading.reason.as_deref(), Some("Not logged in"));
}

#[test]
fn a_claude_window_whose_reset_cannot_be_read_is_kept_without_one() {
    let json = r#"{"result":"Current session: 5% used · resets soon (Europe/Zagreb)"}"#;
    let reading = parse_claude_usage(json, at("2026-11-25T16:00:00.000Z"));
    assert_eq!(reading.state, UsageState::Ok);
    assert_eq!(
        reading.windows,
        vec![window("Current session", 5.0, None, true)]
    );
}

#[test]
fn a_reset_date_already_past_this_year_is_next_year() {
    assert_eq!(
        reset_time(
            "Jan 2 at 9:00am",
            "Europe/Zagreb",
            at("2026-12-30T00:00:00.000Z")
        )
        .as_deref(),
        Some("2027-01-02T08:00:00.000Z")
    );
}

#[test]
fn a_reset_date_still_ahead_is_this_year() {
    assert_eq!(
        reset_time(
            "Nov 25 at 7:09pm",
            "Europe/Zagreb",
            at("2026-11-25T10:00:00.000Z")
        )
        .as_deref(),
        Some("2026-11-25T18:09:00.000Z")
    );
}

#[test]
fn a_bare_reset_time_is_today_or_tomorrow_whichever_is_ahead() {
    let now = at("2026-11-25T10:00:00.000Z");
    assert_eq!(
        reset_time("5:59pm", "Europe/Zagreb", now).as_deref(),
        Some("2026-11-25T16:59:00.000Z")
    );
    assert_eq!(
        reset_time("9am", "Europe/Zagreb", now).as_deref(),
        Some("2026-11-26T08:00:00.000Z")
    );
}

#[test]
fn an_unknown_zone_or_unreadable_reset_gives_nothing() {
    let now = at("2026-11-25T10:00:00.000Z");
    assert_eq!(reset_time("Nov 28 at 5pm", "Nowhere/City", now), None);
    assert_eq!(reset_time("in 3 hours", "Europe/Zagreb", now), None);
}

type Answer = Box<dyn Fn() -> Result<RunOutput, String> + Send + Sync>;

/// The machine as a test has it: `claude` where it says, and a runner that keeps its calls.
struct FakeMachine {
    program: Option<PathBuf>,
    answer: Answer,
    calls: Mutex<Vec<(PathBuf, Vec<String>, PathBuf, Duration)>>,
}

impl FakeMachine {
    fn new(
        program: Option<&str>,
        answer: impl Fn() -> Result<RunOutput, String> + Send + Sync + 'static,
    ) -> Self {
        FakeMachine {
            program: program.map(PathBuf::from),
            answer: Box::new(answer),
            calls: Mutex::new(Vec::new()),
        }
    }
}

impl ClaudeUsageDeps for FakeMachine {
    fn find_program(&self, _name: &str) -> Option<PathBuf> {
        self.program.clone()
    }
    fn run(
        &self,
        program: PathBuf,
        args: Vec<String>,
        cwd: PathBuf,
        timeout: Duration,
    ) -> Pending<Result<RunOutput, String>> {
        self.calls
            .lock()
            .unwrap()
            .push((program, args, cwd, timeout));
        let answer = (self.answer)();
        Box::pin(async move { answer })
    }
    fn work_dir(&self) -> Pending<PathBuf> {
        Box::pin(async { PathBuf::from("/work") })
    }
    fn now(&self) -> SystemTime {
        at("2026-11-25T16:00:00.000Z")
    }
}

fn printed(stdout: String) -> Result<RunOutput, String> {
    Ok(RunOutput {
        code: 0,
        stdout,
        stderr: String::new(),
    })
}

#[tokio::test]
async fn reading_claude_starts_nothing_when_it_is_not_on_path() {
    let machine = FakeMachine::new(None, || printed(fixture("_usage-claude.json")));
    let reading = read_claude_usage(&machine).await;
    assert_eq!(
        reading,
        UsageReading {
            harness: Harness::Claude,
            kind: UsageKind::Limit,
            windows: vec![],
            spend: None,
            observed_at: None,
            state: UsageState::NotInstalled,
            reason: Some("claude is not on PATH".to_string()),
        }
    );
    assert!(machine.calls.lock().unwrap().is_empty());
}

#[tokio::test]
async fn reading_claude_runs_it_in_the_work_dir_and_reads_what_it_prints() {
    let machine = FakeMachine::new(Some("/bin/claude"), || {
        printed(fixture("_usage-claude.json"))
    });
    let reading = read_claude_usage(&machine).await;
    assert_eq!(
        *machine.calls.lock().unwrap(),
        vec![(
            PathBuf::from("/bin/claude"),
            vec![
                "-p".to_string(),
                "/usage".into(),
                "--output-format".into(),
                "json".into()
            ],
            PathBuf::from("/work"),
            Duration::from_secs(30),
        )]
    );
    assert_eq!(
        reading,
        parse_claude_usage(
            &fixture("_usage-claude.json"),
            at("2026-11-25T16:00:00.000Z")
        )
    );
}

#[tokio::test]
async fn reading_claude_gives_unavailable_for_a_timeout() {
    let machine = FakeMachine::new(Some("/bin/claude"), || {
        Err("timed out after 30 seconds".to_string())
    });
    let reading = read_claude_usage(&machine).await;
    assert_eq!(reading.state, UsageState::Unavailable);
    assert!(reading.windows.is_empty());
    assert_eq!(
        reading.reason.as_deref(),
        Some("claude /usage: timed out after 30 seconds")
    );
}

#[tokio::test]
async fn reading_claude_gives_unavailable_for_a_non_zero_exit_with_what_it_said() {
    let machine = FakeMachine::new(Some("/bin/claude"), || {
        Ok(RunOutput {
            code: 2,
            stdout: String::new(),
            stderr: "\nboom\n".to_string(),
        })
    });
    let reading = read_claude_usage(&machine).await;
    assert_eq!(reading.state, UsageState::Unavailable);
    assert_eq!(
        reading.reason.as_deref(),
        Some("claude /usage exited with code 2: boom")
    );
}

fn codex_fixture() -> serde_json::Value {
    serde_json::from_str(&fixture("_usage-codex.json")).unwrap()
}

#[test]
fn the_codex_fixture_maps_to_a_5h_and_a_weekly_window() {
    let reading = map_codex_rate_limits(&codex_fixture(), at("2026-11-25T16:00:00.000Z"));
    assert_eq!(
        reading,
        UsageReading {
            harness: Harness::Codex,
            kind: UsageKind::Limit,
            windows: vec![
                window("5h", 42.0, Some("2026-11-25T18:40:00.000Z"), true),
                window("weekly", 17.0, Some("2026-11-29T11:00:00.000Z"), true),
            ],
            spend: None,
            observed_at: Some("2026-11-25T16:00:00.000Z".to_string()),
            state: UsageState::Ok,
            reason: None,
        }
    );
}

#[test]
fn other_codex_durations_are_whole_hours_under_48_hours_and_whole_days_above() {
    let names: Vec<String> = [60.0, 300.0, 1440.0, 2880.0, 10080.0, 43200.0]
        .into_iter()
        .map(window_name)
        .collect();
    assert_eq!(names, ["1h", "5h", "24h", "2d", "weekly", "30d"]);
}

#[test]
fn codex_rate_limits_without_rate_limits_or_a_used_percent_are_unavailable() {
    let now = at("2026-11-25T16:00:00.000Z");
    let reading = map_codex_rate_limits(&serde_json::json!({}), now);
    assert_eq!(reading.state, UsageState::Unavailable);
    assert_eq!(reading.reason.as_deref(), Some("codex gave no rateLimits"));
    let reading = map_codex_rate_limits(
        &serde_json::json!({ "rateLimits": { "primary": { "windowDurationMins": 300 } } }),
        now,
    );
    assert_eq!(reading.state, UsageState::Unavailable);
    assert_eq!(
        reading.reason.as_deref(),
        Some("codex gave no usedPercent for its primary limit")
    );
}

/// A machine with `codex` (or without it) whose one `codex app-server` is the test's streams.
struct FakeCodex {
    child: Mutex<Option<CodexChild>>,
    spawned: Mutex<Vec<(PathBuf, Vec<String>)>>,
    on_path: bool,
}

impl CodexUsageDeps for FakeCodex {
    fn find_program(&self, _name: &str) -> Option<PathBuf> {
        self.on_path.then(|| PathBuf::from("/bin/codex"))
    }
    fn spawn(&self, program: PathBuf, args: Vec<String>) -> Result<CodexChild, String> {
        self.spawned.lock().unwrap().push((program, args));
        self.child
            .lock()
            .unwrap()
            .take()
            .ok_or_else(|| "no child".to_string())
    }
    fn client_version(&self) -> String {
        "1.2.3".to_string()
    }
    fn now(&self) -> SystemTime {
        at("2026-11-25T16:00:00.000Z")
    }
}

/// The test's ends of a fake `codex app-server`: what the reader wrote, and its stdout to answer on.
struct CodexEnds {
    written: tokio::io::Lines<tokio::io::BufReader<tokio::io::DuplexStream>>,
    stdout: tokio::io::DuplexStream,
    kills: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}

impl CodexEnds {
    async fn read(&mut self) -> serde_json::Value {
        let line = self.written.next_line().await.unwrap().expect("a line");
        serde_json::from_str(&line).unwrap()
    }
    async fn reply(&mut self, value: serde_json::Value) {
        use tokio::io::AsyncWriteExt;
        self.stdout
            .write_all(format!("{value}\n").as_bytes())
            .await
            .unwrap();
    }
    fn kills(&self) -> usize {
        self.kills.load(std::sync::atomic::Ordering::SeqCst)
    }
}

fn fake_codex() -> (FakeCodex, CodexEnds) {
    use tokio::io::AsyncBufReadExt;
    let (stdin, stdin_end) = tokio::io::duplex(64 * 1024);
    let (stdout_end, stdout) = tokio::io::duplex(64 * 1024);
    let kills = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = kills.clone();
    let child = CodexChild {
        stdin: Box::new(stdin),
        stdout: Box::new(stdout),
        kill: Box::new(move || {
            counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }),
    };
    let machine = FakeCodex {
        child: Mutex::new(Some(child)),
        spawned: Mutex::new(Vec::new()),
        on_path: true,
    };
    let ends = CodexEnds {
        written: tokio::io::BufReader::new(stdin_end).lines(),
        stdout: stdout_end,
        kills,
    };
    (machine, ends)
}

#[tokio::test]
async fn reading_codex_starts_nothing_when_it_is_not_on_path() {
    let machine = FakeCodex {
        child: Mutex::new(None),
        spawned: Mutex::new(Vec::new()),
        on_path: false,
    };
    let reading = read_codex_usage(&machine).await;
    assert_eq!(
        reading,
        UsageReading {
            harness: Harness::Codex,
            kind: UsageKind::Limit,
            windows: vec![],
            spend: None,
            observed_at: None,
            state: UsageState::NotInstalled,
            reason: Some("codex is not on PATH".to_string()),
        }
    );
    assert!(machine.spawned.lock().unwrap().is_empty());
}

#[tokio::test]
async fn reading_codex_writes_three_messages_in_order_and_kills_it_after_the_id_2_reply() {
    let (machine, mut ends) = fake_codex();
    let script = async {
        let initialize = ends.read().await;
        ends.reply(serde_json::json!({ "id": 1, "result": { "userAgent": "codex/0.165.0" } }))
            .await;
        let initialized = ends.read().await;
        let read = ends.read().await;
        assert_eq!(ends.kills(), 0);
        ends.reply(serde_json::json!({ "method": "account/rateLimits/updated", "params": {} }))
            .await;
        ends.reply(serde_json::json!({ "id": 2, "result": codex_fixture() }))
            .await;
        vec![initialize, initialized, read]
    };
    let (reading, written) = tokio::join!(read_codex_usage(&machine), script);
    assert_eq!(
        *machine.spawned.lock().unwrap(),
        vec![(PathBuf::from("/bin/codex"), vec!["app-server".to_string()])]
    );
    assert_eq!(
        written,
        vec![
            serde_json::json!({
                "method": "initialize",
                "id": 1,
                "params": { "clientInfo": { "name": "synapse-desktop", "version": "1.2.3" } },
            }),
            serde_json::json!({ "method": "initialized" }),
            serde_json::json!({ "method": "account/rateLimits/read", "id": 2 }),
        ]
    );
    assert_eq!(
        reading,
        map_codex_rate_limits(&codex_fixture(), at("2026-11-25T16:00:00.000Z"))
    );
    assert_eq!(ends.kills(), 1);
}

#[tokio::test]
async fn reading_codex_maps_an_auth_error_to_not_signed_in() {
    let (machine, mut ends) = fake_codex();
    let script = async {
        ends.read().await;
        ends.reply(serde_json::json!({ "id": 1, "result": {} }))
            .await;
        ends.read().await;
        ends.read().await;
        ends.reply(serde_json::json!({
            "id": 2,
            "error": { "code": -32600, "message": "codex account authentication required" },
        }))
        .await;
    };
    let (reading, ()) = tokio::join!(read_codex_usage(&machine), script);
    assert_eq!(reading.state, UsageState::NotSignedIn);
    assert_eq!(
        reading.reason.as_deref(),
        Some("codex account authentication required")
    );
    assert_eq!(ends.kills(), 1);
}

#[tokio::test]
async fn reading_codex_maps_any_other_error_to_unavailable() {
    let (machine, mut ends) = fake_codex();
    let script = async {
        ends.read().await;
        ends.reply(serde_json::json!({
            "id": 1,
            "error": { "code": -32603, "message": "internal error" },
        }))
        .await;
    };
    let (reading, ()) = tokio::join!(read_codex_usage(&machine), script);
    assert_eq!(reading.state, UsageState::Unavailable);
    assert_eq!(reading.reason.as_deref(), Some("internal error"));
}

#[tokio::test]
async fn reading_codex_is_unavailable_when_it_ends_before_answering() {
    let (machine, ends) = fake_codex();
    drop(ends.stdout);
    let reading = read_codex_usage(&machine).await;
    assert_eq!(reading.state, UsageState::Unavailable);
    assert_eq!(
        reading.reason.as_deref(),
        Some("codex app-server: exited before answering")
    );
}

#[test]
fn the_opencode_fixture_maps_to_its_cost_as_spend_today() {
    let reading = map_opencode_stats(
        &fixture("_usage-opencode.json"),
        at("2026-11-25T16:00:00.000Z"),
    );
    assert_eq!(
        reading,
        UsageReading {
            harness: Harness::Opencode,
            kind: UsageKind::Spend,
            windows: vec![],
            spend: Some(Spend {
                amount: 1.42,
                period: SpendPeriod::Today,
            }),
            observed_at: Some("2026-11-25T16:00:00.000Z".to_string()),
            state: UsageState::Ok,
            reason: None,
        }
    );
}

#[test]
fn opencode_stats_without_the_cost_field_or_without_json_are_unavailable() {
    let mut stats: serde_json::Value =
        serde_json::from_str(&fixture("_usage-opencode.json")).unwrap();
    stats.as_object_mut().unwrap().remove("cost");
    let now = at("2026-11-25T16:00:00.000Z");
    let reading = map_opencode_stats(&stats.to_string(), now);
    assert_eq!(reading.state, UsageState::Unavailable);
    assert_eq!(reading.spend, None);
    assert_eq!(reading.observed_at, None);
    assert_eq!(
        reading.reason.as_deref(),
        Some("opencode stats gave no cost")
    );
    assert_eq!(
        map_opencode_stats("not json", now).reason.as_deref(),
        Some("opencode stats did not print JSON")
    );
}

#[test]
fn the_major_opencode_version_is_read_from_what_it_prints() {
    assert_eq!(major_version("2.0.0\n"), Some(2));
    assert_eq!(major_version("opencode 1.4.2"), Some(1));
    assert_eq!(major_version("dev"), None);
}

/// The machine as a test has it: `opencode` where it says, answering `--version` with `version`
/// and `stats` with `stats`, keeping every call.
struct FakeOpencode {
    program: Option<PathBuf>,
    version: String,
    stats: RunOutput,
    calls: Mutex<Vec<(PathBuf, Vec<String>, PathBuf, Duration)>>,
}

impl FakeOpencode {
    fn new(program: Option<&str>, version: &str, stats: RunOutput) -> Self {
        FakeOpencode {
            program: program.map(PathBuf::from),
            version: version.to_string(),
            stats,
            calls: Mutex::new(Vec::new()),
        }
    }
    fn args(&self) -> Vec<Vec<String>> {
        self.calls
            .lock()
            .unwrap()
            .iter()
            .map(|c| c.1.clone())
            .collect()
    }
}

impl OpencodeUsageDeps for FakeOpencode {
    fn find_program(&self, _name: &str) -> Option<PathBuf> {
        self.program.clone()
    }
    fn run(
        &self,
        program: PathBuf,
        args: Vec<String>,
        cwd: PathBuf,
        timeout: Duration,
    ) -> Pending<Result<RunOutput, String>> {
        let answer = if args.first().map(String::as_str) == Some("--version") {
            RunOutput {
                code: 0,
                stdout: self.version.clone(),
                stderr: String::new(),
            }
        } else {
            self.stats.clone()
        };
        self.calls
            .lock()
            .unwrap()
            .push((program, args, cwd, timeout));
        Box::pin(async move { Ok(answer) })
    }
    fn work_dir(&self) -> Pending<PathBuf> {
        Box::pin(async { PathBuf::from("/work") })
    }
    fn now(&self) -> SystemTime {
        at("2026-11-25T16:00:00.000Z")
    }
}

fn opencode_stats() -> RunOutput {
    RunOutput {
        code: 0,
        stdout: fixture("_usage-opencode.json"),
        stderr: String::new(),
    }
}

#[tokio::test]
async fn reading_opencode_starts_nothing_when_it_is_not_on_path() {
    let machine = FakeOpencode::new(None, "2.0.0", opencode_stats());
    let reading = read_opencode_usage(&machine).await;
    assert_eq!(reading.harness, Harness::Opencode);
    assert_eq!(reading.state, UsageState::NotInstalled);
    assert_eq!(reading.reason.as_deref(), Some("opencode is not on PATH"));
    assert!(machine.calls.lock().unwrap().is_empty());
}

#[tokio::test]
async fn reading_opencode_2_runs_stats_for_today_as_json_and_reads_its_cost() {
    let machine = FakeOpencode::new(Some("/bin/opencode"), "2.0.0\n", opencode_stats());
    let reading = read_opencode_usage(&machine).await;
    assert_eq!(
        reading,
        map_opencode_stats(
            &fixture("_usage-opencode.json"),
            at("2026-11-25T16:00:00.000Z")
        )
    );
    let call = |args: &[&str]| {
        (
            PathBuf::from("/bin/opencode"),
            args.iter().map(|a| a.to_string()).collect::<Vec<_>>(),
            PathBuf::from("/work"),
            Duration::from_secs(15),
        )
    };
    assert_eq!(
        *machine.calls.lock().unwrap(),
        vec![
            call(&["--version"]),
            call(&["stats", "--days", "0", "--json"])
        ]
    );
}

#[tokio::test]
async fn reading_opencode_1_is_unavailable_without_running_stats() {
    let machine = FakeOpencode::new(Some("/bin/opencode"), "1.4.2\n", opencode_stats());
    let reading = read_opencode_usage(&machine).await;
    assert_eq!(reading.state, UsageState::Unavailable);
    assert_eq!(
        reading.reason.as_deref(),
        Some("opencode 1.x has no stats --json; update to 2.x")
    );
    assert_eq!(machine.args(), vec![vec!["--version".to_string()]]);
}

#[tokio::test]
async fn reading_opencode_is_unavailable_when_stats_fails() {
    let failing = RunOutput {
        code: 1,
        stdout: String::new(),
        stderr: "\nboom\n".to_string(),
    };
    let machine = FakeOpencode::new(Some("/bin/opencode"), "2.1.2", failing);
    let reading = read_opencode_usage(&machine).await;
    assert_eq!(reading.state, UsageState::Unavailable);
    assert_eq!(
        reading.reason.as_deref(),
        Some("opencode stats exited with code 1: boom")
    );
}

// ---- Polling, with fake providers and short intervals, the same cases as server/usage.test.ts ----

fn claude_ok(percent: f64) -> UsageReading {
    UsageReading {
        harness: Harness::Claude,
        kind: UsageKind::Limit,
        windows: vec![UsageWindow {
            name: "Current session".into(),
            percent,
            resets_at: None,
            decides: true,
        }],
        spend: None,
        observed_at: Some("2026-11-25T10:00:00.000Z".into()),
        state: UsageState::Ok,
        reason: None,
    }
}

fn claude_failed(state: UsageState, reason: &str) -> UsageReading {
    UsageReading {
        harness: Harness::Claude,
        kind: UsageKind::Limit,
        windows: vec![],
        spend: None,
        observed_at: None,
        state,
        reason: Some(reason.into()),
    }
}

/// A provider that counts its reads and answers from `answers`, the last one again once they run
/// out.
fn counted(answers: Vec<UsageReading>, delay: Duration) -> (Provider, Arc<AtomicUsize>) {
    let reads = Arc::new(AtomicUsize::new(0));
    let counter = reads.clone();
    let provider: Provider = Arc::new(move || {
        let n = counter.fetch_add(1, Ordering::SeqCst);
        let answer = answers[n.min(answers.len() - 1)].clone();
        Box::pin(async move {
            if !delay.is_zero() {
                tokio::time::sleep(delay).await;
            }
            answer
        })
    });
    (provider, reads)
}

fn options(providers: Vec<Provider>, interval_ms: u64, quiet_ms: u64) -> UsageOptions {
    UsageOptions {
        providers,
        interval: Duration::from_millis(interval_ms),
        nudge_quiet: Duration::from_millis(quiet_ms),
    }
}

type Events = Arc<Mutex<Vec<UsageEvent>>>;

fn watch(usage: &Usage) -> (Events, Box<dyn FnOnce() + Send>) {
    let seen: Events = Arc::new(Mutex::new(vec![]));
    let kept = seen.clone();
    let stop = usage.subscribe(Arc::new(move |event| kept.lock().unwrap().push(event)));
    (seen, stop)
}

async fn pause(ms: u64) {
    tokio::time::sleep(Duration::from_millis(ms)).await;
}

async fn until(done: impl Fn() -> bool) {
    for _ in 0..400 {
        if done() {
            return;
        }
        pause(5).await;
    }
    panic!("timed out");
}

#[tokio::test]
async fn usage_reads_nothing_while_no_client_is_subscribed() {
    let (provider, reads) = counted(vec![claude_ok(10.0)], Duration::ZERO);
    let _usage = Usage::new(options(vec![provider], 20, 30_000));
    pause(80).await;
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn usage_gives_a_subscriber_an_event_at_once_and_a_later_one_the_last_event() {
    let (provider, reads) = counted(vec![claude_ok(10.0)], Duration::ZERO);
    let usage = Usage::new(options(vec![provider], 10_000, 30_000));
    let (first, stop_first) = watch(&usage);
    until(|| first.lock().unwrap().len() == 1).await;
    assert_eq!(
        first.lock().unwrap()[0],
        UsageEvent {
            readings: vec![claude_ok(10.0)]
        }
    );
    let (second, stop_second) = watch(&usage);
    assert_eq!(second.lock().unwrap().len(), 1);
    assert_eq!(reads.load(Ordering::SeqCst), 1);
    stop_first();
    stop_second();
}

#[tokio::test]
async fn usage_reads_all_providers_in_parallel_in_their_order() {
    let (slow, _) = counted(vec![claude_ok(10.0)], Duration::from_millis(40));
    let (quick, _) = counted(
        vec![claude_failed(UsageState::NotInstalled, "codex is not on PATH")],
        Duration::ZERO,
    );
    let usage = Usage::new(options(vec![slow, quick], 10_000, 30_000));
    let (seen, stop) = watch(&usage);
    until(|| seen.lock().unwrap().len() == 1).await;
    let states: Vec<UsageState> = seen.lock().unwrap()[0]
        .readings
        .iter()
        .map(|r| r.state)
        .collect();
    assert_eq!(states, vec![UsageState::Ok, UsageState::NotInstalled]);
    stop();
}

#[tokio::test]
async fn usage_reads_again_at_the_interval() {
    let (provider, _) = counted(
        vec![claude_ok(10.0), claude_ok(20.0), claude_ok(30.0)],
        Duration::ZERO,
    );
    let usage = Usage::new(options(vec![provider], 30, 30_000));
    let (seen, stop) = watch(&usage);
    until(|| seen.lock().unwrap().len() >= 3).await;
    assert_eq!(seen.lock().unwrap()[2].readings[0].windows[0].percent, 30.0);
    stop();
}

#[tokio::test]
async fn usage_stops_reading_when_the_last_client_unsubscribes() {
    let (provider, reads) = counted(vec![claude_ok(10.0)], Duration::ZERO);
    let usage = Usage::new(options(vec![provider], 20, 30_000));
    let (_, stop) = watch(&usage);
    until(|| reads.load(Ordering::SeqCst) >= 2).await;
    stop();
    pause(30).await;
    let after = reads.load(Ordering::SeqCst);
    pause(80).await;
    assert_eq!(reads.load(Ordering::SeqCst), after);
}

#[tokio::test]
async fn usage_keeps_the_old_figures_as_stale_when_an_ok_provider_later_fails() {
    let (provider, _) = counted(
        vec![
            claude_ok(29.0),
            claude_failed(UsageState::Unavailable, "claude /usage: timed out"),
        ],
        Duration::ZERO,
    );
    let usage = Usage::new(options(vec![provider], 30, 30_000));
    let (seen, stop) = watch(&usage);
    until(|| seen.lock().unwrap().len() >= 2).await;
    assert_eq!(
        seen.lock().unwrap()[1].readings[0],
        UsageReading {
            state: UsageState::Stale,
            reason: Some("claude /usage: timed out".into()),
            ..claude_ok(29.0)
        }
    );
    stop();
}

#[tokio::test]
async fn usage_drops_the_old_figures_after_a_sign_out_so_a_later_failure_has_none() {
    let (provider, _) = counted(
        vec![
            claude_ok(29.0),
            claude_failed(UsageState::NotSignedIn, "not signed in"),
            claude_failed(UsageState::Unavailable, "claude /usage: timed out"),
        ],
        Duration::ZERO,
    );
    let usage = Usage::new(options(vec![provider], 30, 30_000));
    let (seen, stop) = watch(&usage);
    until(|| seen.lock().unwrap().len() >= 3).await;
    assert_eq!(
        seen.lock().unwrap()[2].readings[0],
        claude_failed(UsageState::Unavailable, "claude /usage: timed out")
    );
    stop();
}

#[tokio::test]
async fn usage_starts_one_read_for_two_nudges_10_ms_apart() {
    let (provider, reads) = counted(vec![claude_ok(10.0)], Duration::from_millis(30));
    let usage = Usage::new(options(vec![provider], 10_000, 0));
    let (seen, stop) = watch(&usage);
    until(|| seen.lock().unwrap().len() == 1).await;
    usage.nudge();
    pause(10).await;
    usage.nudge();
    until(|| seen.lock().unwrap().len() == 2).await;
    pause(60).await;
    assert_eq!(reads.load(Ordering::SeqCst), 2);
    stop();
}

#[tokio::test]
async fn usage_does_not_read_on_a_nudge_within_the_quiet_time_after_a_read() {
    let (provider, reads) = counted(vec![claude_ok(10.0)], Duration::ZERO);
    let usage = Usage::new(options(vec![provider], 10_000, 10_000));
    let (seen, stop) = watch(&usage);
    until(|| seen.lock().unwrap().len() == 1).await;
    usage.nudge();
    pause(30).await;
    assert_eq!(reads.load(Ordering::SeqCst), 1);
    stop();
}
