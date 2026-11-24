//! Having an agent write for the person: the text of a definition from a description, a note of the
//! vault, a change to a note. The agent is a headless session of a harness. For a definition it has no
//! tools and answers with text, which the editor shows and the program then checks. For a note it has
//! Synapse loaded and the tools writing a note takes, because a note has to follow the vault's own
//! rules, and the new note is found by comparing the vault before and after.

use crate::cli::{CliRun, CliRunner};
use crate::dispatch::HostError;
use crate::environment::{split_paths, Environment};
use crate::inject::{plan_session, InjectDeps, SessionPlan};
use crate::messages::{
    AppConfig, CliBinary, CliResult, DefinitionKind, DefinitionName, Harness, NoteEdit, NoteKind,
    Project,
};
use crate::status::find_pipeline_root;
use regex::Regex;
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::oneshot;

const AGENT_TIMEOUT: Duration = Duration::from_secs(180);
const NOTE_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const MAX_OUTPUT_BYTES: usize = 1024 * 1024;

// ---------------------------------------------------------------------------------------------
// Running a session
// ---------------------------------------------------------------------------------------------

/// A command to run: the program, its arguments, what it is given besides the environment, and what
/// is typed to it.
#[derive(Clone, Debug, PartialEq)]
pub struct Command {
    pub program: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub stdin: String,
}

/// Handed each complete non-empty line a session prints.
pub type OnLine = Arc<dyn Fn(String) + Send + Sync>;

/// The exit code of a run that was stopped, as the Node host reports it.
pub const STOPPED_CODE: i32 = 143;

/// Reads `from` to its end into `kept`, handing each complete non-empty line to `on_line` (and the
/// last one, which may have no newline, at the end). `kept` is filled as it goes, so that what was
/// read is there when the run is stopped before the end.
async fn read_into(
    from: &mut (impl AsyncReadExt + Unpin),
    kept: &mut Vec<u8>,
    on_line: Option<&OnLine>,
) -> Result<(), String> {
    let mut chunk = [0u8; 16 * 1024];
    let mut from_line = 0;
    let hand_over = |line: &[u8]| {
        if let Some(on_line) = on_line {
            let text = String::from_utf8_lossy(line);
            let text = text.trim_end_matches('\r');
            if !text.trim().is_empty() {
                on_line(text.to_string());
            }
        }
    };
    loop {
        let n = from.read(&mut chunk).await.map_err(|e| e.to_string())?;
        if n == 0 {
            hand_over(&kept[from_line..]);
            return Ok(());
        }
        kept.extend_from_slice(&chunk[..n]);
        if kept.len() > MAX_OUTPUT_BYTES {
            return Err("the output is too large".to_string());
        }
        while let Some(at) = kept[from_line..].iter().position(|b| *b == b'\n') {
            hand_over(&kept[from_line..from_line + at]);
            from_line += at + 1;
        }
    }
}

/// Runs a command in `folder`, which is empty, so that no project instructions are loaded into it. A
/// non-zero exit is a result, not an error. When `stop` fires the process is killed and the result is
/// code 143 with what was read so far.
async fn run_command(
    command: Command,
    env: BTreeMap<String, String>,
    limit: Duration,
    folder: &Path,
    stop: Option<oneshot::Receiver<()>>,
    on_line: Option<OnLine>,
) -> Result<CliResult, String> {
    let failed = |why: String| format!("{} could not be run: {why}", command.program);
    let mut child = tokio::process::Command::new(&command.program);
    child
        .args(&command.args)
        .env_clear()
        .envs(&env)
        .current_dir(folder)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = child.spawn().map_err(|e| failed(e.to_string()))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| failed("no standard input".into()))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| failed("no standard output".into()))?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| failed("no standard error".into()))?;
    let input = command.stdin.clone();
    let mut out = Vec::new();
    let mut err = Vec::new();
    enum Ended {
        Done(Result<std::process::ExitStatus, String>),
        TimedOut,
        Stopped,
    }
    let ended = {
        let work = async {
            let write = async move {
                let _ = stdin.write_all(input.as_bytes()).await;
                drop(stdin);
            };
            let (_, read_out, read_err) = tokio::join!(
                write,
                read_into(&mut stdout, &mut out, on_line.as_ref()),
                read_into(&mut stderr, &mut err, None)
            );
            read_out?;
            read_err?;
            child.wait().await.map_err(|e| e.to_string())
        };
        // Only a stop that is sent counts: a sender that is dropped is not a stop.
        let stopping = async move {
            if let Some(stop) = stop {
                if stop.await.is_ok() {
                    return;
                }
            }
            std::future::pending::<()>().await
        };
        tokio::select! {
            done = tokio::time::timeout(limit, work) => match done {
                Ok(done) => Ended::Done(done),
                Err(_) => Ended::TimedOut,
            },
            _ = stopping => Ended::Stopped,
        }
    };
    let status = match ended {
        Ended::Done(done) => done.map_err(failed)?,
        Ended::TimedOut => return Err(failed("it did not finish in time".into())),
        Ended::Stopped => {
            let _ = child.kill().await;
            return Ok(CliResult {
                code: STOPPED_CODE,
                stdout: String::from_utf8_lossy(&out).to_string(),
                stderr: String::from_utf8_lossy(&err).to_string(),
            });
        }
    };
    let code = status
        .code()
        .ok_or_else(|| failed("it was ended by a signal".into()))?;
    Ok(CliResult {
        code,
        stdout: String::from_utf8_lossy(&out).to_string(),
        stderr: String::from_utf8_lossy(&err).to_string(),
    })
}

// ---------------------------------------------------------------------------------------------
// A definition from a description
// ---------------------------------------------------------------------------------------------

