//! What the host does for the first families of requests: files, settings, the programs of Synapse,
//! the projects and conventions, and what it says of the machine.

use crate::agents::{
    created_path, edit_note, generate_text, note_prompt, paths_of, reason_of, restore_note,
    set_note_status, vault_dir_of, AgentChoice, AgentRunner, GenerateRequest, NoteSession,
    NoteSessionRun, OnLine,
};
use crate::cli::{refuse_cli, CliRun, CliRunner};
use crate::config::{config_file, load_config, load_stored, merged, save_config};
use crate::definitions::{preview_draft, write_definition};
use crate::dispatch::{Handlers, HostError};
use crate::environment::{
    allowed_roots, definition_dirs, existing_dirs, pipeline_config_dir, resolve_inside, Environment,
};
use crate::graphs::{
    check_graph_repo, clean_graphs, drop_graph, find_graph_repos, graph_health, plan_graph_clean,
    plan_graph_drop, repository_of,
};
use crate::history::{list_sessions, list_workspaces};
use crate::inject::{injected_dir, InjectDeps};
use crate::messages::*;
use crate::models::{model_cache_file, ModelStore, ProgramRunner};
use crate::note_runs::{NoteRunHandle, NoteRuns};
use crate::registries::{
    add_convention, add_project, list_conventions, load_projects, remove_convention, split_project,
    Projects,
};
use crate::runs::{ask_run, socket_path, AskError, RunStarter};
use crate::status::{diagnose, find_content_root, inspect_integrations, LoginPath, VersionOf};
use crate::usage::Usage;
use crate::vault::{inspect_vault, seed_vault};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::sync::oneshot;

const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;

/// What the handlers share: where things are, and how programs are run.
pub struct Context {
    pub environment: Environment,
    pub config_file: PathBuf,
    pub cli: CliRunner,
    pub login_path: LoginPath,
    pub version_of: VersionOf,
    /// The models of the harnesses, kept between runs.
    pub models: ModelStore,
    /// Starts and stops the runs of pipelines.
    pub runs: RunStarter,
    /// Writes the text of a definition from a description.
    pub agent: AgentRunner,
    /// Writes and changes notes of the vault, with Synapse loaded.
    pub note_session: NoteSession,
    /// The runs of an agent on a note, a new note or a definition, which a client can watch and stop.
    pub note_runs: NoteRuns,
    /// The folders the app is bundled with, where its skills and harness files are when no program
    /// on the PATH says.
    pub bundled_roots: Vec<PathBuf>,
    /// The usage of the harnesses, published on the `usage` topic.
    pub usage: Usage,
}

impl Context {
    /// The context of a host that runs on this machine.
    pub fn system(environment: Environment, bundled_roots: Vec<PathBuf>) -> Context {
        let login_path = LoginPath::shell(&environment);
        Context {
            config_file: config_file(&environment),
            cli: CliRunner::system(environment.env.clone()),
            models: ModelStore::system(
                model_cache_file(&environment),
                ProgramRunner::system(),
                environment.clone(),
                login_path.clone(),
            ),
            usage: Usage::system(
                environment.clone(),
                config_file(&environment),
                login_path.clone(),
            ),
            login_path,
            runs: RunStarter::new("synapse-pipeline", environment.env.clone()),
            version_of: VersionOf::program(),
            agent: AgentRunner::system(environment.env.clone()),
            note_session: NoteSession::system(InjectDeps {
                data_dir: injected_dir(&environment),
                bundled_roots: bundled_roots.clone(),
                environment: environment.clone(),
            }),
            note_runs: NoteRuns::new(),
            bundled_roots,
            environment,
        }
    }

    fn config(&self) -> Result<AppConfig, HostError> {
        load_config(&self.config_file, &self.environment)
    }

    fn paths(&self) -> Result<AppPaths, HostError> {
        let config = self.config()?;
        let environment = &self.environment;
        let skills = pipeline_config_dir(environment).join("skills");
        let records: Vec<PathBuf> = config
            .work_dir
            .iter()
            .map(|work_dir| Path::new(work_dir).join("pipelines"))
            .collect();
        Ok(AppPaths {
            definition_dirs: existing_dirs(&definition_dirs(&config.definition_paths, environment)),
            skills_dir: existing_dirs(&[skills]).into_iter().next(),
            records_dir: existing_dirs(&records).into_iter().next(),
        })
    }

