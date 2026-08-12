//! What all five hooks share: the payload on stdin, the vault, the namespace the
//! wrapper resolved, and the one output shape Claude Code reads.

const std = @import("std");
const core = @import("core");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The hook payload, as much of it as any hook reads.
///
/// Field names are Claude Code's, each verified live rather than assumed:
/// `session_id` (stop-nudge), `cwd` (session-start, prompt-context), `prompt`
/// (prompt-context), `tool_input.file_path` with `tool_response.filePath` as the
/// fallback (staleness). A payload change degrades to "the hook does nothing",
/// because every field is optional here and every absent field is an early exit
/// there.
pub const Payload = struct {
    parsed: ?std.json.Parsed(std.json.Value),

    pub fn read(gpa: Allocator, io: Io) Payload {
        var buf: [64 * 1024]u8 = undefined;
        var in = Io.File.stdin().reader(io, &buf);
        const text = in.interface.allocRemaining(gpa, .limited(16 << 20)) catch
            return .{ .parsed = null };
        defer gpa.free(text);
        if (text.len == 0) return .{ .parsed = null };
        return .{
            .parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch null,
        };
    }

    pub fn deinit(self: *Payload) void {
        if (self.parsed) |p| p.deinit();
    }

    /// A top-level string field, or null.
    pub fn str(self: Payload, key: []const u8) ?[]const u8 {
        const p = self.parsed orelse return null;
        const obj = switch (p.value) {
            .object => |o| o,
            else => return null,
        };
        return switch (obj.get(key) orelse return null) {
            .string => |s| if (s.len == 0) null else s,
            else => null,
        };
    }

    /// A nested string field, `outer.inner`.
    pub fn nested(self: Payload, outer: []const u8, inner: []const u8) ?[]const u8 {
        const p = self.parsed orelse return null;
        const obj = switch (p.value) {
            .object => |o| o,
            else => return null,
        };
        const sub = switch (obj.get(outer) orelse return null) {
            .object => |o| o,
            else => return null,
        };
        return switch (sub.get(inner) orelse return null) {
            .string => |s| if (s.len == 0) null else s,
            else => null,
        };
    }
};

/// The vault directory, from the environment the wrapper exported.
///
/// The wrapper sources `synapse.conf` (falling back to the pre-rename
/// `second-brain.conf`) and exports `OBSIDIAN_VAULT_DIR`, so no hook parses a conf
/// file itself. Absent or not a directory is silence, like every other missing
/// precondition.
pub fn vault(io: Io, env: *std.process.Environ.Map) ?[]const u8 {
    const dir = env.get("OBSIDIAN_VAULT_DIR") orelse return null;
    if (dir.len == 0) return null;
    const st = Io.Dir.cwd().statFile(io, dir, .{}) catch return null;
    if (st.kind != .directory) return null;
    return dir;
}

/// The namespace the wrapper resolved: `{repo}@{branch}`, plus its repo root,
/// branch and remote.
///
/// All four come from the environment for the reason `context.zig` gives for the
/// commands: a second resolution that disagreed with the first is precisely the bug
/// this arrangement prevents. A hook with no namespace exported is a hook in a
/// checkout with no namespace -- a detached HEAD, or not a git repo -- and that is
/// an ordinary state, so it is null rather than an error.
pub const Namespace = struct {
    key: []const u8,
    repo_root: []const u8,
    branch: []const u8,
    remote: []const u8,

    pub fn fromEnv(env: *std.process.Environ.Map) ?Namespace {
        const key = nonEmpty(env, "SYNAPSE_NAMESPACE") orelse return null;
        const root = nonEmpty(env, "SYNAPSE_REPO_ROOT") orelse return null;
        const branch = nonEmpty(env, "SYNAPSE_BRANCH") orelse return null;
        return .{
            .key = key,
            .repo_root = root,
            .branch = branch,
            // An empty remote is a real configuration (a repo with none), and the
            // check below treats "" == "" as a match only if the index also records
            // none.
            .remote = env.get("SYNAPSE_REMOTE") orelse "",
        };
    }
};

