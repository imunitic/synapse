//! A real `Context` plus a real Obsidian PUT, for `*_cmd.zig` native tests
//! that need both without a real vault, a real git repo, or a real network
//! call.
//!
//! Reuses `tests/fixtures/fake-bin/curl` rather than a second, divergent
//! fake -- one script defines what a PUT/GET/search looks like, for both
//! the bats suite and native tests. `context.resolve`'s own env-var
//! overrides (`SYNAPSE_NAMESPACE`/`REPO_ROOT`/`BRANCH`/`REMOTE`/`WORK_DIR`)
//! are what let this skip real git entirely -- the same escape hatch the
//! bats suite pins fixture repos through.
//!
//! Established for `write_node_cmd.zig`; reusable by any future `*_cmd.zig`
//! native-test migration that needs a Context and/or a store.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const context = @import("context.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Fixture = struct {
    gpa: Allocator,
    tmp: testing.TmpDir,
    root: []const u8,
    repo: []const u8,
    vault: []const u8,
    work: []const u8,
    home: []const u8,
    curl_log: []const u8,
    env: std.process.Environ.Map,
    io_threaded: std.Io.Threaded,
    environ_block: std.process.Environ.PosixBlock,

    /// Everything spawned through this (curl, git, date) sees `env`
    /// verbatim -- an `Io.Threaded` built with no `environ` option falls
    /// back to a hardcoded `default_PATH`, not the real environment, so
    /// this is the only way to make `PATH` (fake-bin prepended) and the
    /// `FAKE_CURL_*` vars visible to a child process at all.
    pub fn io(self: *Fixture) std.Io {
        return self.io_threaded.io();
    }

    pub fn init(gpa: Allocator) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try gpa.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
        errdefer gpa.free(root);

        const repo = try std.fmt.allocPrint(gpa, "{s}/repo", .{root});
        errdefer gpa.free(repo);
        const vault = try std.fmt.allocPrint(gpa, "{s}/vault", .{root});
        errdefer gpa.free(vault);
        const work = try std.fmt.allocPrint(gpa, "{s}/work", .{root});
        errdefer gpa.free(work);
        const home = try std.fmt.allocPrint(gpa, "{s}/home", .{root});
        errdefer gpa.free(home);
        const curl_log = try std.fmt.allocPrint(gpa, "{s}/curl.log", .{root});
        errdefer gpa.free(curl_log);

        try tmp.dir.createDirPath(testing.io, "repo");
        try tmp.dir.createDirPath(testing.io, "vault/.obsidian/plugins/obsidian-local-rest-api");
        try tmp.dir.createDirPath(testing.io, "work");
        try tmp.dir.createDirPath(testing.io, "home");
        try tmp.dir.writeFile(testing.io, .{
            .sub_path = "vault/.obsidian/plugins/obsidian-local-rest-api/data.json",
            .data = "{\"apiKey\":\"test-key\",\"port\":27124}",
        });

        var env = try std.process.Environ.createMap(testing.environ, gpa);
        errdefer env.deinit();
        try env.put("HOME", home);
        try env.put("OBSIDIAN_VAULT_DIR", vault);
        try env.put("SYNAPSE_NAMESPACE", "repo@main");
        try env.put("SYNAPSE_REPO_ROOT", repo);
        try env.put("SYNAPSE_BRANCH", "main");
        try env.put("SYNAPSE_REMOTE", "");
        try env.put("SYNAPSE_WORK_DIR", work);
        try env.put("SYNAPSE_DISABLE_SYMBOL_CACHE", "1");
        try env.put("FAKE_CURL_LOG", curl_log);
        try env.put("FAKE_CURL_VAULT_DIR", vault);

        // Absolute, not just a resolvable relative path: `tests/fixtures/
        // fake-bin/git` strips its own directory from PATH by computing its
        // real absolute location and grep -F-matching that string against
        // PATH, to `exec` the real `git` underneath without recursing into
        // itself. A relative PATH entry ("tests/fixtures/fake-bin") never
        // matches that absolute string, so the strip silently no-ops and
        // the script re-execs itself as `git` forever, spinning at 100% CPU
        // until killed. `curl` has no such self-check,
        // so this was invisible until a test first spawned `git` for real.
        // `Io.Dir.cwd().realPath` (the cwd sentinel itself) fails with
        // FileNotFound in this test environment. Opening
        // the relative path as a real directory handle first and resolving
        // *that* sidesteps it; the same pattern `tmp.dir.realPath` above
        // already relies on for a non-sentinel handle.
        var fake_bin_dir = try std.Io.Dir.cwd().openDir(testing.io, "tests/fixtures/fake-bin", .{});
        defer fake_bin_dir.close(testing.io);
        var fake_bin_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const fake_bin_abs = fake_bin_buf[0..try fake_bin_dir.realPath(testing.io, &fake_bin_buf)];
        const real_path = env.get("PATH") orelse "";
        const fake_bin = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ fake_bin_abs, real_path });
        defer gpa.free(fake_bin);
        try env.put("PATH", fake_bin);

        var block = try env.createPosixBlock(gpa, .{});
        errdefer block.deinit(gpa);
        var io_threaded: std.Io.Threaded = .init(gpa, .{ .environ = .{ .block = block } });
        errdefer io_threaded.deinit();

        return .{
            .gpa = gpa,
            .tmp = tmp,
            .root = root,
            .repo = repo,
            .vault = vault,
            .work = work,
            .home = home,
            .curl_log = curl_log,
            .env = env,
            .io_threaded = io_threaded,
            .environ_block = block,
        };
    }

    pub fn deinit(self: *Fixture) void {
        self.io_threaded.deinit();
        self.environ_block.deinit(self.gpa);
        self.env.deinit();
        self.gpa.free(self.curl_log);
        self.gpa.free(self.home);
        self.gpa.free(self.work);
        self.gpa.free(self.vault);
        self.gpa.free(self.repo);
        self.gpa.free(self.root);
        self.tmp.cleanup();
    }

    /// A file under the fixture's repo dir, parent directories included.
    pub fn writeRepoFile(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir_part = std.fs.path.dirname(sub_path);
        if (dir_part) |d| {
            const full_dir = try std.fmt.bufPrint(&path_buf, "repo/{s}", .{d});
            try self.tmp.dir.createDirPath(testing.io, full_dir);
        }
        const full = try std.fmt.allocPrint(self.gpa, "repo/{s}", .{sub_path});
        defer self.gpa.free(full);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = full, .data = data });
    }

    /// A node as the fake-curl PUT left it in the fixture's vault, or null
    /// if nothing was ever written there.
    pub fn readNode(self: *Fixture, gpa: Allocator, title: []const u8) !?[]u8 {
        const sub = try std.fmt.allocPrint(self.gpa, "vault/synapse/repo@main/{s}.md", .{title});
        defer self.gpa.free(sub);
        return self.tmp.dir.readFileAlloc(testing.io, sub, gpa, .limited(1 << 20)) catch null;
    }

    /// A file written directly at an arbitrary vault-relative path -- for a
    /// command (`frontmatter`) that addresses the vault directly rather
    /// than through one repo's `synapse/{namespace}/` code-graph directory.
    pub fn writeVaultFile(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir_part = std.fs.path.dirname(sub_path);
        if (dir_part) |d| {
            const full_dir = try std.fmt.bufPrint(&path_buf, "vault/{s}", .{d});
            try self.tmp.dir.createDirPath(testing.io, full_dir);
        }
        const full = try std.fmt.allocPrint(self.gpa, "vault/{s}", .{sub_path});
        defer self.gpa.free(full);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = full, .data = data });
    }

    /// The raw bytes at an arbitrary vault-relative path, as a PUT (real or
    /// fake-curl) left it, or null if nothing is there.
    pub fn readVaultFile(self: *Fixture, gpa: Allocator, sub_path: []const u8) !?[]u8 {
        const full = try std.fmt.allocPrint(self.gpa, "vault/{s}", .{sub_path});
        defer self.gpa.free(full);
        return self.tmp.dir.readFileAlloc(testing.io, full, gpa, .limited(1 << 20)) catch null;
    }

    pub fn resolveContext(self: *Fixture) !context.Context {
        return (try context.resolve(self.gpa, self.io(), &self.env, "test")).?;
    }

    /// `synapse/repo@main/Index.md`, the namespace marker `write()` checks
    /// an existing remote/branch against. Absent means a first-time build,
    /// which `write()` allows unconditionally.
    pub fn writeIndex(self: *Fixture, remote: []const u8, branch: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, "vault/synapse/repo@main");
        const data = try std.fmt.allocPrint(self.gpa,
            \\---
            \\title: "repo@main -- Synapse index"
            \\node_type: synapse-index
            \\project: repo
            \\branch: {s}
            \\remote: "{s}"
            \\built_at: "test"
            \\---
            \\# repo@main -- Synapse index
            \\
        , .{ branch, remote });
        defer self.gpa.free(data);
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = "vault/synapse/repo@main/Index.md",
            .data = data,
        });
    }

    /// A node file written directly into the fixture's vault -- for tests
    /// of a read-only query command, which doesn't care how the node came
    /// to exist, only what's in it.
    pub fn writeNodeFile(self: *Fixture, title: []const u8, content: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, "vault/synapse/repo@main");
        const sub = try std.fmt.allocPrint(self.gpa, "vault/synapse/repo@main/{s}.md", .{title});
        defer self.gpa.free(sub);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = content });
    }

    /// `$HOME/.claude/synapse-grammars.conf` registering `.ml` (matching
    /// `fake_grammar.FakeBackend`'s taggable extensions) to a fake repo URL
    /// -- for any `*_cmd.zig` test that tags through
    /// `fake_grammar.FakeExtractor`. The registry lookup happens before the
    /// fake backend ever runs, so an unregistered extension scores
    /// `.unsupported` without `FakeBackend.tagFile` being reached at all;
    /// `Ex.prepare`'s `git clone` of the URL is intercepted by
    /// `tests/fixtures/fake-bin/git`'s `clone`-only stub, already on every
    /// fixture's `PATH`.
    pub fn writeGrammars(self: *Fixture) !void {
        try self.writeGrammarsJson(
            "{\"ml\": {\"repo\": \"https://example.invalid/tree-sitter-ocaml\", \"scope\": \"source.ocaml\"}}",
        );
    }

    /// Same, with caller-chosen registry content -- for a test that needs
    /// more than just `.ml` (e.g. `.java`/`.py` too), or an entry shaped
    /// like `{"unsupported": true}`.
    pub fn writeGrammarsJson(self: *Fixture, json: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, "home/.claude");
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = "home/.claude/synapse-grammars.conf",
            .data = json,
        });
    }

    /// A real `_index.bin` in the fixture's work dir, built directly
    /// through `core.index_map.build` -- the same call `synapse index
    /// build`/`build-index` make internally, skipping the CLI round trip.
    pub fn writeIndexBin(self: *Fixture, pairs: []const core.index_map.Pair) !void {
        const bytes = try core.index_map.build(self.gpa, pairs, &.{});
        defer self.gpa.free(bytes);
        const path = try std.fmt.allocPrint(self.gpa, "{s}/_index.bin", .{self.work});
        defer self.gpa.free(path);
        try core.index_map.writeFile(self.gpa, self.io(), path, bytes);
    }

    /// `git init` plus one commit adding everything currently in the
    /// fixture's repo dir -- for the handful of commands that genuinely
    /// need real git (identity resolution, `git ls-files`), not the
    /// env-var bypass most of this fixture's callers use instead.
    pub fn gitCommit(self: *Fixture, message: []const u8) !void {
        // `-b main`: git's own default branch name isn't uniform across
        // installs (this repo's tests assume "main" throughout), and the
        // fixture's own overridden `HOME` (no `.gitconfig`) means an ambient
        // `init.defaultBranch` never reaches this subprocess either way.
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

    /// Any other real `git` command against the fixture's repo -- branch,
    /// checkout, reset, mv, rm, upstream tracking, whatever a test needs
    /// choreographed. Caller frees the result.
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

    pub fn nodeExists(self: *Fixture, title: []const u8) !bool {
        const sub = try std.fmt.allocPrint(self.gpa, "vault/synapse/repo@main/{s}.md", .{title});
        defer self.gpa.free(sub);
        self.tmp.dir.access(testing.io, sub, .{}) catch return false;
        return true;
    }

    /// Rebuilds the scoped `Io.Threaded`'s environ block from `env` as it
    /// stands right now -- call after any `env.put`/`env.swapRemove` a
    /// spawned subprocess (git, curl, ...) needs to see, since the block is
    /// a snapshot taken at `init`/the last call to this, not a live view.
    pub fn refreshEnv(self: *Fixture) !void {
        self.io_threaded.deinit();
        self.environ_block.deinit(self.gpa);
        self.environ_block = try self.env.createPosixBlock(self.gpa, .{});
        self.io_threaded = .init(self.gpa, .{ .environ = .{ .block = self.environ_block } });
    }

    /// `FAKE_CURL_PUT_STATUS`, for the "PUT rejected" case.
    pub fn setPutStatus(self: *Fixture, status: []const u8) !void {
        try self.env.put("FAKE_CURL_PUT_STATUS", status);
        try self.refreshEnv();
    }
};