    /// The projects, or why they cannot be had, for what shows them.
    async fn projects(&self, config: &AppConfig) -> Projects {
        load_projects(&self.cli, config)
            .await
            .map_err(|e| e.message)
    }

    fn config_answer(&self) -> Result<ConfigAnswer, HostError> {
        Ok(ConfigAnswer {
            config: self.config()?,
            paths: self.paths()?,
        })
    }

    fn inside_roots(&self, path: &str) -> Result<PathBuf, HostError> {
        let config = self.config()?;
        let roots = allowed_roots(
            &config.definition_paths,
            config.work_dir.as_deref(),
            &self.environment,
        );
        resolve_inside(path, &roots)
    }
}

fn io(error: std::io::Error) -> HostError {
    HostError::internal(error.to_string())
}

/// Makes `handlers` answer the first families.
pub fn first_families(handlers: &mut Handlers, context: Arc<Context>) {
    let c = context.clone();
    handlers.on::<PathParams, Text, _, _>("fs.read", move |params| {
        let c = c.clone();
        async move {
            let real = c.inside_roots(&params.path)?;
            let size = tokio::fs::metadata(&real).await.map_err(io)?.len();
            if size > MAX_FILE_BYTES {
                return Err(HostError::new(
                    crate::protocol::ErrorCode::TooLarge,
                    "file is too large",
                ));
            }
            let bytes = tokio::fs::read(&real).await.map_err(io)?;
            Ok(Text {
                text: String::from_utf8_lossy(&bytes).to_string(),
            })
        }
    });

    handlers.on::<ChangesSnapshotParams, SnapshotAnswer, _, _>(
        "changes.snapshot",
        |params| async move {
            let folder = absolute_folder(&params.folder)?;
            let tree = match params.of {
                Some(SnapshotOf::Head) => crate::changes::head_tree(&folder).await?,
                None => crate::changes::snapshot_tree(&folder).await?,
            };
            let head = match tree {
                Some(_) => crate::changes::head_position(&folder).await?,
                None => None,
            };
            Ok(SnapshotAnswer { tree, head })
        },
    );

    handlers.on::<ChangesDiffParams, FolderChanges, _, _>("changes.diff", |params| async move {
        let folder = absolute_folder(&params.folder)?;
        let path = params.path.as_deref();
        match params.after.as_deref() {
            Some(after) => {
                crate::changes::changes_between(&folder, &params.before, after, path).await
            }
            None => crate::changes::changes_since(&folder, &params.before, path).await,
        }
    });

    handlers.on::<ChangesPinParams, (), _, _>("changes.pin", |params| async move {
        let folder = absolute_folder(&params.folder)?;
        crate::changes::pin_snapshot(&folder, &params.reference, &params.tree).await
    });

    handlers.on::<ChangesUnpinParams, (), _, _>("changes.unpin", |params| async move {
        let folder = absolute_folder(&params.folder)?;
        crate::changes::unpin_snapshot(&folder, &params.reference).await
    });

    handlers.on::<ChangesLogParams, CommitLog, _, _>("changes.log", |params| async move {
        let folder = absolute_folder(&params.folder)?;
        crate::changes::commit_log(&folder, params.limit as usize, params.before.as_deref()).await
    });

    handlers.on::<ChangesCommitParams, FolderChanges, _, _>(
        "changes.commit",
        |params| async move {
            let folder = absolute_folder(&params.folder)?;
            crate::changes::commit_changes(&folder, &params.commit, params.path.as_deref()).await
        },
    );

    let c = context.clone();
    handlers.on::<PathParams, Entries, _, _>("fs.list", move |params| {
        let c = c.clone();
        async move {
            let real = c.inside_roots(&params.path)?;
            let mut entries = Vec::new();
            let mut read = tokio::fs::read_dir(&real).await.map_err(io)?;
            while let Some(entry) = read.next_entry().await.map_err(io)? {
                // A link that leads nowhere has no modification time to report.
                let info = tokio::fs::metadata(entry.path()).await.ok();
                entries.push(DirEntry {
                    name: entry.file_name().to_string_lossy().to_string(),
                    is_dir: info.as_ref().is_some_and(|i| i.is_dir()),
                    mtime_ms: info
                        .and_then(|i| i.modified().ok())
                        .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|d| d.as_secs_f64() * 1000.0)
                        .unwrap_or(0.0),
                });
            }
            entries.sort_by(|a, b| {
                a.name
                    .to_lowercase()
                    .cmp(&b.name.to_lowercase())
                    .then_with(|| a.name.cmp(&b.name))
            });
            Ok(Entries { entries })
        }
    });

    let c = context.clone();
    handlers.on::<CliParams, CliResult, _, _>("cli", move |params| {
        let c = c.clone();
        async move {
            if let Some(refusal) = refuse_cli(params.binary, &params.args) {
                return Err(HostError::bad_request(refusal));
            }
            let mut run = CliRun::new(params.binary, &[], c.config()?);
            run.args = params.args;
            run.stdin = params.stdin;
            c.cli.run(run).await.map_err(HostError::unavailable)
        }
    });

    let c = context.clone();
    handlers.on::<Nothing, ConfigAnswer, _, _>("config.get", move |_| {
        let c = c.clone();
        async move { c.config_answer() }
    });

    let c = context.clone();
    handlers.on::<ConfigSet, ConfigAnswer, _, _>("config.set", move |params| {
        let c = c.clone();
        async move {
            let stored = load_stored(&c.config_file)?;
            let config = merged(stored, params.patch, &c.environment.home)?;
            save_config(&c.config_file, &config)?;
            c.config_answer()
        }
    });

    let c = context.clone();
    handlers.on::<RegistryListParams, RegistryAnswer, _, _>("registry.list", move |params| {
        let c = c.clone();
        async move {
            let config = c.config()?;
            Ok(match params.kind {
                RegistryKind::Projects => RegistryAnswer::Projects {
                    list: load_projects(&c.cli, &config).await?,
                },
                RegistryKind::Conventions => RegistryAnswer::Conventions {
                    list: list_conventions(&c.environment, &c.projects(&config).await),
                },
            })
        }
    });

    let c = context.clone();
    handlers.on::<RegistryAddParams, RegistryAnswer, _, _>("registry.add", move |params| {
        let c = c.clone();
        async move {
            let config = c.config()?;
            Ok(match params {
                RegistryAddParams::Projects { name, prefix } => RegistryAnswer::Projects {
                    list: add_project(&c.cli, &config, &name, &prefix).await?,
                },
                // A project is written name=prefix; whether it may be added is for `synapse
                // projects` to say.
                RegistryAddParams::Conventions { id, entry } if id == "projects" => {
                    let (name, prefix) = split_project(&entry)
                        .ok_or_else(|| HostError::conflict("A project is written name=prefix."))?;
                    add_project(&c.cli, &config, name, prefix).await?;
                    RegistryAnswer::Conventions {
                        list: list_conventions(&c.environment, &c.projects(&config).await),
                    }
                }
                RegistryAddParams::Conventions { id, entry } => RegistryAnswer::Conventions {
                    list: add_convention(&c.environment, &c.projects(&config).await, &id, &entry)?,
                },
            })
        }
    });

    let c = context.clone();
    handlers.on::<RegistryRemoveParams, ConventionsAnswer, _, _>(
        "registry.remove",
        move |params| {
            let c = c.clone();
            async move {
                if params.kind != RegistryKind::Conventions {
                    return Err(HostError::bad_request("only a convention is taken out"));
                }
                let config = c.config()?;
                Ok(ConventionsAnswer {
                    kind: params.kind,
                    list: remove_convention(
                        &c.environment,
                        &c.projects(&config).await,
                        &params.id,
                        &params.entry,
                    )?,
                })
            }
        },
    );

    let c = context.clone();
    handlers.on::<Nothing, Diagnosis, _, _>("diagnose", move |_| {
        let c = c.clone();
        async move { diagnose(c.config()?, &c.cli, &c.login_path, &c.environment).await }
    });

    let c = context;
    handlers.on::<Nothing, Integrations, _, _>("integrations", move |_| {
        let c = c.clone();
        async move {
            // The programs the app runs are looked for as it runs them: with its own settings over
            // the variables it was started with.
            let config = c.config()?;
            let environment = Environment {
                env: crate::cli::cli_environment(&c.environment.env, &config),
                home: c.environment.home.clone(),
            };
            Ok(inspect_integrations(&environment, &c.version_of, &c.bundled_roots).await)
        }
    });
}

