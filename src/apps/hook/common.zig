//! What all five hooks share: the payload on stdin, the vault, the namespace the
//! wrapper resolved, and the one output shape Claude Code reads.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The hook payload, as much of it as any hook reads. Field names are Claude
/// Code's: `session_id` (stop-nudge), `cwd` (session-start, prompt-context),
/// `prompt` (prompt-context), `tool_input.file_path`/`tool_response.filePath`
/// (staleness). A payload change degrades to "the hook does nothing" -- every
/// field here is optional and every absent field is an early exit downstream.
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

    /// The file a mutating tool touched, across every payload shape a hook in
    /// this repo has to read: Claude Code's `tool_input.file_path` (Write/
    /// Edit) or `tool_response.filePath` (some other tools) -- both already
    /// absolute -- and Codex's `apply_patch`, whose `tool_input` carries no
    /// path field at all: the target path is the first line of patch-
    /// directive text instead, `"*** Update File: {path}"` or `"*** Add
    /// File: {path}"`, right after `"*** Begin Patch"`. That path is
    /// relative to the payload's own `cwd`, not absolute, unlike the other
    /// two shapes -- live-observed against a real Codex session, not
    /// assumed. Always allocates, so every match resolves the same way;
    /// caller frees.
    pub fn toolFile(self: Payload, gpa: Allocator) !?[]u8 {
        if (self.nested("tool_input", "file_path")) |f| return try gpa.dupe(u8, f);
        if (self.nested("tool_response", "filePath")) |f| return try gpa.dupe(u8, f);
        const cmd = self.nested("tool_input", "command") orelse return null;
        const markers = [_][]const u8{ "*** Update File: ", "*** Add File: " };
        for (markers) |m| {
            const idx = std.mem.indexOf(u8, cmd, m) orelse continue;
            const rest = cmd[idx + m.len ..];
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const path = std.mem.trimEnd(u8, rest[0..end], " \r");
            if (path.len == 0) continue;
            if (std.fs.path.isAbsolute(path)) return try gpa.dupe(u8, path);
            const cwd = self.str("cwd") orelse return try gpa.dupe(u8, path);
            return try std.fmt.allocPrint(gpa, "{s}/{s}", .{ cwd, path });
        }
        return null;
    }
};

/// The vault directory: the environment, else `~/.claude/synapse.conf`.
/// Absent, unreadable or not a directory is silence, like every other
/// missing precondition. The caller owns the result.
pub fn vault(gpa: Allocator, io: Io, env: *std.process.Environ.Map) ?[]u8 {
    const dir = (core.conf.vaultDir(gpa, io, adapters.env.vars(env)) catch return null) orelse return null;
    const st = Io.Dir.cwd().statFile(io, dir, .{}) catch {
        gpa.free(dir);
        return null;
    };
    if (st.kind != .directory) {
        gpa.free(dir);
        return null;
    }
    return dir;
}

/// The namespace the wrapper resolved: `{repo}@{branch}`, plus its repo
/// root, branch and remote. All four come from the environment, same as
/// `context.zig`'s commands, so a second resolution can't disagree with the
/// first. No namespace exported means a checkout with none (detached HEAD,
/// not a git repo) -- ordinary, so null rather than an error.
pub const Namespace = struct {
    key: []const u8,
    repo_root: []const u8,
    branch: []const u8,
    remote: []const u8,
    /// Set when the fields point into a git resolution this owns.
    owned: ?core.identity.Resolved = null,

    pub fn fromEnv(env: *std.process.Environ.Map) ?Namespace {
        const key = nonEmpty(env, "SYNAPSE_NAMESPACE") orelse return null;
        const root = nonEmpty(env, "SYNAPSE_REPO_ROOT") orelse return null;
        const branch = nonEmpty(env, "SYNAPSE_BRANCH") orelse return null;
        return .{
            .key = key,
            .repo_root = root,
            .branch = branch,
            .remote = env.get("SYNAPSE_REMOTE") orelse "", // empty is a real config, not absence
            .owned = null,
        };
    }

    /// From the environment when set, else asked of git for the repository
    /// containing `cwd` -- taken as an argument since `staleness` resolves
    /// from the *edited file's* directory, not necessarily `$PWD`. A
    /// detached HEAD or non-repo returns null, an ordinary state.
    pub fn resolve(gpa: Allocator, io: Io, env: *std.process.Environ.Map, cwd: []const u8) ?Namespace {
        if (fromEnv(env)) |ns| return ns;
        const id = core.identity.resolve(gpa, io, cwd) catch return null;
        return .{
            .key = id.key,
            .repo_root = id.layout.repo_root,
            .branch = id.branch_key,
            .remote = id.remote,
            .owned = id,
        };
    }

    pub fn deinit(self: Namespace, gpa: Allocator) void {
        if (self.owned) |id| id.deinit(gpa);
    }
};

