//! Naming a namespace: `synapse/{repo}@{branch}/`.
//!
//! One implementation on purpose -- five inline copies of this logic used to
//! risk one refusing where another proceeds.
//!
//! A namespace is keyed by repo **and** branch, so the graph describes one
//! tree, not every branch at once. Worktrees need no disambiguation of their
//! own: git refuses to check out one branch in two worktrees, so a branch
//! already names at most one checkout. What they need is knowing where to
//! *look*, which is what the `.git`-file/`commondir` handling below is for.
//!
//! Nothing here spawns git -- four files (`.git`, `HEAD`, `commondir`,
//! `config`) answer the whole question, and reading them is exact where a
//! spawn is merely convenient, at zero cost against the hook budget.
//!
//! Not reproduced: `url.<base>.insteadOf` rewriting, which `git remote
//! get-url` applies and a config read does not. None are configured here
//! (checked); matching it would mean reimplementing git's whole config
//! resolution (repo + global + system, `include`/`includeIf`). If one ever
//! appears, the recorded remote stops matching and every component reports
//! the mismatch instead of writing -- a namespace is never silently migrated.
//!
//! Linked worktrees are handled, since this repo is one: `.git` may be a
//! *file* holding `gitdir: <path>`. Then `HEAD` lives in that per-worktree
//! directory while `config` lives in the *common* directory `commondir`
//! names beside it -- getting that backwards resolves a worktree to its
//! parent's branch.

const std = @import("std");

/// `std.Io.Dir`: `core` may only reach the system through an injected `Io`,
/// so it may not name `std.fs` directly either.
const Dir = std.Io.Dir;

/// The repo half of the key, taken from the **remote**, not the directory --
/// a linked worktree's directory basename differs from its parent's, and
/// deriving from it would put one repo's branches under two names. With no
/// remote, the caller passes the repo root path, whose basename is a stable
/// name for a local-only project.
pub fn repoName(remote: []const u8) []const u8 {
    var name = remote;
    if (name.len > 1 and name[name.len - 1] == '/') name = name[0 .. name.len - 1];
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |at| name = name[at + 1 ..];
    // `:` for the scp-like form (`git@host:org/repo.git`) -- also needed for
    // a remote with no slash at all (`host:repo.git`).
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |at| name = name[at + 1 ..];
    if (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - ".git".len];
    return name;
}

/// Characters a branch name may legally contain that a namespace directory
/// may not -- git permits `/` and a few others that are illegal filenames
/// elsewhere, so this is the vault's own illegal set, not git's ref rules.
pub const illegal_in_branch = "/:*?\"<>|";

/// The branch half, sanitised for use as one directory name.
pub fn sanitizeBranch(gpa: std.mem.Allocator, branch: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, branch);
    for (out) |*c| {
        if (std.mem.indexOfScalar(u8, illegal_in_branch, c.*) != null) c.* = '-';
    }
    return out;
}

/// `{repo}@{branch}`. `@` rather than `:`, which is illegal in a vault
/// filename and renders as `/` in macOS Finder.
pub fn namespace(gpa: std.mem.Allocator, repo: []const u8, sanitised_branch: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}@{s}", .{ repo, sanitised_branch });
}

/// What a detached HEAD gets: nothing. `rev-parse --abbrev-ref HEAD` would
/// return the literal string `HEAD`, identical across every detached
/// checkout -- a silently *shared* key. `symbolic-ref` also correctly
/// resolves an unborn branch (before the first commit), where `rev-parse`
/// fails with "ambiguous argument."
pub const detached_message =
    "synapse: detached HEAD -- a namespace is keyed by branch, so there is none here";

const testing = std.testing;

