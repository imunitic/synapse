//! Where things are: the home folder and the variables the host runs in, the folders the file
//! messages may reach, and the places Synapse keeps its files.

use crate::dispatch::HostError;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The variables and the home folder the host and its programs run in.
#[derive(Clone, Debug, Default)]
pub struct Environment {
    pub env: BTreeMap<String, String>,
    pub home: PathBuf,
}

impl Environment {
    /// What the process has.
    pub fn from_process() -> Environment {
        let env: BTreeMap<String, String> = std::env::vars().collect();
        let home = env
            .get("HOME")
            .or_else(|| env.get("USERPROFILE"))
            .map(PathBuf::from)
            .unwrap_or_default();
        Environment { env, home }
    }

    /// A variable that is set and not empty.
    pub fn var(&self, name: &str) -> Option<&str> {
        self.env
            .get(name)
            .map(String::as_str)
            .filter(|v| !v.is_empty())
    }

    /// `$XDG_CONFIG_HOME`, or `~/.config` when unset.
    pub fn config_base(&self) -> PathBuf {
        match self.var("XDG_CONFIG_HOME") {
            Some(base) => PathBuf::from(base),
            None => self.home.join(".config"),
        }
    }
}

const SEPARATOR: char = if cfg!(windows) { ';' } else { ':' };

/// The directories of a PATH-like variable.
pub fn split_paths(value: &str) -> Vec<&str> {
    value
        .split(SEPARATOR)
        .filter(|part| !part.is_empty())
        .collect()
}

pub fn join_paths<S: AsRef<str>>(parts: &[S]) -> String {
    parts
        .iter()
        .map(|p| p.as_ref())
        .collect::<Vec<_>>()
        .join(&SEPARATOR.to_string())
}

/// What to start for the program `name` in the environment `env`: its full path on that `PATH`. The
/// standard library starts a program that is named without a folder, in an environment made for it,
/// with `fork`, and on macOS a child made that way can crash before the program starts. A program
/// named by its full path is started with `posix_spawn`.
///
/// The name comes back as it is when it holds a folder, when it is not found, when a relative entry
/// of `PATH` comes before it, and on Windows.
pub fn program_path(name: &str, env: &BTreeMap<String, String>) -> PathBuf {
    #[cfg(unix)]
    if !name.contains('/') {
        use std::os::unix::fs::PermissionsExt;
        for dir in env.get("PATH").map_or("", String::as_str).split(SEPARATOR) {
            let candidate = Path::new(dir).join(name);
            if !candidate.is_absolute() {
                break;
            }
            let runs = std::fs::metadata(&candidate)
                .is_ok_and(|file| file.is_file() && file.permissions().mode() & 0o111 != 0);
            if runs {
                return candidate;
            }
        }
    }
    #[cfg(not(unix))]
    let _ = env;
    PathBuf::from(name)
}

/// `~` and `~/rest` (`~\rest` too) are the home folder and a path in it; anything else, including
/// `~name`, is left as it was typed.
pub fn expand_home(path: &str, home: &Path) -> String {
    if home.as_os_str().is_empty() {
        return path.to_string();
    }
    if path == "~" {
        return home.to_string_lossy().to_string();
    }
    if let Some(rest) = path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\")) {
        return home.join(rest).to_string_lossy().to_string();
    }
    path.to_string()
}

/// `$XDG_CONFIG_HOME/synapse-pipeline`, or `~/.config/synapse-pipeline`.
pub fn pipeline_config_dir(environment: &Environment) -> PathBuf {
    environment.config_base().join("synapse-pipeline")
}

/// The folder of definitions: `SYNAPSE_PIPELINE_PATH`, the default folder, and those the user added.
pub fn definition_dirs(definition_paths: &[String], environment: &Environment) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> =
        split_paths(environment.var("SYNAPSE_PIPELINE_PATH").unwrap_or(""))
            .into_iter()
            .map(PathBuf::from)
            .collect();
    dirs.push(pipeline_config_dir(environment));
    dirs.extend(definition_paths.iter().map(PathBuf::from));
    dirs
}

/// The folders the file messages may reach: where definitions are looked for, and the work
/// directory's records.
pub fn allowed_roots(
    definition_paths: &[String],
    work_dir: Option<&str>,
    environment: &Environment,
) -> Vec<PathBuf> {
    let mut roots = definition_dirs(definition_paths, environment);
    if let Some(work_dir) = work_dir {
        roots.push(Path::new(work_dir).join("pipelines"));
    }
    roots
}

/// The real path of `target` when it lies inside one of the roots, after following links, so that a
/// link or a `..` cannot lead out.
pub fn resolve_inside(target: &str, roots: &[PathBuf]) -> Result<PathBuf, HostError> {
    let path = Path::new(target);
    if !path.is_absolute() {
        return Err(HostError::forbidden("path must be absolute"));
    }
    let real = dunce::canonicalize(path).map_err(|_| HostError::forbidden("not found"))?;
    for root in roots {
        let Ok(real_root) = dunce::canonicalize(root) else {
            continue;
        };
        // `starts_with` compares whole components: a sibling that starts with the root's name is not
        // inside it.
        if real.starts_with(&real_root) {
            return Ok(real);
        }
    }
    Err(HostError::forbidden(
        "path is outside the allowed directories",
    ))
}

/// The paths that are directories now, without repeats, in their order.
pub fn existing_dirs<P: AsRef<Path>>(paths: &[P]) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    for path in paths {
        let text = path.as_ref().to_string_lossy().to_string();
        if !found.contains(&text) && path.as_ref().is_dir() {
            found.push(text);
        }
    }
    found
}

/// Where one of Synapse's `synapse-*.conf` files is: the first of `$XDG_CONFIG_HOME/synapse/` (or
/// `~/.config/synapse/`) and `~/.claude/` that has it. A file that is in neither is made in the
/// first, or in `~/.claude/` when `~/.config` is not there.
pub fn conf_file(environment: &Environment, name: &str) -> PathBuf {
    let base = environment.config_base();
    let first = base.join("synapse").join(name);
    let second = environment.home.join(".claude").join(name);
    for candidate in [&first, &second] {
        if candidate.is_file() {
            return candidate.clone();
        }
    }
    if environment.var("XDG_CONFIG_HOME").is_some() || base.is_dir() {
        first
    } else {
        second
    }
}