pub struct AgentRun {
    /// Variables set in the app, over those the host has.
    pub env: BTreeMap<String, String>,
    pub harness: Harness,
    /// The model the session is asked to use; the harness's own when absent.
    pub model: Option<String>,
    /// Added to the session's own instructions.
    pub system: String,
    pub prompt: String,
    /// Fires when the person stops the run.
    pub stop: Option<oneshot::Receiver<()>>,
}

type Running = Pin<Box<dyn Future<Output = Result<CliResult, String>> + Send>>;

/// Runs an agent that can read and answer but not change anything or run anything.
#[derive(Clone)]
pub struct AgentRunner(Arc<dyn Fn(AgentRun) -> Running + Send + Sync>);

impl AgentRunner {
    pub fn new<F, Fut>(runner: F) -> AgentRunner
    where
        F: Fn(AgentRun) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<CliResult, String>> + Send + 'static,
    {
        AgentRunner(Arc::new(move |run| Box::pin(runner(run))))
    }

    pub async fn run(&self, run: AgentRun) -> Result<CliResult, String> {
        (self.0)(run).await
    }

    /// The programs themselves, in the environment the host has.
    pub fn system(base: BTreeMap<String, String>) -> AgentRunner {
        AgentRunner::new(move |run| {
            let base = base.clone();
            async move {
                let mut run = run;
                let command = agent_command(&run);
                let mut env = base;
                env.extend(run.env.clone());
                env.extend(command.env.clone());
                run_command(
                    command,
                    env,
                    AGENT_TIMEOUT,
                    &std::env::temp_dir(),
                    run.stop.take(),
                    None,
                )
                .await
            }
        })
    }
}

/// The headless session of a harness that can read and answer but not change anything or run
/// anything. Codex and OpenCode have no flag for added instructions, so those go in front of the
/// prompt.
pub fn agent_command(run: &AgentRun) -> Command {
    let together = format!("{}\n\n{}", run.system, run.prompt);
    let model = |flag: &str| -> Vec<String> {
        run.model
            .iter()
            .flat_map(|m| [flag.to_string(), m.clone()])
            .collect()
    };
    let strings = |items: &[&str]| -> Vec<String> { items.iter().map(|s| s.to_string()).collect() };
    match run.harness {
        Harness::Claude => Command {
            program: "claude".into(),
            args: [
                strings(&[
                    "-p",
                    "--output-format",
                    "text",
                    "--no-session-persistence",
                    "--permission-mode",
                    "dontAsk",
                    "--tools",
                    "",
                    "--append-system-prompt",
                    &run.system,
                ]),
                model("--model"),
            ]
            .concat(),
            env: BTreeMap::new(),
            stdin: run.prompt.clone(),
        },
        Harness::Codex => Command {
            program: "codex".into(),
            args: [
                strings(&["exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only"]),
                model("-m"),
            ]
            .concat(),
            env: BTreeMap::new(),
            stdin: together,
        },
        Harness::Opencode => Command {
            program: "opencode".into(),
            args: [strings(&["run", "--standalone", "--auto"]), model("-m"), vec![together]].concat(),
            env: BTreeMap::from([(
                "OPENCODE_CONFIG_CONTENT".to_string(),
                json!({ "permission": {
                    "edit": "deny", "bash": "deny", "webfetch": "deny", "external_directory": "deny",
                } })
                .to_string(),
            )]),
            stdin: String::new(),
        },
    }
}

/// The text of the skill that comes with `synapse-pipeline`: it sits in the package next to the
/// program's launcher, which is a link on PATH, or in the folders the app is bundled with.
pub fn find_pipeline_skill(
    environment: &Environment,
    bundled: &[PathBuf],
) -> Result<String, HostError> {
    for dir in split_paths(
        environment
            .env
            .get("PATH")
            .map(String::as_str)
            .unwrap_or(""),
    ) {
        let Ok(real) = dunce::canonicalize(Path::new(dir).join("synapse-pipeline")) else {
            continue;
        };
        let skill = real
            .parent()
            .unwrap_or(Path::new(""))
            .join("..")
            .join("skills")
            .join("synapse-pipeline")
            .join("SKILL.md");
        if let Ok(text) = std::fs::read_to_string(skill) {
            return Ok(text);
        }
    }
    if let Some(root) = find_pipeline_root(environment, bundled) {
        if let Ok(text) = std::fs::read_to_string(root.join("skills/synapse-pipeline/SKILL.md")) {
            return Ok(text);
        }
    }
    Err(HostError::conflict(
        "the synapse-pipeline skill was not found next to the program",
    ))
}

/// The part of the skill that says what definitions are and how they behave: from "Definitions" up to
/// the part about running them.
pub fn reference_from(skill: &str) -> Result<String, HostError> {
    let start = skill.find("\n## Definitions");
    let end = skill.find("\n## Trying a pipeline without agents");
    match (start, end) {
        (Some(start), Some(end)) if end >= start => Ok(skill[start..end].trim().to_string()),
        _ => Err(HostError::unavailable(
            "the synapse-pipeline skill has an unknown layout",
        )),
    }
}

const REPLY_RULES: &str = "Reply with the text of one file and nothing else: no code fences, no explanation before or after. You cannot run commands or write files here; the text you give is checked afterwards, so it has to be right as written.";

const SKILL_FORMAT: &str = "A skill is a SKILL.md: frontmatter between --- lines holding name (1 to 64 lowercase letters, digits and single hyphens) and description (what the skill does and when to use it), then the instructions the agent follows.";

const REVISE_RULES: &str = "You are given the current text of the file. Reply with the whole revised text, with the same name and the same kind of definition, and change only what the description asks for.";

/// What a definition is asked for: its kind, a description, the current text when it is a change, and
/// what exists so that a name is not taken.
pub struct GenerateRequest<'a> {
    pub kind: DefinitionKind,
    pub prompt: &'a str,
    pub current: Option<&'a str>,
    pub definitions: &'a [DefinitionName],
    pub skills: &'a [String],
}