test "the repo name comes off the remote, in every form a remote takes" {
    try testing.expectEqualStrings("fw-core", repoName("ssh://git@host:7999/fw/fw-core.git"));
    try testing.expectEqualStrings("fw-core", repoName("git@github.com:org/fw-core.git"));
    try testing.expectEqualStrings("fw-core", repoName("https://github.com/org/fw-core"));
    try testing.expectEqualStrings("fw-core", repoName("/Users/x/Development/fw-core"));
    try testing.expectEqualStrings("repo", repoName("host:repo.git"));
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
    // A change here renames a namespace, which orphans every node in it.
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

/// Where a checkout's git metadata lives.
pub const Layout = struct {
    /// The working tree root: the directory containing `.git`.
    repo_root: []const u8,
    /// Per-worktree metadata. `HEAD` is here.
    git_dir: []const u8,
    /// Shared metadata. `config` is here. Equal to `git_dir` outside a worktree.
    common_dir: []const u8,

    pub fn deinit(self: Layout, gpa: std.mem.Allocator) void {
        gpa.free(self.repo_root);
        gpa.free(self.git_dir);
        gpa.free(self.common_dir);
    }
};

/// A resolved namespace, and everything it was derived from.
pub const Resolved = struct {
    layout: Layout,
    /// The remote URL used as identity, or the repo root when there is none.
    remote: []const u8,
    /// The branch as `HEAD` names it, unsanitised.
    branch: []const u8,
    /// The branch as a directory name.
    branch_key: []const u8,
    /// `{repo}@{branch_key}`.
    key: []const u8,

    pub fn deinit(self: Resolved, gpa: std.mem.Allocator) void {
        self.layout.deinit(gpa);
        gpa.free(self.remote);
        gpa.free(self.branch);
        gpa.free(self.branch_key);
        gpa.free(self.key);
    }
};

pub const Error = error{
    NotAGitRepo,
    /// A detached HEAD has no branch and therefore no namespace.
    DetachedHead,
};

/// The path a `.git` *file* points at, made absolute against the repo root.
/// The path may be relative -- git normally writes an absolute one, but a
/// repository moved with `git worktree repair`, or set up by hand, may not.
pub fn parseGitDirFile(content: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "gitdir:")) continue;
        const path = std.mem.trim(u8, trimmed["gitdir:".len..], " \t");
        if (path.len == 0) return null;
        return path;
    }
    return null;
}

/// The branch `HEAD` names, or null for a detached one. `symbolic-ref
/// --short HEAD`, deliberately not `rev-parse --abbrev-ref` -- see
/// `detached_message`. Also resolves an *unborn* branch correctly.
pub fn parseHead(content: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, content, " \t\r\n");
    if (!std.mem.startsWith(u8, line, "ref:")) return null;
    const ref = std.mem.trim(u8, line["ref:".len..], " \t");
    if (std.mem.startsWith(u8, ref, "refs/heads/")) {
        const branch = ref["refs/heads/".len..];
        return if (branch.len == 0) null else branch;
    }
    return null; // symbolic HEAD outside refs/heads is not a branch this can name
}

/// `remote.origin.url` from a git config file, else the first remote's url.
/// A hand-rolled reader for one key, not a config parser -- includes,
/// conditional includes and multi-valued keys belong to the resolution
/// chain this deliberately doesn't reimplement (see the module docstring).
pub fn remoteUrlFromConfig(config: []const u8, preferred: []const u8) ?[]const u8 {
    var first: ?[]const u8 = null;
    var in_remote = false;
    var is_preferred = false;

    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const header = line[1..close];
            in_remote = false;
            is_preferred = false;
            // `[remote "name"]`, and the legal-but-rare `[remote.name]`.
            if (std.mem.startsWith(u8, header, "remote")) {
                const rest = std.mem.trim(u8, header["remote".len..], " \t");
                const name = if (rest.len >= 2 and rest[0] == '"' and rest[rest.len - 1] == '"')
                    rest[1 .. rest.len - 1]
                else if (rest.len > 1 and rest[0] == '.')
                    rest[1..]
                else
                    "";
                if (name.len != 0) {
                    in_remote = true;
                    is_preferred = std.mem.eql(u8, name, preferred);
                }
            }
            continue;
        }
        if (!in_remote) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "url")) continue; // case-insensitive in git config
        const value = parseConfigValue(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        if (value.len == 0) continue;
        if (is_preferred) return value;
        if (first == null) first = value;
    }
    return first;
}

/// A config value: quotes stripped, an unquoted trailing comment cut.
fn parseConfigValue(raw: []const u8) []const u8 {
    if (raw.len >= 2 and raw[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, raw, 1, '"') orelse return raw[1..];
        return raw[1..close];
    }
    var end = raw.len;
    for (raw, 0..) |c, i| if (c == '#' or c == ';') {
        end = i;
        break;
    };
    return std.mem.trim(u8, raw[0..end], " \t");
}

