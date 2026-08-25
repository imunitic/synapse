//! `synapse-hook prompt-context` -- UserPromptSubmit.
//!
//! One standing line per turn, in a repo with a namespace: the graph
//! exists, here are the tools that read it. No search, no node list, no
//! network. `SYNAPSE_DISABLE_PROMPT_INJECTION` (any value) disables it.
//!
//! Used to tokenize the prompt into a regexp OR-pattern and search the
//! vault instead: on a real 52-node namespace, "can you explain how
//! BatchRunner dispatches work items" returned 50 of 52 nodes for ~1057
//! tokens, every turn -- `[Ww]ork` matched the substring inside
//! `framework` (1392 occurrences), and one weak term OR'd in destroys the
//! query. A per-turn nudge also survives context compaction, unlike a
//! SessionStart injection.
//!
//! Names the Graph and the Code Cache separately, not "read the graph":
//! collapsing them once cost a real session where the reader skimmed node
//! titles, saw nothing matching, and fell back to grep even though every
//! file was indexed. Each half is announced only when actually present.

const std = @import("std");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    if (env.get("SYNAPSE_DISABLE_PROMPT_INJECTION") != null) return;

    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();
    _ = payload.str("prompt") orelse return; // an empty prompt exits silently

    const text = try build(gpa, io, env, payload.str("cwd") orelse ".") orelse return;
    defer gpa.free(text);
    try common.emitContext(gpa, io, "UserPromptSubmit", text);
}

/// The nudge text, or null when nothing should be emitted -- separated from
/// `run()` so a test can drive it against a real fixture `env`/vault
/// directly, without needing a real stdin payload. Caller owns the result.
pub fn build(gpa: Allocator, io: Io, env: *std.process.Environ.Map, cwd: []const u8) !?[]u8 {
    const vault = common.vault(gpa, io, env) orelse return null;
    defer gpa.free(vault);

    const ns = common.Namespace.resolve(gpa, io, env, cwd) orelse return null;
    defer ns.deinit(gpa);
    const ns_dir = try std.fmt.allocPrint(gpa, "{s}/synapse/{s}", .{ vault, ns.key });
    defer gpa.free(ns_dir);
    const ns_index = try std.fmt.allocPrint(gpa, "{s}/Index.md", .{ns_dir});
    defer gpa.free(ns_index);

    const index_text = Io.Dir.cwd().readFileAlloc(io, ns_index, gpa, .limited(64 << 20)) catch return null;
    defer gpa.free(index_text);
    // Remote check, not branch (unlike the write paths): two repos can
    // share a key, and pointing at another project's graph is worse than silence.
    const remote = @import("core").query.field(index_text, "remote") orelse return null;
    if (remote.len == 0 or !std.mem.eql(u8, remote, ns.remote)) return null;

    const nodes = try countNodes(io, ns_dir);
    if (nodes == 0) return null;

    const work_dir = common.workDir(gpa, env, ns.key);
    defer if (work_dir) |w| gpa.free(w);
    const have_cache = blk: {
        const w = work_dir orelse break :blk false;
        const refs = try std.fmt.allocPrint(gpa, "{s}/_refs.tsv", .{w});
        defer gpa.free(refs);
        _ = Io.Dir.cwd().statFile(io, refs, .{}) catch break :blk false;
        break :blk true;
    };

    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try text.writer.print(
        "Synapse: this repo has a code graph at synapse/{s}/ ({d} nodes). If this turn needs to know how the codebase works, consult Synapse before grepping or opening files -- `synapse query` (body/sources/field/links), `synapse index lookup <path>` for the owning node (authoritative coverage: never infer from titles).",
        .{ ns.key, nodes },
    );
    if (have_cache) try text.writer.writeAll(
        " Separately, and independent of the graph, a Code Cache indexes exact names: `synapse callers <name>` gives repo-wide call sites (no graph needed), `synapse query symbol <name> <node>` scopes that lookup to one node. Prefer either over grep for \"where is X defined/used\"; their line numbers come from the index and can lag the working tree, so re-check a range before relying on it.",
    );
    try text.writer.writeAll(" The synapse-query and synapse-node skills have the procedure.");

    return try gpa.dupe(u8, text.written());
}

/// Every `*.md` directly under the namespace except `Index.md`.
fn countNodes(io: Io, ns_dir: []const u8) !usize {
    var dir = Io.Dir.cwd().openDir(io, ns_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (std.mem.eql(u8, entry.name, "Index.md")) continue;
        n += 1;
    }
    return n;
}

const testing = std.testing;