fn kind_word(kind: DefinitionKind) -> &'static str {
    match kind {
        DefinitionKind::Pipeline => "pipeline",
        DefinitionKind::System => "system",
        DefinitionKind::Agent => "agent",
        DefinitionKind::Skill => "skill",
    }
}

pub fn system_for(request: &GenerateRequest, skill: &str) -> Result<String, HostError> {
    let revising = if request.current.is_some() {
        format!("\n\n{REVISE_RULES}")
    } else {
        String::new()
    };
    if request.kind == DefinitionKind::Skill {
        return Ok(format!(
            "You write skills for coding agents. {SKILL_FORMAT}\n\n{REPLY_RULES}{revising}"
        ));
    }
    let wanted = match request.kind {
        DefinitionKind::Pipeline => "a Pipeline: a single file, with each step's role and instructions in its own Prompt. Refer to an existing Agent or System only when one in the list below fits. Give every step a Harness and say in its prompt the exact outcome words it may report. Every back-edge needs Max_Iterations.",
        DefinitionKind::System => "a System: one reusable setup that steps can share.",
        _ => "an Agent: one role, a Prompt that says who the session is.",
    };
    Ok(format!(
        "You write definition files for synapse-pipeline. Write {wanted}\n\n{REPLY_RULES}{revising}\n\n{}",
        reference_from(skill)?
    ))
}

pub fn prompt_for(request: &GenerateRequest) -> String {
    let kind = kind_word(request.kind);
    let mut lines: Vec<String> = match request.current {
        None => vec![
            format!("Write a new {kind} as described here."),
            String::new(),
            request.prompt.trim().to_string(),
        ],
        Some(current) => vec![
            format!("Change this {kind} as described here."),
            String::new(),
            request.prompt.trim().to_string(),
            String::new(),
            "The current text:".into(),
            String::new(),
            current.to_string(),
        ],
    };
    if request.kind != DefinitionKind::Skill && !request.definitions.is_empty() {
        lines.push(String::new());
        lines.push("Definitions that exist (a name is taken by any of them):".into());
        for d in request.definitions {
            let word = match d.kind {
                crate::messages::DefinitionDraftKind::Pipeline => "pipeline",
                crate::messages::DefinitionDraftKind::System => "system",
                crate::messages::DefinitionDraftKind::Agent => "agent",
            };
            lines.push(format!("- {word} {}", d.name));
        }
    }
    if request.kind == DefinitionKind::Skill && !request.skills.is_empty() {
        lines.push(String::new());
        lines.push(format!(
            "Skills that exist (a name is taken by any of them): {}",
            request.skills.join(", ")
        ));
    }
    lines.join("\n")
}

/// What the agent answered, as the text of the file: a reply wrapped in a code fence has the fence
/// taken off.
pub fn text_of(answer: &str) -> String {
    let trimmed = answer.trim();
    let fenced = Regex::new(r"(?s)^```[^\n]*\n(.*?)\n?```$").unwrap();
    let inner = fenced
        .captures(trimmed)
        .map(|c| c[1].to_string())
        .unwrap_or_else(|| trimmed.to_string());
    format!("{}\n", inner.trim())
}

/// Which agent answers a generation: the harness, the model it is asked to use (its own when
/// absent) and the variables set in the app.
pub struct AgentChoice {
    pub harness: Harness,
    pub model: Option<String>,
    pub env: BTreeMap<String, String>,
}

/// Asks the agent for the text of a definition.
pub async fn generate_text(
    request: &GenerateRequest<'_>,
    environment: &Environment,
    bundled: &[PathBuf],
    agent: &AgentRunner,
    choice: AgentChoice,
    stop: Option<oneshot::Receiver<()>>,
    stopped: impl Fn() -> bool,
) -> Result<String, HostError> {
    let AgentChoice {
        harness,
        model,
        env,
    } = choice;
    let skill = if request.kind == DefinitionKind::Skill {
        String::new()
    } else {
        find_pipeline_skill(environment, bundled)?
    };
    let result = agent
        .run(AgentRun {
            env,
            harness,
            model,
            system: system_for(request, &skill)?,
            prompt: prompt_for(request),
            stop,
        })
        .await
        .map_err(HostError::unavailable)?;
    if result.code == STOPPED_CODE && stopped() {
        return Err(HostError::unavailable("the run was stopped"));
    }
    if result.code != 0 {
        let reason = result
            .stderr
            .trim()
            .lines()
            .last()
            .unwrap_or("")
            .to_string();
        let tail = if reason.is_empty() {
            String::new()
        } else {
            format!(": {reason}")
        };
        return Err(HostError::unavailable(format!("the agent failed{tail}")));
    }
    let text = text_of(&result.stdout);
    if text.trim().is_empty() {
        return Err(HostError::unavailable("the agent answered with nothing"));
    }
    Ok(text)
}

// ---------------------------------------------------------------------------------------------
// A note of the vault
// ---------------------------------------------------------------------------------------------

fn kind_instructions(kind: NoteKind) -> &'static str {
    match kind {
        NoteKind::Note => "a plain note: use the synapse-note skill in bare mode",
        NoteKind::Task => "a tracked task note: use the synapse-note skill with --task",
        NoteKind::Design => "a design note: use the synapse-design-note skill",
    }
}

/// Claude Code and OpenCode run a command only when the whole of it is allowed, so the session is told
/// which commands those are. Codex runs anything inside its sandbox.
const COMMAND_RULES: &str = "Only these commands work in this session: synapse, ls, cat, head, tail, grep, sort and wc. Run one command in each Bash call: do not chain commands with ;, && or ||, do not use cd or echo, and write paths out in full, with ~ and not a variable.";

/// How input is given to the synapse program in a session that may only write through it.
const HERE_DOCUMENT_RULE: &str = "Give a note's text to `synapse vault-write <path>`, and a query to `synapse vault-search`, on standard input as a here-document, not through cat, echo or <<<: the synapse program is the only thing that may write here.";

