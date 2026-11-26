//! The changes made in a working tree, from git, without touching the repository. A snapshot is the
//! tree object made from a temporary index, so nothing is committed, stashed or staged and the real
//! index is left alone; the changes are the difference between two snapshots.

use crate::dispatch::HostError;
use crate::messages::{is_commit_id, is_pin_ref, AddedFile, Commit, CommitLog, FolderChanges};
use crate::protocol::ErrorCode;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

/// The most a patch may hold: a change larger than this is refused, not cut.
pub const MAX_PATCH_BYTES: usize = 4 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(60);

struct Git {
    ok: bool,
    stdout: String,
    stderr: String,
}

/// Runs git in `folder`. A non-zero exit is a result. The variables that point git at another
/// repository are not passed on, and the user's configuration of external diff programs and text
/// conversions is not used: the diff is git's own.
async fn git(folder: &Path, args: &[&str], index: Option<&Path>) -> Result<Git, HostError> {
    let failed = |why: String| HostError::unavailable(format!("git could not be run: {why}"));
    let mut command = Command::new("git");
    command
        .arg("--no-pager")
        .args(["-c", "core.quotepath=off"])
        .arg("--literal-pathspecs")
        .args(args)
        .current_dir(folder)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(index) = index {
        command.env("GIT_INDEX_FILE", index);
    }
    let mut child = command.spawn().map_err(|e| failed(e.to_string()))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| failed("no output".into()))?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| failed("no error output".into()))?;
    let errors = tokio::spawn(async move {
        let mut text = Vec::new();
        let _ = stderr.read_to_end(&mut text).await;
        text
    });
    let work = async {
        let mut out = Vec::new();
        (&mut stdout)
            .take(MAX_PATCH_BYTES as u64 + 1)
            .read_to_end(&mut out)
            .await
            .map_err(|e| failed(e.to_string()))?;
        if out.len() > MAX_PATCH_BYTES {
            let _ = child.kill().await;
            return Err(HostError::new(
                ErrorCode::TooLarge,
                "the changes are too large to show",
            ));
        }
        let status = child.wait().await.map_err(|e| failed(e.to_string()))?;
        Ok((out, status.success()))
    };
    let (out, ok) = tokio::time::timeout(TIMEOUT, work)
        .await
        .map_err(|_| HostError::unavailable("git took too long"))??;
    let err = errors.await.unwrap_or_default();
    Ok(Git {
        ok,
        stdout: String::from_utf8_lossy(&out).to_string(),
        stderr: String::from_utf8_lossy(&err).to_string(),
    })
}

/// Copies the real index to `to`, which starts the temporary one, so that only what changed is read
/// again. The copy keeps the real index's time: git trusts an entry that has the size and the time of
/// its file only when the entry is older than the index, and a copy that looked newer would make it
/// trust an entry of a file that was written again, with the same size, in the second the index was.
/// With no index yet the temporary one starts empty.
async fn copy_index(from: &Path, to: &Path) {
    let Ok(modified) = tokio::fs::metadata(from).await.and_then(|m| m.modified()) else {
        return;
    };
    if tokio::fs::copy(from, to).await.is_err() {
        return;
    }
    if let Ok(file) = std::fs::OpenOptions::new().write(true).open(to) {
        let _ = file.set_modified(modified);
    }
}

/// The id of the tree the working tree is now, or None when the folder is not in a git repository.
/// `add -A` brings the temporary index to the working tree: new files in, deleted files out, ignored
/// files left out.
pub async fn snapshot_tree(folder: &Path) -> Result<Option<String>, HostError> {
    if !folder.is_dir() {
        return Err(HostError::not_found("the folder is not there"));
    }
    let inside = git(folder, &["rev-parse", "--is-inside-work-tree"], None).await?;
    if !inside.ok || inside.stdout.trim() != "true" {
        return Ok(None);
    }
    let git_dir = git(folder, &["rev-parse", "--absolute-git-dir"], None).await?;
    if !git_dir.ok {
        return Ok(None);
    }
    let scratch = tempfile::Builder::new()
        .prefix("synapse-changes-")
        .tempdir()
        .map_err(|e| HostError::internal(e.to_string()))?;
    let index = scratch.path().join("index");
    copy_index(&Path::new(git_dir.stdout.trim()).join("index"), &index).await;
    let added = git(folder, &["add", "-A"], Some(&index)).await?;
    if !added.ok {
        return Err(HostError::unavailable(format!(
            "git add failed: {}",
            added.stderr.trim()
        )));
    }
    let tree = git(folder, &["write-tree"], Some(&index)).await?;
    if !tree.ok {
        return Err(HostError::unavailable(format!(
            "git write-tree failed: {}",
            tree.stderr.trim()
        )));
    }
    Ok(Some(tree.stdout.trim().to_string()))
}

