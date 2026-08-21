//! A real git repo, a real fake-vault (Obsidian REST plugin stub, matched
//! by `tests/fixtures/fake-bin/curl`), and a real `_index.bin`, for
//! `src/apps/hook/*.zig` native tests.
//!
//! `src/apps/synapse/cmd_test_support.zig` isn't importable here: `hook` is
//! a separate `build.zig` module (no `ports` import, a different root file
//! entirely), so this is its own copy of the same pattern -- established
//! for `staleness.zig`, reusable by any later `src/apps/hook/*.zig` native
//! test that needs a real git identity and/or a real Obsidian PUT.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");

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
    curl_capture: []const u8,
    env: std.process.Environ.Map,
    io_threaded: std.Io.Threaded,
    environ_block: std.process.Environ.PosixBlock,

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
        const curl_capture = try std.fmt.allocPrint(gpa, "{s}/curl-capture", .{root});
        errdefer gpa.free(curl_capture);

        try tmp.dir.createDirPath(testing.io, "repo");
        try tmp.dir.createDirPath(testing.io, "vault/.obsidian/plugins/obsidian-local-rest-api");
        try tmp.dir.createDirPath(testing.io, "work");
        try tmp.dir.createDirPath(testing.io, "home/.claude");
        try tmp.dir.createDirPath(testing.io, "curl-capture");
        try tmp.dir.writeFile(testing.io, .{
            .sub_path = "vault/.obsidian/plugins/obsidian-local-rest-api/data.json",
            .data = "{\"apiKey\":\"test-key\",\"port\":27124}",
        });
        try tmp.dir.writeFile(testing.io, .{
            .sub_path = "home/.claude/obsidian-local-rest-api-ca.pem",
            .data = "",
        });

        var env = try std.process.Environ.createMap(testing.environ, gpa);
        errdefer env.deinit();
        try env.put("HOME", home);
        try env.put("OBSIDIAN_VAULT_DIR", vault);
        try env.put("SYNAPSE_WORK_DIR", work);
        try env.put("FAKE_CURL_LOG", curl_log);
        try env.put("FAKE_CURL_VAULT_DIR", vault);
        try env.put("FAKE_CURL_CAPTURE_DIR", curl_capture);

        // Absolute, not just a resolvable relative path -- see
        // `src/apps/synapse/cmd_test_support.zig`'s own comment on this
        // exact gotcha: `tests/fixtures/fake-bin/git` strips its own
        // directory from `PATH` by exact-matching its real absolute
        // location, so a relative entry here would silently no-op and the
        // script would re-exec itself as `git` forever.
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
            .curl_capture = curl_capture,
            .env = env,
            .io_threaded = io_threaded,
            .environ_block = block,
        };
    }

    pub fn deinit(self: *Fixture) void {
        self.io_threaded.deinit();
        self.environ_block.deinit(self.gpa);
        self.env.deinit();
        self.gpa.free(self.curl_capture);
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

    /// `git init` plus one commit adding everything currently in the
    /// fixture's repo dir. A separate step from `init()`, called by every
    /// test right after construction -- spawning a subprocess on `init()`'s
    /// own local copy before it returns the fixture by value binds
    /// `Io.Threaded`'s worker thread to a stale, soon-to-be-orphaned
    /// address (found building `BriefFixture` in `src/apps/synapse/
    /// brief_cmd.zig`; see that file's own fixture comment for the full
    /// mechanism).
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

    /// Any other real `git` command against the fixture's repo -- adding a
    /// remote, mostly.
    pub fn git(self: *Fixture, args: []const []const u8) !adapters.process.Result {
        var argv_buf: [16][]const u8 = undefined;
        argv_buf[0] = "git";
        @memcpy(argv_buf[1 .. 1 + args.len], args);
        return adapters.process.run(self.io(), self.gpa, argv_buf[0 .. 1 + args.len], .{
            .cwd = .{ .path = self.repo },
        });
    }

    /// `vault/synapse/{key}/Index.md`, the namespace marker `namespaceMatches`
    /// checks a hook's resolved identity against.
    pub fn writeIndex(self: *Fixture, key: []const u8, remote: []const u8, branch: []const u8) !void {
        const dir = try std.fmt.allocPrint(self.gpa, "vault/synapse/{s}", .{key});
        defer self.gpa.free(dir);
        try self.tmp.dir.createDirPath(testing.io, dir);
        const path = try std.fmt.allocPrint(self.gpa, "{s}/Index.md", .{dir});
        defer self.gpa.free(path);
        const data = try std.fmt.allocPrint(
            self.gpa,
            "---\ntitle: \"{s} — Synapse index\"\nnode_type: synapse-index\nbranch: {s}\nremote: \"{s}\"\nbuilt_at: \"test\"\n---\n# {s} — Synapse index\n",
            .{ key, branch, remote, key },
        );
        defer self.gpa.free(data);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    /// Raw content, verbatim -- for node fixtures that need full control
    /// over their own frontmatter (stale flag, crux/grounding directives).
    pub fn writeNode(self: *Fixture, key: []const u8, name: []const u8, content: []const u8) !void {
        const dir = try std.fmt.allocPrint(self.gpa, "vault/synapse/{s}", .{key});
        defer self.gpa.free(dir);
        try self.tmp.dir.createDirPath(testing.io, dir);
        const path = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ dir, name });
        defer self.gpa.free(path);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = content });
    }

    /// A node as it stands in the fixture vault right now, or null if it
    /// was never written (or PUT). Caller frees.
    pub fn readNode(self: *Fixture, gpa: Allocator, key: []const u8, name: []const u8) !?[]u8 {
        const path = try std.fmt.allocPrint(self.gpa, "vault/synapse/{s}/{s}", .{ key, name });
        defer self.gpa.free(path);
        return self.tmp.dir.readFileAlloc(testing.io, path, gpa, .limited(1 << 20)) catch null;
    }

    /// A real `_index.bin` in the fixture's work dir, built directly
    /// through `core.index_map.build` -- the same call `synapse index
    /// build` makes internally, skipping the CLI round trip.
    pub fn writeIndexBin(self: *Fixture, pairs: []const core.index_map.Pair) !void {
        const bytes = try core.index_map.build(self.gpa, pairs, &.{});
        defer self.gpa.free(bytes);
        const path = try std.fmt.allocPrint(self.gpa, "{s}/_index.bin", .{self.work});
        defer self.gpa.free(path);
        try core.index_map.writeFile(self.gpa, self.io(), path, bytes);
    }
};