fn nonEmpty(env: *std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

/// The work dir, which the wrapper exports the same way every command's does.
pub fn workDir(env: *std.process.Environ.Map) ?[]const u8 {
    return nonEmpty(env, "SYNAPSE_WORK_DIR");
}

/// Whether the namespace's own `Index.md` agrees that it belongs to this repo *and*
/// this branch.
///
/// The write side of the check `query` makes before answering and the SessionStart
/// hook makes before pointing. **An absent field is a mismatch**, not a match against
/// the empty string: absent provenance is not permission to write. The directory name
/// already encodes the branch, so a disagreement means it was renamed by hand, and
/// writing into it would flag one branch's nodes for another branch's edit.
pub fn namespaceMatches(
    gpa: Allocator,
    io: Io,
    vault_dir: []const u8,
    ns: Namespace,
) !bool {
    const path = try std.fmt.allocPrint(gpa, "{s}/synapse/{s}/Index.md", .{ vault_dir, ns.key });
    defer gpa.free(path);
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch return false;
    defer gpa.free(text);
    return indexAgrees(text, ns);
}

/// The comparison itself, split out so it is testable without a filesystem.
pub fn indexAgrees(index_text: []const u8, ns: Namespace) bool {
    const remote = core.query.field(index_text, "remote") orelse return false;
    if (remote.len == 0 or !std.mem.eql(u8, remote, ns.remote)) return false;
    const branch = core.query.field(index_text, "branch") orelse return false;
    if (branch.len == 0 or !std.mem.eql(u8, branch, ns.branch)) return false;
    return true;
}

/// `{hookSpecificOutput: {hookEventName: …, additionalContext: …}}` on stdout.
///
/// `additionalContext` rather than `decision: block` everywhere: this is information
/// for the next turn, not a reason to stop. The Stop hook's own note records why --
/// the CLI labels this shape "Stop hook feedback" instead of the alarming "Stop hook
/// error" that `decision: block` renders as.
pub fn emitContext(gpa: Allocator, io: Io, event: []const u8, context_text: []const u8) !void {
    if (context_text.len == 0) return;
    var buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    try out.interface.writeAll("{\"hookSpecificOutput\":{\"hookEventName\":");
    try writeJsonString(&out.interface, event);
    try out.interface.writeAll(",\"additionalContext\":");
    try writeJsonString(&out.interface, context_text);
    try out.interface.writeAll("}}\n");
    try out.interface.flush();
    _ = gpa;
}

/// A JSON string literal.
///
/// Written out rather than reached for through a serialiser because the *only*
/// structure here is two fixed keys, and the escaping is the part that has to be
/// right: an injected node title carries em dashes and quotes, and a vault path can
/// carry a backslash.
pub fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            // Control bytes must be escaped or the payload is not valid JSON. Above
            // 0x1F everything passes through as-is, including UTF-8, which `jq`
            // also emitted raw.
            if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else try w.writeByte(c);
        },
    };
    try w.writeByte('"');
}

const testing = std.testing;

test "an index that names another repo, or another branch, does not agree" {
    const ns: Namespace = .{
        .key = "r@main",
        .repo_root = "/r",
        .branch = "main",
        .remote = "ssh://git@x/r.git",
    };
    try testing.expect(indexAgrees(
        "---\nremote: \"ssh://git@x/r.git\"\nbranch: main\n---\n",
        ns,
    ));
    try testing.expect(!indexAgrees(
        "---\nremote: \"ssh://git@x/other.git\"\nbranch: main\n---\n",
        ns,
    ));
    try testing.expect(!indexAgrees(
        "---\nremote: \"ssh://git@x/r.git\"\nbranch: feature\n---\n",
        ns,
    ));
}

test "an absent field is a mismatch, not a match against the empty string" {
    const ns: Namespace = .{ .key = "r@main", .repo_root = "/r", .branch = "main", .remote = "" };
    // Absent provenance is not permission to write, so even a namespace whose repo
    // genuinely has no remote does not match an index that records none.
    try testing.expect(!indexAgrees("---\nbranch: main\n---\n", ns));
    try testing.expect(!indexAgrees("---\nremote: \"\"\nbranch: main\n---\n", ns));
    try testing.expect(!indexAgrees("---\nremote: \"x\"\n---\n", ns));
    try testing.expect(!indexAgrees("", ns));
}

test "a context payload escapes what a node title and a path can contain" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeJsonString(&out.writer, "World — \"x\"\nC:\\dir\ttab");
    try testing.expectEqualStrings(
        "\"World — \\\"x\\\"\\nC:\\\\dir\\ttab\"",
        out.written(),
    );
}

test "a control byte is escaped rather than emitted raw" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeJsonString(&out.writer, "a\x01b");
    try testing.expectEqualStrings("\"a\\u0001b\"", out.written());
}