/// Makes `handlers` answer what the harnesses know: their models, and the sessions and folders they
/// remember.
pub fn next_families(handlers: &mut Handlers, context: Arc<Context>) {
    let c = context.clone();
    handlers.on::<ModelsParams, ModelCatalog, _, _>("models.get", move |params| {
        let c = c.clone();
        async move {
            Ok(if params.refresh == Some(true) {
                c.models.refresh(params.harness).await
            } else {
                c.models.list(params.harness).await
            })
        }
    });

    let c = context.clone();
    handlers.on::<PreviewParams, CliResult, _, _>("definition.preview", move |params| {
        let c = c.clone();
        async move {
            let config = c.config()?;
            // Nothing of the real configuration: the copy is the whole world.
            let nothing = AppConfig {
                work_dir: None,
                definition_paths: vec![],
                default_harness: None,
                default_models: Default::default(),
                env: Default::default(),
                recent_vaults: vec![],
                terminal_folder: None,
                graph_repos: Default::default(),
            };
            preview_draft(&params.draft, &config, &c.environment, &c.cli, nothing).await
        }
    });

    let c = context.clone();
    handlers.on::<DefinitionWriteParams, WrittenPath, _, _>("definition.write", move |params| {
        let c = c.clone();
        async move { write_definition(params, &c.config()?, &c.environment) }
    });

    let c = context;
    handlers.on::<HistoryParams, HistoryAnswer, _, _>("history.get", move |params| {
        let environment = c.environment.clone();
        async move {
            // The files are read on a thread of their own, as some are large.
            tokio::task::spawn_blocking(move || match params.what {
                HistoryKind::Sessions => HistoryAnswer::Sessions {
                    sessions: list_sessions(&environment),
                },
                HistoryKind::Workspaces => HistoryAnswer::Workspaces {
                    workspaces: list_workspaces(&environment),
                },
            })
            .await
            .map_err(|e| HostError::internal(e.to_string()))
        }
    });
}