/// The tree of the last commit, the empty tree when there is none, or None when the folder is not in
/// a git repository: what everything that is not committed is a change against.
pub async fn head_tree(folder: &Path) -> Result<Option<String>, HostError> {
    if !folder.is_dir() {
        return Err(HostError::not_found("the folder is not there"));
    }
    let inside = git(folder, &["rev-parse", "--is-inside-work-tree"], None).await?;
    if !inside.ok || inside.stdout.trim() != "true" {
        return Ok(None);
    }
    let head = git(
        folder,
        &["rev-parse", "--verify", "--quiet", "HEAD^{tree}"],
        None,
    )
    .await?;
    if head.ok && !head.stdout.trim().is_empty() {
        return Ok(Some(head.stdout.trim().to_string()));
    }
    // No commit yet: git writes the empty tree, whatever hash the repository uses.
    let empty = git(folder, &["mktree"], None).await?;
    Ok(empty.ok.then(|| empty.stdout.trim().to_string()))
}

/// Where HEAD is: the name of the branch checked out, also before its first commit; the id of the
/// commit when HEAD is detached; None when the folder is not in a git repository or HEAD is neither.
pub async fn head_position(folder: &Path) -> Result<Option<String>, HostError> {
    let branch = git(
        folder,
        &["symbolic-ref", "--quiet", "--short", "HEAD"],
        None,
    )
    .await?;
    if branch.ok && !branch.stdout.trim().is_empty() {
        return Ok(Some(branch.stdout.trim().to_string()));
    }
    let commit = git(folder, &["rev-parse", "--verify", "--quiet", "HEAD"], None).await?;
    if commit.ok && !commit.stdout.trim().is_empty() {
        return Ok(Some(commit.stdout.trim().to_string()));
    }
    Ok(None)
}

/// The files of `git diff --numstat -z`, each as `added<TAB>removed<TAB>path` ending in a NUL.
fn added_files(numstat: &str) -> Vec<AddedFile> {
    numstat
        .split('\0')
        .filter(|record| !record.is_empty())
        .map(|record| {
            let mut parts = record.splitn(3, '\t');
            let lines = parts.next().unwrap_or("");
            let _removed = parts.next();
            AddedFile {
                path: parts.next().unwrap_or("").to_string(),
                lines: lines.parse().ok(),
            }
        })
        .collect()
}

const DIFF: [&str; 5] = [
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--find-renames",
];

fn diff_args<'a>(extra: &[&'a str], before: &'a str, after: &'a str) -> Vec<&'a str> {
    let mut args = DIFF.to_vec();
    args.extend_from_slice(extra);
    args.push(before);
    args.push(after);
    args
}

/// What changed in the folder's working tree since the snapshot `before`. Without a path: the patch
/// of the files that already existed, and the new files by path and number of lines. With a path:
/// that file's patch, a new file's whole content included.
pub async fn changes_since(
    folder: &Path,
    before: &str,
    path: Option<&str>,
) -> Result<FolderChanges, HostError> {
    if path.is_some_and(|p| p.contains('\0')) {
        return Err(HostError::bad_request("the path holds a NUL"));
    }
    let Some(after) = snapshot_tree(folder).await? else {
        return Ok(FolderChanges {
            repository: false,
            patch: String::new(),
            added: vec![],
            head: None,
        });
    };
    let head = head_position(folder).await?;
    let nothing = || FolderChanges {
        repository: true,
        patch: String::new(),
        added: vec![],
        head: head.clone(),
    };
    if after == before {
        return Ok(nothing());
    }
    check_snapshot(folder, before).await?;
    let (patch, added) = diff_trees(folder, before, &after, path).await?;
    Ok(FolderChanges {
        repository: true,
        patch,
        added,
        head,
    })
}

/// What changed from the snapshot `before` to the snapshot `after`, without reading the working
/// tree; otherwise as `changes_since`.
pub async fn changes_between(
    folder: &Path,
    before: &str,
    after: &str,
    path: Option<&str>,
) -> Result<FolderChanges, HostError> {
    if path.is_some_and(|p| p.contains('\0')) {
        return Err(HostError::bad_request("the path holds a NUL"));
    }
    if !in_repository(folder).await? {
        return Ok(FolderChanges {
            repository: false,
            patch: String::new(),
            added: vec![],
            head: None,
        });
    }
    check_snapshot(folder, after).await?;
    let head = head_position(folder).await?;
    if after == before {
        return Ok(FolderChanges {
            repository: true,
            patch: String::new(),
            added: vec![],
            head,
        });
    }
    check_snapshot(folder, before).await?;
    let (patch, added) = diff_trees(folder, before, after, path).await?;
    Ok(FolderChanges {
        repository: true,
        patch,
        added,
        head,
    })
}

