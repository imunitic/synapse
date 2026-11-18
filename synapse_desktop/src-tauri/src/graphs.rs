//! Code graphs: finding the checkout a graph was built from, asking how it stands against that checkout,
//! and deleting one or cleaning up the graphs of branches that are gone. All of it runs `synapse` on the
//! repository a graph was built from, and a drop is only done when that folder is on the namespace's own
//! branch: `synapse graph-wipe` drops the graph of the checkout it is run in, and the wrong folder would
//! drop another one.

use crate::cli::{CliRun, CliRunner};
use crate::dispatch::HostError;
use crate::messages::{
    AppConfig, CliBinary, GraphCheck, GraphFinding, GraphHealth, GraphPlan, GraphRepoCheck,
};
use std::path::{Path, PathBuf};

/// How many folders are asked for their namespace, and how many at a time.
const MOST_CANDIDATES: usize = 60;
const AT_ONCE: usize = 6;

/// The rows of a check: a node's name, a tab and what is wrong with it. Nothing is printed when nothing
/// is.
pub fn parse_findings(text: &str) -> Vec<GraphFinding> {
    text.split('\n')
        .filter(|line| !line.is_empty())
        .map(|line| match line.split_once('\t') {
            Some((node, reason)) => GraphFinding {
                node: node.into(),
                reason: reason.into(),
            },
            None => GraphFinding {
                node: line.into(),
                reason: String::new(),
            },
        })
        .collect()
}

/// The `<repo>@<branch>` of a folder as it is checked out now.
pub async fn check_graph_repo(
    runner: &CliRunner,
    config: &AppConfig,
    path: &str,
) -> GraphRepoCheck {
    if !Path::new(path).is_absolute() || !Path::new(path).is_dir() {
        return GraphRepoCheck {
            key: None,
            error: Some(format!("{path} is not a folder")),
        };
    }
    let run = CliRun::new(
        CliBinary::Synapse,
        &["namespace", "--repo", path],
        config.clone(),
    );
    let Ok(result) = runner.run(run).await else {
        return GraphRepoCheck {
            key: None,
            error: Some("synapse could not be run".into()),
        };
    };
    let key = result.stdout.trim();
    if result.code == 0 && !key.is_empty() {
        return GraphRepoCheck {
            key: Some(key.into()),
            error: None,
        };
    }
    let why = if result.stderr.is_empty() {
        &result.stdout
    } else {
        &result.stderr
    };
    let why = why.trim();
    GraphRepoCheck {
        key: None,
        error: Some(if why.is_empty() {
            "that folder has no namespace".into()
        } else {
            why.into()
        }),
    }
}

async fn check(
    runner: &CliRunner,
    config: &AppConfig,
    namespace: &str,
    repo: &str,
    subcommand: &str,
) -> GraphCheck {
    let mut run = CliRun::new(
        CliBinary::Synapse,
        &["query", "--namespace", namespace, subcommand],
        config.clone(),
    );
    run.env.insert("SYNAPSE_REPO_ROOT".into(), repo.into());
    let result = match runner.run(run).await {
        Ok(result) => result,
        Err(error) => return GraphCheck::Failed { ok: false, error },
    };
    // Exit 1 means it could not run, never that all is clean.
    if result.code != 0 {
        let why = if result.stderr.is_empty() {
            &result.stdout
        } else {
            &result.stderr
        };
        let why = why.trim();
        return GraphCheck::Failed {
            ok: false,
            error: if why.is_empty() {
                format!("{subcommand} could not run")
            } else {
                why.into()
            },
        };
    }
    GraphCheck::Found {
        ok: true,
        findings: parse_findings(&result.stdout),
    }
}

/// How a graph stands against the repository it was built from: which nodes are stale, what has drifted
/// and what is no longer grounded.
pub async fn graph_health(
    runner: &CliRunner,
    config: &AppConfig,
    namespace: &str,
    repo: &str,
) -> GraphHealth {
    let (stale, drift, grounding) = tokio::join!(
        check(runner, config, namespace, repo, "stale"),
        check(runner, config, namespace, repo, "drift"),
        check(runner, config, namespace, repo, "grounding"),
    );
    GraphHealth {
        stale,
        drift,
        grounding,
    }
}

/// The folders whose subfolders are looked through: next to the checkouts already saved for other
/// graphs, where worktrees and clones of one project are kept, and the folder the terminals start in.
pub fn search_roots(config: &AppConfig) -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    let mut add = |root: PathBuf| {
        if !roots.contains(&root) {
            roots.push(root);
        }
    };
    for repo in config.graph_repos.values() {
        if let Some(parent) = Path::new(repo).parent() {
            add(parent.to_path_buf());
        }
    }
    if let Some(folder) = &config.terminal_folder {
        if Path::new(folder).is_absolute() {
            add(PathBuf::from(folder));
        }
    }
    roots
}

fn subfolders(root: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            e.path().is_dir() && !name.starts_with('.') && name != "node_modules"
        })
        .map(|e| e.path())
        .collect()
}

/// A git checkout has `.git`, a folder or, for a worktree, a file.
fn is_checkout(path: &Path) -> bool {
    path.join(".git").exists()
}

