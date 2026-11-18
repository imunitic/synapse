//! The app's own settings, kept in one JSON file.

use crate::dispatch::HostError;
use crate::environment::{expand_home, Environment};
use crate::messages::{AppConfig, AppConfigPatch, Harness};
use regex::Regex;
use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// `$XDG_CONFIG_HOME/synapse-desktop/config.json`, or `~/.config/synapse-desktop/config.json`.
pub fn config_file(environment: &Environment) -> PathBuf {
    environment
        .config_base()
        .join("synapse-desktop")
        .join("config.json")
}

fn default_config() -> AppConfig {
    AppConfig {
        work_dir: None,
        definition_paths: vec![],
        default_harness: None,
        default_models: BTreeMap::new(),
        env: BTreeMap::new(),
        recent_vaults: vec![],
        terminal_folder: None,
        graph_repos: BTreeMap::new(),
    }
}

/// The file as it is read: one written before a setting existed has its default.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stored {
    work_dir: Option<String>,
    definition_paths: Vec<String>,
    default_harness: Option<Harness>,
    #[serde(default)]
    default_models: BTreeMap<Harness, String>,
    #[serde(default)]
    env: BTreeMap<String, String>,
    #[serde(default)]
    recent_vaults: Vec<String>,
    #[serde(default)]
    terminal_folder: Option<String>,
    #[serde(default)]
    graph_repos: BTreeMap<String, String>,
}

/// What the file says. A missing file is the default configuration; a file that does not parse is an
/// error.
pub fn load_stored(file: &Path) -> Result<AppConfig, HostError> {
    let text = match std::fs::read_to_string(file) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(default_config()),
        Err(error) => return Err(HostError::internal(error.to_string())),
    };
    let stored: Stored =
        serde_json::from_str(&text).map_err(|e| HostError::internal(e.to_string()))?;
    Ok(AppConfig {
        work_dir: stored.work_dir,
        definition_paths: stored.definition_paths,
        default_harness: stored.default_harness,
        default_models: stored.default_models,
        env: stored.env,
        recent_vaults: stored.recent_vaults,
        terminal_folder: stored.terminal_folder,
        graph_repos: stored.graph_repos,
    })
}

/// Where Synapse keeps its working files when nothing names a place: the same `.cache/synapse/work`
/// in the home folder that `synapse` and `synapse-pipeline` use.
pub fn default_work_dir(environment: &Environment) -> Option<String> {
    if environment.home.as_os_str().is_empty() {
        return None;
    }
    Some(
        environment
            .home
            .join(".cache")
            .join("synapse")
            .join("work")
            .to_string_lossy()
            .to_string(),
    )
}

/// The settings that hold a folder, with `~` in them expanded.
pub fn expand_config_paths(config: AppConfig, home: &Path) -> AppConfig {
    AppConfig {
        work_dir: config.work_dir.map(|p| expand_home(&p, home)),
        definition_paths: config
            .definition_paths
            .iter()
            .map(|p| expand_home(p, home))
            .collect(),
        terminal_folder: config.terminal_folder.map(|p| expand_home(&p, home)),
        graph_repos: config
            .graph_repos
            .into_iter()
            .map(|(key, path)| (key, expand_home(&path, home)))
            .collect(),
        ..config
    }
}

/// The configuration in force. The work directory is `SYNAPSE_WORK_DIR` when the app sets it for its
/// programs or the host was started with it, else the one saved, else the default.
pub fn load_config(file: &Path, environment: &Environment) -> Result<AppConfig, HostError> {
    let mut config = expand_config_paths(load_stored(file)?, &environment.home);
    let named = config
        .env
        .get("SYNAPSE_WORK_DIR")
        .filter(|v| !v.is_empty())
        .cloned()
        .or_else(|| environment.var("SYNAPSE_WORK_DIR").map(String::from));
    config.work_dir = named
        .or_else(|| config.work_dir.clone().filter(|v| !v.is_empty()))
        .or_else(|| default_work_dir(environment));
    Ok(config)
}

/// Written beside the file and renamed over it, so a reader never sees half of it.
pub fn save_config(file: &Path, config: &AppConfig) -> Result<(), HostError> {
    let internal = |e: std::io::Error| HostError::internal(e.to_string());
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir).map_err(internal)?;
    }
    let temporary = PathBuf::from(format!("{}.tmp", file.display()));
    let text =
        serde_json::to_string_pretty(config).map_err(|e| HostError::internal(e.to_string()))?;
    std::fs::write(&temporary, text + "\n").map_err(internal)?;
    std::fs::rename(&temporary, file).map_err(internal)
}