/// How a note session is reached for one request: the harness and model it is for, the environment
/// the programs run in and the folders it may write in. It is refused when there is no vault to write
/// in.
async fn note_session_of(
    context: &Context,
    config: &AppConfig,
    harness: Harness,
    model: Option<String>,
    stop: Option<oneshot::Receiver<()>>,
    on_line: Option<OnLine>,
    stream: bool,
) -> Result<
    impl Fn(
        String,
    )
        -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<CliResult, String>> + Send>>,
    HostError,
> {
    let settings = context
        .cli
        .run(CliRun::new(
            CliBinary::Synapse,
            &["config", "list", "--format", "json"],
            config.clone(),
        ))
        .await
        .map_err(HostError::unavailable)?;
    let vault = vault_dir_of(&settings.stdout)
        .ok_or_else(|| HostError::conflict("no vault is set up to write the note in"))?;
    let env = crate::cli::cli_environment(&context.environment.env, config);
    let home = &context.environment.home;
    let work = config.work_dir.clone().unwrap_or_else(|| {
        home.join(".cache/synapse/work")
            .to_string_lossy()
            .to_string()
    });
    let writable = existing_dirs(&[
        PathBuf::from(&vault),
        home.join(".config/synapse"),
        PathBuf::from(work),
    ]);
    let session = context.note_session.clone();
    // The session is run once, and a stop signal can be taken only once.
    let stop = Mutex::new(stop);
    Ok(move |prompt: String| {
        let session = session.clone();
        let run = NoteSessionRun {
            harness,
            prompt,
            model: model.clone(),
            env: env.clone(),
            writable: writable.clone(),
            stop: stop.lock().unwrap().take(),
            on_line: on_line.clone(),
            stream,
        };
        Box::pin(async move { session.run(run).await })
            as std::pin::Pin<
                Box<dyn std::future::Future<Output = Result<CliResult, String>> + Send>,
            >
    })
}

