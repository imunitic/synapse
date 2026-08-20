//! `synapse-bard-hook session-start` -- SessionStart.
//!
//! Injects up to three pieces, same assembly shape `synapse-hook`'s own
//! SessionStart uses (each piece optional, joined with a blank line,
//! nothing emitted at all if all are empty): `synapse-bard-claude.md`
//! (the plugin's own standing instructions -- vault discipline, the
//! Bible-graph query CLI, `synapse-bard-001`/`-002`/`-003`),
//! `_bard/vault/Index.md` (the vault's own folder layout), and --
//! `synapse-bard-009` -- a Bible-graph drift note, only when there
//! actually is one. Much simpler than the coding side's version otherwise:
//! `_bard/vault/` is always repo-relative, so there is no external
//! `synapse.conf`/`OBSIDIAN_VAULT_DIR` to resolve, no namespace, no remote
//! to verify. The one thing this still needs from outside the payload is
//! the repo root -- `core.identity.resolve` (already shared, already
//! tested) finds it from `cwd`, so a session started from a subdirectory
//! still finds the vault at the repo's top, not wherever the shell
//! happened to be.
//!
//! `synapse-bard-claude.md` resolves via `CLAUDE_PLUGIN_ROOT` only --
//! unlike `synapse-hook`'s own version, bard has no legacy pre-plugin
//! install to support an argv0-relative fallback for.
//!
//! **The drift check only ever reports; it must never write.** It calls
//! `adapters.bard_sync_plan.computePlan` in-process -- the same clustering/
//! extraction pipeline `synapse-bard sync --check` runs, never a second,
//! parallel implementation -- and compares the result against what's on
//! disk via `cluster.isDirty`/`cluster.wouldRemove`, exactly what
//! `sync --check` itself does, but without shelling out to that binary.
//! See `designs/synapse-bard/synapse-bard — Bible-graph drift detection.md`
//! (Synapse Vault) for why this stays a report-only Tier-1-style flag
//! rather than an automatic `sync` run.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();

    const id = core.identity.resolve(gpa, io, payload.str("cwd") orelse ".") catch return;
    defer id.deinit(gpa);

    var claude_md: ?[]u8 = null;
    defer if (claude_md) |s| gpa.free(s);
    if (claudeMdPath(gpa, env) catch null) |path| {
        defer gpa.free(path);
        claude_md = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null;
    }

    const index_path = try std.fmt.allocPrint(gpa, "{s}/_bard/vault/Index.md", .{id.layout.repo_root});
    defer gpa.free(index_path);

    var index_text: []u8 = undefined;
    if (Io.Dir.cwd().readFileAlloc(io, index_path, gpa, .limited(64 << 20))) |content| {
        index_text = try std.fmt.allocPrint(
            gpa,
            "Writer's notes vault index ({s}) -- read before creating or linking any note; prefer linking to an existing note over duplicating content, and fall back to linking this index if nothing more specific applies:\n\n{s}",
            .{ index_path, content },
        );
        gpa.free(content);
    } else |_| {
        // Offer, don't seed -- same rule `synapse-hook`'s own SessionStart
        // follows for the coding vault: this hook stays read-only, seeding
        // is the agent's call.
        const template_path = templatePath(gpa, env) catch null;
        defer if (template_path) |p| gpa.free(p);
        index_text = try std.fmt.allocPrint(
            gpa,
            "No Writer's notes vault index found at {s} -- offer to seed it from the shipped default ({s}) before creating or linking any note.",
            .{ index_path, template_path orelse "this plugin's own Index.md.template" },
        );
    }
    defer gpa.free(index_text);

    const drift_note: ?[]u8 = driftNote(gpa, io, id.layout.repo_root);
    defer if (drift_note) |s| gpa.free(s);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var wrote = false;
    for ([_]?[]u8{ claude_md, index_text, drift_note }) |part| {
        const p = part orelse continue;
        if (p.len == 0) continue;
        if (wrote) try out.writer.writeAll("\n\n");
        try out.writer.writeAll(p);
        wrote = true;
    }
    if (!wrote) return;

    try common.emitContext(gpa, io, "SessionStart", out.written());
}

/// `synapse-bard-009`: `null` on anything short of confirmed drift --
/// already current, or the check itself couldn't run cleanly (I/O error,
/// no `_bard/graph/` yet) -- this hook only ever reports, so anything it
/// can't cleanly answer is silence, the same "missing precondition is
/// silence" rule every hook here follows. Never writes.
fn driftNote(gpa: Allocator, io: Io, repo_root: []const u8) ?[]u8 {
    return driftNoteImpl(gpa, io, repo_root) catch null;
}

