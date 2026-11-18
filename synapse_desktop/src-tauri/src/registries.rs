//! The lists Synapse keeps in the user's configuration directory: the projects the vault's notes belong
//! to, and the conventions (tag vocabulary, stopwords, the rules of the code graph). An agent writes
//! most of them, and a person can add to them or take an entry out. A file of lines can be changed here;
//! a file of JSON is shown as it is.

use crate::cli::{CliRun, CliRunner};
use crate::dispatch::HostError;
use crate::environment::{conf_file, Environment};
use crate::messages::{
    AppConfig, CliBinary, Convention, ConventionEntry, ConventionGroup, ConventionList, Project,
    ProjectList,
};
use serde_json::Value;
use std::path::PathBuf;

/// The projects and the file they are in, as `synapse projects` says them. A program that cannot be
/// asked is told as its message, to show in place of the projects.
pub type Projects = Result<ProjectList, String>;

/// What the program says when it is refused, without its own name in front of it.
fn reason_of(stderr: &str, stdout: &str) -> String {
    let text = if stderr.is_empty() { stdout } else { stderr }.trim();
    let text = text.strip_prefix("synapse-projects: ").unwrap_or(text);
    if text.is_empty() {
        "synapse projects failed".into()
    } else {
        text.into()
    }
}

/// The projects there are, and the file they are in (the one that would be made, when there is
/// none). `synapse projects` finds the file, reads it and checks what is added to it, as it does for
/// the skills that use the same file.
pub async fn load_projects(
    runner: &CliRunner,
    config: &AppConfig,
) -> Result<ProjectList, HostError> {
    let run = CliRun::new(
        CliBinary::Synapse,
        &["projects", "--format", "json"],
        config.clone(),
    );
    let result = runner.run(run).await.map_err(HostError::unavailable)?;
    if result.code != 0 {
        return Err(HostError::unavailable(reason_of(
            &result.stderr,
            &result.stdout,
        )));
    }
    let json: Value = serde_json::from_str(&result.stdout).map_err(|_| {
        HostError::unavailable("synapse projects printed something this app does not know")
    })?;
    let format_known = json.get("format").and_then(Value::as_str) == Some("synapse-projects/v1");
    let projects: Option<Vec<Project>> =
        serde_json::from_value(json.get("projects").cloned().unwrap_or_default()).ok();
    match (format_known, projects) {
        (true, Some(projects)) => Ok(ProjectList {
            projects,
            file: json
                .get("file")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        }),
        _ => Err(HostError::unavailable(
            "synapse projects answered in a format this app does not know",
        )),
    }
}

/// Adds one pair, which the program checks first, and answers with the projects there are now.
pub async fn add_project(
    runner: &CliRunner,
    config: &AppConfig,
    name: &str,
    prefix: &str,
) -> Result<ProjectList, HostError> {
    let run = CliRun::new(
        CliBinary::Synapse,
        &["projects", "add", name, prefix],
        config.clone(),
    );
    let result = runner.run(run).await.map_err(HostError::unavailable)?;
    if result.code != 0 {
        return Err(HostError::conflict(reason_of(
            &result.stderr,
            &result.stdout,
        )));
    }
    load_projects(runner, config).await
}

fn appended(file: &PathBuf, before: &str, line: &str) -> Result<(), HostError> {
    let internal = |e: std::io::Error| HostError::internal(e.to_string());
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir).map_err(internal)?;
    }
    let separator = if before.is_empty() || before.ends_with('\n') {
        ""
    } else {
        "\n"
    };
    std::fs::write(file, format!("{before}{separator}{line}\n")).map_err(internal)
}

// ---------------------------------------------------------------------------------------------
// The conventions
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Lines,
    Projects,
    Json,
}

struct Definition {
    id: &'static str,
    group: ConventionGroup,
    title: &'static str,
    about: &'static str,
    file: &'static str,
    kind: Kind,
}

