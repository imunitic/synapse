//! `synapse-bard-hook session-start` -- SessionStart.
//!
//! Gated on `_bard/` already existing at the repo root: nothing here creates
//! `_bard/` (only a real `/synapse-bard-sync` run or an explicit vault seed
//! does that), so its absence means bard has never been deliberately used in
//! this repo, and the hook must stay silent rather than offer a fiction-bible
//! vault in every repo the plugin happens to be installed in.
//!
//! Once `_bard/` exists, injects up to two pieces, same assembly shape
//! `synapse-hook`'s own SessionStart uses (each piece optional, joined with a
//! blank line, nothing emitted at all if both are empty): `synapse-bard-
//! claude.md` (the plugin's own standing instructions -- vault discipline,
//! the Bible-graph query CLI) and `_bard/vault/Index.md` (the vault's own
//! folder layout), or, if the vault side hasn't been set up yet even though
//! `_bard/graph/` has (a sync-only repo), the seed-offer message instead.
//! Much simpler than the coding side's version otherwise: `_bard/vault/` is
//! always repo-relative, so there is no external `synapse.conf`/
//! `OBSIDIAN_VAULT_DIR` to resolve, no namespace, no remote to verify. The
//! one thing this still needs from outside the payload is the repo root --
//! `core.identity.resolve` (already shared, already tested) finds it from
//! `cwd`, so a session started from a subdirectory still finds `_bard/` at
//! the repo's top, not wherever the shell happened to be.
//!
//! `synapse-bard-claude.md` resolves via `CLAUDE_PLUGIN_ROOT` only --
//! unlike `synapse-hook`'s own version, bard has no legacy pre-plugin
//! install to support an argv0-relative fallback for.

const std = @import("std");
const core = @import("core");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();

    const id = core.identity.resolve(gpa, io, payload.str("cwd") orelse ".") catch return;
    defer id.deinit(gpa);

    if (!bardEnabled(gpa, io, id.layout.repo_root)) return;

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
        // is the agent's call. Reaching this point means `_bard/` exists
        // (the gate above), so a human has already used bard in this repo,
        // just not the vault side yet.
        const template_path = templatePath(gpa, env) catch null;
        defer if (template_path) |p| gpa.free(p);
        index_text = try std.fmt.allocPrint(
            gpa,
            "No Writer's notes vault index found at {s} -- offer to seed it from the shipped default ({s}) before creating or linking any note.",
            .{ index_path, template_path orelse "this plugin's own Index.md.template" },
        );
    }
    defer gpa.free(index_text);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var wrote = false;
    for ([_]?[]u8{ claude_md, index_text }) |part| {
        const p = part orelse continue;
        if (p.len == 0) continue;
        if (wrote) try out.writer.writeAll("\n\n");
        try out.writer.writeAll(p);
        wrote = true;
    }
    if (!wrote) return;

    try common.emitContext(gpa, io, "SessionStart", out.written());
}

/// Whether `_bard/` exists at all under `repo_root` -- the one thing that
/// distinguishes a repo where bard has been deliberately used (a real
/// `/synapse-bard-sync` run wrote `_bard/graph/`, or the vault side was
/// seeded) from a repo where the plugin merely happens to be installed.
/// Nothing in this hook ever creates `_bard/` itself.
fn bardEnabled(gpa: Allocator, io: Io, repo_root: []const u8) bool {
    const path = std.fmt.allocPrint(gpa, "{s}/_bard", .{repo_root}) catch return false;
    defer gpa.free(path);
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
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

test "bardEnabled is false when _bard doesn't exist" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try testing.expect(!bardEnabled(gpa, testing.io, root));
}

test "bardEnabled is true once _bard/graph exists, e.g. after a sync-only repo" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.createDirPath(testing.io, "_bard/graph");

    try testing.expect(bardEnabled(gpa, testing.io, root));
}