/// A note written by an agent: the path of the one the session made.
async fn create_note(
    context: &Context,
    config: &AppConfig,
    request: &AgentRunParams,
    stop: Option<oneshot::Receiver<()>>,
    stopped: impl Fn() -> bool,
) -> Result<String, HostError> {
    let AgentRunParams::Note {
        what,
        prompt,
        harness,
        model,
        project,
        ..
    } = request
    else {
        return Err(HostError::bad_request("not a note"));
    };
    let harness = harness
        .or(config.default_harness)
        .unwrap_or(Harness::Claude);
    let model = model
        .clone()
        .or_else(|| config.default_models.get(&harness).cloned());
    let session = note_session_of(context, config, harness, model, stop, None, false).await?;
    // A task or design note belongs to a project, which a request names or the agent matches from the
    // ones there are.
    let projects = load_projects(&context.cli, config).await?.projects;
    let chosen = match project {
        None => None,
        Some(name) => Some(projects.iter().find(|p| &p.name == name).ok_or_else(|| {
            HostError::conflict(format!("{name} is not a project in synapse-projects.conf"))
        })?),
    };
    let list = || async {
        let result = context
            .cli
            .run(CliRun::new(
                CliBinary::Synapse,
                &["vault-list"],
                config.clone(),
            ))
            .await
            .map_err(HostError::unavailable)?;
        if result.code != 0 {
            let why = result.stderr.trim();
            return Err(HostError::unavailable(if why.is_empty() {
                "the vault could not be listed"
            } else {
                why
            }));
        }
        Ok(paths_of(&result.stdout))
    };
    let before: std::collections::BTreeSet<String> = list().await?.into_iter().collect();
    let run = session(note_prompt(*what, prompt, harness, &projects, chosen))
        .await
        .map_err(HostError::unavailable)?;
    if let Some(path) = created_path(&run.stdout, &before, &list().await?) {
        return Ok(path);
    }
    if stopped() {
        return Err(HostError::unavailable(
            "The run was stopped. No note was written.",
        ));
    }
    let why = reason_of(&run.stdout, &run.stderr);
    Err(HostError::unavailable(
        format!("No note was written. {why}").trim().to_string(),
    ))
}

/// The id the client gave the run, when it gave one.
fn run_of(request: &AgentRunParams) -> Option<&str> {
    match request {
        AgentRunParams::Definition { run, .. }
        | AgentRunParams::Note { run, .. }
        | AgentRunParams::NoteEdit { run, .. } => run.as_deref(),
    }
}

/// What an agent run does for one request. `handle` is the run's entry in the registry, when the client
/// gave an id: it says when the person stopped the run and takes the lines of a streaming session.
async fn run_agent(
    c: &Context,
    config: &AppConfig,
    request: &AgentRunParams,
    handle: Option<&Arc<NoteRunHandle>>,
    stop: Option<oneshot::Receiver<()>>,
) -> Result<AgentRunAnswer, HostError> {
    let stopped = || handle.is_some_and(|h| h.stopped());
    match request {
        AgentRunParams::Definition {
            what,
            prompt,
            harness,
            model,
            current,
            definitions,
            skills,
            ..
        } => {
            let harness = harness
                .or(config.default_harness)
                .unwrap_or(Harness::Claude);
            let model = model
                .clone()
                .or_else(|| config.default_models.get(&harness).cloned());
            let generate = GenerateRequest {
                kind: *what,
                prompt,
                current: current.as_deref(),
                definitions,
                skills,
            };
            let text = generate_text(
                &generate,
                &c.environment,
                &c.bundled_roots,
                &c.agent,
                AgentChoice {
                    harness,
                    model,
                    env: config.env.clone(),
                },
                stop,
                stopped,
            )
            .await?;
            Ok(AgentRunAnswer::Definition { text })
        }
        AgentRunParams::Note { .. } => Ok(AgentRunAnswer::Note {
            path: create_note(c, config, request, stop, stopped).await?,
        }),
        AgentRunParams::NoteEdit {
            path,
            prompt,
            harness,
            model,
            ..
        } => {
            let harness = harness
                .or(config.default_harness)
                .unwrap_or(Harness::Claude);
            let model = model
                .clone()
                .or_else(|| config.default_models.get(&harness).cloned());
            // Only a Claude edit prints its events, which the page reads as actions.
            let streaming = harness == Harness::Claude && handle.is_some();
            let on_line: Option<OnLine> = match handle {
                Some(h) if streaming => {
                    let h = h.clone();
                    Some(Arc::new(move |line| h.publish(line)))
                }
                _ => None,
            };
            let session =
                note_session_of(c, config, harness, model, stop, on_line, streaming).await?;
            let edit = edit_note(&c.cli, config, harness, session, path, prompt, stopped).await?;
            Ok(AgentRunAnswer::NoteEdit { edit })
        }
    }
}

