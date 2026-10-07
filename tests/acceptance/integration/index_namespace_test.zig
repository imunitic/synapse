//! `synapse index`'s read forms (`unassigned`/`lookup`/`nodes`/`paths`)
//! addressing another namespace's already-built `_index.bin` directly via
//! `--namespace`, the same read-only escape hatch `query --namespace` and
//! `callers --namespace` already have -- no checkout of that namespace
//! needs to exist on disk. The write forms (`build`/`add-unassigned`)
//! refuse `--namespace` outright; native coverage for the lookup logic
//! itself lives in `index_cmd.zig`'s own tests.

const std = @import("std");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;

test "index lookup --namespace reads another checkout's index directly, no repo at cwd needed" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const other_ns = "other-repo@main";
    const other_work = try std.fmt.allocPrint(fx.gpa, "{s}/.cache/synapse/work/{s}", .{ fx.home, other_ns });
    defer fx.gpa.free(other_work);

    try fx.writeIndexBin(other_work, &.{
        .{ .path = "src/Foo.java", .node = "Foo concept.md" },
    });

    // No vault, and `self.repo` (the fixture's default cwd) is never turned
    // into a real git repo at all.
    try fx.unsetEnv("SYNAPSE_VAULT_DIR");

    const r = try fx.runFake(&.{ "index", "lookup", "src/Foo.java", "--namespace", other_ns });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "Foo concept") != null);
}

test "index unassigned/nodes/paths --namespace all resolve the same other index" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const other_ns = "other-repo@main";
    const other_work = try std.fmt.allocPrint(fx.gpa, "{s}/.cache/synapse/work/{s}", .{ fx.home, other_ns });
    defer fx.gpa.free(other_work);

    try fx.writeIndexBin(other_work, &.{
        .{ .path = "src/Foo.java", .node = "Foo concept.md" },
    });
    try fx.unsetEnv("SYNAPSE_VAULT_DIR");

    const nodes = try fx.runFake(&.{ "index", "nodes", "--namespace", other_ns });
    defer nodes.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), nodes.exitCode());
    try testing.expect(std.mem.indexOf(u8, nodes.stdout, "Foo concept") != null);

    const paths = try fx.runFake(&.{ "index", "paths", "--namespace", other_ns });
    defer paths.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), paths.exitCode());
    try testing.expect(std.mem.indexOf(u8, paths.stdout, "src/Foo.java") != null);

    const unassigned = try fx.runFake(&.{ "index", "unassigned", "--namespace", other_ns });
    defer unassigned.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), unassigned.exitCode());
    try testing.expectEqualStrings("", unassigned.stdout);
}

test "index build --namespace is a usage error: --namespace is read-only" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.unsetEnv("SYNAPSE_VAULT_DIR");

    const r = try fx.runFake(&.{ "index", "build", "--unassigned", "/nonexistent/unassigned.txt", "--namespace", "other-repo@main" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r.exitCode());
}

test "index lookup --file and --namespace together is a usage error, not a silent pick" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.unsetEnv("SYNAPSE_VAULT_DIR");

    const r = try fx.runFake(&.{
        "index", "lookup", "src/Foo.java", "--file", "/nonexistent/_index.bin", "--namespace", "other-repo@main",
    });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r.exitCode());
}
