//! The changes made in a working tree, from git, on repositories made for each test.

use std::fs;
use std::path::Path;
use std::process::Command;
use synapse_desktop_host::changes::{
    changes_between, changes_since, commit_changes, commit_log, head_position, head_tree,
    pin_snapshot, snapshot_tree, unpin_snapshot, GIT_BASE_ARGS,
};
use synapse_desktop_host::messages::AddedFile;
use synapse_desktop_host::protocol::ErrorCode;
use tempfile::{tempdir, TempDir};

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "A")
        .env("GIT_AUTHOR_EMAIL", "a@example.com")
        .env("GIT_COMMITTER_NAME", "A")
        .env("GIT_COMMITTER_EMAIL", "a@example.com")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).to_string()
}

fn put(dir: &Path, name: &str, text: &str) {
    let path = dir.join(name);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// A repository with one commit: a file, one to delete and an ignore file.
fn repository() -> TempDir {
    let dir = tempdir().unwrap();
    git(dir.path(), &["init", "-q"]);
    put(dir.path(), "a.txt", "one\ntwo\nthree\n");
    put(dir.path(), "gone.txt", "bye\n");
    put(dir.path(), ".gitignore", "ignored.log\n");
    git(dir.path(), &["add", "-A"]);
    git(dir.path(), &["commit", "-q", "-m", "first"]);
    dir
}

fn is_tree_id(id: &str) -> bool {
    id.len() == 40 && id.bytes().all(|b| b.is_ascii_hexdigit())
}

#[test]
fn git_never_starts_an_fsmonitor_daemon() {
    assert!(
        GIT_BASE_ARGS
            .windows(2)
            .any(|pair| pair == ["-c", "core.fsmonitor=false"]),
        "every git command carries -c core.fsmonitor=false: {GIT_BASE_ARGS:?}"
    );
}

#[tokio::test]
async fn a_snapshot_is_the_id_of_a_tree_and_the_same_while_nothing_changes() {
    let dir = repository();
    let first = snapshot_tree(dir.path()).await.unwrap().unwrap();
    assert!(is_tree_id(&first));
    assert_eq!(snapshot_tree(dir.path()).await.unwrap().unwrap(), first);
    put(dir.path(), "a.txt", "changed\n");
    assert_ne!(snapshot_tree(dir.path()).await.unwrap().unwrap(), first);
}

#[tokio::test]
async fn a_file_written_again_with_the_same_size_in_the_second_of_the_last_commit_is_seen() {
    // The file is rewritten at once, in the second the index was written, and the snapshot is taken
    // after that second: the copy of the index must not look newer than the index it is a copy of.
    let dir = repository();
    put(dir.path(), "a.txt", "one\nTWO\nthree\n");
    tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
    let tree = snapshot_tree(dir.path()).await.unwrap().unwrap();
    assert_eq!(
        git(dir.path(), &["show", &format!("{tree}:a.txt")]),
        "one\nTWO\nthree\n"
    );
}

#[tokio::test]
async fn a_snapshot_leaves_the_repository_as_it_was() {
    let dir = repository();
    put(dir.path(), "a.txt", "changed\n");
    put(dir.path(), "new.txt", "new\n");
    let head = git(dir.path(), &["rev-parse", "HEAD"]);
    let status = git(dir.path(), &["status", "--porcelain=v1"]);
    let index = fs::read(dir.path().join(".git").join("index")).unwrap();
    snapshot_tree(dir.path()).await.unwrap();
    assert_eq!(git(dir.path(), &["rev-parse", "HEAD"]), head);
    assert_eq!(git(dir.path(), &["status", "--porcelain=v1"]), status);
    assert_eq!(git(dir.path(), &["stash", "list"]), "");
    assert_eq!(
        fs::read(dir.path().join(".git").join("index")).unwrap(),
        index
    );
}

#[tokio::test]
async fn a_folder_that_is_not_in_a_repository_has_no_snapshot_and_one_that_is_not_there_is_refused()
{
    let plain = tempdir().unwrap();
    assert_eq!(snapshot_tree(plain.path()).await.unwrap(), None);
    let missing = snapshot_tree(&plain.path().join("nope")).await.unwrap_err();
    assert_eq!(missing.code, ErrorCode::NotFound);
}

#[tokio::test]
async fn a_repository_with_no_commit_yet_has_a_snapshot() {
    let fresh = tempdir().unwrap();
    git(fresh.path(), &["init", "-q"]);
    put(fresh.path(), "x.txt", "x\n");
    assert!(is_tree_id(
        &snapshot_tree(fresh.path()).await.unwrap().unwrap()
    ));
}

#[tokio::test]
async fn a_changed_file_is_in_the_patch_and_nothing_changed_is_empty() {
    let dir = repository();
    let before = snapshot_tree(dir.path()).await.unwrap().unwrap();
    let none = changes_since(dir.path(), &before, None).await.unwrap();
    assert!(none.repository && none.patch.is_empty() && none.added.is_empty());

    put(dir.path(), "a.txt", "one\nTWO\nthree\n");
    let changes = changes_since(dir.path(), &before, None).await.unwrap();
    assert!(changes.patch.contains("diff --git a/a.txt b/a.txt"));
    assert!(changes.patch.contains("-two") && changes.patch.contains("+TWO"));
    assert!(changes.added.is_empty());
}

#[tokio::test]
async fn a_new_file_is_listed_by_path_and_lines_and_has_its_content_only_when_asked_for() {
    let dir = repository();
    let before = snapshot_tree(dir.path()).await.unwrap().unwrap();
    put(dir.path(), "src/new.txt", "a\nb\nc\nd\n");
    let changes = changes_since(dir.path(), &before, None).await.unwrap();
    assert_eq!(
        changes.added,
        [AddedFile {
            path: "src/new.txt".into(),
            lines: Some(4)
        }]
    );
    assert!(!changes.patch.contains("new.txt"));

    let one = changes_since(dir.path(), &before, Some("src/new.txt"))
        .await
        .unwrap();
    assert!(one.patch.contains("new file mode") && one.patch.contains("+a"));
    assert!(one.added.is_empty());

    fs::write(dir.path().join("blob.bin"), [0u8, 1, 2, 0, 255, 0]).unwrap();
    let binary = changes_since(dir.path(), &before, None).await.unwrap();
    assert!(binary.added.contains(&AddedFile {
        path: "blob.bin".into(),
        lines: None
    }));
}

#[tokio::test]
async fn a_deleted_file_is_in_the_patch_and_a_rename_is_one_file() {
    let dir = repository();
    let big: String = (0..30).map(|i| format!("line {i}\n")).collect();
    put(dir.path(), "big.txt", &big);
    git(dir.path(), &["add", "-A"]);
    git(dir.path(), &["commit", "-q", "-m", "second"]);
    let before = snapshot_tree(dir.path()).await.unwrap().unwrap();
    fs::remove_file(dir.path().join("gone.txt")).unwrap();
    fs::remove_file(dir.path().join("big.txt")).unwrap();
    put(dir.path(), "moved.txt", &big);
    let changes = changes_since(dir.path(), &before, None).await.unwrap();
    assert!(changes.patch.contains("deleted file mode"));
    assert!(changes.patch.contains("rename from big.txt"));
    assert!(changes.patch.contains("rename to moved.txt"));
    assert!(changes.added.is_empty());
}

#[tokio::test]
async fn what_was_already_changed_when_the_snapshot_was_taken_is_not_shown() {
    let dir = repository();
    put(dir.path(), "a.txt", "dirty before the agent\n");
    put(dir.path(), "untracked.txt", "was here\n");
    let before = snapshot_tree(dir.path()).await.unwrap().unwrap();
    put(
        dir.path(),
        "a.txt",
        "dirty before the agent\nand then the agent\n",
    );
    let changes = changes_since(dir.path(), &before, None).await.unwrap();
    assert!(changes.patch.contains("+and then the agent"));
    assert!(!changes.patch.contains("-three"));
    assert!(changes.added.is_empty());
}

#[tokio::test]
async fn an_ignored_file_is_never_shown() {
    let dir = repository();
    let before = snapshot_tree(dir.path()).await.unwrap().unwrap();
    put(dir.path(), "ignored.log", "noise\n");
    let changes = changes_since(dir.path(), &before, None).await.unwrap();
    assert!(changes.patch.is_empty() && changes.added.is_empty());
}

#[tokio::test]
async fn a_folder_outside_a_repository_has_no_changes_to_show() {
    let dir = repository();
    let before = snapshot_tree(dir.path()).await.unwrap().unwrap();
    let plain = tempdir().unwrap();
    let changes = changes_since(plain.path(), &before, None).await.unwrap();
    assert!(!changes.repository && changes.patch.is_empty());
}

#[tokio::test]
async fn a_snapshot_that_is_not_there_and_a_path_with_a_nul_are_refused() {
    let dir = repository();
    put(dir.path(), "a.txt", "changed\n");
    let unknown = changes_since(dir.path(), &"a".repeat(40), None)
        .await
        .unwrap_err();
    assert_eq!(unknown.code, ErrorCode::NotFound);
    let before = snapshot_tree(dir.path()).await.unwrap().unwrap();
    put(dir.path(), "a.txt", "changed again\n");
    let nul = changes_since(dir.path(), &before, Some("a\0b"))
        .await
        .unwrap_err();
    assert_eq!(nul.code, ErrorCode::BadRequest);
}

#[tokio::test]
async fn a_path_is_taken_as_a_name_and_not_as_an_option_or_a_pattern() {
    let dir = repository();
    let before = snapshot_tree(dir.path()).await.unwrap().unwrap();
    put(dir.path(), "a.txt", "changed\n");
    for odd in ["--stat", "*.txt"] {
        let none = changes_since(dir.path(), &before, Some(odd)).await.unwrap();
        assert!(none.patch.is_empty(), "{odd}");
    }
    let one = changes_since(dir.path(), &before, Some("a.txt"))
        .await
        .unwrap();
    assert!(one.patch.contains("+changed"));
}

#[tokio::test]
async fn the_head_tree_is_the_last_commit_and_changes_against_it_are_everything_not_committed() {
    let dir = repository();
    let head = head_tree(dir.path()).await.unwrap().unwrap();
    assert_eq!(head, git(dir.path(), &["rev-parse", "HEAD^{tree}"]).trim());
    put(dir.path(), "a.txt", "one\nTWO\nthree\n");
    put(dir.path(), "src/new.txt", "fresh\n");
    let changes = changes_since(dir.path(), &head, None).await.unwrap();
    assert!(changes.patch.contains("+TWO"));
    assert_eq!(
        changes.added,
        [AddedFile {
            path: "src/new.txt".into(),
            lines: Some(1)
        }]
    );
}

#[tokio::test]
async fn the_head_tree_of_a_repository_with_no_commit_is_the_empty_tree() {
    let fresh = tempdir().unwrap();
    git(fresh.path(), &["init", "-q"]);
    put(fresh.path(), "x.txt", "x\n");
    let empty = head_tree(fresh.path()).await.unwrap().unwrap();
    assert!(is_tree_id(&empty));
    let changes = changes_since(fresh.path(), &empty, None).await.unwrap();
    assert_eq!(
        changes.added,
        [AddedFile {
            path: "x.txt".into(),
            lines: Some(1)
        }]
    );
}

#[tokio::test]
async fn there_is_no_head_tree_outside_a_repository_and_a_missing_folder_is_refused() {
    let plain = tempdir().unwrap();
    assert_eq!(head_tree(plain.path()).await.unwrap(), None);
    let missing = head_tree(&plain.path().join("nope")).await.unwrap_err();
    assert_eq!(missing.code, ErrorCode::NotFound);
}

/// The branch `git init` checked out, which the user's configuration may name.
fn branch(dir: &Path) -> String {
    git(dir, &["symbolic-ref", "--short", "HEAD"])
        .trim()
        .to_string()
}

#[tokio::test]
async fn head_is_the_branch_checked_out_and_follows_a_switch() {
    let dir = repository();
    let first = branch(dir.path());
    assert_eq!(head_position(dir.path()).await.unwrap(), Some(first));
    git(dir.path(), &["checkout", "-q", "-b", "other"]);
    assert_eq!(
        head_position(dir.path()).await.unwrap(),
        Some("other".to_string())
    );
    let before = snapshot_tree(dir.path()).await.unwrap().unwrap();
    let changes = changes_since(dir.path(), &before, None).await.unwrap();
    assert_eq!(changes.head, Some("other".to_string()));
}

#[tokio::test]
async fn head_is_the_commit_when_detached() {
    let dir = repository();
    let commit = git(dir.path(), &["rev-parse", "HEAD"]).trim().to_string();
    git(dir.path(), &["checkout", "-q", "--detach"]);
    assert_eq!(head_position(dir.path()).await.unwrap(), Some(commit));
}

#[tokio::test]
async fn head_is_the_branch_before_its_first_commit_and_none_outside_a_repository() {
    let fresh = tempdir().unwrap();
    git(fresh.path(), &["init", "-q", "-b", "start"]);
    assert_eq!(
        head_position(fresh.path()).await.unwrap(),
        Some("start".to_string())
    );
    let plain = tempdir().unwrap();
    assert_eq!(head_position(plain.path()).await.unwrap(), None);
    let changes = changes_since(
        plain.path(),
        "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
        None,
    )
    .await
    .unwrap();
    assert_eq!(changes.head, None);
}

/// Commits the files it is given with the message it is given, and says the commit's hash.
fn commit_of(dir: &Path, message: &str, files: &[(&str, &str)]) -> String {
    for (name, text) in files {
        put(dir, name, text);
    }
    git(dir, &["add", "-A"]);
    git(dir, &["commit", "-q", "-m", message]);
    git(dir, &["rev-parse", "HEAD"]).trim().to_string()
}

fn subjects(log: &synapse_desktop_host::messages::CommitLog) -> Vec<&str> {
    log.commits.iter().map(|c| c.subject.as_str()).collect()
}

#[tokio::test]
async fn the_log_is_the_commits_of_head_newest_first_with_who_made_them_and_when() {
    let dir = repository();
    commit_of(dir.path(), "second", &[("b.txt", "b\n")]);
    commit_of(dir.path(), "third", &[("c.txt", "c\n")]);
    let log = commit_log(dir.path(), 10, None).await.unwrap();
    assert!(log.repository);
    assert!(!log.more);
    assert_eq!(subjects(&log), vec!["third", "second", "first"]);
    assert_eq!(
        log.commits[0].hash,
        git(dir.path(), &["rev-parse", "HEAD"]).trim()
    );
    assert_eq!(log.commits[0].author, "A");
    assert!(log.commits[0].time.contains('T'));
}

#[tokio::test]
async fn the_log_counts_the_lines_of_each_commit_a_merge_against_its_first_parent() {
    let dir = repository();
    commit_of(dir.path(), "add a line", &[("b.txt", "b\n")]);
    commit_of(
        dir.path(),
        "change a line",
        &[("a.txt", "one\nTWO\nthree\n")],
    );
    let main = git(dir.path(), &["symbolic-ref", "--short", "HEAD"])
        .trim()
        .to_string();
    git(dir.path(), &["checkout", "-q", "-b", "side"]);
    commit_of(dir.path(), "on side", &[("s.txt", "s1\ns2\n")]);
    git(dir.path(), &["checkout", "-q", &main]);
    git(
        dir.path(),
        &["merge", "-q", "--no-ff", "-m", "merge side", "side"],
    );
    let log = commit_log(dir.path(), 10, None).await.unwrap();
    let counts: Vec<(&str, u64, u64)> = log
        .commits
        .iter()
        .map(|c| (c.subject.as_str(), c.added, c.removed))
        .collect();
    assert_eq!(
        counts,
        vec![
            ("merge side", 2, 0),
            ("change a line", 1, 1),
            ("add a line", 1, 0),
            ("first", 5, 0),
        ]
    );
}

#[tokio::test]
async fn the_log_is_given_a_page_at_a_time_from_the_one_after_the_last_listed() {
    let dir = repository();
    commit_of(dir.path(), "second", &[("b.txt", "b\n")]);
    commit_of(dir.path(), "third", &[("c.txt", "c\n")]);
    let first = commit_log(dir.path(), 2, None).await.unwrap();
    assert_eq!(subjects(&first), vec!["third", "second"]);
    assert!(first.more);
    let next = commit_log(dir.path(), 2, Some(&first.commits[1].hash))
        .await
        .unwrap();
    assert_eq!(subjects(&next), vec!["first"]);
    assert!(!next.more);
}

#[tokio::test]
async fn the_log_follows_the_first_parent_so_a_merge_is_one_commit() {
    let dir = repository();
    let main = git(dir.path(), &["symbolic-ref", "--short", "HEAD"])
        .trim()
        .to_string();
    git(dir.path(), &["checkout", "-q", "-b", "side"]);
    commit_of(dir.path(), "on side", &[("s.txt", "s\n")]);
    git(dir.path(), &["checkout", "-q", &main]);
    git(
        dir.path(),
        &["merge", "-q", "--no-ff", "-m", "merge side", "side"],
    );
    let log = commit_log(dir.path(), 10, None).await.unwrap();
    assert_eq!(subjects(&log), vec!["merge side", "first"]);
    // And the merge is shown against the branch it was merged into.
    let merge = commit_changes(dir.path(), &log.commits[0].hash, None)
        .await
        .unwrap();
    assert_eq!(
        merge.added,
        vec![AddedFile {
            path: "s.txt".into(),
            lines: Some(1)
        }]
    );
}

#[tokio::test]
async fn a_subject_with_a_tab_is_kept_and_one_of_two_lines_is_given_as_one() {
    let dir = repository();
    commit_of(dir.path(), "a\tb", &[("b.txt", "b\n")]);
    commit_of(dir.path(), "line one\nline two", &[("c.txt", "c\n")]);
    let log = commit_log(dir.path(), 10, None).await.unwrap();
    assert_eq!(subjects(&log), vec!["line one line two", "a\tb", "first"]);
}

#[tokio::test]
async fn there_are_no_commits_before_the_first_and_no_repository_outside_one() {
    let fresh = tempdir().unwrap();
    git(fresh.path(), &["init", "-q"]);
    let log = commit_log(fresh.path(), 10, None).await.unwrap();
    assert!(log.repository && log.commits.is_empty() && !log.more);
    let plain = tempdir().unwrap();
    let outside = commit_log(plain.path(), 10, None).await.unwrap();
    assert!(!outside.repository && outside.commits.is_empty());
}

#[tokio::test]
async fn a_cursor_or_commit_that_is_not_a_hash_or_not_there_is_refused() {
    let dir = repository();
    for bad in ["--all", "HEAD"] {
        let refused = commit_log(dir.path(), 10, Some(bad)).await.unwrap_err();
        assert_eq!(refused.code, ErrorCode::BadRequest);
        let refused = commit_changes(dir.path(), bad, None).await.unwrap_err();
        assert_eq!(refused.code, ErrorCode::BadRequest);
    }
    let missing = commit_log(dir.path(), 10, Some("abcdef0"))
        .await
        .unwrap_err();
    assert_eq!(missing.code, ErrorCode::NotFound);
    let missing = commit_changes(dir.path(), "abcdef0", None)
        .await
        .unwrap_err();
    assert_eq!(missing.code, ErrorCode::NotFound);
    let head = git(dir.path(), &["rev-parse", "HEAD"]).trim().to_string();
    let nul = commit_changes(dir.path(), &head, Some("a\0b"))
        .await
        .unwrap_err();
    assert_eq!(nul.code, ErrorCode::BadRequest);
}

#[tokio::test]
async fn a_commit_is_what_it_changed_against_its_parent() {
    let dir = repository();
    let hash = commit_of(
        dir.path(),
        "change",
        &[("a.txt", "one\nTWO\nthree\n"), ("src/new.txt", "x\ny\n")],
    );
    let changes = commit_changes(dir.path(), &hash, None).await.unwrap();
    assert!(changes.repository);
    assert!(changes.patch.contains("-two") && changes.patch.contains("+TWO"));
    assert!(!changes.patch.contains("src/new.txt"));
    assert_eq!(
        changes.added,
        vec![AddedFile {
            path: "src/new.txt".into(),
            lines: Some(2)
        }]
    );
    let one = commit_changes(dir.path(), &hash, Some("src/new.txt"))
        .await
        .unwrap();
    assert!(one.patch.contains("+y"));
}

#[tokio::test]
async fn the_first_commit_is_compared_with_nothing_and_a_rename_is_one_file() {
    let dir = repository();
    let first = git(dir.path(), &["rev-list", "--max-parents=0", "HEAD"])
        .trim()
        .to_string();
    let changes = commit_changes(dir.path(), &first, None).await.unwrap();
    let mut paths: Vec<&str> = changes.added.iter().map(|f| f.path.as_str()).collect();
    paths.sort();
    assert_eq!(paths, vec![".gitignore", "a.txt", "gone.txt"]);
    git(dir.path(), &["mv", "gone.txt", "kept.txt"]);
    git(dir.path(), &["commit", "-q", "-m", "rename"]);
    let head = git(dir.path(), &["rev-parse", "HEAD"]).trim().to_string();
    let renamed = commit_changes(dir.path(), &head, None).await.unwrap();
    assert!(renamed.patch.contains("rename from gone.txt"));
    assert!(renamed.patch.contains("rename to kept.txt"));
}

#[tokio::test]
async fn a_diff_between_two_snapshots_holds_what_changed_from_one_to_the_other_whatever_the_working_tree_is_now(
) {
    let dir = repository();
    let before = snapshot_tree(dir.path()).await.unwrap().unwrap();
    put(dir.path(), "a.txt", "one\nTWO\nthree\n");
    put(dir.path(), "new.txt", "x\ny\n");
    let after = snapshot_tree(dir.path()).await.unwrap().unwrap();
    put(dir.path(), "a.txt", "changed again\n");
    put(dir.path(), "later.txt", "later\n");
    let changes = changes_between(dir.path(), &before, &after, None)
        .await
        .unwrap();
    assert!(changes.repository);
    assert!(changes.patch.contains("+TWO"), "{}", changes.patch);
    assert!(!changes.patch.contains("changed again"));
    assert_eq!(
        changes.added,
        vec![AddedFile {
            path: "new.txt".into(),
            lines: Some(2)
        }]
    );
    let one = changes_between(dir.path(), &before, &after, Some("new.txt"))
        .await
        .unwrap();
    assert!(one.patch.contains("+x"));
    assert_ne!(snapshot_tree(dir.path()).await.unwrap().unwrap(), after);
}

#[tokio::test]
async fn an_after_snapshot_that_is_not_there_is_not_found() {
    let dir = repository();
    let before = snapshot_tree(dir.path()).await.unwrap().unwrap();
    let error = changes_between(dir.path(), &before, &"b".repeat(40), None)
        .await
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::NotFound);
}