/// Makes `handlers` answer what an agent writes: a definition, a note, a change to a note.
pub fn agent_families(handlers: &mut Handlers, context: Arc<Context>) {
    let c = context.clone();
    handlers.on::<AgentRunParams, AgentRunAnswer, _, _>("agent.run", move |request| {
        let c = c.clone();
        async move {
            let config = c.config()?;
            let mut handle = match run_of(&request) {
                Some(id) => Some(c.note_runs.start(id)?),
                None => None,
            };
            let stop = handle.as_mut().and_then(|h| h.stop.take());
            let handle = handle.map(Arc::new);
            let answer = run_agent(&c, &config, &request, handle.as_ref(), stop).await;
            // The session and its closures are gone by now, so this is the only holder.
            if let Some(handle) = handle.and_then(|h| Arc::try_unwrap(h).ok()) {
                handle.finish();
            }
            answer
        }
    });

    let c = context.clone();
    handlers.on::<StopRunParams, (), _, _>("agent.stop", move |params| {
        let c = c.clone();
        async move {
            c.note_runs.stop(&params.run);
            Ok(())
        }
    });

    let c = context.clone();
    handlers.on::<NoteStatusParams, (), _, _>("note.status", move |params| {
        let c = c.clone();
        async move {
            let config = c.config()?;
            // The note is checked against the vault's schemas, which are in the Synapse package.
            let environment = Environment {
                env: crate::cli::cli_environment(&c.environment.env, &config),
                home: c.environment.home.clone(),
            };
            let content_root = find_content_root(&environment, &c.bundled_roots);
            set_note_status(
                &c.cli,
                &config,
                &params.path,
                params.status,
                content_root.as_deref(),
            )
            .await
        }
    });

    let c = context;
    handlers.on::<NoteRestoreParams, (), _, _>("note.restore", move |params| {
        let c = c.clone();
        async move {
            let config = c.config()?;
            // The note is checked against the vault's schemas, which are in the Synapse package.
            let environment = Environment {
                env: crate::cli::cli_environment(&c.environment.env, &config),
                home: c.environment.home.clone(),
            };
            let content_root = find_content_root(&environment, &c.bundled_roots);
            restore_note(
                &c.cli,
                &config,
                &params.path,
                &params.before,
                &params.after,
                content_root.as_deref(),
            )
            .await
        }
    });
}

/// The folder the page names for the changes in it: absolute, as the working folder of a terminal is.
fn absolute_folder(folder: &str) -> Result<PathBuf, HostError> {
    let path = PathBuf::from(folder);
    if !path.is_absolute() {
        return Err(HostError::bad_request("the folder must be absolute"));
    }
    Ok(path)
}

/// A path a person typed for a folder: `~` is the home folder, and it must be absolute.
fn typed_folder(path: &str, home: &Path) -> Result<String, HostError> {
    let path = crate::environment::expand_home(path, home);
    if !Path::new(&path).is_absolute() {
        return Err(HostError::bad_request("the path must be absolute"));
    }
    Ok(path)
}

