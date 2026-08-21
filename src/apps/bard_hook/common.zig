//! What `synapse-bard-hook`'s hooks share: the payload on stdin, and the one
//! output shape Claude Code reads.
//!
//! Deliberately a smaller, independent copy of `synapse-hook`'s own
//! `common.zig`, not an import of it: `bard_hook` is its own binary
//! (`build.zig`'s own scaffolding keeps the two apps
//! independent, same as `synapse-hook`/`synapse-fake`), and the two files
//! would diverge immediately anyway -- `synapse-hook`'s `Payload` also
//! carries `tool_input.file_path`/`session_id` fields no bard hook needs,
//! and its vault resolution reads `synapse.conf` for an external Obsidian
//! directory, which `_bard/vault/` (always repo-relative, no config) has no
//! use for at all. What's actually shared -- the JSON payload/output
//! protocol Claude Code hooks speak -- is small and stable; if a third
//! hook-based app ever needs it too, that's when promoting it to `core`
//! stops being premature.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The hook payload, as much of it as `session-start` reads: just `cwd`.
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
};

/// `{hookSpecificOutput: {hookEventName: …, additionalContext: …}}` on
/// stdout -- same shape `synapse-hook`'s own `emitContext` writes, since
/// this half really is just "what Claude Code's hook protocol requires,"
/// not app-specific.
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
/// right (a vault path can carry a backslash on some platforms, a note
/// title an em dash).
pub fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else try w.writeByte(c);
        },
    };
    try w.writeByte('"');
}

const testing = std.testing;

test "a context payload escapes what a path can contain" {
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