/// No `Io.Threaded` needed anywhere in this file's tests: `build()` spawns
/// no subprocess (no git, no curl), so plain `testing.io` and a bare
/// `std.process.Environ.Map.init` (the pattern `bard_hook/session_start.zig`
/// already established for this same app) are enough.
const Fixture = struct {
    gpa: Allocator,
    tmp: testing.TmpDir,
    vault: []const u8,
    env: std.process.Environ.Map,

    fn init(gpa: Allocator) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "vault");

        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
        const vault = try std.fmt.allocPrint(gpa, "{s}/vault", .{root});
        errdefer gpa.free(vault);

        var env = std.process.Environ.Map.init(gpa);
        errdefer env.deinit();
        try env.put("OBSIDIAN_VAULT_DIR", vault);

        return .{ .gpa = gpa, .tmp = tmp, .vault = vault, .env = env };
    }

    fn deinit(self: *Fixture) void {
        self.env.deinit();
        self.gpa.free(self.vault);
        self.tmp.cleanup();
    }

    /// The env-var identity bypass `common.Namespace.fromEnv` reads --
    /// `context.zig`'s commands use the same escape hatch to skip real git
    /// resolution in a test.
    fn setNamespace(self: *Fixture, key: []const u8, remote: []const u8) !void {
        try self.env.put("SYNAPSE_NAMESPACE", key);
        try self.env.put("SYNAPSE_REPO_ROOT", "/repo");
        try self.env.put("SYNAPSE_BRANCH", "main");
        try self.env.put("SYNAPSE_REMOTE", remote);
    }

    fn writeIndex(self: *Fixture, ns_key: []const u8, remote: []const u8) !void {
        const dir = try std.fmt.allocPrint(self.gpa, "vault/synapse/{s}", .{ns_key});
        defer self.gpa.free(dir);
        try self.tmp.dir.createDirPath(testing.io, dir);
        const path = try std.fmt.allocPrint(self.gpa, "{s}/Index.md", .{dir});
        defer self.gpa.free(path);
        const data = try std.fmt.allocPrint(self.gpa, "---\nremote: \"{s}\"\nbranch: main\n---\n", .{remote});
        defer self.gpa.free(data);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    fn writeNode(self: *Fixture, ns_key: []const u8, title: []const u8) !void {
        const path = try std.fmt.allocPrint(self.gpa, "vault/synapse/{s}/{s}.md", .{ ns_key, title });
        defer self.gpa.free(path);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "---\ntitle: x\n---\nbody\n" });
    }

    /// Absolute path to `{tmp}/work`, creating it and pointing
    /// `SYNAPSE_WORK_DIR` at it. Caller still has to write `_refs.tsv`
    /// inside it to trigger the "have_cache" branch.
    fn workDir(self: *Fixture) ![]const u8 {
        try self.tmp.dir.createDirPath(testing.io, "work");
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = buf[0..try self.tmp.dir.realPath(testing.io, &buf)];
        const work = try std.fmt.allocPrint(self.gpa, "{s}/work", .{root});
        try self.env.put("SYNAPSE_WORK_DIR", work);
        return work;
    }

    fn nudge(self: *Fixture, cwd: []const u8) !?[]u8 {
        return build(self.gpa, testing.io, &self.env, cwd);
    }
};

test "no Synapse namespace for this repo: no-op" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    // `/tmp` itself: no `SYNAPSE_NAMESPACE` env-var bypass is set, so
    // `common.Namespace.resolve` falls to real git identity resolution on
    // `cwd`, which must fail here -- `/tmp` is reliably outside any git repo
    // on this machine.
    try testing.expectEqual(@as(?[]u8, null), try fx.nudge("/tmp"));
}

test "namespace exists, remote mismatches: no-op" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.setNamespace("repo@main", "ssh://git@github.com/example/repo.git");
    try fx.writeIndex("repo@main", "ssh://git@github.com/someone-else/unrelated.git");

    try testing.expectEqual(@as(?[]u8, null), try fx.nudge("."));
}

test "namespace present: one short line naming the namespace and node count" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.setNamespace("repo@main", "ssh://git@github.com/example/repo.git");
    try fx.writeIndex("repo@main", "ssh://git@github.com/example/repo.git");
    try fx.writeNode("repo@main", "Cached backend");
    try fx.writeNode("repo@main", "Query API");

    const text = (try fx.nudge(".")).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "repo@main") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2 nodes") != null); // Index.md is the map, not a node
    // The commands it names must be ones that exist: `synapse query`, not the
    // `synapse-query.sh` wrapper the Zig rewrite deleted.
    try testing.expect(std.mem.indexOf(u8, text, "synapse query") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".sh") == null);
}

test "the nudge never lists nodes, and stays small enough to pay every turn" {
    // The whole reason the search was removed. A per-turn injection is
    // charged on every turn including ones with nothing to do with the
    // codebase, so its size is the feature.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.setNamespace("repo@main", "ssh://git@github.com/example/repo.git");
    try fx.writeIndex("repo@main", "ssh://git@github.com/example/repo.git");
    var i: usize = 1;
    var buf: [16]u8 = undefined;
    while (i <= 30) : (i += 1) {
        try fx.writeNode("repo@main", try std.fmt.bufPrint(&buf, "Node {d}", .{i}));
    }

    const text = (try fx.nudge(".")).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Node 1.md") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Node 17.md") == null);
    // Constant regardless of namespace size: 30 nodes must not cost more than 2.
    try testing.expect(text.len < 400);
}

test "a namespace with an Index.md but no nodes says nothing" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.setNamespace("repo@main", "ssh://git@github.com/example/repo.git");
    try fx.writeIndex("repo@main", "ssh://git@github.com/example/repo.git");

    try testing.expectEqual(@as(?[]u8, null), try fx.nudge("."));
}

test "a Code Cache present adds a second sentence about it, independent of the graph" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.setNamespace("repo@main", "ssh://git@github.com/example/repo.git");
    try fx.writeIndex("repo@main", "ssh://git@github.com/example/repo.git");
    try fx.writeNode("repo@main", "Cached backend");
    const work = try fx.workDir();
    defer gpa.free(work);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/_refs.tsv", .data = "" });

    const text = (try fx.nudge(".")).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Code Cache") != null);
    try testing.expect(std.mem.indexOf(u8, text, "synapse callers") != null);
}