fn definitions() -> Vec<Definition> {
    use ConventionGroup::{CodeGraph, Prompts, Vault};
    use Kind::{Json, Lines, Projects};
    let d = |id, group, title, about, file, kind| Definition {
        id,
        group,
        title,
        about,
        file,
        kind,
    };
    vec![
        d("projects", Vault, "Projects", "The folder and the id prefix of each project’s notes, one name=prefix to a line. A person makes them; a note session never does.", "synapse-projects.conf", Projects),
        d("tags", Vault, "Tag vocabulary", "The tags a note may take, one to a line.", "synapse-tag-vocabulary.conf", Lines),
        d("grammars", CodeGraph, "Grammars", "Which grammar serves each file extension, and where it comes from.", "synapse-grammars.conf", Json),
        d("namespace-rules", CodeGraph, "Namespace rules", "How the namespace a file declares is found, by file extension.", "synapse-namespace-rules.conf", Json),
        d("dependency-rules", CodeGraph, "Dependency rules", "How what a file depends on is found, by file extension.", "synapse-dependency-rules.conf", Json),
        d("kind-synonyms", CodeGraph, "Kind synonyms", "How a grammar’s own name for a kind of symbol maps onto Synapse’s. Tried from the top; the first match wins.", "synapse-kind-synonyms.conf", Json),
        d("fence-languages", CodeGraph, "Fence languages", "The language a code block in a node gets, by file extension.", "synapse-fence-languages.conf", Json),
        d("module-boilerplate", CodeGraph, "Module boilerplate", "Path segments that are not part of a module’s name, such as a source root, one chain to a line.", "synapse-module-boilerplate.conf", Lines),
        d("ignore-files", CodeGraph, "Ignored files", "Extra path patterns left out when the graph is built, one to a line.", "synapse-ignore-files.conf", Lines),
        d("comment-style-rules", CodeGraph, "Comment style rules", "How comments are to be written in this code, for the agent to follow.", "synapse-comment-style-rules.conf", Lines),
        d("stopwords", Prompts, "Prompt stopwords", "Words dropped when a prompt is turned into a search, one to a line.", "synapse-prompt-stopwords.conf", Lines),
    ]
}

/// The entries of a file of lines: what is not blank and not a comment, trimmed.
pub fn parse_lines(text: &str) -> Vec<String> {
    text.split('\n')
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(String::from)
        .collect()
}

fn one_line(value: &Value) -> String {
    value.to_string()
}

/// The entries of a file of JSON: for an object each key with its value, for a list each rule in
/// order. The text of the problem when it is not JSON, or is another shape.
pub fn parse_json(text: &str) -> Result<Vec<ConventionEntry>, String> {
    if text.trim().is_empty() {
        return Ok(vec![]);
    }
    let value: Value = serde_json::from_str(text).map_err(|e| format!("It is not JSON: {e}"))?;
    match value {
        Value::Array(items) => Ok(items
            .iter()
            .enumerate()
            .map(|(index, item)| ConventionEntry {
                text: (index + 1).to_string(),
                detail: Some(one_line(item)),
            })
            .collect()),
        Value::Object(map) => Ok(map
            .iter()
            .map(|(key, item)| ConventionEntry {
                text: key.clone(),
                detail: Some(one_line(item)),
            })
            .collect()),
        _ => Err("It is neither an object nor a list.".into()),
    }
}

fn describe(environment: &Environment, projects: &Projects, definition: &Definition) -> Convention {
    let mut file = conf_file(environment, definition.file);
    if definition.kind == Kind::Projects {
        if let Ok(held) = projects {
            file = PathBuf::from(&held.file);
        }
    }
    let text = std::fs::read_to_string(&file).ok();
    let base = Convention {
        id: definition.id.into(),
        group: definition.group.clone(),
        title: definition.title.into(),
        about: definition.about.into(),
        file: file.to_string_lossy().to_string(),
        exists: text.is_some(),
        editable: definition.kind != Kind::Json,
        entries: vec![],
        problem: None,
    };
    if definition.kind == Kind::Projects {
        return match projects {
            Ok(held) => Convention {
                entries: held
                    .projects
                    .iter()
                    .map(|p| ConventionEntry {
                        text: format!("{}={}", p.name, p.prefix),
                        detail: None,
                    })
                    .collect(),
                ..base
            },
            Err(problem) => Convention {
                problem: Some(problem.clone()),
                ..base
            },
        };
    }
    let Some(text) = text else { return base };
    match definition.kind {
        Kind::Json => match parse_json(&text) {
            Ok(entries) => Convention { entries, ..base },
            Err(problem) => Convention {
                problem: Some(problem),
                ..base
            },
        },
        _ => Convention {
            entries: parse_lines(&text)
                .into_iter()
                .map(|text| ConventionEntry { text, detail: None })
                .collect(),
            ..base
        },
    }
}