/// Makes `handlers` answer runs, the folders of vaults and the code graphs.
pub fn last_families(handlers: &mut Handlers, context: Arc<Context>) {
    let c = context.clone();
    handlers.on::<RunStartParams, ExecutionId, _, _>("run.start", move |params| {
        let c = c.clone();
        async move {
            let config = c.config()?;
            let folder = params.folder.as_deref();
            // A folder that is not there is the caller's mistake, not the host's.
            c.runs
                .folder(folder)
                .map_err(|error| HostError::bad_request(error.0))?;
            match c
                .runs
                .start(
                    &params.pipeline,
                    &params.input,
                    &config,
                    folder,
                    params.run_name.as_deref(),
                )
                .await
            {
                Ok(execution_id) => Ok(ExecutionId { execution_id }),
                Err(error) if config.work_dir.is_none() => Err(HostError::conflict(error.0)),
                Err(error) => Err(HostError::unavailable(error.0)),
            }
        }
    });

    let c = context.clone();
    handlers.on::<ExecutionIdParams, (), _, _>("run.stop", move |params| {
        let c = c.clone();
        async move {
            c.runs
                .stop(&params.execution_id)
                .map_err(|_| HostError::not_found("this run was not started by this app"))
        }
    });

    let c = context.clone();
    handlers.on::<RunAskParams, RunAnswer, _, _>("run.ask", move |params| {
        let c = c.clone();
        async move {
            let work_dir = c
                .config()?
                .work_dir
                .ok_or_else(|| HostError::conflict("no work directory is set"))?;
            let path = socket_path(
                &Path::new(&work_dir).join("pipelines"),
                &params.execution_id,
                cfg!(windows),
            );
            match ask_run(&path, &params.request).await {
                Ok(answer) => Ok(answer),
                Err(AskError::NotListening(_)) => {
                    Err(HostError::not_found("the run is not listening"))
                }
                Err(AskError::Unreadable(why)) => Err(HostError::internal(why)),
            }
        }
    });

    let c = context.clone();
    handlers.on::<VaultPathParams, VaultInfo, _, _>("vault.inspect", move |params| {
        let c = c.clone();
        async move {
            let path = typed_folder(&params.path, &c.environment.home)?;
            tokio::task::spawn_blocking(move || inspect_vault(&path))
                .await
                .map_err(|e| HostError::internal(e.to_string()))
        }
    });

    let c = context.clone();
    handlers.on::<VaultPathParams, VaultInfo, _, _>("vault.seed", move |params| {
        let c = c.clone();
        async move {
            let path = typed_folder(&params.path, &c.environment.home)?;
            let config = c.config()?;
            let environment = Environment {
                env: crate::cli::cli_environment(&c.environment.env, &config),
                home: c.environment.home.clone(),
            };
            let template = find_content_root(&environment, &c.bundled_roots)
                .map(|root| root.join("Index.md.template"));
            tokio::task::spawn_blocking(move || {
                seed_vault(&path, template.as_deref())?;
                Ok(inspect_vault(&path))
            })
            .await
            .map_err(|e| HostError::internal(e.to_string()))?
        }
    });

    let c = context.clone();
    handlers.on::<GraphRepoParams, GraphRepoAnswer, _, _>("graph.repo", move |params| {
        let c = c.clone();
        async move {
            let config = c.config()?;
            Ok(match params {
                GraphRepoParams::Check { path } => GraphRepoAnswer::Check {
                    check: check_graph_repo(
                        &c.cli,
                        &config,
                        &crate::environment::expand_home(&path, &c.environment.home),
                    )
                    .await,
                },
                GraphRepoParams::Find { namespace } => GraphRepoAnswer::Find {
                    matches: GraphRepoMatches {
                        paths: find_graph_repos(&c.cli, &config, &namespace).await,
                    },
                },
            })
        }
    });

    let c = context.clone();
    handlers.on::<NamespaceParams, GraphHealth, _, _>("graph.health", move |params| {
        let c = c.clone();
        async move {
            let config = c.config()?;
            let repo = repository_of(&config, &params.namespace)?;
            Ok(graph_health(&c.cli, &config, &params.namespace, &repo).await)
        }
    });

    let c = context;
    handlers.on::<GraphManageParams, GraphManageAnswer, _, _>("graph.manage", move |params| {
        let c = c.clone();
        async move {
            let config = c.config()?;
            let namespace = &params.namespace;
            Ok(match (params.action, params.what) {
                (GraphAction::Plan, GraphWhat::Drop) => GraphManageAnswer::Plan {
                    plan: plan_graph_drop(&c.cli, &config, namespace).await?,
                },
                (GraphAction::Plan, GraphWhat::Clean) => GraphManageAnswer::Plan {
                    plan: plan_graph_clean(&c.cli, &config, namespace).await?,
                },
                (GraphAction::Apply, GraphWhat::Drop) => GraphManageAnswer::Apply {
                    output: drop_graph(&c.cli, &config, namespace).await?,
                },
                (GraphAction::Apply, GraphWhat::Clean) => GraphManageAnswer::Apply {
                    output: clean_graphs(&c.cli, &config, namespace).await?,
                },
            })
        }
    });
}
