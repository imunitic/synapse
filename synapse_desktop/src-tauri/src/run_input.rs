//! Having an agent write the input of a run from a description. The agent reads the pipeline's
//! declaration, may look up notes in the vault to turn a description of one into its name, and
//! answers with one JSON object. It writes nothing and never starts the run: the JSON goes into the
//! run dialog's editor, where the person starts the run. The same wording and rules as the Node
//! host's `run-input.ts`.

use crate::agents::{reason_of, Access, NoteSessionRun};
use crate::cli::{cli_environment, CliRun};
use crate::dispatch::HostError;
use crate::efforts::{choice_of, RunChoice};
use crate::families::Context;
use crate::messages::{AgentRunParams, AppConfig, CliBinary, CliResult, Harness};
use regex::Regex;
use serde_json::Value;
use tokio::sync::oneshot;

/// How the agent may reach the vault: only through the commands that read and search it.
const VAULT_RULE: &str = "To turn a description of a note into its name, use only `synapse vault-search-text <words>`, `synapse vault-list` and `synapse vault-read <path>`. Write nothing.";

/// Claude Code and OpenCode run a command only when the whole of it is allowed, so the session is
/// told how to run them. Codex runs in its read-only sandbox.
const READ_COMMAND_RULES: &str = "Only these three commands work in this session. Run one command in each Bash call: do not chain commands with ;, && or ||, do not pipe them, and do not use cd or echo.";

const CLOSING: &str =
    "Answer with one JSON object that satisfies the declaration, and nothing else: no prose, no code fence.";

/// The empty value of a field: what the run dialog's sample starts each field with.
fn is_empty_value(value: &Value) -> bool {
    match value {
        Value::String(s) => s.is_empty(),
        Value::Number(n) => n.as_f64() == Some(0.0),
        Value::Bool(b) => !b,
        Value::Null => true,
        Value::Array(items) => items.is_empty(),
        Value::Object(_) => false,
    }
}

/// Whether the JSON in the editor says something the agent should keep: not when it is missing,
/// `{}`, the sample with every field empty, or not an object at all.
fn says_something(current: Option<&str>) -> Option<&str> {
    let current = current?;
    match serde_json::from_str::<Value>(current) {
        Ok(Value::Object(fields)) => (!fields.values().all(is_empty_value)).then_some(current),
        Ok(_) => None,
        // Text that is not JSON yet is still what the person typed.
        Err(_) => (!current.trim().is_empty()).then_some(current),
    }
}

/// The prompt of a session that fills in the input of `pipeline`. `problems` are the ones the program
/// found in an earlier answer, given in the session that corrects it.
pub fn run_input_prompt(
    pipeline: &str,
    declaration: &Value,
    description: &str,
    current: Option<&str>,
    harness: Harness,
    problems: &[String],
) -> String {
    let mut lines = vec![
        format!("Fill in the input of the pipeline {pipeline} from the description below. Nobody can answer questions in this session, so decide what you would otherwise ask and carry on."),
        String::new(),
        "The pipeline declares its input as follows:".to_string(),
        serde_json::to_string_pretty(declaration).unwrap_or_default(),
        String::new(),
    ];
    if let Some(current) = says_something(current) {
        lines.push("The input holds this JSON now: add to this; keep what the description does not change.".into());
        lines.push(current.trim().to_string());
        lines.push(String::new());
    }
    lines.push(VAULT_RULE.into());
    lines.push(String::new());
    if harness != Harness::Codex {
        lines.push(READ_COMMAND_RULES.into());
        lines.push(String::new());
    }
    lines.push("Description:".into());
    lines.push(description.trim().to_string());
    lines.push(String::new());
    if !problems.is_empty() {
        lines.push("These problems were found in your answer:".into());
        lines.extend(problems.iter().cloned());
        lines.push(String::new());
    }
    lines.push(CLOSING.into());
    lines.join("\n")
}

/// The text of the JSON object in an answer, pretty-printed with a two-space indent: the answer
/// without one surrounding code fence, from its first `{` to its last `}`. Nothing when that is not a
/// JSON object, or when the answer is a list.
pub fn json_answer(answer: &str) -> Option<String> {
    let mut text = answer.trim();
    let fence = Regex::new(r"(?s)^```[^\n]*\n(.*?)\n?```$").expect("the fence pattern is valid");
    if let Some(inner) = fence.captures(text).and_then(|c| c.get(1)) {
        text = inner.as_str().trim();
    }
    // A list of objects is not one object, though its first `{` and last `}` may make one.
    if text.starts_with('[') {
        return None;
    }
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    if end < start {
        return None;
    }
    match serde_json::from_str::<Value>(&text[start..=end]) {
        Ok(object @ Value::Object(_)) => serde_json::to_string_pretty(&object).ok(),
        _ => None,
    }
}