/// What a task or design note is told about its project: the one chosen, else the ones there are to
/// match the description to. A project is made by a person on the page, never by the session, and a
/// plain note has none.
pub fn project_paragraph(
    kind: NoteKind,
    projects: &[Project],
    chosen: Option<&Project>,
) -> Vec<String> {
    if kind == NoteKind::Note {
        return vec![];
    }
    let folder = if kind == NoteKind::Task {
        "tasks"
    } else {
        "designs"
    };
    if let Some(chosen) = chosen {
        return vec![
            format!("The project of this note is {}, with the prefix {}: use it as it is and do not resolve another. The note is in {folder}/{}/ and its project is {}.", chosen.name, chosen.prefix, chosen.name, chosen.prefix),
            String::new(),
        ];
    }
    let known = if projects.is_empty() {
        "There are none.".to_string()
    } else {
        projects
            .iter()
            .map(|p| format!("{}={}", p.name, p.prefix))
            .collect::<Vec<_>>()
            .join(", ")
    };
    vec![
        format!("The projects of this machine, as name=prefix: {known} A note of the project NAME with the prefix PREFIX is in {folder}/NAME/ and has the project PREFIX. Choose the project the description belongs to, matching loosely: a description about a part of a project belongs to that project."),
        "Never add a project, since that file is not yours to change here. If none fits the description, write nothing and end with FAILED: saying that no project fits, so that the person can add one on the page.".into(),
        String::new(),
    ]
}

fn command_rules(harness: Harness) -> Vec<String> {
    if harness == Harness::Codex {
        vec![]
    } else {
        vec![COMMAND_RULES.to_string(), String::new()]
    }
}

/// How a note that is changed is handed to the synapse program by a session that may edit only the
/// files of its own folder. A command that carries the whole text of a long note is refused, so the
/// note is saved to a file there, changed with the edit tool and written back from the file.
const WORK_FILE_RULE: &str = "Save the note in the current folder with `synapse vault-read <path> > note.md`, change it there with the Edit tool, and write it back with `synapse vault-write <path> < note.md`. Give the synapse program its input from a file in the current folder, made with the Write tool and read with `<`, never as a here-document and never through cat, echo or <<<: a command that carries the text is refused, as the whole text of a long note is and as a JSON query is. A query for `synapse vault-search` is in query.json and run as `synapse vault-search < query.json`; the text of an addition for `synapse vault-patch` is in addition.md. The synapse program is the only thing that may write to the vault.";

/// The same for a note that is made: it is written to a file there with the Write tool and given to the
/// vault from the file.
const NEW_NOTE_FILE_RULE: &str = "Write the note with the Write tool to note.md in the current folder, and give it to the vault with `synapse vault-write <path> < note.md`. Give the synapse program its input from a file in the current folder, made with the Write tool and read with `<`, never as a here-document and never through cat, echo or <<<: a command that carries the text is refused, as the whole text of a long note is and as a JSON query is. A query for `synapse vault-search` is in query.json and run as `synapse vault-search < query.json`; the text of an addition for `synapse vault-patch` is in addition.md. The synapse program is the only thing that may write to the vault. When the note is in a top-level folder that Index.md does not list, add the folder to Index.md as the skill says.";

/// The prompt to change one note that is there already. The agent is held to that note by what it is
/// told, and the app checks afterwards that no other note moved.
pub fn edit_prompt(path: &str, description: &str, harness: Harness) -> String {
    let mut lines = vec![
        format!("Change one note that already exists in my Synapse Vault, as the description below says. The note is `{path}`: read it first with `synapse vault-read`. Nobody can answer questions in this session, so decide what you would otherwise ask and carry on."),
        String::new(),
        "Follow the synapse-vault skill, and for a task note the synapse-task skill: a checklist moves the status up to REVIEW and never to DONE. Change only what the description asks for, and change no other note. Edit with `synapse vault-patch` when a heading or a field is the target, or write the whole note again with `synapse vault-write` from what you read, keeping every frontmatter field, section, link and line you were not asked to change. Never change `schema`, `note_id`, `task_id`, `created` or `project`, and set `updated` from `synapse now`.".into(),
        String::new(),
    ];
    lines.extend(command_rules(harness));
    lines.push(if harness == Harness::Claude {
        WORK_FILE_RULE.into()
    } else {
        HERE_DOCUMENT_RULE.into()
    });
    lines.push(String::new());
    lines.push("When the note is changed, end your reply with the line EDITED. If you cannot change it, or the description asks for what you may not do, end with one line that starts with FAILED: and says why.".into());
    lines.push(String::new());
    lines.push("Description:".into());
    lines.push(description.trim().to_string());
    lines.join("\n")
}

pub fn note_prompt(
    kind: NoteKind,
    description: &str,
    harness: Harness,
    projects: &[Project],
    chosen: Option<&Project>,
) -> String {
    let mut lines = vec![
        "Create one note in my Synapse Vault from the description below. Nobody can answer questions in this session, so decide what you would otherwise ask and carry on.".to_string(),
        String::new(),
        format!("Write {}. Follow that skill and the synapse-vault skill: search the vault first and link to the notes that already exist, put the note where the skill says, tag it, and write the content the description asks for. The note is not finished while it is only a title.", kind_instructions(kind)),
        String::new(),
    ];
    lines.extend(command_rules(harness));
    lines.push(if harness == Harness::Claude {
        NEW_NOTE_FILE_RULE.into()
    } else {
        "Give a note's text to `synapse vault-write <path>`, and a query to `synapse vault-search`, on standard input as a here-document, not through cat, echo or <<<: the synapse program is the only thing that may write here. When the note is in a top-level folder that Index.md does not list, add the folder to Index.md as the skill says, with `synapse vault-patch` or `synapse vault-write`.".into()
    });
    lines.push(String::new());
    lines.extend(project_paragraph(kind, projects, chosen));
    lines.push("When the note is written, end your reply with one line that holds its path in the vault, as `synapse vault-list` shows it. If you cannot write it, end with one line that starts with FAILED: and says why.".into());
    lines.push(String::new());
    lines.push("Description:".into());
    lines.push(description.trim().to_string());
    lines.join("\n")
}

