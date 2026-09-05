//! The grammar lock's real concurrency behavior: a lock is coordination
//! between genuinely separate OS processes, which only a real second
//! process actually exercises -- an in-process simulation would test
//! cooperative scheduling within one address space, not the real
//! crash/signal semantics the lock exists for. Registry lookup, tagging,
//! and the CLI's own exit-code contract have native coverage (`tags.zig`'s
//! own tests, using `fake_grammar.FakeExtractor`).

const std = @import("std");
const adapters = @import("adapters");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;

fn exists(fx: *Fixture, sub_path: []const u8) bool {
    fx.dir.access(std.testing.io, sub_path, .{}) catch return false;
    return true;
}

fn writeRegistry(fx: *Fixture, json: []const u8) !void {
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "home/.claude/synapse-grammars.conf", .data = json });
}

/// Drops every `synapse:`/`synapse-tags:` warning line -- the per-extension
/// noise mixed into combined stdout+stderr that a test asserting on *tags*
/// has to filter out first.
fn withoutWarnings(gpa: std.mem.Allocator, output: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "synapse:") or std.mem.startsWith(u8, line, "synapse-tags:")) continue;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn sleepMs(io: std.Io, ms: u64) void {
    std.Io.sleep(io, .{ .nanoseconds = @intCast(ms * std.time.ns_per_ms) }, .real) catch {};
}

test "concurrent first clone: a waiter picks up another worker's finished clone instead of racing it" {
    // Simulates two parallel workers hitting the same never-before-cloned
    // extension at once. The lock directory existing with no repo directory
    // yet is exactly what a worker mid-clone leaves behind, whether that
    // worker is real or (as here) simulated directly.
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "sample.ml", .data = "let x = 1\n" });
    try writeRegistry(&fx, "{\"ml\": {\"repo\": \"https://example.invalid/tree-sitter-ocaml\", \"scope\": \"source.ocaml\"}}");
    const grammars_dir = try std.fmt.allocPrint(fx.gpa, "{s}/grammars", .{fx.root});
    defer fx.gpa.free(grammars_dir);
    try fx.setEnv("SYNAPSE_GRAMMARS_DIR", grammars_dir);
    try fx.dir.createDirPath(std.testing.io, "grammars/repos/tree-sitter-ocaml.lock");
    const git_log = try std.fmt.allocPrint(fx.gpa, "{s}/git.log", .{fx.root});
    defer fx.gpa.free(git_log);
    try fx.setEnv("FAKE_GIT_LOG", git_log);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "git.log", .data = "" });

    const sample = try std.fmt.allocPrint(fx.gpa, "{s}/sample.ml", .{fx.root});
    defer fx.gpa.free(sample);
    const argv = [_][]const u8{ fx.synapse_fake_bin, "tags", sample };
    var waiter = std.Io.async(fx.io(), adapters.process.run, .{ fx.io(), fx.gpa, &argv, .{ .cwd = .{ .path = fx.repo } } });

    // Long enough that a waiter which raced the lock instead of honouring it
    // would already have finished (and logged a clone) by this point.
    sleepMs(fx.io(), 500);
    const during = try fx.dir.readFileAlloc(std.testing.io, "git.log", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(during);
    try testing.expectEqualStrings("", during);

    // The other worker finishes: repo appears, then its lock is released --
    // the same order ensureCloned's own clone-then-unlock path uses.
    try fx.dir.createDirPath(std.testing.io, "grammars/repos/tree-sitter-ocaml");
    try fx.dir.deleteTree(std.testing.io, "grammars/repos/tree-sitter-ocaml.lock");

    const r = try waiter.await(fx.io());
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "FAKE_NAME") != null or std.mem.indexOf(u8, r.stderr, "FAKE_NAME") != null);

    const after = try fx.dir.readFileAlloc(std.testing.io, "git.log", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("", after);
}

test "concurrent first clone: a lock released with no repo means the holder failed -- the waiter clones instead" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "sample.ml", .data = "let x = 1\n" });
    try writeRegistry(&fx, "{\"ml\": {\"repo\": \"https://example.invalid/tree-sitter-ocaml\", \"scope\": \"source.ocaml\"}}");
    const grammars_dir = try std.fmt.allocPrint(fx.gpa, "{s}/grammars", .{fx.root});
    defer fx.gpa.free(grammars_dir);
    try fx.setEnv("SYNAPSE_GRAMMARS_DIR", grammars_dir);
    try fx.dir.createDirPath(std.testing.io, "grammars/repos/tree-sitter-ocaml.lock");
    const git_log = try std.fmt.allocPrint(fx.gpa, "{s}/git.log", .{fx.root});
    defer fx.gpa.free(git_log);
    try fx.setEnv("FAKE_GIT_LOG", git_log);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "git.log", .data = "" });

    const sample = try std.fmt.allocPrint(fx.gpa, "{s}/sample.ml", .{fx.root});
    defer fx.gpa.free(sample);
    const argv = [_][]const u8{ fx.synapse_fake_bin, "tags", sample };
    var waiter = std.Io.async(fx.io(), adapters.process.run, .{ fx.io(), fx.gpa, &argv, .{ .cwd = .{ .path = fx.repo } } });
    sleepMs(fx.io(), 500);

    // The other worker's clone failed: lock released, repo never appeared --
    // the waiter must not conclude "someone else has it" forever.
    try fx.dir.deleteTree(std.testing.io, "grammars/repos/tree-sitter-ocaml.lock");

    const r = try waiter.await(fx.io());
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "FAKE_NAME") != null or std.mem.indexOf(u8, r.stderr, "FAKE_NAME") != null);

    const after = try fx.dir.readFileAlloc(std.testing.io, "git.log", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "clone") != null);
    try testing.expect(exists(&fx, "grammars/repos/tree-sitter-ocaml"));
}

test "a wedged lock times out rather than waiting forever, and is left for its actual owner" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "sample.ml", .data = "let x = 1\n" });
    try writeRegistry(&fx, "{\"ml\": {\"repo\": \"https://example.invalid/tree-sitter-ocaml\", \"scope\": \"source.ocaml\"}}");
    const grammars_dir = try std.fmt.allocPrint(fx.gpa, "{s}/grammars", .{fx.root});
    defer fx.gpa.free(grammars_dir);
    try fx.setEnv("SYNAPSE_GRAMMARS_DIR", grammars_dir);
    try fx.dir.createDirPath(std.testing.io, "grammars/repos/tree-sitter-ocaml.lock");
    try fx.setEnv("SYNAPSE_GRAMMAR_LOCK_TRIES", "3");

    const sample = try std.fmt.allocPrint(fx.gpa, "{s}/sample.ml", .{fx.root});
    defer fx.gpa.free(sample);
    const r = try fx.runFake(&.{ "tags", sample });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 1), r.exitCode());

    // A timeout now says so on stderr, where the shell script was silent.
    // Stdout is still empty, which is the part callers parse.
    const clean_out = try withoutWarnings(testing.allocator, r.stdout);
    defer testing.allocator.free(clean_out);
    const clean_err = try withoutWarnings(testing.allocator, r.stderr);
    defer testing.allocator.free(clean_err);
    try testing.expectEqualStrings("", clean_out);
    try testing.expectEqualStrings("", clean_err);

    // A timed-out waiter does not own the lock and must not delete it.
    try testing.expect(exists(&fx, "grammars/repos/tree-sitter-ocaml.lock"));
    try testing.expect(!exists(&fx, "grammars/repos/tree-sitter-ocaml"));
}
