//! `synapse/{repo}@{branch}/Index.md` -- the per-namespace node map. In
//! core, not the command, since it's written once and read three places:
//! the SessionStart hook checks `remote`, `query`'s preamble checks
//! `remote` and `branch`, and `write-node` checks both.
//!
//! ```
//! ---
//! title: "fw-core@master — Synapse index"
//! node_type: synapse-index
//! project: fw-core
//! branch: master
//! remote: "ssh://…/fw-core.git"
//! built_at: "2026-08-12 20:16"
//! ---
//!
//! # fw-core@master — Synapse index
//!
//! 124817 tracked files, 52 nodes. …
//!
//! - [[State machine]] — How states advance (19 files)
//! ```
//!
//! `project` is the repo half alone (the key is already the title/folder
//! name); a bare repo name groups every branch's namespace in a vault
//! query, and `branch` stays a separate field so identity is checkable
//! without parsing a directory name.
//!
//! Bullets link by filename, not title -- Obsidian resolves a wikilink by
//! filename, so the writer sanitises the same way `emit.fileTitle` does.

const std = @import("std");

/// One node's line in the map.
pub const Bullet = struct {
    /// The node's filename stem, already sanitised -- what the wikilink
    /// resolves against.
    link: []const u8,
    files: usize,
    /// The node's own `summary` frontmatter, read back off the node.
    summary: []const u8,
};

pub const Params = struct {
    /// `{repo}@{branch}`.
    namespace: []const u8,
    /// The repo half alone.
    project: []const u8,
    branch: []const u8,
    remote: []const u8,
    built_at: []const u8,
    total_files: usize,
    /// Sorted by `link`, alphabetical, since a reader scans an index for a name.
    bullets: []const Bullet,
};

/// The node count is the bullet count, deliberately -- can't disagree with
/// what's printed, unlike the script's separate `lists/*.txt` count.
pub fn write(w: *std.Io.Writer, p: Params) !void {
    try w.writeAll("---\n");
    try w.print("title: \"{s} — Synapse index\"\n", .{p.namespace});
    try w.writeAll("node_type: synapse-index\n");
    try w.print("project: {s}\n", .{p.project});
    try w.print("branch: {s}\n", .{p.branch});
    try w.print("remote: \"{s}\"\n", .{p.remote});
    try w.print("built_at: \"{s}\"\n", .{p.built_at});
    try w.writeAll("---\n\n");

    try w.print("# {s} — Synapse index\n\n", .{p.namespace});
    // No repo-specific prose (see docs/synapse/synapse-graph.md) -- just how to
    // read the namespace without opening a multi-MB node file.
    try w.print(
        "{d} tracked files, {d} nodes. Nodes are subsystems and concepts, not modules — each one's frontmatter `sources` lists every file it covers, and `synapse index lookup <path>` is the reverse index from any path back to its owning node.\n\n",
        .{ p.total_files, p.bullets.len },
    );
    try w.writeAll(
        "Reading a node: use `synapse query body <node>` rather than opening the file — `sources` runs to tens of thousands of tokens on the hub nodes and the reverse index is far larger still. `synapse query sources <node> --modules` gives the module breakdown, `--count` just the number, and `synapse query stale` verifies the whole namespace against the working tree.\n\n",
    );
    for (p.bullets) |b| {
        try w.print("- [[{s}]] — {s} ({d} files)\n", .{ b.link, b.summary, b.files });
    }
}

const testing = std.testing;

test "the index carries every field its three readers check" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{
        .namespace = "fw-core@master",
        .project = "fw-core",
        .branch = "master",
        .remote = "ssh://git@example.invalid/fw/fw-core.git",
        .built_at = "2026-08-12 20:16",
        .total_files = 124817,
        .bullets = &.{
            .{ .link = "Alerts and exception system", .files = 42, .summary = "How failures surface." },
            .{ .link = "State machine", .files = 19, .summary = "How states advance." },
        },
    });
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "\nproject: fw-core\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\nbranch: master\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\nremote: \"ssh://git@example.invalid/fw/fw-core.git\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "node_type: synapse-index\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "124817 tracked files, 2 nodes.") != null); // from the bullet count

    try testing.expect(std.mem.endsWith(
        u8,
        text,
        "- [[Alerts and exception system]] — How failures surface. (42 files)\n" ++
            "- [[State machine]] — How states advance. (19 files)\n",
    ));
}

test "a namespace with no nodes yet still produces a readable index" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{
        .namespace = "r@main",
        .project = "r",
        .branch = "main",
        .remote = "",
        .built_at = "2026-08-12 20:16",
        .total_files = 0,
        .bullets = &.{},
    });
    try testing.expect(std.mem.indexOf(u8, out.written(), "remote: \"\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "0 tracked files, 0 nodes.") != null);
}

test "the title and the H1 are the namespace key, not the repo name" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{
        .namespace = "repo@feature/x",
        .project = "repo",
        .branch = "feature/x",
        .remote = "r",
        .built_at = "t",
        .total_files = 1,
        .bullets = &.{},
    });
    try testing.expect(std.mem.startsWith(u8, out.written(), "---\ntitle: \"repo@feature/x — Synapse index\"\n"));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\n# repo@feature/x — Synapse index\n") != null);
}