/// Resolve the namespace for the repository containing `cwd`.
pub fn resolve(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) !Resolved {
    const layout = try findLayout(gpa, io, cwd);
    errdefer layout.deinit(gpa);

    const head_path = try std.fmt.allocPrint(gpa, "{s}/HEAD", .{layout.git_dir});
    defer gpa.free(head_path);
    const head = Dir.cwd().readFileAlloc(io, head_path, gpa, .limited(64 << 10)) catch
        return Error.NotAGitRepo;
    defer gpa.free(head);
    const branch_ref = parseHead(head) orelse return Error.DetachedHead;
    const branch = try gpa.dupe(u8, branch_ref);
    errdefer gpa.free(branch);

    const remote = try resolveRemote(gpa, io, layout);
    errdefer gpa.free(remote);
    const branch_key = try sanitizeBranch(gpa, branch);
    errdefer gpa.free(branch_key);
    const key = try namespace(gpa, repoName(remote), branch_key);

    return .{
        .layout = layout,
        .remote = remote,
        .branch = branch,
        .branch_key = branch_key,
        .key = key,
    };
}

/// Walk up from `cwd` for a `.git`, then follow it if it is a file.
fn findLayout(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) !Layout {
    const start = realPath(gpa, io, cwd) catch return Error.NotAGitRepo;
    defer gpa.free(start);

    var dir: []const u8 = start;
    while (true) {
        const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{dir});
        const st = Dir.cwd().statFile(io, dot_git, .{}) catch {
            gpa.free(dot_git);
            const parent = Dir.path.dirname(dir) orelse return Error.NotAGitRepo; // dirname("/") is null
            if (parent.len == dir.len) return Error.NotAGitRepo;
            dir = parent;
            continue;
        };

        const repo_root = try gpa.dupe(u8, dir);
        errdefer gpa.free(repo_root);

        if (st.kind == .directory) {
            errdefer gpa.free(dot_git);
            return .{
                .repo_root = repo_root,
                .git_dir = dot_git,
                .common_dir = try gpa.dupe(u8, dot_git),
            };
        }

        // A linked worktree: `.git` is a file naming the per-worktree git dir.
        defer gpa.free(dot_git);
        const content = Dir.cwd().readFileAlloc(io, dot_git, gpa, .limited(64 << 10)) catch
            return Error.NotAGitRepo;
        defer gpa.free(content);
        const named = parseGitDirFile(content) orelse return Error.NotAGitRepo;
        const git_dir = if (Dir.path.isAbsolute(named))
            try gpa.dupe(u8, named)
        else
            try Dir.path.join(gpa, &.{ repo_root, named });
        errdefer gpa.free(git_dir);

        // `commondir` names where the shared metadata is, relative to the
        // git dir -- `config` is there, never in the per-worktree directory.
        const common_path = try std.fmt.allocPrint(gpa, "{s}/commondir", .{git_dir});
        defer gpa.free(common_path);
        const common_dir = blk: {
            const rel = Dir.cwd().readFileAlloc(io, common_path, gpa, .limited(64 << 10)) catch
                break :blk try gpa.dupe(u8, git_dir);
            defer gpa.free(rel);
            const trimmed = std.mem.trim(u8, rel, " \t\r\n");
            if (trimmed.len == 0) break :blk try gpa.dupe(u8, git_dir);
            const joined = if (Dir.path.isAbsolute(trimmed))
                try gpa.dupe(u8, trimmed)
            else
                try Dir.path.join(gpa, &.{ git_dir, trimmed });
            defer gpa.free(joined);
            break :blk realPath(gpa, io, joined) catch try gpa.dupe(u8, joined); // resolve ../.. away
        };
        return .{ .repo_root = repo_root, .git_dir = git_dir, .common_dir = common_dir };
    }
}

/// `origin`, else the first remote in the config, else the repo root path --
/// a repo with no remote at all still gets a stable value.
fn resolveRemote(gpa: std.mem.Allocator, io: std.Io, layout: Layout) ![]u8 {
    const config_path = try std.fmt.allocPrint(gpa, "{s}/config", .{layout.common_dir});
    defer gpa.free(config_path);
    const config = Dir.cwd().readFileAlloc(io, config_path, gpa, .limited(8 << 20)) catch
        return gpa.dupe(u8, layout.repo_root);
    defer gpa.free(config);
    const url = remoteUrlFromConfig(config, "origin") orelse
        return gpa.dupe(u8, layout.repo_root);
    return gpa.dupe(u8, url);
}

/// The symlink-free form of `path`. Load-bearing: the staleness hook strips
/// the repo root as a string prefix off an edited file's path, and macOS
/// routinely reaches a project through a symlink (`/tmp` -> `/private/tmp`).
fn realPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var dir = try Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}