fn candidates(config: &AppConfig) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = Vec::new();
    for root in search_roots(config) {
        let mut paths = vec![root.clone()];
        paths.extend(subfolders(&root));
        for path in paths {
            if found.len() >= MOST_CANDIDATES {
                break;
            }
            if is_checkout(&path) && !found.contains(&path) {
                found.push(path);
            }
        }
    }
    found
}

/// The checkouts that are on the namespace now, in name order.
pub async fn find_graph_repos(
    runner: &CliRunner,
    config: &AppConfig,
    namespace: &str,
) -> Vec<String> {
    let paths = candidates(config);
    let mut matches: Vec<String> = Vec::new();
    for chunk in paths.chunks(AT_ONCE) {
        let checks = futures_join(chunk, runner, config).await;
        for (path, found) in chunk.iter().zip(checks) {
            if found.key.as_deref() == Some(namespace) {
                matches.push(path.to_string_lossy().to_string());
            }
        }
    }
    matches.sort_by_key(|p| p.to_lowercase());
    matches
}

async fn futures_join(
    chunk: &[PathBuf],
    runner: &CliRunner,
    config: &AppConfig,
) -> Vec<GraphRepoCheck> {
    let mut tasks = Vec::new();
    for path in chunk {
        let (runner, config, path) = (
            runner.clone(),
            config.clone(),
            path.to_string_lossy().to_string(),
        );
        tasks.push(tokio::spawn(async move {
            check_graph_repo(&runner, &config, &path).await
        }));
    }
    let mut checks = Vec::new();
    for task in tasks {
        checks.push(task.await.unwrap_or(GraphRepoCheck {
            key: None,
            error: None,
        }));
    }
    checks
}

// ---------------------------------------------------------------------------------------------
// Deleting a graph, and cleaning up
// ---------------------------------------------------------------------------------------------

/// The folder saved for a namespace, which must exist.
pub fn repository_of(config: &AppConfig, namespace: &str) -> Result<String, HostError> {
    let repo = config
        .graph_repos
        .get(namespace)
        .ok_or_else(|| HostError::conflict("no repository is saved for this graph"))?;
    if !Path::new(repo).is_dir() {
        return Err(HostError::conflict(format!("{repo} is not a folder")));
    }
    Ok(repo.clone())
}

fn lines(text: &str) -> Vec<String> {
    text.split('\n')
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect()
}

async fn run_in(
    runner: &CliRunner,
    config: &AppConfig,
    repo: &str,
    command: &str,
    dry: bool,
) -> Result<String, HostError> {
    let args: Vec<&str> = if dry {
        vec![command, "--dry-run"]
    } else {
        vec![command]
    };
    let mut run = CliRun::new(CliBinary::Synapse, &args, config.clone());
    run.cwd = Some(repo.into());
    let result = runner.run(run).await.map_err(HostError::unavailable)?;
    if result.code != 0 {
        let why = if result.stderr.is_empty() {
            &result.stdout
        } else {
            &result.stderr
        };
        let why = why.trim();
        return Err(HostError::unavailable(if why.is_empty() {
            format!("{command} failed")
        } else {
            why.into()
        }));
    }
    Ok(result.stdout)
}

/// The folder a drop is made in, which is only for the checkout that is on the namespace.
async fn drop_repository(
    runner: &CliRunner,
    config: &AppConfig,
    namespace: &str,
) -> Result<String, HostError> {
    let repo = repository_of(config, namespace)?;
    let check = check_graph_repo(runner, config, &repo).await;
    match check.key.as_deref() {
        Some(key) if key == namespace => Ok(repo),
        Some(key) => Err(HostError::conflict(format!(
            "{repo} is on {key}, not {namespace}, so deleting from it would delete another graph"
        ))),
        None => Err(HostError::conflict(
            format!(
                "{repo} has no namespace: {}",
                check.error.unwrap_or_default()
            )
            .trim()
            .to_string(),
        )),
    }
}

pub async fn plan_graph_drop(
    runner: &CliRunner,
    config: &AppConfig,
    namespace: &str,
) -> Result<GraphPlan, HostError> {
    let repo = drop_repository(runner, config, namespace).await?;
    Ok(GraphPlan {
        lines: lines(&run_in(runner, config, &repo, "graph-wipe", true).await?),
    })
}

pub async fn drop_graph(
    runner: &CliRunner,
    config: &AppConfig,
    namespace: &str,
) -> Result<String, HostError> {
    let repo = drop_repository(runner, config, namespace).await?;
    Ok(run_in(runner, config, &repo, "graph-wipe", false)
        .await?
        .trim()
        .to_string())
}

pub async fn plan_graph_clean(
    runner: &CliRunner,
    config: &AppConfig,
    namespace: &str,
) -> Result<GraphPlan, HostError> {
    let repo = repository_of(config, namespace)?;
    Ok(GraphPlan {
        lines: lines(&run_in(runner, config, &repo, "graph-clean", true).await?),
    })
}

pub async fn clean_graphs(
    runner: &CliRunner,
    config: &AppConfig,
    namespace: &str,
) -> Result<String, HostError> {
    let repo = repository_of(config, namespace)?;
    Ok(run_in(runner, config, &repo, "graph-clean", false)
        .await?
        .trim()
        .to_string())
}