/// The read-only commands the skills chain the synapse program with.
const HELPERS: [&str; 7] = ["ls", "head", "tail", "cat", "grep", "sort", "wc"];

/// The files the skills keep their lists in, which a session may read.
const LIST_FILES: [&str; 2] = ["~/.config/synapse/**", "~/.claude/synapse-*.conf"];

/// The only list a session may add to: the tag vocabulary. A project is chosen by a person, since it
/// names the folder and the prefix of every note after it, so `synapse-projects.conf` is read and never
/// changed here.
const TAG_FILES: [&str; 2] = [
    "~/.config/synapse/synapse-tag-vocabulary.conf",
    "~/.claude/synapse-tag-vocabulary.conf",
];

/// What a Claude Code session may use: the skills, the Synapse program with the read-only commands,
/// reading the files the skills keep their lists in and adding to the tag vocabulary. A command that
/// chains one of these with anything else is refused whole, and anything else is refused, not asked.
pub fn note_tools() -> String {
    let mut tools: Vec<String> = vec!["Skill".into(), "Read".into()];
    tools.extend(LIST_FILES.iter().map(|f| format!("Read({f})")));
    tools.push("Bash(synapse *)".into());
    tools.extend(HELPERS.iter().map(|c| format!("Bash({c} *)")));
    tools.extend(TAG_FILES.iter().map(|f| format!("Edit({f})")));
    // The files of the session's own folder, which is empty and removed when the session ends.
    tools.push("Edit(./**)".into());
    tools.join(",")
}

/// The same for OpenCode: a command is allowed by its start, and all else is denied.
pub fn opencode_permission() -> serde_json::Value {
    let mut bash = serde_json::Map::new();
    bash.insert("*".into(), json!("deny"));
    bash.insert("synapse *".into(), json!("allow"));
    for command in HELPERS {
        bash.insert(format!("{command} *"), json!("allow"));
    }
    let mut edit = serde_json::Map::new();
    edit.insert("*".into(), json!("deny"));
    for file in TAG_FILES {
        edit.insert(file.into(), json!("allow"));
    }
    json!({ "bash": bash, "edit": edit, "webfetch": "deny" })
}

/// What the session is told after the prompt: where its folder is, written out, since the edit tool
/// takes a full path and has no other way to know it.
pub fn folder_sentence(folder: &Path) -> String {
    format!(
        "Your current folder is {}: a file you make there, such as note.md, is at that path.",
        folder.display()
    )
}

/// The prompt a session is given: the sentence about its folder comes first, so that the prompt still
/// ends with the description of what is asked.
pub fn session_prompt(prompt: &str, folder: &Path) -> String {
    format!("{}\n\n{prompt}", folder_sentence(folder))
}

/// The headless session of a harness for a note, with what the session plan adds to load Synapse.
/// Claude Code and OpenCode are held to the commands above. Codex runs in its sandbox, which writes
/// only to its working folder and the folders in `writable`, where the vault and the skills' files are,
/// and has no network. With `stream` Claude Code prints each event as a line; the other two ignore it.
pub fn note_command(
    harness: Harness,
    plan: &SessionPlan,
    prompt: &str,
    writable: &[String],
    model: Option<&str>,
    stream: bool,
) -> Command {
    let strings = |items: &[&str]| -> Vec<String> { items.iter().map(|s| s.to_string()).collect() };
    let model_args = |flag: &str| -> Vec<String> {
        model
            .iter()
            .flat_map(|m| [flag.to_string(), m.to_string()])
            .collect()
    };
    match harness {
        Harness::Claude => {
            // The folder of the Synapse package, when it is loaded for the session, is there to be
            // read: its skills and the schemas the vault holds notes to.
            let tools = match plan.env.get("SYNAPSE_CONTENT_ROOT") {
                None => note_tools(),
                Some(root) => format!("{},Read({root}/**)", note_tools()),
            };
            Command {
                program: plan.command.clone(),
                args: [
                    strings(&["-p", "--output-format"]),
                    // Streamed, every event is printed as a line, which needs --verbose.
                    strings(if stream {
                        &["stream-json", "--verbose"]
                    } else {
                        &["text"]
                    }),
                    strings(&[
                        "--no-session-persistence",
                        "--permission-mode",
                        "dontAsk",
                        "--allowedTools",
                    ]),
                    vec![tools],
                    plan.args.clone(),
                    model_args("--model"),
                ]
                .concat(),
                env: BTreeMap::new(),
                stdin: prompt.to_string(),
            }
        }
        Harness::Codex => Command {
            program: plan.command.clone(),
            args: [
                strings(&[
                    "exec",
                    "--ephemeral",
                    "--skip-git-repo-check",
                    "-s",
                    "workspace-write",
                    "-c",
                    "approval_policy=\"never\"",
                ]),
                writable
                    .iter()
                    .flat_map(|d| ["--add-dir".to_string(), d.clone()])
                    .collect(),
                plan.args.clone(),
                model_args("-m"),
                strings(&["-"]),
            ]
            .concat(),
            env: BTreeMap::new(),
            stdin: prompt.to_string(),
        },
        Harness::Opencode => Command {
            program: plan.command.clone(),
            args: [
                strings(&["run", "--standalone", "--auto"]),
                plan.args.clone(),
                model_args("-m"),
                vec![prompt.to_string()],
            ]
            .concat(),
            env: BTreeMap::from([(
                "OPENCODE_CONFIG_CONTENT".to_string(),
                json!({ "permission": opencode_permission() }).to_string(),
            )]),
            stdin: String::new(),
        },
    }
}