pub fn list_conventions(environment: &Environment, projects: &Projects) -> ConventionList {
    ConventionList {
        conventions: definitions()
            .iter()
            .map(|d| describe(environment, projects, d))
            .collect(),
    }
}

fn definition_for(id: &str) -> Result<Definition, HostError> {
    let found = definitions()
        .into_iter()
        .find(|d| d.id == id)
        .ok_or_else(|| HostError::not_found(format!("There is no file called {id}.")))?;
    if found.kind == Kind::Json {
        return Err(HostError::conflict(format!(
            "{} is changed in its file, not here.",
            found.title
        )));
    }
    Ok(found)
}

/// What is wrong with a line to add, or none.
fn refusal_of(entry: &str, known: &[String]) -> Option<String> {
    if entry.is_empty() || entry.contains('\n') || entry.contains('\r') {
        return Some("An entry is one line of text.".into());
    }
    if entry.starts_with('#') {
        return Some("An entry that starts with # would be a comment.".into());
    }
    if known.iter().any(|k| k == entry) {
        return Some(format!("{entry} is already there."));
    }
    None
}

/// The pair of a project written `name=prefix`, split at the first `=`.
pub fn split_project(entry: &str) -> Option<(&str, &str)> {
    let entry = entry.trim();
    let at = entry.find('=').filter(|at| *at > 0)?;
    Some((entry[..at].trim(), entry[at + 1..].trim()))
}

/// Adds a line to a file of lines. The projects are not one: they are added through `add_project`.
pub fn add_convention(
    environment: &Environment,
    projects: &Projects,
    id: &str,
    raw_entry: &str,
) -> Result<ConventionList, HostError> {
    let definition = definition_for(id)?;
    let entry = raw_entry.trim();
    let file = conf_file(environment, definition.file);
    let before = std::fs::read_to_string(&file).unwrap_or_default();
    if let Some(refusal) = refusal_of(entry, &parse_lines(&before)) {
        return Err(HostError::conflict(refusal));
    }
    appended(&file, &before, entry)?;
    Ok(list_conventions(environment, projects))
}

/// Takes the first line that is the entry out of the file, and leaves every other line, the comments
/// among them, as it was. The projects are in the file `synapse projects` names.
pub fn remove_convention(
    environment: &Environment,
    projects: &Projects,
    id: &str,
    raw_entry: &str,
) -> Result<ConventionList, HostError> {
    let definition = definition_for(id)?;
    let entry = raw_entry.trim();
    let file = match (definition.kind, projects) {
        (Kind::Projects, Ok(held)) => PathBuf::from(&held.file),
        (Kind::Projects, Err(problem)) => return Err(HostError::unavailable(problem.clone())),
        _ => conf_file(environment, definition.file),
    };
    let before = std::fs::read_to_string(&file).ok();
    let mut lines: Vec<String> = before
        .as_deref()
        .unwrap_or("")
        .split('\n')
        .map(String::from)
        .collect();
    let at = lines
        .iter()
        .position(|line| line.trim() == entry && !line.trim().starts_with('#'));
    let (Some(_), Some(at)) = (&before, at) else {
        return Err(HostError::not_found(format!(
            "{entry} is not in {}.",
            definition.file
        )));
    };
    lines.remove(at);
    std::fs::write(&file, lines.join("\n")).map_err(|e| HostError::internal(e.to_string()))?;
    Ok(list_conventions(environment, projects))
}
