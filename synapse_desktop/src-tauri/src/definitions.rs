//! Definitions: the text of a pipeline, a system, an agent or a prompt that is not saved yet, looked
//! at by the program, and written to the folders definitions live in.

use crate::cli::{CliRun, CliRunner};
use crate::dispatch::HostError;
use crate::environment::{
    definition_dirs, join_paths, pipeline_config_dir, resolve_inside, Environment,
};
use crate::messages::{
    AppConfig, CliBinary, CliResult, DefinitionDraftKind, DefinitionWriteParams, DraftDefinition,
    NewDefinition, WrittenPath,
};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use tempfile::TempDir;

/// A definition that is not saved yet, and what is needed to ask the program about it.
pub struct SandboxInput<'a> {
    /// The default definition folder, where the draft goes.
    pub default_dir: &'a Path,
    /// The other folders definitions are looked for in.
    pub other_dirs: &'a [PathBuf],
    /// The name of the draft: the file is `<name>.synapse`.
    pub draft: (&'a str, &'a str),
    /// A file that is there for the program to be asked about, when the draft is not itself something
    /// the program can be asked about.
    pub extra: Option<(&'a str, &'a str)>,
}

/// A throwaway copy of the definitions with a draft among them, so that the program, which reads
/// files, can be asked about text that is not saved yet. It is removed when it is dropped.
pub struct Sandbox {
    root: TempDir,
}

impl Sandbox {
    /// The variables that make the program read the copy and not the real files.
    pub fn env(&self, others: &[PathBuf]) -> BTreeMap<String, String> {
        let list: Vec<String> = others
            .iter()
            .map(|p| p.to_string_lossy().to_string())
            .collect();
        BTreeMap::from([
            (
                "XDG_CONFIG_HOME".to_string(),
                self.root.path().join("xdg").to_string_lossy().to_string(),
            ),
            ("SYNAPSE_PIPELINE_PATH".to_string(), join_paths(&list)),
        ])
    }

    pub fn path(&self) -> &Path {
        self.root.path()
    }
}

/// Copies the `.synapse` files directly in `from` into `to`, leaving out the one called `skip`. A
/// folder that is not there has none.
fn copy_definitions(from: &Path, to: &Path, skip: &str) -> std::io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.ends_with(".synapse") || name == skip {
            continue;
        }
        // A link to a file counts as the file.
        if fs::metadata(entry.path()).is_ok_and(|m| m.is_file()) {
            fs::copy(entry.path(), to.join(&name))?;
        }
    }
    Ok(())
}

/// The copy, and the folders of the others that were copied beside it.
pub fn build_sandbox(input: &SandboxInput) -> std::io::Result<(Sandbox, Vec<PathBuf>)> {
    let root = tempfile::Builder::new()
        .prefix("synapse-desktop-draft-")
        .tempdir()?;
    let default_copy = root.path().join("xdg").join("synapse-pipeline");
    let (name, text) = input.draft;
    let draft_file = format!("{name}.synapse");

    // The draft replaces the file of its name in the folder it is saved to.
    copy_definitions(input.default_dir, &default_copy, &draft_file)?;
    fs::write(default_copy.join(&draft_file), text)?;
    if let Some((extra, extra_text)) = input.extra {
        fs::write(default_copy.join(format!("{extra}.synapse")), extra_text)?;
    }

    let mut others = Vec::new();
    for (i, dir) in input.other_dirs.iter().enumerate() {
        let copy = root.path().join(format!("dir{i}"));
        copy_definitions(dir, &copy, "")?;
        others.push(copy);
    }

    Ok((Sandbox { root }, others))
}

fn random_hex(bytes: usize) -> String {
    let mut buffer = vec![0u8; bytes];
    getrandom::fill(&mut buffer).expect("the system gives random bytes");
    buffer.iter().map(|b| format!("{b:02x}")).collect()
}