/// The declared input of a pipeline, from `synapse-pipeline show <pipeline> --format json`; nothing
/// when the pipeline declares none.
async fn declaration_of(
    context: &Context,
    config: &AppConfig,
    pipeline: &str,
) -> Result<Option<Value>, HostError> {
    let shown = context
        .cli
        .run(CliRun::new(
            CliBinary::SynapsePipeline,
            &["show", pipeline, "--format", "json"],
            config.clone(),
        ))
        .await
        .map_err(HostError::unavailable)?;
    if shown.code != 0 {
        let stderr = shown.stderr.trim();
        let why = if stderr.is_empty() {
            format!("{pipeline} could not be read")
        } else {
            stderr.to_string()
        };
        return Err(if why.contains("there is no pipeline named") {
            HostError::not_found(why)
        } else {
            HostError::unavailable(why)
        });
    }
    let parsed: Value = serde_json::from_str(&shown.stdout).map_err(|_| {
        HostError::unavailable(format!("the description of {pipeline} is not JSON"))
    })?;
    Ok(match parsed.get("input") {
        None | Some(Value::Null) => None,
        Some(input) => Some(input.clone()),
    })
}

/// Two stop signals that both fire when `stop` does: one for each session a fill may run.
fn split_stop(
    stop: Option<oneshot::Receiver<()>>,
) -> (Option<oneshot::Receiver<()>>, Option<oneshot::Receiver<()>>) {
    let Some(stop) = stop else {
        return (None, None);
    };
    let (first, first_stop) = oneshot::channel();
    let (second, second_stop) = oneshot::channel();
    tokio::spawn(async move {
        if stop.await.is_ok() {
            let _ = first.send(());
            let _ = second.send(());
        }
    });
    (Some(first_stop), Some(second_stop))
}

/// The JSON an agent wrote for the input of a run, from a description of the run: checked by the
/// program, with one more session to correct it when the program found problems. Never run. The
/// sessions only read: they reach the vault through the synapse CLI, which finds it itself, so no
/// vault is looked up and no folder is writable.
pub async fn fill_run_input(
    context: &Context,
    config: &AppConfig,
    request: &AgentRunParams,
    stop: Option<oneshot::Receiver<()>>,
    stopped: impl Fn() -> bool,
) -> Result<String, HostError> {
    let AgentRunParams::RunInput {
        pipeline,
        prompt: description,
        harness,
        model,
        effort,
        current,
        ..
    } = request
    else {
        return Err(HostError::bad_request("not the input of a run"));
    };
    let RunChoice {
        harness,
        model,
        effort,
    } = choice_of(*harness, model.as_ref(), effort.as_ref(), config)?;
    let declaration = declaration_of(context, config, pipeline)
        .await?
        .ok_or_else(|| HostError::conflict(format!("{pipeline} declares no input")))?;
    let prompt = |current: Option<&str>, problems: &[String]| {
        run_input_prompt(
            pipeline,
            &declaration,
            description,
            current,
            harness,
            problems,
        )
    };
    let env = cli_environment(&context.environment.env, config);
    let session = |prompt: String, stop: Option<oneshot::Receiver<()>>| {
        context.note_session.run(NoteSessionRun {
            harness,
            prompt,
            model: model.clone(),
            effort: effort.clone(),
            env: env.clone(),
            writable: vec![],
            stop,
            on_line: None,
            stream: false,
            access: Access::Read,
        })
    };
    let (first_stop, second_stop) = split_stop(stop);

    let first: CliResult = session(prompt(current.as_deref(), &[]), first_stop)
        .await
        .map_err(HostError::unavailable)?;
    let Some(answer) = json_answer(&first.stdout) else {
        if stopped() {
            return Err(HostError::unavailable("The run was stopped."));
        }
        let why = reason_of(&first.stdout, &first.stderr);
        return Err(HostError::unavailable(
            format!("The agent did not answer with JSON: {why}")
                .trim()
                .to_string(),
        ));
    };

    let mut check = CliRun::new(
        CliBinary::SynapsePipeline,
        &["check", pipeline, "--input", "-"],
        config.clone(),
    );
    check.stdin = Some(answer.clone());
    let checked = context
        .cli
        .run(check)
        .await
        .map_err(HostError::unavailable)?;
    if checked.code != 2 || stopped() {
        return Ok(answer);
    }
    let problems: Vec<String> = checked
        .stderr
        .lines()
        .map(str::trim)
        .filter(|line| line.starts_with("error:"))
        .map(String::from)
        .collect();
    let second = session(prompt(Some(&answer), &problems), second_stop)
        .await
        .map_err(HostError::unavailable)?;
    Ok(json_answer(&second.stdout).unwrap_or(answer))
}