pub struct NoteSessionRun {
    pub harness: Harness,
    pub prompt: String,
    /// The model the session is asked to use; the harness's own when absent.
    pub model: Option<String>,
    /// The environment the session runs in.
    pub env: BTreeMap<String, String>,
    /// The folders the session writes in besides its own: the vault, and where the skills keep their
    /// files.
    pub writable: Vec<String>,
    /// Fires when the person stops the run.
    pub stop: Option<oneshot::Receiver<()>>,
    /// Handed each line the session prints, as it prints it.
    pub on_line: Option<OnLine>,
    /// Whether Claude Code prints its events as lines; `stdout` is then its final result.
    pub stream: bool,
}

type NoteRunning = Pin<Box<dyn Future<Output = Result<CliResult, String>> + Send>>;

/// Runs a note session: a harness with Synapse loaded, held to what writing a note takes.
#[derive(Clone)]
pub struct NoteSession(Arc<dyn Fn(NoteSessionRun) -> NoteRunning + Send + Sync>);

impl NoteSession {
    pub fn new<F, Fut>(runner: F) -> NoteSession
    where
        F: Fn(NoteSessionRun) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<CliResult, String>> + Send + 'static,
    {
        NoteSession(Arc::new(move |run| Box::pin(runner(run))))
    }

    pub async fn run(&self, run: NoteSessionRun) -> Result<CliResult, String> {
        (self.0)(run).await
    }

    /// The programs themselves, started the way a session is, with Synapse loaded from the folders
    /// `deps` names.
    pub fn system(deps: InjectDeps) -> NoteSession {
        NoteSession::new(move |run| {
            let deps = deps.clone();
            async move {
                let plan = tokio::task::spawn_blocking(move || {
                    plan_session(run.harness, &deps).map(|p| (p, run))
                })
                .await
                .map_err(|e| e.to_string())?
                .map_err(|e| e.to_string())?;
                let (session, mut run) = plan;
                // A folder of the session's own, removed when it ends, for the files it makes. Its
                // real path: the permission rules compare it with the path a file is made at.
                let folder = tempfile::Builder::new()
                    .prefix("synapse-note-")
                    .tempdir()
                    .map_err(|e| e.to_string())?;
                let path = dunce::canonicalize(folder.path()).map_err(|e| e.to_string())?;
                let command = note_command(
                    run.harness,
                    &session,
                    &session_prompt(&run.prompt, &path),
                    &run.writable,
                    run.model.as_deref(),
                    run.stream,
                );
                let mut env = run.env.clone();
                env.extend(session.env.clone());
                env.extend(command.env.clone());
                let streaming = run.stream && run.harness == Harness::Claude;
                let mut result = run_command(
                    command,
                    env,
                    NOTE_TIMEOUT,
                    &path,
                    run.stop.take(),
                    run.on_line.take(),
                )
                .await?;
                if streaming {
                    result.stdout = stream_result(&result.stdout);
                }
                Ok(result)
            }
        })
    }
}

/// The text of the final `result` event of a stream-json transcript, empty when there is none.
pub fn stream_result(stdout: &str) -> String {
    for line in stdout.lines().rev() {
        let Ok(event) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if event.get("type").and_then(|t| t.as_str()) == Some("result") {
            return event
                .get("result")
                .and_then(|r| r.as_str())
                .unwrap_or("")
                .to_string();
        }
    }
    String::new()
}

fn last_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .rfind(|l| !l.is_empty())
        .unwrap_or("")
        .to_string()
}

/// The reason the agent gave for not writing the note, when it said so.
pub fn failure_of(stdout: &str) -> Option<String> {
    last_line(stdout)
        .strip_prefix("FAILED:")
        .map(|rest| rest.trim().to_string())
}

fn last_words(text: &str) -> String {
    let clean = Regex::new("\u{1b}\\[[0-9;]*m")
        .unwrap()
        .replace_all(text, "")
        .trim()
        .to_string();
    let chars: Vec<char> = clean.chars().collect();
    chars[chars.len().saturating_sub(300)..].iter().collect()
}

/// Why a session that was to write or change a note did not: the reason it gave on a line that starts
/// with FAILED:, else the end of what it said, else the end of what the harness printed on standard
/// error. What it said comes first because some harnesses print their whole transcript on standard
/// error, the banner and the prompt among it, and the agent's own words are on standard output.
pub fn reason_of(stdout: &str, stderr: &str) -> String {
    failure_of(stdout).unwrap_or_else(|| {
        let said = last_words(stdout);
        if said.is_empty() {
            last_words(stderr)
        } else {
            said
        }
    })
}

/// The note that was written: the one the agent named when it is among the notes that were not there
/// before, else the first new note that is not a graph's.
pub fn created_path(stdout: &str, before: &BTreeSet<String>, after: &[String]) -> Option<String> {
    let added: Vec<&String> = after
        .iter()
        .filter(|p| !before.contains(*p) && p.ends_with(".md"))
        .collect();
    let said = last_line(stdout);
    let said = said
        .trim_matches(|c| "`'\"".contains(c))
        .trim_end_matches(['`', '\'', '"', '.']);
    if !said.is_empty() && added.iter().any(|p| p.as_str() == said) {
        return Some(said.to_string());
    }
    added
        .into_iter()
        .find(|p| !p.starts_with("synapse/"))
        .cloned()
}

pub fn paths_of(listing: &str) -> Vec<String> {
    listing
        .split('\n')
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect()
}