const REF: &str = "desktop/exec-1/key-1/start";

#[tokio::test]
async fn a_pinned_snapshot_survives_gc_under_refs_synapse_and_is_not_a_branch_or_a_tag() {
    let dir = repository();
    put(dir.path(), "pinned.txt", "only in the snapshot\n");
    let tree = snapshot_tree(dir.path()).await.unwrap().unwrap();
    fs::remove_file(dir.path().join("pinned.txt")).unwrap();
    pin_snapshot(dir.path(), REF, &tree).await.unwrap();
    assert_eq!(
        git(dir.path(), &["rev-parse", &format!("refs/synapse/{REF}")]).trim(),
        tree
    );
    git(dir.path(), &["gc", "-q", "--prune=now"]);
    git(dir.path(), &["cat-file", "-e", &tree]);
    let branch = git(dir.path(), &["symbolic-ref", "--short", "HEAD"]);
    assert_eq!(
        git(dir.path(), &["branch", "--list"]).trim(),
        format!("* {}", branch.trim())
    );
    assert_eq!(git(dir.path(), &["tag"]).trim(), "");
}

#[tokio::test]
async fn unpinning_removes_the_ref_and_unpinning_twice_is_not_an_error() {
    let dir = repository();
    let tree = snapshot_tree(dir.path()).await.unwrap().unwrap();
    pin_snapshot(dir.path(), REF, &tree).await.unwrap();
    unpin_snapshot(dir.path(), REF).await.unwrap();
    assert_eq!(
        git(dir.path(), &["for-each-ref", "refs/synapse/"]).trim(),
        ""
    );
    unpin_snapshot(dir.path(), REF).await.unwrap();
}

