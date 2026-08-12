//! Naming a namespace: `synapse/{repo}@{branch}/`.
//!
//! One implementation on purpose. `synapse-staleness.sh` carried a comment warning
//! that a divergent resolution chain makes one component refuse where another
//! proceeds, and that warning applied to five inline copies of the same logic; the
//! shell library that replaced them was that chain once, and this is the same chain
//! again with the git calls lifted out.
//!
//! A namespace is keyed by repo **and** branch, so the graph describes one tree rather
//! than every branch at once. Worktrees need no handling of their own: git refuses to
//! check out one branch in two worktrees of a repository (the main checkout included),
//! so a branch already names at most one checkout. That is why there is no `.git`-file
//! parsing here, no `gitdir:` or `commondir` walking, and no
//! worktree-versus-submodule discrimination -- the whole question reduces to which
//! branch is checked out.
//!
//! ## Why the git calls did not move in here with the rules
//!
//! Reading `.git/config` directly would be spawn-free and wrong. `git remote get-url`
//! applies `url.<base>.insteadOf` rewriting and reading the config file does not --
//! verified, they return different strings for a checkout with such a rule. Identity
//! that changed the day someone added an `insteadOf` line would silently move a
//! repository into a different namespace, which is the one failure this file exists to
//! prevent. So the caller spawns git, and what lives here is everything that is a
//! function of git's answers.

const std = @import("std");

/// The repo half of the key, taken from the **remote** rather than the directory.
///
/// A linked worktree's directory basename differs from its parent's, and that
/// difference is exactly what must stop mattering -- deriving from the directory would
/// put one repo's branches under two different names. When there is no remote at all
/// the caller passes the repo root path, which is what the shell's fallback chain
/// produced, and the basename of that is a stable name for a local-only project.
pub fn repoName(remote: []const u8) []const u8 {
    var name = remote;
    // A trailing slash would otherwise make the basename empty.
    while (name.len > 1 and name[name.len - 1] == '/') name = name[0 .. name.len - 1];
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |at| name = name[at + 1 ..];
    // `:` for the scp-like form, `git@host:org/repo.git`, whose last segment after a
    // slash is already the repo -- but a remote with no slash at all (`host:repo.git`)
    // needs the colon cut too.
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |at| name = name[at + 1 ..];
    if (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - ".git".len];
    return name;
}

/// The characters a branch name may legally contain that a namespace directory may
/// not.
///
/// Branch names legally contain `/` (`feature/CORE-101490-…`), which would silently
/// create nesting, and git permits a few characters that are illegal in filenames
/// elsewhere -- so the vault's own illegal set is translated too rather than trusting
/// git's ref rules to be a filename whitelist.
pub const illegal_in_branch = "/:*?\"<>|";

/// The branch half, sanitised for use as one directory name.
pub fn sanitizeBranch(gpa: std.mem.Allocator, branch: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, branch);
    for (out) |*c| {
        if (std.mem.indexOfScalar(u8, illegal_in_branch, c.*) != null) c.* = '-';
    }
    return out;
}

/// `{repo}@{branch}`.
///
/// `@` rather than `:` because `:` is illegal in a vault filename and renders as `/`
/// in macOS Finder. Flat rather than nested, so every caller keeps building
/// `synapse/{ns}/…` with a single variable segment.
pub fn namespace(gpa: std.mem.Allocator, repo: []const u8, sanitised_branch: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}@{s}", .{ repo, sanitised_branch });
}

/// What a detached HEAD gets: nothing.
///
/// `git symbolic-ref --short HEAD` fails there, and that failure is the correct
/// answer. `rev-parse --abbrev-ref HEAD` returns the literal string `HEAD` instead --
/// a plausible-looking value identical across every detached checkout everywhere, so
/// it would silently become a *shared* key. The other reason for `symbolic-ref` is the
/// opposite case: before the first commit the branch exists but points at nothing,
/// where `rev-parse` fails with "ambiguous argument 'HEAD'" and `symbolic-ref` reports
/// the unborn branch correctly -- and a repo mid-`/synapse-init` on a fresh branch is a
/// real case that should resolve.
pub const detached_message =
    "synapse: detached HEAD -- a namespace is keyed by branch, so there is none here";

const testing = std.testing;

test "the repo name comes off the remote, in every form a remote takes" {
    try testing.expectEqualStrings("fw-core", repoName("ssh://git@host:7999/fw/fw-core.git"));
    try testing.expectEqualStrings("fw-core", repoName("git@github.com:org/fw-core.git"));
    try testing.expectEqualStrings("fw-core", repoName("https://github.com/org/fw-core"));
    try testing.expectEqualStrings("fw-core", repoName("/Users/x/Development/fw-core"));
    // The scp-like form with no path at all still has to cut the colon.
    try testing.expectEqualStrings("repo", repoName("host:repo.git"));
    // A trailing slash would otherwise produce an empty name.
    try testing.expectEqualStrings("fw-core", repoName("https://github.com/org/fw-core/"));
}

test "a name containing .git only loses a trailing one" {
    try testing.expectEqualStrings("dot.git.inside", repoName("/x/dot.git.inside"));
    try testing.expectEqualStrings(".gitignore-tools", repoName("/x/.gitignore-tools"));
}

test "a branch is sanitised to one directory name" {
    const gpa = testing.allocator;
    const b = try sanitizeBranch(gpa, "feature/CORE-101490-deployment-mode");
    defer gpa.free(b);
    // The slash is the case that matters: left alone it would silently create
    // nesting, and every caller builds `synapse/{ns}/…` with one variable segment.
    try testing.expectEqualStrings("feature-CORE-101490-deployment-mode", b);

    const nasty = try sanitizeBranch(gpa, "a:b*c?d\"e<f>g|h");
    defer gpa.free(nasty);
    try testing.expectEqualStrings("a-b-c-d-e-f-g-h", nasty);
}

test "the namespace key is repo@branch" {
    const gpa = testing.allocator;
    const ns = try namespace(gpa, "fw-core", "master");
    defer gpa.free(ns);
    try testing.expectEqualStrings("fw-core@master", ns);
}

test "the shipped namespaces resolve to the names the vault already holds" {
    const gpa = testing.allocator;
    // The three real remotes, against the three directory names in the vault. This is
    // the whole contract: a change here renames a namespace, which orphans every node
    // in it.
    const cases = [_]struct { remote: []const u8, branch: []const u8, key: []const u8 }{
        .{
            .remote = "ssh://git@git.devres.internal.adcubum.com:7999/fw/fw-core.git",
            .branch = "master",
            .key = "fw-core@master",
        },
        .{
            .remote = "ssh://git@git.devres.internal.adcubum.com:7999/qstb/syrius-querschnitt-basis.git",
            .branch = "master",
            .key = "syrius-querschnitt-basis@master",
        },
        .{
            .remote = "ssh://git@git.devres.internal.adcubum.com:7999/syr/syrius3.git",
            .branch = "master",
            .key = "syrius3@master",
        },
    };
    for (cases) |c| {
        const branch = try sanitizeBranch(gpa, c.branch);
        defer gpa.free(branch);
        const key = try namespace(gpa, repoName(c.remote), branch);
        defer gpa.free(key);
        try testing.expectEqualStrings(c.key, key);
    }
}
