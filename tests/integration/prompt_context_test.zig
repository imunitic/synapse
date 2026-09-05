//! `run()`'s stdin payload handling and its
//! `SYNAPSE_DISABLE_PROMPT_INJECTION` short-circuit -- the half of the
//! prompt-context hook that only a real process can exercise. The nudge
//! text itself is covered natively (`prompt_context.zig`'s own tests,
//! against `build()` directly).

const std = @import("std");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;

/// Enough of a namespace for the hook to have something to announce: an
/// Index.md whose `remote` matches this repo, plus one node so the count is
/// non-zero (the hook stays silent at zero nodes).
fn makeNamespace(fx: *Fixture) !void {
    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const remote = try fx.repoRemoteOrPath();
    defer fx.gpa.free(remote);
    try fx.writeSynapseIndex(ns, remote);

    const ns_dir = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}", .{ns});
    defer fx.gpa.free(ns_dir);
    const node_path = try std.fmt.allocPrint(fx.gpa, "{s}/Foo Node.md", .{ns_dir});
    defer fx.gpa.free(node_path);
    try fx.dir.writeFile(std.testing.io, .{
        .sub_path = node_path,
        .data =
        \\---
        \\title: "Foo Node"
        \\node_type: synapse-node
        \\stale: false
        \\---
        \\# Foo Node
        \\
        ,
    });
}

fn runHook(fx: *Fixture, prompt: []const u8, cwd: []const u8) !support_process_Result {
    const payload = try std.fmt.allocPrint(fx.gpa, "{{\"prompt\":{f},\"cwd\":{f}}}", .{
        std.json.fmt(prompt, .{}), std.json.fmt(cwd, .{}),
    });
    defer fx.gpa.free(payload);
    return fx.runHookStdin(&.{"prompt-context"}, payload);
}

const support_process_Result = @import("adapters").process.Result;

test "a real stdin payload in a repo with a namespace emits the nudge" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.makeRepo(null);
    try makeNamespace(&fx);

    const r = try runHook(&fx, "how does Cached_backend invalidate results", fx.repo);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.stdout, .{});
    defer parsed.deinit();
    const ctx = parsed.value.object.get("hookSpecificOutput").?.object.get("additionalContext").?.string;

    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const needle = try std.fmt.allocPrint(testing.allocator, "synapse/{s}/", .{ns});
    defer testing.allocator.free(needle);
    try testing.expect(std.mem.indexOf(u8, ctx, needle) != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "1 nodes") != null);
    // The instruction, not a suggestion -- the wording is the feature here.
    try testing.expect(std.mem.indexOf(u8, ctx, "Query it FIRST") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "Do not grep or open source files") != null);
}

test "an empty prompt exits silently, before anything is announced" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.makeRepo(null);
    try makeNamespace(&fx);

    const r = try runHook(&fx, "", fx.repo);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expectEqualStrings("", r.stdout);
}

test "SYNAPSE_DISABLE_PROMPT_INJECTION short-circuits before the payload is even read" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.makeRepo(null);
    try makeNamespace(&fx);
    try fx.setEnv("SYNAPSE_DISABLE_PROMPT_INJECTION", "1");

    const r = try runHook(&fx, "how does Cached_backend invalidate results", fx.repo);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expectEqualStrings("", r.stdout);
}