/// The vault's folder in the output of `synapse config list --format json`.
pub fn vault_dir_of(listing: &str) -> Option<String> {
    let parsed: serde_json::Value = serde_json::from_str(listing).ok()?;
    let value = parsed
        .get("settings")?
        .as_array()?
        .iter()
        .find(|s| s.get("key").and_then(|k| k.as_str()) == Some("SYNAPSE_VAULT_DIR"))?
        .get("value")?
        .as_str()?;
    (!value.is_empty()).then(|| value.to_string())
}

// ---------------------------------------------------------------------------------------------
// Having an agent change a note that is there already
// ---------------------------------------------------------------------------------------------

/// The nodes of a code graph, `synapse/<repo>@<branch>/<node>.md`, are written by the graph tools,
/// which compute what each one holds; a change by hand puts them out of step.
fn is_graph_node(path: &str) -> bool {
    Regex::new(r"^synapse/[^/]+@[^/]+/").unwrap().is_match(path)
}

/// Why a path may not be changed here, or none when it may: a note of the vault by its path, which is
/// relative and stays inside the vault.
pub fn note_path_problem(path: &str) -> Option<&'static str> {
    if path.is_empty() || path.chars().count() > 1024 || path.contains('\0') {
        return Some("There is no such note.");
    }
    let drive = path.chars().nth(1) == Some(':')
        && path.chars().next().is_some_and(|c| c.is_ascii_alphabetic());
    if path.starts_with('/') || drive || path.split('/').any(|part| part == "..") {
        return Some("A note is named by its path in the vault.");
    }
    if !path.ends_with(".md") {
        return Some("Only a note, a .md file, can be changed here.");
    }
    if is_graph_node(path) {
        return Some(
            "The nodes of a code graph are written by the graph tools and are not changed by hand.",
        );
    }
    None
}

async fn read_note(run: &CliRunner, config: &AppConfig, path: &str) -> Result<String, HostError> {
    let result = run
        .run(CliRun::new(
            CliBinary::Synapse,
            &["vault-read", path],
            config.clone(),
        ))
        .await
        .map_err(HostError::unavailable)?;
    if result.code != 0 {
        return Err(HostError::not_found(
            format!("{path} could not be read: {}", result.stderr.trim())
                .trim()
                .to_string(),
        ));
    }
    Ok(result.stdout)
}

/// The date each note says it was updated, by path; a note with none is not in it.
pub async fn stamps(run: &CliRunner, config: &AppConfig) -> BTreeMap<String, String> {
    let mut request = CliRun::new(
        CliBinary::Synapse,
        &["vault-search", "--fields", "frontmatter.updated"],
        config.clone(),
    );
    request.stdin = Some("{\"var\":\"frontmatter.updated\"}".into());
    let mut found = BTreeMap::new();
    let Ok(result) = run.run(request).await else {
        return found;
    };
    if result.code != 0 {
        return found;
    }
    for line in result.stdout.split('\n') {
        let mut parts = line.split('\t');
        if let (Some(path), Some(updated)) = (parts.next(), parts.next()) {
            if !path.is_empty() {
                found.insert(path.to_string(), updated.to_string());
            }
        }
    }
    found
}

async fn listing(run: &CliRunner, config: &AppConfig) -> BTreeSet<String> {
    match run
        .run(CliRun::new(
            CliBinary::Synapse,
            &["vault-list"],
            config.clone(),
        ))
        .await
    {
        Ok(result) if result.code == 0 => paths_of(&result.stdout).into_iter().collect(),
        _ => BTreeSet::new(),
    }
}

/// What a vault looked like: the date each note says it was updated, and every path.
pub struct Seen {
    pub stamps: BTreeMap<String, String>,
    pub paths: BTreeSet<String>,
}

/// The other notes that moved: one whose date changed, one that is new and one that is gone, in path
/// order.
pub fn touched_elsewhere(before: &Seen, after: &Seen, target: &str) -> Vec<String> {
    let mut moved: BTreeSet<String> = BTreeSet::new();
    for (path, updated) in &after.stamps {
        if before.stamps.get(path) != Some(updated) {
            moved.insert(path.clone());
        }
    }
    for path in before.stamps.keys() {
        if !after.stamps.contains_key(path) {
            moved.insert(path.clone());
        }
    }
    moved.extend(after.paths.difference(&before.paths).cloned());
    moved.extend(before.paths.difference(&after.paths).cloned());
    moved.remove(target);
    moved.into_iter().collect()
}

async fn seen(run: &CliRunner, config: &AppConfig) -> Seen {
    Seen {
        stamps: stamps(run, config).await,
        paths: listing(run, config).await,
    }
}

/// Changes a note with an agent: the note is read before and after, and the two are given back to be
/// shown and undone, with the other notes that moved.
pub async fn edit_note(
    run: &CliRunner,
    config: &AppConfig,
    harness: Harness,
    session: impl Fn(String) -> Pin<Box<dyn Future<Output = Result<CliResult, String>> + Send>>,
    path: &str,
    description: &str,
    // Whether the run was stopped by the person, which the registry knows and the exit code does not.
    stopped: impl Fn() -> bool,
) -> Result<NoteEdit, HostError> {
    if let Some(problem) = note_path_problem(path) {
        return Err(HostError::bad_request(problem));
    }
    let before = read_note(run, config, path).await?;
    let first = seen(run, config).await;
    let result = session(edit_prompt(path, description, harness))
        .await
        .map_err(HostError::unavailable)?;
    let after = read_note(run, config, path).await?;
    if after == before {
        if stopped() {
            return Err(HostError::unavailable(
                "The run was stopped and the note was not changed.",
            ));
        }
        let why = reason_of(&result.stdout, &result.stderr);
        return Err(HostError::unavailable(
            format!("The note was not changed. {why}")
                .trim()
                .to_string(),
        ));
    }
    let now = seen(run, config).await;
    Ok(NoteEdit {
        before,
        after,
        touched: touched_elsewhere(&first, &now, path),
    })
}