/// Refused as not found when the tree is not in the folder's repository, as after a `git gc` that
/// removed a snapshot nothing kept.
async fn check_snapshot(folder: &Path, tree: &str) -> Result<(), HostError> {
    let known = git(
        folder,
        &["cat-file", "-e", &format!("{tree}^{{tree}}")],
        None,
    )
    .await?;
    if known.ok {
        Ok(())
    } else {
        Err(HostError::not_found(
            "the snapshot is not in this repository any more",
        ))
    }
}

/// The full name of the ref a run's snapshot is pinned as, checked again here, so that nothing else
/// is ever written.
fn pinned_ref(reference: &str) -> Result<String, HostError> {
    if is_pin_ref(reference) {
        Ok(format!("refs/synapse/{reference}"))
    } else {
        Err(HostError::bad_request(format!(
            "'{reference}' is not a snapshot ref"
        )))
    }
}

/// Pins the snapshot `tree` as `refs/synapse/<reference>`, which keeps it through `git gc`. A ref
/// outside `refs/heads/` and `refs/tags/` is not a branch or a tag, and a normal push does not send
/// it. The folder must be the root of its repository: two folders of one repository would pin the
/// same ref.
pub async fn pin_snapshot(folder: &Path, reference: &str, tree: &str) -> Result<(), HostError> {
    let name = pinned_ref(reference)?;
    if !in_repository(folder).await? {
        return Err(HostError::bad_request(
            "the folder is not in a git repository",
        ));
    }
    let prefix = git(folder, &["rev-parse", "--show-prefix"], None).await?;
    if !prefix.ok || !prefix.stdout.trim().is_empty() {
        return Err(HostError::bad_request(
            "the folder is not the root of a git repository",
        ));
    }
    check_snapshot(folder, tree).await?;
    let pinned = git(folder, &["update-ref", &name, tree], None).await?;
    if !pinned.ok {
        return Err(HostError::unavailable(format!(
            "git update-ref failed: {}",
            pinned.stderr.trim()
        )));
    }
    Ok(())
}

/// Deletes the ref a snapshot was pinned as; a ref that is not there is not an error.
pub async fn unpin_snapshot(folder: &Path, reference: &str) -> Result<(), HostError> {
    let name = pinned_ref(reference)?;
    if !in_repository(folder).await? {
        return Ok(());
    }
    let there = git(folder, &["rev-parse", "--verify", "--quiet", &name], None).await?;
    if !there.ok {
        return Ok(());
    }
    let unpinned = git(folder, &["update-ref", "-d", &name], None).await?;
    if !unpinned.ok {
        return Err(HostError::unavailable(format!(
            "git update-ref -d failed: {}",
            unpinned.stderr.trim()
        )));
    }
    Ok(())
}

/// What changed from the tree `before` to the tree `after`. Without a path: the patch of the files
/// that already existed, and the new files by path and number of lines. With a path: that file's
/// patch, a new file's whole content included.
async fn diff_trees(
    folder: &Path,
    before: &str,
    after: &str,
    path: Option<&str>,
) -> Result<(String, Vec<AddedFile>), HostError> {
    if let Some(path) = path {
        let mut args = diff_args(&[], before, after);
        args.push("--");
        args.push(path);
        let one = git(folder, &args, None).await?;
        if !one.ok {
            return Err(HostError::unavailable(format!(
                "git diff failed: {}",
                one.stderr.trim()
            )));
        }
        return Ok((one.stdout, vec![]));
    }
    let patch_args = diff_args(&["--diff-filter=a"], before, after);
    let numstat_args = diff_args(&["--numstat", "-z", "--diff-filter=A"], before, after);
    let (patch, numstat) = tokio::join!(
        git(folder, &patch_args, None),
        git(folder, &numstat_args, None)
    );
    let (patch, numstat) = (patch?, numstat?);
    if !patch.ok || !numstat.ok {
        let why = if patch.ok {
            &numstat.stderr
        } else {
            &patch.stderr
        };
        return Err(HostError::unavailable(format!(
            "git diff failed: {}",
            why.trim()
        )));
    }
    Ok((patch.stdout, added_files(&numstat.stdout)))
}

fn check_commit_id(id: &str) -> Result<(), HostError> {
    if is_commit_id(id) {
        Ok(())
    } else {
        Err(HostError::bad_request(format!("'{id}' is not a commit")))
    }
}

/// Whether the folder is in a git repository; refused when the folder is not there.
async fn in_repository(folder: &Path) -> Result<bool, HostError> {
    if !folder.is_dir() {
        return Err(HostError::not_found("the folder is not there"));
    }
    let inside = git(folder, &["rev-parse", "--is-inside-work-tree"], None).await?;
    Ok(inside.ok && inside.stdout.trim() == "true")
}

