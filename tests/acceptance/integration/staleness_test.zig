//! The staleness hook's real stdin-payload round trip. Everything else has
//! native coverage (`staleness.zig`'s own tests, via `build()`); this is the
//! one case that genuinely needs a real stdin payload and the compiled hook
//! binary, proving that wiring, end to end, actually works.

const std = @import("std");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;

/// A Synapse node whose frontmatter contains every shape the old
/// `PATCH -H "Target-Type: frontmatter"` call used to mangle: a title long
/// enough to be line-folded, quoted values, and an all-digit `hash` that
/// YAML happily coerces to a float.
fn writeSynapseNode(fx: *Fixture, project: []const u8, node: []const u8, stale: []const u8) !void {
    const dir = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}", .{project});
    defer fx.gpa.free(dir);
    try fx.dir.createDirPath(std.testing.io, dir);

    const path = try std.fmt.allocPrint(fx.gpa, "{s}/{s}", .{ dir, node });
    defer fx.gpa.free(path);
    const body = try std.fmt.allocPrint(fx.gpa,
        \\---
        \\title: "A deliberately long node title that a re-serialising writer would fold across two lines"
        \\node_type: synapse-node
        \\project: {s}
        \\sources:
        \\  - path: src/foo.aa
        \\    hash: 1111111111111111111111111111111111111111
        \\sources_digest: "2222222222222222222222222222222222222222222222222222222222222222"
        \\stale: {s}
        \\built_at: "2026-08-03 16:15"
        \\---
        \\
        \\# A node
        \\
        \\Body text, including a decoy: stale: false
        \\
    , .{ project, stale });
    defer fx.gpa.free(body);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = body });
}

test "file mapped to a node: rewrites that node's stale line, never PATCHes frontmatter" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.setEnv("SYNAPSE_WORK_DIR", fx.work);
    try fx.makeRepo(null);

    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const remote = try fx.repoRemoteOrPath();
    defer fx.gpa.free(remote);
    try fx.writeSynapseIndex(ns, remote);
    try writeSynapseNode(&fx, ns, "Foo Node.md", "false");
    try fx.writeIndexBin(fx.work, &.{.{ .path = "src/foo.aa", .node = "Foo Node.md" }});

    const file_path = try std.fmt.allocPrint(fx.gpa, "{s}/src/foo.aa", .{fx.repo});
    defer fx.gpa.free(file_path);
    const payload = try std.fmt.allocPrint(fx.gpa, "{{\"tool_input\":{{\"file_path\":{f}}}}}", .{
        std.json.fmt(file_path, .{}),
    });
    defer fx.gpa.free(payload);

    const r = try fx.runHookStdin(&.{"staleness"}, payload);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());

    const node_path = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}/Foo Node.md", .{ns});
    defer fx.gpa.free(node_path);
    const body = try fx.dir.readFileAlloc(std.testing.io, node_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "stale: true") != null);
}