fn matches(cell: &'static OnceLock<Regex>, pattern: &str, text: &str) -> bool {
    cell.get_or_init(|| Regex::new(pattern).unwrap())
        .is_match(text)
}

/// A variable's name: the form every shell takes.
pub fn is_env_name(name: &str) -> bool {
    static CELL: OnceLock<Regex> = OnceLock::new();
    name.len() <= 128 && matches(&CELL, r"^[A-Za-z_][A-Za-z0-9_]*$", name)
}

/// A model as a harness is given it on its command line.
pub fn is_model_name(name: &str) -> bool {
    static CELL: OnceLock<Regex> = OnceLock::new();
    matches(&CELL, r"^[A-Za-z0-9][A-Za-z0-9._:/@+~\[\]-]{0,199}$", name)
}

/// `<repo>@<branch>`: a folder's name, with no separator and no dots alone.
pub fn is_namespace(name: &str) -> bool {
    static CELL: OnceLock<Regex> = OnceLock::new();
    matches(
        &CELL,
        r"^[A-Za-z0-9._+-]{1,128}@[A-Za-z0-9._+-]{1,128}$",
        name,
    )
}

/// A definition's name is its file's name: an identifier.
pub fn is_definition_name(name: &str) -> bool {
    static CELL: OnceLock<Regex> = OnceLock::new();
    name.len() <= 128 && matches(&CELL, r"^[A-Za-z][A-Za-z0-9_]*$", name)
}

/// The form the Agent Skills specification gives a skill's name.
pub fn is_skill_name(name: &str) -> bool {
    static CELL: OnceLock<Regex> = OnceLock::new();
    name.len() <= 64 && matches(&CELL, r"^[a-z0-9]+(-[a-z0-9]+)*$", name)
}

/// A run's id names a directory, so it may not hold a separator or a dot.
pub fn is_execution_id(name: &str) -> bool {
    static CELL: OnceLock<Regex> = OnceLock::new();
    matches(&CELL, r"^[A-Za-z0-9_-]{1,64}$", name)
}

/// What is wrong with a configuration, or none: the rules of every setting.
pub fn problem_with(config: &AppConfig) -> Option<String> {
    let folder = |text: &str| !text.is_empty() && text.len() <= 4096;
    if config.work_dir.as_deref().is_some_and(str::is_empty) {
        return Some("workDir must not be empty".into());
    }
    if config.definition_paths.iter().any(String::is_empty) {
        return Some("a definition path must not be empty".into());
    }
    if let Some(bad) = config.default_models.values().find(|m| !is_model_name(m)) {
        return Some(format!("{bad} is not the name of a model"));
    }
    if let Some(bad) = config.env.keys().find(|k| !is_env_name(k)) {
        return Some(format!("{bad} is not the name of a variable"));
    }
    if config.env.values().any(|v| v.len() > 4096) {
        return Some("a variable's value is at most 4096 characters".into());
    }
    if config.env.len() > 64 {
        return Some("at most 64 variables".into());
    }
    if config.recent_vaults.len() > 8 || config.recent_vaults.iter().any(String::is_empty) {
        return Some("at most 8 vaults, each named".into());
    }
    if config
        .terminal_folder
        .as_deref()
        .is_some_and(|f| !folder(f))
    {
        return Some("terminalFolder is a path of 1 to 4096 characters".into());
    }
    if config.graph_repos.keys().any(|k| !is_namespace(k)) {
        return Some("a graph is named <repo>@<branch>".into());
    }
    if config.graph_repos.values().any(|p| !folder(p)) {
        return Some("a repository is a path of 1 to 4096 characters".into());
    }
    if config.graph_repos.len() > 64 {
        return Some("at most 64 repositories".into());
    }
    None
}

/// The saved settings with `patch` over them, checked, with `~` expanded.
pub fn merged(
    stored: AppConfig,
    patch: AppConfigPatch,
    home: &Path,
) -> Result<AppConfig, HostError> {
    let config = AppConfig {
        work_dir: patch.work_dir.unwrap_or(stored.work_dir),
        definition_paths: patch.definition_paths.unwrap_or(stored.definition_paths),
        default_harness: patch.default_harness.unwrap_or(stored.default_harness),
        default_models: patch.default_models.unwrap_or(stored.default_models),
        env: patch.env.unwrap_or(stored.env),
        recent_vaults: patch.recent_vaults.unwrap_or(stored.recent_vaults),
        terminal_folder: patch.terminal_folder.unwrap_or(stored.terminal_folder),
        graph_repos: patch.graph_repos.unwrap_or(stored.graph_repos),
    };
    if let Some(problem) = problem_with(&config) {
        return Err(HostError::bad_request(format!(
            "invalid parameters: {problem}"
        )));
    }
    Ok(expand_config_paths(config, home))
}