/// A pipeline is described. A system, an agent or a prompt cannot be, so the program is asked to
/// check a pipeline that uses none of them: it loads every definition, and says in a warning what is wrong with one
/// that does not load.
pub async fn preview_draft(
    draft: &DraftDefinition,
    config: &AppConfig,
    environment: &Environment,
    runner: &CliRunner,
    default_config: AppConfig,
) -> Result<CliResult, HostError> {
    let default_dir = pipeline_config_dir(environment);
    let other_dirs: Vec<PathBuf> = definition_dirs(&config.definition_paths, environment)
        .into_iter()
        .filter(|d| *d != default_dir)
        .collect();

    let probe = (draft.kind != DefinitionDraftKind::Pipeline)
        .then(|| format!("Draft_Probe_{}", random_hex(3)));
    let probe_text = probe
        .as_ref()
        .map(|p| format!("Pipeline {p} {{ Only [Harness => Claude, Prompt => \"probe\"]; }}"));
    let input = SandboxInput {
        default_dir: &default_dir,
        other_dirs: &other_dirs,
        draft: (&draft.name, &draft.text),
        extra: probe.as_deref().zip(probe_text.as_deref()),
    };
    let (sandbox, others) =
        build_sandbox(&input).map_err(|e| HostError::internal(e.to_string()))?;
    let args: Vec<&str> = match &probe {
        None => vec!["show", &draft.name, "--format", "json"],
        Some(probe) => vec!["check", probe],
    };
    let mut run = CliRun::new(CliBinary::SynapsePipeline, &args, default_config);
    // Nothing of the real configuration: the copy is the whole world.
    run.env = sandbox.env(&others);
    // The copy is removed when `sandbox` is dropped, which is after the program has answered.
    runner.run(run).await.map_err(HostError::unavailable)
}

/// The real path of a definition file, only where definitions live: not the records of runs.
fn definition_file(
    path: &str,
    config: &AppConfig,
    environment: &Environment,
    what: &str,
) -> Result<PathBuf, HostError> {
    if !path.ends_with(".synapse") {
        return Err(HostError::bad_request(format!(
            "only a definition can be {what}"
        )));
    }
    let roots = definition_dirs(&config.definition_paths, environment);
    resolve_inside(path, &roots)
}

/// Writes a definition: a new file, never over one that is there, or the text of one that was read,
/// which is refused when the file is no longer as it was read. Or removes one.
pub fn write_definition(
    params: DefinitionWriteParams,
    config: &AppConfig,
    environment: &Environment,
) -> Result<WrittenPath, HostError> {
    let io = |e: std::io::Error| HostError::internal(e.to_string());
    match params {
        DefinitionWriteParams::Replace {
            path,
            previous,
            text,
        } => {
            let real = definition_file(&path, config, environment, "saved")?;
            if fs::read_to_string(&real).map_err(io)? != previous {
                return Err(HostError::conflict(
                    "the file has changed since it was read",
                ));
            }
            fs::write(&real, text).map_err(io)?;
            Ok(WrittenPath { path })
        }
        DefinitionWriteParams::Delete { path } => {
            let real = definition_file(&path, config, environment, "removed")?;
            fs::remove_file(&real).map_err(io)?;
            Ok(WrittenPath { path })
        }
        DefinitionWriteParams::Create { item } => {
            let default_dir = pipeline_config_dir(environment);
            let NewDefinition::Definition { name, text } = item;
            let path = default_dir.join(format!("{name}.synapse"));
            fs::create_dir_all(&default_dir).map_err(io)?;
            // `create_new` fails when the file is there: a definition is never replaced.
            match fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
            {
                Ok(mut file) => file.write_all(text.as_bytes()).map_err(io)?,
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    return Err(HostError::conflict(format!("{name} already exists")));
                }
                Err(e) => return Err(io(e)),
            }
            Ok(WrittenPath {
                path: path.to_string_lossy().to_string(),
            })
        }
    }
}