test "a .git file names the per-worktree git dir" {
    try testing.expectEqualStrings(
        "/Users/x/Development/synapse/.git/worktrees/zig-rewrite",
        parseGitDirFile("gitdir: /Users/x/Development/synapse/.git/worktrees/zig-rewrite\n").?,
    );
    try testing.expectEqualStrings("../.git/worktrees/wt", parseGitDirFile("gitdir: ../.git/worktrees/wt").?);
    try testing.expectEqual(@as(?[]const u8, null), parseGitDirFile("gitdir:\n"));
    try testing.expectEqual(@as(?[]const u8, null), parseGitDirFile("something else\n"));
}

test "HEAD names a branch, and a detached one names none" {
    try testing.expectEqualStrings("master", parseHead("ref: refs/heads/master\n").?);
    try testing.expectEqualStrings("feature/CORE-1", parseHead("ref: refs/heads/feature/CORE-1\n").?);
    try testing.expectEqual(
        @as(?[]const u8, null),
        parseHead("9f1c2b3d4e5f60718293a4b5c6d7e8f901234567\n"),
    );
    try testing.expectEqual(@as(?[]const u8, null), parseHead("ref: refs/remotes/origin/master\n"));
    try testing.expectEqual(@as(?[]const u8, null), parseHead(""));
}

test "the remote url comes out of a real config's shape" {
    const config =
        "[core]\n\trepositoryformatversion = 0\n\tbare = false\n" ++
        "[remote \"upstream\"]\n\turl = ssh://git@host/other.git\n\tfetch = +refs/heads/*:refs/remotes/upstream/*\n" ++
        "[remote \"origin\"]\n\turl = ssh://git@host:7999/fw/fw-core.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n" ++
        "[branch \"master\"]\n\tremote = origin\n\tmerge = refs/heads/master\n";
    try testing.expectEqualStrings(
        "ssh://git@host:7999/fw/fw-core.git",
        remoteUrlFromConfig(config, "origin").?,
    );
}

test "no origin falls back to the first remote, in file order" {
    const config =
        "[remote \"beta\"]\n\turl = ssh://git@host/beta.git\n" ++
        "[remote \"alpha\"]\n\turl = ssh://git@host/alpha.git\n";
    try testing.expectEqualStrings("ssh://git@host/beta.git", remoteUrlFromConfig(config, "origin").?);
}

test "a config with no remote at all yields nothing" {
    try testing.expectEqual(
        @as(?[]const u8, null),
        remoteUrlFromConfig("[core]\n\tbare = false\n", "origin"),
    );
    try testing.expectEqual(@as(?[]const u8, null), remoteUrlFromConfig("", "origin"));
}

test "comments, quotes and the deprecated subsection form" {
    try testing.expectEqualStrings("ssh://h/r.git", remoteUrlFromConfig(
        "# a comment\n[remote \"origin\"]\n\turl = ssh://h/r.git ; trailing\n",
        "origin",
    ).?);
    try testing.expectEqualStrings("ssh://h/r.git", remoteUrlFromConfig(
        "[remote \"origin\"]\n\turl = \"ssh://h/r.git\"\n",
        "origin",
    ).?);
    try testing.expectEqualStrings("ssh://h/r.git", remoteUrlFromConfig(
        "[remote.origin]\n\tURL = ssh://h/r.git\n",
        "origin",
    ).?);
    try testing.expectEqual(@as(?[]const u8, null), remoteUrlFromConfig(
        "[gui]\n\turl = ssh://h/wrong.git\n",
        "origin",
    ));
}

test "resolveRemote falls back to the first configured remote when there is no origin" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config",
        .data = "[core]\n\tbare = false\n[remote \"upstream\"]\n\turl = ssh://git@example.com/x/up.git\n",
    });
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const dir_path = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const layout: Layout = .{ .repo_root = dir_path, .git_dir = dir_path, .common_dir = dir_path };

    const remote = try resolveRemote(gpa, testing.io, layout);
    defer gpa.free(remote);
    try testing.expectEqualStrings("ssh://git@example.com/x/up.git", remote);
}

test "resolveRemote falls back to the repo root when there is no remote at all" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config", .data = "[core]\n\tbare = false\n" });
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const dir_path = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const layout: Layout = .{ .repo_root = dir_path, .git_dir = dir_path, .common_dir = dir_path };

    const remote = try resolveRemote(gpa, testing.io, layout);
    defer gpa.free(remote);
    try testing.expectEqualStrings(dir_path, remote);
}