#[tokio::test]
async fn a_ref_that_is_not_one_of_the_apps_and_a_tree_that_is_not_there_are_refused() {
    let dir = repository();
    let tree = snapshot_tree(dir.path()).await.unwrap().unwrap();
    let branch = pin_snapshot(dir.path(), "heads/main", &tree)
        .await
        .unwrap_err();
    assert_eq!(branch.code, ErrorCode::BadRequest);
    let climb = unpin_snapshot(dir.path(), "desktop/exec-1/../start")
        .await
        .unwrap_err();
    assert_eq!(climb.code, ErrorCode::BadRequest);
    let missing = pin_snapshot(dir.path(), REF, &"c".repeat(40))
        .await
        .unwrap_err();
    assert_eq!(missing.code, ErrorCode::NotFound);
}

#[tokio::test]
async fn pinning_from_a_linked_worktree_leaves_the_refs_of_the_run_unchanged_and_refuses_their_names(
) {
    let dir = repository();
    let tree = snapshot_tree(dir.path()).await.unwrap().unwrap();
    for end in ["start", "end"] {
        let name = format!("refs/synapse/runs/exec-1/{end}");
        git(dir.path(), &["update-ref", &name, &tree]);
    }
    let run_refs = || {
        git(
            dir.path(),
            &[
                "for-each-ref",
                "--format=%(refname) %(objectname)",
                "refs/synapse/runs/",
            ],
        )
    };
    let before = run_refs();
    let parent = tempdir().unwrap();
    let linked = parent.path().join("linked");
    git(
        dir.path(),
        &[
            "worktree",
            "add",
            "-q",
            "--detach",
            linked.to_str().unwrap(),
        ],
    );
    put(&linked, "a.txt", "changed in the worktree\n");
    let other = snapshot_tree(&linked).await.unwrap().unwrap();
    assert_ne!(other, tree);
    for end in ["start", "end"] {
        let own = format!("desktop/exec-1/key-1/{end}");
        pin_snapshot(&linked, &own, &other).await.unwrap();
        assert_eq!(
            git(dir.path(), &["rev-parse", &format!("refs/synapse/{own}")]).trim(),
            other
        );
        unpin_snapshot(&linked, &own).await.unwrap();
        let theirs = format!("runs/exec-1/{end}");
        let pinned = pin_snapshot(&linked, &theirs, &other).await.unwrap_err();
        assert_eq!(pinned.code, ErrorCode::BadRequest);
        let unpinned = unpin_snapshot(&linked, &theirs).await.unwrap_err();
        assert_eq!(unpinned.code, ErrorCode::BadRequest);
    }
    assert_eq!(run_refs(), before);
    assert_eq!(
        git(dir.path(), &["for-each-ref", "refs/synapse/desktop/"]).trim(),
        ""
    );
}

#[tokio::test]
async fn a_folder_inside_a_repository_that_is_not_its_root_is_refused_and_nothing_is_pinned() {
    let dir = repository();
    put(dir.path(), "sub/file.txt", "in a folder\n");
    let tree = snapshot_tree(dir.path()).await.unwrap().unwrap();
    let inside = pin_snapshot(&dir.path().join("sub"), REF, &tree)
        .await
        .unwrap_err();
    assert_eq!(inside.code, ErrorCode::BadRequest);
    assert_eq!(
        inside.message,
        "the folder is not the root of a git repository"
    );
    assert_eq!(
        git(dir.path(), &["for-each-ref", "refs/synapse/"]).trim(),
        ""
    );
}