/// The lines of the frontmatter of a note, between its first two lines of `---`.
fn frontmatter_lines(text: &str) -> Vec<&str> {
    let mut lines = text.lines();
    if lines.next().map(str::trim) != Some("---") {
        return vec![];
    }
    lines.take_while(|l| *l != "---").collect()
}

/// Sets the status of a task note: a note that has a task id and a status. It is for a person to ask,
/// from the page, and never for an agent, which does not set DONE; the program writes the one field,
/// as an agent's tools do, and the time it was updated.
pub async fn set_note_status(
    run: &CliRunner,
    config: &AppConfig,
    path: &str,
    status: crate::messages::NoteStatus,
    // Where the program finds the schemas it checks a note against, when it cannot tell.
    content_root: Option<&Path>,
) -> Result<(), HostError> {
    if let Some(problem) = note_path_problem(path) {
        return Err(HostError::bad_request(problem));
    }
    let text = read_note(run, config, path).await?;
    let lines = frontmatter_lines(&text);
    if !lines.iter().any(|l| l.starts_with("task_id:"))
        || !lines.iter().any(|l| l.starts_with("status:"))
    {
        return Err(HostError::bad_request("Only a task note has a status."));
    }
    let set = |key: &str, value: &str| {
        let mut request = CliRun::new(
            CliBinary::Synapse,
            &["frontmatter", "set", path, key, value],
            config.clone(),
        );
        if let Some(root) = content_root {
            request.env.insert(
                "SYNAPSE_CONTENT_ROOT".to_string(),
                root.to_string_lossy().to_string(),
            );
        }
        request
    };
    let done = run
        .run(set("status", status.as_str()))
        .await
        .map_err(HostError::unavailable)?;
    if done.code != 0 {
        return Err(HostError::unavailable(
            format!("The status could not be set: {}", done.stderr.trim())
                .trim()
                .to_string(),
        ));
    }
    let now = run
        .run(CliRun::new(CliBinary::Synapse, &["now"], config.clone()))
        .await
        .map_err(HostError::unavailable)?;
    let stamp = now.stdout.trim();
    if now.code == 0 && !stamp.is_empty() {
        run.run(set("updated", stamp))
            .await
            .map_err(HostError::unavailable)?;
    }
    Ok(())
}

/// Puts the text from before back, when the note is still as the edit left it: a note that was
/// changed again since is not overwritten.
pub async fn restore_note(
    run: &CliRunner,
    config: &AppConfig,
    path: &str,
    before: &str,
    after: &str,
    // Where the program finds the schemas it checks a note against, when it cannot tell.
    content_root: Option<&Path>,
) -> Result<(), HostError> {
    if let Some(problem) = note_path_problem(path) {
        return Err(HostError::bad_request(problem));
    }
    if read_note(run, config, path).await? != after {
        return Err(HostError::conflict(
            "The note was changed again since, so it is not put back.",
        ));
    }
    let mut request = CliRun::new(CliBinary::Synapse, &["vault-write", path], config.clone());
    request.stdin = Some(before.to_string());
    if let Some(root) = content_root {
        request.env.insert(
            "SYNAPSE_CONTENT_ROOT".to_string(),
            root.to_string_lossy().to_string(),
        );
    }
    let result = run.run(request).await.map_err(HostError::unavailable)?;
    if result.code != 0 {
        return Err(HostError::unavailable(
            format!("The note could not be put back: {}", result.stderr.trim())
                .trim()
                .to_string(),
        ));
    }
    Ok(())
}

// These run `/bin/sh`, which Windows does not have.
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn shell(script: &str) -> Command {
        Command {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), script.into()],
            env: BTreeMap::new(),
            stdin: String::new(),
        }
    }

    fn env() -> BTreeMap<String, String> {
        BTreeMap::from([("PATH".to_string(), "/bin:/usr/bin".to_string())])
    }

    #[tokio::test]
    async fn each_complete_non_empty_line_is_handed_over_and_the_whole_text_is_kept() {
        let lines = Arc::new(Mutex::new(Vec::<String>::new()));
        let kept = lines.clone();
        let on_line: OnLine = Arc::new(move |line| kept.lock().unwrap().push(line));
        let result = run_command(
            shell("printf 'a\\n\\nb\\nc'"),
            env(),
            Duration::from_secs(10),
            &std::env::temp_dir(),
            None,
            Some(on_line),
        )
        .await
        .unwrap();
        assert_eq!(*lines.lock().unwrap(), ["a", "b", "c"]);
        assert_eq!(result.code, 0);
        assert_eq!(result.stdout, "a\n\nb\nc");
    }

    #[tokio::test]
    async fn a_stopped_run_ends_with_code_143_and_what_it_had_printed() {
        let (stop, stopped) = oneshot::channel::<()>();
        let stop_once = Arc::new(Mutex::new(Some(stop)));
        let on_line: OnLine = Arc::new(move |_| {
            if let Some(stop) = stop_once.lock().unwrap().take() {
                let _ = stop.send(());
            }
        });
        let started = std::time::Instant::now();
        let result = run_command(
            shell("echo one; sleep 30; echo two"),
            env(),
            Duration::from_secs(60),
            &std::env::temp_dir(),
            Some(stopped),
            Some(on_line),
        )
        .await
        .unwrap();
        assert_eq!(result.code, STOPPED_CODE);
        assert_eq!(result.stdout, "one\n");
        assert!(started.elapsed() < Duration::from_secs(10));
    }

    #[tokio::test]
    async fn a_stop_that_is_dropped_without_being_sent_does_not_end_the_run() {
        let (stop, stopped) = oneshot::channel::<()>();
        drop(stop);
        let result = run_command(
            shell("echo done"),
            env(),
            Duration::from_secs(10),
            &std::env::temp_dir(),
            Some(stopped),
            None,
        )
        .await
        .unwrap();
        assert_eq!((result.code, result.stdout.as_str()), (0, "done\n"));
    }
}
