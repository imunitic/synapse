//! The task-to-command map: which `synapse` command answers which question
//! about a codebase. One definition, rendered by `synapse context` and by the
//! SessionStart hook, so the CLI and the injected text cannot disagree.
//!
//! Injected once per session rather than learned per session: a session that
//! does not know `query symbol` or `callers --all` exists finds them only by
//! running `--help`, and each such discovery turn re-reads the whole context.

const std = @import("std");

pub const Entry = struct {
    /// What the agent wants to know.
    task: []const u8,
    /// The command that answers it, as the agent would type it.
    command: []const u8,
    /// The top-level `synapse` subcommand `command` runs, checked against the
    /// dispatch table so an entry can never name a subcommand that is gone.
    sub: []const u8,
};

pub const entries = [_]Entry{
    .{ .task = "how an area works", .command = "synapse query body \"<node>\"", .sub = "query" },
    .{ .task = "which files a node covers", .command = "synapse query sources \"<node>\"", .sub = "query" },
    .{ .task = "which node owns a file", .command = "synapse index lookup <path>", .sub = "index" },
    .{ .task = "where a symbol is defined", .command = "synapse query symbol <name> \"<node>\"", .sub = "query" },
    .{ .task = "every definition and reference of a name, repo-wide", .command = "synapse callers <name> --all", .sub = "callers" },
    .{ .task = "who calls a name", .command = "synapse callers <name>", .sub = "callers" },
    .{ .task = "what a node links to, or what links to it", .command = "synapse query links \"<node>\" [--inbound]", .sub = "query" },
    .{ .task = "whether files changed under the graph", .command = "synapse query stale", .sub = "query" },
    .{ .task = "what changed since each node's commit", .command = "synapse query drift", .sub = "query" },
    .{ .task = "another branch's graph", .command = "add --namespace <repo>@<branch> to query, index lookup or callers", .sub = "query" },
};

/// The full map, one line per entry, under a one-line heading.
pub fn render(w: *std.Io.Writer) !void {
    try w.writeAll("Synapse commands by question:\n");
    for (entries) |e| try w.print("- {s}: `{s}`\n", .{ e.task, e.command });
}

/// Only the entries that run `sub` -- what a usage error for that subcommand
/// prints. Writes nothing when no entry runs it.
pub fn renderFor(w: *std.Io.Writer, sub: []const u8) !void {
    for (entries) |e| {
        if (std.mem.eql(u8, e.sub, sub)) try w.print("- {s}: `{s}`\n", .{ e.task, e.command });
    }
}

const testing = std.testing;

test "render lists every entry once" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(&out.writer);
    // Backtick-delimited, as rendered: `synapse callers <name>` is otherwise a
    // substring of `synapse callers <name> --all`.
    for (entries) |e| {
        const quoted = try std.fmt.allocPrint(testing.allocator, "`{s}`", .{e.command});
        defer testing.allocator.free(quoted);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), quoted));
    }
}

test "renderFor keeps only the entries for that subcommand" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try renderFor(&out.writer, "callers");
    try testing.expect(std.mem.indexOf(u8, out.written(), "synapse callers <name> --all") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "synapse query") == null);
}

test "renderFor writes nothing for a subcommand the map does not cover" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try renderFor(&out.writer, "vault-list");
    try testing.expectEqualStrings("", out.written());
}