fn nonEmpty(env: *std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

/// The work dir: `$SYNAPSE_WORK_DIR` when set, else `~/.cache/synapse/work/{key}`
/// -- the same default `context.workDirFor` already uses for the main CLI, so a
/// hook agrees with a bare `synapse` invocation about where the cache lives
/// even when nothing exported the override, which nothing in `hooks.json`
/// ever does. Caller-owned.
pub fn workDir(gpa: Allocator, env: *std.process.Environ.Map, key: []const u8) ?[]u8 {
    if (nonEmpty(env, "SYNAPSE_WORK_DIR")) |w| return gpa.dupe(u8, w) catch null;
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(gpa, "{s}/.cache/synapse/work/{s}", .{ home, key }) catch null;
}

/// Whether the namespace's own `Index.md` agrees it belongs to this repo
/// *and* branch -- the write side of the check `query` and SessionStart
/// already make before reading. An absent field is a mismatch, not a match
/// against the empty string: absent provenance is not permission to write.
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
/// `additionalContext`, not `decision: block`, everywhere: information for
/// the next turn, not a reason to stop -- the CLI labels this "Stop hook
/// feedback" rather than the alarming "Stop hook error".
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

/// A JSON string literal, written out rather than through a serialiser --
/// only two fixed keys ever need this, and the escaping is what has to be
/// right (a node title carries em dashes/quotes, a vault path a backslash).
pub fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            // Control bytes must be escaped; above 0x1F passes through raw.
            if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else try w.writeByte(c);
        },
    };
    try w.writeByte('"');
}

const testing = std.testing;

fn parsedPayload(gpa: Allocator, json: []const u8) Payload {
    return .{ .parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch unreachable };
}

test "toolFile: tool_input.file_path wins outright" {
    const gpa = testing.allocator;
    var p = parsedPayload(gpa, "{\"tool_input\":{\"file_path\":\"/a/b.ml\"}}");
    defer p.deinit();
    const got = (try p.toolFile(gpa)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("/a/b.ml", got);
}

test "toolFile: falls back to tool_response.filePath when tool_input.file_path is absent" {
    const gpa = testing.allocator;
    var p = parsedPayload(gpa, "{\"tool_response\":{\"filePath\":\"/a/c.ml\"}}");
    defer p.deinit();
    const got = (try p.toolFile(gpa)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("/a/c.ml", got);
}

test "toolFile: apply_patch's Update File path is relative to the payload's own cwd" {
    const gpa = testing.allocator;
    var p = parsedPayload(
        gpa,
        "{\"cwd\":\"/repo\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: lib/calc.ml\\n@@\\n-old\\n+new\\n*** End Patch\"}}",
    );
    defer p.deinit();
    const got = (try p.toolFile(gpa)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("/repo/lib/calc.ml", got);
}

test "toolFile: apply_patch's Add File path, also joined against cwd" {
    const gpa = testing.allocator;
    var p = parsedPayload(
        gpa,
        "{\"cwd\":\"/repo\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Add File: brand/new.txt\\n+content\\n*** End Patch\"}}",
    );
    defer p.deinit();
    const got = (try p.toolFile(gpa)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("/repo/brand/new.txt", got);
}

test "toolFile: an already-absolute apply_patch path is used as-is, not double-joined" {
    const gpa = testing.allocator;
    var p = parsedPayload(
        gpa,
        "{\"cwd\":\"/repo\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: /elsewhere/calc.ml\\n*** End Patch\"}}",
    );
    defer p.deinit();
    const got = (try p.toolFile(gpa)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("/elsewhere/calc.ml", got);
}

test "toolFile: none of the known shapes present is null, not a crash" {
    const gpa = testing.allocator;
    var p = parsedPayload(gpa, "{\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Delete File: gone.ml\\n*** End Patch\"}}");
    defer p.deinit();
    try testing.expectEqual(@as(?[]u8, null), try p.toolFile(gpa));

    var empty = parsedPayload(gpa, "{}");
    defer empty.deinit();
    try testing.expectEqual(@as(?[]u8, null), try empty.toolFile(gpa));
}

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

// Regression coverage for the bug where every real hook invocation silently
// no-oped: hooks.json never exports SYNAPSE_WORK_DIR (nothing in this repo's
// wiring ever has), so a bare env lookup with no default -- what workDir()
// used to be -- always returned null in production while every test's own
// fixture happily set the variable for it, masking the gap completely.

test "workDir: SYNAPSE_WORK_DIR set wins outright" {
    const gpa = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    try env.put("SYNAPSE_WORK_DIR", "/explicit/work");
    try env.put("HOME", "/home/nobody");

    const got = workDir(gpa, &env, "repo@main").?;
    defer gpa.free(got);
    try testing.expectEqualStrings("/explicit/work", got);
}

test "workDir: SYNAPSE_WORK_DIR unset falls back to ~/.cache/synapse/work/{key}" {
    const gpa = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    _ = env.swapRemove("SYNAPSE_WORK_DIR");
    try env.put("HOME", "/home/nobody");

    const got = workDir(gpa, &env, "repo@main").?;
    defer gpa.free(got);
    try testing.expectEqualStrings("/home/nobody/.cache/synapse/work/repo@main", got);
}

test "workDir: neither SYNAPSE_WORK_DIR nor HOME set is null, not a crash" {
    const gpa = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    _ = env.swapRemove("SYNAPSE_WORK_DIR");
    _ = env.swapRemove("HOME");

    try testing.expectEqual(@as(?[]u8, null), workDir(gpa, &env, "repo@main"));
}
