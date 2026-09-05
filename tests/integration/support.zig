//! Shared fixture for the Zig-native integration suite (`zig build
//! test-integration`) -- a real temp repo/vault/work/home directory tree and
//! a fake-bin-prepended `PATH`, spawning the real compiled binaries (their
//! paths come in through `build_options`, injected at `zig build` time off
//! each binary's own `Step.Compile`) as real subprocesses via
//! `adapters.process.run` -- the same spawn primitive `DiskStore`'s own git
//! calls already go through, not a new one.
//!
//! Only `HOME` and `SYNAPSE_VAULT_DIR` are overridden by default: this suite
//! exists to exercise real git-based namespace/branch/remote detection end
//! to end, so it deliberately leaves `SYNAPSE_NAMESPACE`/`REPO_ROOT`/
//! `BRANCH`/`REMOTE` unset rather than pinning them, unlike
//! `cmd_test_support.zig`'s `Fixture` for the native unit suite (which sets
//! all of them, for speed). A test that needs a specific value can still
//! `setEnv` it after `init()`.

const std = @import("std");
const adapters = @import("adapters");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Fixture = struct {
    gpa: Allocator,
    dir: std.Io.Dir,
    root: []const u8,
    repo: []const u8,
    vault: []const u8,
    work: []const u8,
    home: []const u8,
    env: std.process.Environ.Map,
    io_threaded: std.Io.Threaded,
    environ_block: std.process.Environ.PosixBlock,
    /// `build_options.*_bin` are cache-relative paths, resolved against the
    /// build root -- once a spawned child's own `cwd` points somewhere else
    /// (this fixture's temp repo), that relative path no longer resolves.
    /// Made absolute once here, before anything changes cwd for a child.
    synapse_bin: []const u8,
    synapse_fake_bin: []const u8,
    hook_bin: []const u8,
    bard_bin: []const u8,
    bard_hook_bin: []const u8,

    /// Everything spawned through this sees `env` verbatim -- an
    /// `Io.Threaded` built with no `environ` option falls back to a
    /// hardcoded default `PATH`, not the real one, so this is the only way
    /// to make `PATH` (fake-bin prepended) visible to a spawned binary.
    pub fn io(self: *Fixture) std.Io {
        return self.io_threaded.io();
    }

    pub fn init(gpa: Allocator) !Fixture {
        // Deliberately NOT `std.testing.tmpDir` -- that nests under this
        // checkout's own `.zig-cache/tmp/`, still genuinely inside this
        // repo's real git worktree. `core.identity.resolve`'s repo-root walk
        // spawns no `git` and consults no `GIT_CEILING_DIRECTORIES` -- it's
        // a plain upward directory walk that would ascend right past a
        // nested tmp dir and find this checkout's own real `.git`, exactly
        // wrong for a test asserting "outside any git repo." A real external
        // scratch dir under `/tmp` has nothing above it to find.
        var rand_bytes: [8]u8 = undefined;
        std.testing.io.random(&rand_bytes);
        const rand_id: u64 = std.mem.readInt(u64, &rand_bytes, .little);
        const root = try std.fmt.allocPrint(gpa, "/tmp/synapse-it-{x}", .{rand_id});
        errdefer gpa.free(root);

        try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
        errdefer dir.close(std.testing.io);

        const repo = try std.fmt.allocPrint(gpa, "{s}/repo", .{root});
        errdefer gpa.free(repo);
        const vault = try std.fmt.allocPrint(gpa, "{s}/vault", .{root});
        errdefer gpa.free(vault);
        const work = try std.fmt.allocPrint(gpa, "{s}/work", .{root});
        errdefer gpa.free(work);
        const home = try std.fmt.allocPrint(gpa, "{s}/home", .{root});
        errdefer gpa.free(home);

        try dir.createDirPath(std.testing.io, "repo");
        try dir.createDirPath(std.testing.io, "vault");
        try dir.createDirPath(std.testing.io, "work");
        try dir.createDirPath(std.testing.io, "home/.claude");

        var env = try std.process.Environ.createMap(std.testing.environ, gpa);
        errdefer env.deinit();
        // Belt-and-suspenders for any real `git` subprocess this fixture
        // spawns (`git`/`gitCommit`) -- `root` living under `/tmp` already
        // keeps it outside any repo, but this stops real git's own repo
        // discovery from ascending past it regardless. Git stops before
        // *entering* a listed directory, so the ceiling is `root`'s parent,
        // not `root` itself.
        try env.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root) orelse root);
        try env.put("HOME", home);
        try env.put("SYNAPSE_VAULT_DIR", vault);
        // Deliberately NOT set, unlike `cmd_test_support.zig`'s own Fixture:
        // SYNAPSE_NAMESPACE/REPO_ROOT/BRANCH/REMOTE/WORK_DIR are
        // `context.resolve()`'s escape hatch around real git-based
        // repo/namespace detection -- exactly the mechanism this suite
        // exists to exercise for real, spawning the actual binary. Setting
        // them here would silently bypass real detection for every test,
        // not just the ones that mean to. `work` is isolated because `HOME`
        // is overridden, so the default `$HOME/.cache/synapse/work/...`
        // path lands inside this fixture's own scratch tree without naming
        // it explicitly.
        // Same reasoning as cmd_test_support.zig's Fixture: a real install on
        // the machine running the suite must not leak into an isolated test.
        _ = env.swapRemove("SYNAPSE_CONTENT_ROOT");
        _ = env.swapRemove("CLAUDE_PLUGIN_ROOT");
        _ = env.swapRemove("XDG_CONFIG_HOME");

        // Absolute, not relative: `fake-bin/git`'s own self-recursion guard
        // matches its real absolute location against PATH, same reasoning as
        // cmd_test_support.zig's Fixture.
        var fake_bin_dir = try std.Io.Dir.cwd().openDir(std.testing.io, build_options.fake_bin_dir, .{});
        defer fake_bin_dir.close(std.testing.io);
        var fake_bin_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const fake_bin_abs = fake_bin_buf[0..try fake_bin_dir.realPath(std.testing.io, &fake_bin_buf)];
        const real_path = env.get("PATH") orelse "";
        const fake_bin = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ fake_bin_abs, real_path });
        defer gpa.free(fake_bin);
        try env.put("PATH", fake_bin);

        var block = try env.createPosixBlock(gpa, .{});
        errdefer block.deinit(gpa);
        var io_threaded: std.Io.Threaded = .init(gpa, .{ .environ = .{ .block = block } });
        errdefer io_threaded.deinit();

        const synapse_bin = try absolutePath(gpa, build_options.synapse_bin);
        errdefer gpa.free(synapse_bin);
        const synapse_fake_bin = try absolutePath(gpa, build_options.synapse_fake_bin);
        errdefer gpa.free(synapse_fake_bin);
        const hook_bin = try absolutePath(gpa, build_options.hook_bin);
        errdefer gpa.free(hook_bin);
        const bard_bin = try absolutePath(gpa, build_options.bard_bin);
        errdefer gpa.free(bard_bin);
        const bard_hook_bin = try absolutePath(gpa, build_options.bard_hook_bin);
        errdefer gpa.free(bard_hook_bin);

        return .{
            .gpa = gpa,
            .dir = dir,
            .root = root,
            .repo = repo,
            .vault = vault,
            .work = work,
            .home = home,
            .env = env,
            .io_threaded = io_threaded,
            .environ_block = block,
            .synapse_bin = synapse_bin,
            .synapse_fake_bin = synapse_fake_bin,
            .hook_bin = hook_bin,
            .bard_bin = bard_bin,
            .bard_hook_bin = bard_hook_bin,
        };
    }

    pub fn deinit(self: *Fixture) void {
        self.gpa.free(self.synapse_bin);
        self.gpa.free(self.synapse_fake_bin);
        self.gpa.free(self.hook_bin);
        self.gpa.free(self.bard_bin);
        self.gpa.free(self.bard_hook_bin);
        self.io_threaded.deinit();
        self.environ_block.deinit(self.gpa);
        self.env.deinit();
        self.gpa.free(self.home);
        self.gpa.free(self.work);
        self.gpa.free(self.vault);
        self.gpa.free(self.repo);
        self.dir.close(std.testing.io);
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.root) catch {};
        self.gpa.free(self.root);
    }

    /// Sets an env var every subsequent spawn through this fixture sees --
    /// for the handful of tests that need a specific `SYNAPSE_*` override
    /// (`WORK_DIR`, `CONTENT_ROOT`, ...) set per-test rather than for the
    /// whole suite. Rebuilds the environ block and the scoped `Io.Threaded`
    /// in place, since both are baked in at construction time and don't
    /// observe a later `env.put` on their own.
    pub fn setEnv(self: *Fixture, key: []const u8, value: []const u8) !void {
        try self.env.put(key, value);
        try self.rebuildIo();
    }

    fn rebuildIo(self: *Fixture) !void {
        var block = try self.env.createPosixBlock(self.gpa, .{});
        errdefer block.deinit(self.gpa);
        var io_threaded: std.Io.Threaded = .init(self.gpa, .{ .environ = .{ .block = block } });
        errdefer io_threaded.deinit();

        self.io_threaded.deinit();
        self.environ_block.deinit(self.gpa);
        self.io_threaded = io_threaded;
        self.environ_block = block;
    }

    /// A scratch `SYNAPSE_CONTENT_ROOT` holding only the shipped
    /// `graph-node/v1.yaml` schema, not this checkout's real
    /// `packages/synapse` -- needed by any test that writes a schema-
    /// declaring note (`write-node`/`push-nodes`, since `graph-node/v1`)
    /// through this fixture. Sets the env var and returns the path (owned
    /// by `self.env`, not the caller).
    pub fn setupSchemaContentRoot(self: *Fixture) ![]const u8 {
        const content_root = try std.fmt.allocPrint(self.gpa, "{s}/content", .{self.root});
        defer self.gpa.free(content_root);
        try self.dir.createDirPath(std.testing.io, "content/schema/graph-node");

        const src_path = try absolutePath(self.gpa, "packages/synapse/schema/graph-node/v1.yaml");
        defer self.gpa.free(src_path);
        const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, src_path, self.gpa, .limited(1 << 20));
        defer self.gpa.free(data);
        try self.dir.writeFile(std.testing.io, .{ .sub_path = "content/schema/graph-node/v1.yaml", .data = data });

        try self.setEnv("SYNAPSE_CONTENT_ROOT", content_root);
        return self.env.get("SYNAPSE_CONTENT_ROOT").?;
    }

    /// The `{repo}@{branch}` namespace key for `self.repo`, via the real
    /// shipped resolver (`synapse namespace`) rather than a reimplemented
    /// derivation -- `repo_name()`'s Zig equivalent. Caller frees.
    pub fn repoName(self: *Fixture) ![]u8 {
        const r = try self.runFake(&.{ "namespace", "--repo", self.repo });
        defer r.deinit(self.gpa);
        return self.gpa.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n"));
    }

    /// The project half of `repoName()`, before the last `@`. Caller frees.
    pub fn nsRepo(self: *Fixture) ![]u8 {
        const ns = try self.repoName();
        defer self.gpa.free(ns);
        const at = std.mem.lastIndexOfScalar(u8, ns, '@') orelse ns.len;
        return self.gpa.dupe(u8, ns[0..at]);
    }

    /// Removes an env var every subsequent spawn through this fixture sees
    /// -- for the handful of tests that check behavior with no vault
    /// configured at all. Rebuilds the environ block and the scoped
    /// `Io.Threaded` in place, same reasoning as `setEnv`.
    pub fn unsetEnv(self: *Fixture, key: []const u8) !void {
        _ = self.env.swapRemove(key);
        try self.rebuildIo();
    }

    /// The branch half of `repoName()`, after the last `@`. Caller frees.
    pub fn nsBranch(self: *Fixture) ![]u8 {
        const ns = try self.repoName();
        defer self.gpa.free(ns);
        const at = std.mem.lastIndexOfScalar(u8, ns, '@') orelse return self.gpa.dupe(u8, "");
        return self.gpa.dupe(u8, ns[at + 1 ..]);
    }

    /// Writes a Synapse per-project `Index.md` with the given `remote`
    /// frontmatter value, matching the shape `/synapse-init` produces --
    /// `write_synapse_index()`'s Zig equivalent. `namespace` is the full
    /// `{repo}@{branch}` key (also the subfolder name); `project`/`branch`
    /// inside are split from it the same way the real builder does.
    pub fn writeSynapseIndex(self: *Fixture, namespace: []const u8, remote: []const u8) !void {
        const branch_res = try self.runFake(&.{ "namespace", "--repo", self.repo, "--branch" });
        defer branch_res.deinit(self.gpa);
        const branch = std.mem.trim(u8, branch_res.stdout, " \t\r\n");

        const at = std.mem.lastIndexOfScalar(u8, namespace, '@') orelse namespace.len;
        const project = namespace[0..at];

        const ns_dir = try std.fmt.allocPrint(self.gpa, "vault/synapse/{s}", .{namespace});
        defer self.gpa.free(ns_dir);
        try self.dir.createDirPath(std.testing.io, ns_dir);

        const index_path = try std.fmt.allocPrint(self.gpa, "{s}/Index.md", .{ns_dir});
        defer self.gpa.free(index_path);
        const index_body = try std.fmt.allocPrint(self.gpa,
            \\---
            \\title: "{s} — Synapse index"
            \\node_type: synapse-index
            \\project: {s}
            \\branch: {s}
            \\remote: "{s}"
            \\built_at: "test"
            \\---
            \\# {s} — Synapse index
            \\
        , .{ namespace, project, branch, remote, namespace });
        defer self.gpa.free(index_body);
        try self.dir.writeFile(std.testing.io, .{ .sub_path = index_path, .data = index_body });
    }

    /// `git remote get-url origin`, falling back to the real repo root --
    /// `repo_remote_or_path()`'s Zig equivalent. Caller frees.
    pub fn repoRemoteOrPath(self: *Fixture) ![]u8 {
        const remote_res = try self.git(&.{ "remote", "get-url", "origin" });
        defer remote_res.deinit(self.gpa);
        if (remote_res.ok()) return self.gpa.dupe(u8, std.mem.trim(u8, remote_res.stdout, " \t\r\n"));

        const top_res = try self.git(&.{ "rev-parse", "--show-toplevel" });
        defer top_res.deinit(self.gpa);
        return self.gpa.dupe(u8, std.mem.trim(u8, top_res.stdout, " \t\r\n"));
    }

    /// `$HOME/.cache/synapse/work/{namespace}` -- `default_work_dir()`'s Zig
    /// equivalent, the path every component defaults to when
    /// `SYNAPSE_WORK_DIR` isn't set. Caller frees.
    pub fn defaultWorkDir(self: *Fixture) ![]u8 {
        const ns = try self.repoName();
        defer self.gpa.free(ns);
        return std.fmt.allocPrint(self.gpa, "{s}/.cache/synapse/work/{s}", .{ self.home, ns });
    }

    pub const IndexPair = struct { path: []const u8, node: []const u8 };

    /// Writes `work`'s `_index.bin` from `path<TAB>node` pairs, through the
    /// real shipped `synapse index build` -- `write_index_bin()`'s Zig
    /// equivalent. No unassigned entries (every real caller of this in the
    /// ported tests wants a fully-claimed index).
    pub fn writeIndexBin(self: *Fixture, work_dir: []const u8, pairs: []const IndexPair) !void {
        var stdin: std.ArrayListUnmanaged(u8) = .empty;
        defer stdin.deinit(self.gpa);
        for (pairs) |p| {
            try stdin.appendSlice(self.gpa, p.path);
            try stdin.append(self.gpa, '\t');
            try stdin.appendSlice(self.gpa, p.node);
            try stdin.append(self.gpa, '\n');
        }

        try std.Io.Dir.cwd().createDirPath(std.testing.io, work_dir);
        const un = try std.fmt.allocPrint(self.gpa, "{s}/.unassigned-fixture", .{work_dir});
        defer self.gpa.free(un);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = un, .data = "" });
        const out = try std.fmt.allocPrint(self.gpa, "{s}/_index.bin", .{work_dir});
        defer self.gpa.free(out);

        var full = [_][]const u8{ self.synapse_fake_bin, "index", "build", "--unassigned", un, "--out", out };
        const r = try adapters.process.run(self.io(), self.gpa, &full, .{ .cwd = .{ .path = self.repo }, .stdin = stdin.items });
        defer r.deinit(self.gpa);
        if (!r.ok()) return error.IndexBuildFailed;
        std.Io.Dir.cwd().deleteFile(std.testing.io, un) catch {};
    }

    /// Runs the real compiled `synapse` binary against this fixture's own
    /// scratch dirs, from `self.repo` unless `cwd` overrides it. Thin wrapper
    /// over `adapters.process.run` -- no new spawn mechanics, just the
    /// binary path and this fixture's `Io`/cwd default filled in.
    pub fn runSynapse(self: *Fixture, argv: []const []const u8) !adapters.process.Result {
        return self.runBin(self.synapse_bin, argv);
    }

    /// `synapse-fake` -- the same app as `synapse`, grammar compile-and-load
    /// stubbed out, needed so the suite runs with no network, no C toolchain,
    /// and no real grammar repository. What most CLI-usage checks spawn,
    /// since grammar compilation itself is irrelevant to them.
    pub fn runFake(self: *Fixture, argv: []const []const u8) !adapters.process.Result {
        return self.runBin(self.synapse_fake_bin, argv);
    }

    pub fn runHook(self: *Fixture, argv: []const []const u8) !adapters.process.Result {
        return self.runBin(self.hook_bin, argv);
    }

    pub fn runBard(self: *Fixture, argv: []const []const u8) !adapters.process.Result {
        return self.runBin(self.bard_bin, argv);
    }

    pub fn runBardHook(self: *Fixture, argv: []const []const u8) !adapters.process.Result {
        return self.runBin(self.bard_hook_bin, argv);
    }

    fn runBin(self: *Fixture, bin: []const u8, argv: []const []const u8) !adapters.process.Result {
        return self.runBinAt(bin, argv, self.repo);
    }

    /// Same as `runBin`, from an explicit `cwd` instead of `self.repo` -- for
    /// the handful of tests that specifically check behavior outside any
    /// repo, or against a differently staged directory.
    fn runBinAt(self: *Fixture, bin: []const u8, argv: []const []const u8, cwd: []const u8) !adapters.process.Result {
        var full = try self.gpa.alloc([]const u8, argv.len + 1);
        defer self.gpa.free(full);
        full[0] = bin;
        for (argv, 0..) |a, i| full[i + 1] = a;
        return adapters.process.run(self.io(), self.gpa, full, .{ .cwd = .{ .path = cwd } });
    }

    /// `runSynapse`, but from `self.root` (the fixture's own top-level
    /// scratch dir) instead of `self.repo` -- the "outside any git repo"
    /// case several usage-error tests check.
    pub fn runSynapseOutsideRepo(self: *Fixture, argv: []const []const u8) !adapters.process.Result {
        return self.runBinAt(self.synapse_bin, argv, self.root);
    }

    /// A file under the fixture's repo dir, parent directories included.
    pub fn writeRepoFile(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (std.fs.path.dirname(sub_path)) |d| {
            const full_dir = try std.fmt.bufPrint(&path_buf, "repo/{s}", .{d});
            try self.dir.createDirPath(std.testing.io, full_dir);
        }
        const full = try std.fmt.allocPrint(self.gpa, "repo/{s}", .{sub_path});
        defer self.gpa.free(full);
        try self.dir.writeFile(std.testing.io, .{ .sub_path = full, .data = data });
    }

    /// `git init` plus one commit adding everything currently in the
    /// fixture's repo dir -- for a test that genuinely needs real git
    /// (identity resolution, real remotes), not the `SYNAPSE_*` env-var
    /// bypass most fixtures use instead.
    pub fn gitCommit(self: *Fixture, message: []const u8) !void {
        const init_res = try adapters.process.run(self.io(), self.gpa, &.{ "git", "init", "-q", "-b", "main" }, .{
            .cwd = .{ .path = self.repo },
        });
        defer init_res.deinit(self.gpa);
        const add_res = try adapters.process.run(self.io(), self.gpa, &.{ "git", "add", "-A" }, .{
            .cwd = .{ .path = self.repo },
        });
        defer add_res.deinit(self.gpa);
        const commit_res = try adapters.process.run(self.io(), self.gpa, &.{
            "git",           "-c", "user.email=test@test",
            "-c",            "user.name=test",
            "commit",        "-q", "-m",
            message,
        }, .{ .cwd = .{ .path = self.repo } });
        defer commit_res.deinit(self.gpa);
    }

    /// A throwaway git repo at `self.repo` with one tracked file and an
    /// initial commit -- `make_repo()`'s Zig equivalent. `remote`, if given,
    /// is a local git-config-only remote, never fetched from or pushed to.
    pub fn makeRepo(self: *Fixture, remote: ?[]const u8) !void {
        try self.writeRepoFile("src/foo.aa", "let x = 1\n");
        try self.gitCommit("init");
        if (remote) |r| {
            const res = try self.git(&.{ "remote", "add", "origin", r });
            res.deinit(self.gpa);
        }
    }

    /// Any other real `git` command against the fixture's repo. Caller frees.
    pub fn git(self: *Fixture, args: []const []const u8) !adapters.process.Result {
        var argv_buf: [16][]const u8 = undefined;
        argv_buf[0] = "git";
        @memcpy(argv_buf[1 .. 1 + args.len], args);
        return adapters.process.run(self.io(), self.gpa, argv_buf[0 .. 1 + args.len], .{
            .cwd = .{ .path = self.repo },
        });
    }

    /// `git <args>`'s trimmed stdout, for the common case of reading one
    /// value back (a SHA, a branch name). Caller frees.
    pub fn gitOutput(self: *Fixture, args: []const []const u8) ![]u8 {
        const res = try self.git(args);
        defer res.deinit(self.gpa);
        return self.gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
    }

    /// Feeds `stdin` to the real binary instead of no input -- the shape
    /// `synapse-hook`'s own JSON-payload commands need.
    pub fn runHookStdin(self: *Fixture, argv: []const []const u8, stdin: []const u8) !adapters.process.Result {
        return self.runBinStdin(self.hook_bin, argv, stdin);
    }

    /// `runFake`, but feeding `stdin` -- for `tags-cache --load` and
    /// anything else that reads its own dump-format on stdin.
    pub fn runFakeStdin(self: *Fixture, argv: []const []const u8, stdin: []const u8) !adapters.process.Result {
        return self.runBinStdin(self.synapse_fake_bin, argv, stdin);
    }

    fn runBinStdin(self: *Fixture, bin: []const u8, argv: []const []const u8, stdin: []const u8) !adapters.process.Result {
        var full = try self.gpa.alloc([]const u8, argv.len + 1);
        defer self.gpa.free(full);
        full[0] = bin;
        for (argv, 0..) |a, i| full[i + 1] = a;
        return adapters.process.run(self.io(), self.gpa, full, .{ .cwd = .{ .path = self.repo }, .stdin = stdin });
    }
};

/// `rel` (a build-root-relative path, as every `build_options.*_bin` value
/// is) resolved to an absolute one against the test process's own real cwd
/// -- which is the build root, since `zig build test-integration`'s Run
/// step inherits it, and nothing here has changed it yet. Must run before
/// any fixture points a spawned child's own `cwd` elsewhere.
fn absolutePath(gpa: Allocator, rel: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, std.fs.path.dirname(rel) orelse ".", .{});
    defer dir.close(std.testing.io);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = buf[0..try dir.realPath(std.testing.io, &buf)];
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ resolved, std.fs.path.basename(rel) });
}

const testing = std.testing;

test "runSynapse spawns the real built binary and captures its output" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const res = try fx.runSynapse(&.{"--help"});
    defer res.deinit(testing.allocator);

    try testing.expect(res.ok());
    try testing.expect(res.stderr.len != 0);
}

test "PATH is fake-bin prepended, so a spawned git resolves to the scripted stand-in" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const res = try adapters.process.run(fx.io(), testing.allocator, &.{ "git", "--version" }, .{});
    defer res.deinit(testing.allocator);

    try testing.expect(res.ok());
}