/// The fields of a commit in `git log`, after a record separator and separated by unit separators,
/// which a one-line subject does not hold; its `--shortstat` line follows them.
const LOG_FORMAT: &str = "--format=%x1e%H%x1f%s%x1f%an%x1f%cI";

/// The lines a `--shortstat` line counts: ` 3 files changed, 290 insertions(+), 93 deletions(-)`,
/// either count left out when it is none.
fn shortstat(text: &str) -> (u64, u64) {
    let mut added = 0;
    let mut removed = 0;
    for part in text.trim().split(", ") {
        let number = part
            .split_whitespace()
            .next()
            .and_then(|n| n.parse().ok())
            .unwrap_or(0);
        if part.contains("insertion") {
            added = number;
        } else if part.contains("deletion") {
            removed = number;
        }
    }
    (added, removed)
}

/// The commits of HEAD, newest first along the first parent, at most `limit`; with `before`, those
/// after that one. A merge is one commit of the branch; what it brought in is not listed, and its
/// lines are counted against its first parent.
pub async fn commit_log(
    folder: &Path,
    limit: usize,
    before: Option<&str>,
) -> Result<CommitLog, HostError> {
    if let Some(before) = before {
        check_commit_id(before)?;
    }
    let none = |repository| CommitLog {
        repository,
        commits: vec![],
        more: false,
    };
    if !in_repository(folder).await? {
        return Ok(none(false));
    }
    let head = git(folder, &["rev-parse", "--verify", "--quiet", "HEAD"], None).await?;
    if !head.ok {
        return Ok(none(true));
    }
    // One more than asked for says whether there are more; `before` itself comes first and is dropped.
    let count = (limit + 1 + usize::from(before.is_some())).to_string();
    let from = before.unwrap_or("HEAD");
    let log = git(
        folder,
        &[
            "log",
            "--first-parent",
            "--diff-merges=first-parent",
            "--shortstat",
            "--no-color",
            LOG_FORMAT,
            "-n",
            &count,
            from,
            "--",
        ],
        None,
    )
    .await?;
    if !log.ok {
        return Err(HostError::not_found(format!(
            "there is no commit {from} in this repository"
        )));
    }
    let mut commits: Vec<Commit> = log
        .stdout
        .split('\u{1e}')
        .filter(|record| !record.trim().is_empty())
        .map(|record| {
            let (fields, stat) = record.split_once('\n').unwrap_or((record, ""));
            let mut fields = fields.split('\u{1f}');
            let mut next = || fields.next().unwrap_or("").to_string();
            let (hash, subject, author, time) = (next(), next(), next(), next());
            let (added, removed) = shortstat(stat);
            Commit {
                hash,
                subject,
                author,
                time,
                added,
                removed,
            }
        })
        .collect();
    if before.is_some() && !commits.is_empty() {
        commits.remove(0);
    }
    let more = commits.len() > limit;
    commits.truncate(limit);
    Ok(CommitLog {
        repository: true,
        commits,
        more,
    })
}

/// What a commit changed against its first parent, or against the empty tree for the first commit of
/// a repository. Without a path: the patch of the files that already existed, and the new files by
/// path and number of lines; with a path, that file's whole patch.
pub async fn commit_changes(
    folder: &Path,
    commit: &str,
    path: Option<&str>,
) -> Result<FolderChanges, HostError> {
    check_commit_id(commit)?;
    if path.is_some_and(|p| p.contains('\0')) {
        return Err(HostError::bad_request("the path holds a NUL"));
    }
    if !in_repository(folder).await? {
        return Ok(FolderChanges {
            repository: false,
            patch: String::new(),
            added: vec![],
            head: None,
        });
    }
    let tree = git(
        folder,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("{commit}^{{commit}}^{{tree}}"),
        ],
        None,
    )
    .await?;
    if !tree.ok {
        return Err(HostError::not_found(format!(
            "there is no commit {commit} in this repository"
        )));
    }
    let parent = git(
        folder,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("{commit}^1^{{tree}}"),
        ],
        None,
    )
    .await?;
    let mut before = parent.stdout.trim().to_string();
    if !parent.ok || before.is_empty() {
        // The first commit: git writes the empty tree, whatever hash the repository uses.
        let empty = git(folder, &["mktree"], None).await?;
        if !empty.ok {
            return Err(HostError::unavailable("git could not make the empty tree"));
        }
        before = empty.stdout.trim().to_string();
    }
    let (patch, added) = diff_trees(folder, &before, tree.stdout.trim(), path).await?;
    Ok(FolderChanges {
        repository: true,
        patch,
        added,
        head: head_position(folder).await?,
    })
}