fn driftNoteImpl(gpa: Allocator, io: Io, repo_root: []const u8) !?[]u8 {
    const graph_root = try std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{repo_root});
    defer gpa.free(graph_root);

    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, graph_root);
    defer store.deinit();
    const port = store.store();

    // Same plan `synapse-bard sync --check` computes -- one implementation,
    // never a second one re-derived here.
    var plan = try adapters.bard_sync_plan.computePlan(gpa, io, repo_root, port);
    defer plan.deinit(gpa);

    var dirty: usize = 0;
    for (plan.clusters.items) |pc| {
        const existing = try port.read(gpa, io, pc.node);
        defer if (existing) |e| gpa.free(e);
        if (adapters.bard_cluster.isDirty(existing, pc.body)) dirty += 1;
    }

    const existing_nodes = try port.list(gpa, io);
    defer {
        for (existing_nodes) |n| gpa.free(n);
        gpa.free(existing_nodes);
    }
    const planned_nodes = try gpa.alloc([]const u8, plan.clusters.items.len);
    defer gpa.free(planned_nodes);
    for (plan.clusters.items, 0..) |pc, i| planned_nodes[i] = pc.node;
    const would_remove = try adapters.bard_cluster.wouldRemove(gpa, existing_nodes, planned_nodes);
    defer gpa.free(would_remove);

    const total = dirty + would_remove.len;
    if (total == 0) return null;

    return try std.fmt.allocPrint(
        gpa,
        "_bard/graph/ is behind source by {d} cluster(s) -- run `synapse-bard sync` to refresh it.",
        .{total},
    );
}

/// `CLAUDE_PLUGIN_ROOT/Index.md.template` when running as an installed
/// plugin -- the env var Claude Code exports on every hook invocation
/// regardless of launch method, same one `synapse-hook`'s own SessionStart
/// resolves `synapse-claude.md` against.
fn templatePath(gpa: Allocator, env: *std.process.Environ.Map) !?[]u8 {
    const root = env.get("CLAUDE_PLUGIN_ROOT") orelse return null;
    return try std.fmt.allocPrint(gpa, "{s}/Index.md.template", .{root});
}

fn claudeMdPath(gpa: Allocator, env: *std.process.Environ.Map) !?[]u8 {
    const root = env.get("CLAUDE_PLUGIN_ROOT") orelse return null;
    return try std.fmt.allocPrint(gpa, "{s}/synapse-bard-claude.md", .{root});
}

const testing = std.testing;

test "templatePath is null with no CLAUDE_PLUGIN_ROOT, so the fallback message is used" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(@as(?[]u8, null), try templatePath(testing.allocator, &env));
}

test "templatePath joins CLAUDE_PLUGIN_ROOT onto Index.md.template" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("CLAUDE_PLUGIN_ROOT", "/plugins/synapse-bard");
    const got = (try templatePath(testing.allocator, &env)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/plugins/synapse-bard/Index.md.template", got);
}

test "claudeMdPath is null with no CLAUDE_PLUGIN_ROOT" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(@as(?[]u8, null), try claudeMdPath(testing.allocator, &env));
}

test "claudeMdPath joins CLAUDE_PLUGIN_ROOT onto synapse-bard-claude.md" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("CLAUDE_PLUGIN_ROOT", "/plugins/synapse-bard");
    const got = (try claudeMdPath(testing.allocator, &env)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/plugins/synapse-bard/synapse-bard-claude.md", got);
}

test "driftNote is null on a repo with no entity files at all -- nothing to be behind on" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try testing.expectEqual(@as(?[]u8, null), driftNote(gpa, testing.io, root));
}

test "driftNote is null right after a real sync, since the graph now matches source" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.createDirPath(testing.io, "characters");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "characters/a.md",
        .data = "---\nname: Alice\ntemplate: character\n---\n",
    });

    // A real sync: compute the plan and write it, same as `synapse-bard
    // sync`'s own write path.
    const graph_root = try std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{root});
    defer gpa.free(graph_root);
    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, graph_root);
    defer store.deinit();
    var plan = try adapters.bard_sync_plan.computePlan(gpa, testing.io, root, store.store());
    defer plan.deinit(gpa);
    for (plan.clusters.items) |pc| _ = try store.write(testing.io, pc.node, pc.body);

    try testing.expectEqual(@as(?[]u8, null), driftNote(gpa, testing.io, root));
}

test "driftNote reports a real count when the graph is behind source" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.createDirPath(testing.io, "characters");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "characters/a.md",
        .data = "---\nname: Alice\ntemplate: character\n---\n",
    });
    // No sync ever run -- _bard/graph/ doesn't exist at all yet, so the one
    // computed cluster is drift (a missing file).

    const note = driftNote(gpa, testing.io, root).?;
    defer gpa.free(note);
    try testing.expect(std.mem.indexOf(u8, note, "1 cluster(s)") != null);
    try testing.expect(std.mem.indexOf(u8, note, "synapse-bard sync") != null);
}
