//! `docs/synapse/cli.md`'s generator and its `--check` consistency mode,
//! against the real binaries' `--help` output.

const std = @import("std");
const adapters = @import("adapters");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;
const gpa = testing.allocator;

fn absolutePath(g: std.mem.Allocator, rel: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, std.fs.path.dirname(rel) orelse ".", .{});
    defer dir.close(std.testing.io);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = buf[0..try dir.realPath(std.testing.io, &buf)];
    return std.fmt.allocPrint(g, "{s}/{s}", .{ resolved, std.fs.path.basename(rel) });
}

fn projectRoot(g: std.mem.Allocator) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
    defer dir.close(std.testing.io);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = buf[0..try dir.realPath(std.testing.io, &buf)];
    return g.dupe(u8, resolved);
}

test "the committed docs/synapse/cli.md is up to date" {
    // The generator defaults to `zig-out/bin/synapse`, populated only by a
    // full `zig build` -- not this suite's own `test-integration` step
    // alone. Pointing it at the binaries this suite already has removes
    // that implicit prerequisite rather than relying on it.
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.setEnv("SYNAPSE_BIN", fx.synapse_bin);
    try fx.setEnv("SYNAPSE_HOOK_BIN", fx.hook_bin);

    const gen = try absolutePath(gpa, "docs/synapse/generate-cli-reference.sh");
    defer gpa.free(gen);
    const root = try projectRoot(gpa);
    defer gpa.free(root);

    const r = try adapters.process.run(fx.io(), fx.gpa, &.{ "bash", gen, "--check" }, .{ .cwd = .{ .path = root } });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "up to date") != null or std.mem.indexOf(u8, r.stderr, "up to date") != null);
}

test "--check fails when a subcommand's help has moved on" {
    // Simulated by editing the committed document rather than the binary:
    // rebuilding a mutated binary inside a test would need a Zig toolchain.
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.setEnv("SYNAPSE_BIN", fx.synapse_fake_bin);
    try fx.setEnv("SYNAPSE_HOOK_BIN", fx.hook_bin);

    const cli_md = try absolutePath(gpa, "docs/synapse/cli.md");
    defer gpa.free(cli_md);
    const gen = try absolutePath(gpa, "docs/synapse/generate-cli-reference.sh");
    defer gpa.free(gen);

    try fx.dir.createDirPath(std.testing.io, "docs");
    const cli_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, cli_md, gpa, .limited(4 << 20));
    defer gpa.free(cli_data);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "docs/cli.md", .data = cli_data });
    const gen_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, gen, gpa, .limited(1 << 20));
    defer gpa.free(gen_data);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "docs/generate-cli-reference.sh", .data = gen_data, .flags = .{ .permissions = .executable_file } });

    const scratch_docs = try std.fmt.allocPrint(fx.gpa, "{s}/docs", .{fx.root});
    defer fx.gpa.free(scratch_docs);

    const r1 = try adapters.process.run(fx.io(), fx.gpa, &.{ "bash", "./generate-cli-reference.sh", "--check" }, .{ .cwd = .{ .path = scratch_docs } });
    defer r1.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r1.exitCode());

    const appended = try fx.dir.readFileAlloc(std.testing.io, "docs/cli.md", fx.gpa, .limited(4 << 20));
    defer fx.gpa.free(appended);
    const new_content = try std.fmt.allocPrint(fx.gpa, "{s}a line the binaries never print\n", .{appended});
    defer fx.gpa.free(new_content);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "docs/cli.md", .data = new_content });

    const r2 = try adapters.process.run(fx.io(), fx.gpa, &.{ "bash", "./generate-cli-reference.sh", "--check" }, .{ .cwd = .{ .path = scratch_docs } });
    defer r2.deinit(gpa);
    try testing.expectEqual(@as(?u8, 1), r2.exitCode());
    try testing.expect(std.mem.indexOf(u8, r2.stdout, "out of date") != null or std.mem.indexOf(u8, r2.stderr, "out of date") != null);
}

test "every subcommand contributes a section, and no fenced block is empty" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const doc_path = try absolutePath(gpa, "docs/synapse/cli.md");
    defer gpa.free(doc_path);
    const doc = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, doc_path, gpa, .limited(4 << 20));
    defer gpa.free(doc);

    const help_res = try fx.runFake(&.{"--help"});
    defer help_res.deinit(gpa);
    const combined_help = try std.fmt.allocPrint(gpa, "{s}\n{s}", .{ help_res.stdout, help_res.stderr });
    defer gpa.free(combined_help);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var any = false;
    var lines = std.mem.splitScalar(u8, combined_help, '\n');
    while (lines.next()) |line| {
        if (line.len < 3 or !std.mem.startsWith(u8, line, "  ")) continue;
        const rest = line[2..];
        if (rest.len == 0 or rest[0] == ' ' or !std.ascii.isLower(rest[0])) continue;
        var end: usize = 1;
        while (end < rest.len and (std.ascii.isLower(rest[end]) or rest[end] == '-')) end += 1;
        if (end >= rest.len or rest[end] != ' ') continue;
        const sub = rest[0..end];
        if (seen.contains(sub)) continue;
        try seen.put(gpa, sub, {});
        any = true;

        const header = try std.fmt.allocPrint(gpa, "### synapse {s}", .{sub});
        defer gpa.free(header);
        try testing.expect(containsLine(doc, header));
    }
    try testing.expect(any);
    try testing.expect(containsLine(doc, "## synapse-hook"));

    // An opening fence followed immediately by its closing fence.
    var prev: []const u8 = "";
    var doc_lines = std.mem.splitScalar(u8, doc, '\n');
    while (doc_lines.next()) |line| {
        if (std.mem.eql(u8, line, "```")) {
            try testing.expect(!std.mem.eql(u8, prev, "```"));
        }
        prev = line;
    }
}

fn containsLine(text: []const u8, target: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, line, target)) return true;
    return false;
}

test "the generated help is what the binary actually prints" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const r = try fx.runFake(&.{ "query", "--help" });
    defer r.deinit(gpa);
    const combined = try std.fmt.allocPrint(gpa, "{s}\n{s}", .{ r.stdout, r.stderr });
    defer gpa.free(combined);

    var last_line: []const u8 = "";
    var lines = std.mem.splitScalar(u8, combined, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        last_line = line;
    }
    try testing.expect(last_line.len != 0);

    const doc_path = try absolutePath(gpa, "docs/synapse/cli.md");
    defer gpa.free(doc_path);
    const doc = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, doc_path, gpa, .limited(4 << 20));
    defer gpa.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, last_line) != null);
}

test "a --help that needs an environment fails the generator" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const gen = try absolutePath(gpa, "docs/synapse/generate-cli-reference.sh");
    defer gpa.free(gen);
    try fx.dir.writeFile(std.testing.io, .{
        .sub_path = "needy",
        .data = "#!/bin/bash\n[ -n \"${SOME_REQUIRED_VAR:-}\" ] || exit 1\necho \"usage: needy\"\n",
        .flags = .{ .permissions = .executable_file },
    });
    const needy = try std.fmt.allocPrint(fx.gpa, "{s}/needy", .{fx.root});
    defer fx.gpa.free(needy);
    try fx.setEnv("SYNAPSE_BIN", needy);
    try fx.setEnv("SYNAPSE_HOOK_BIN", needy);

    const r = try adapters.process.run(fx.io(), fx.gpa, &.{ "bash", gen }, .{ .cwd = .{ .path = fx.root } });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 1), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "without an environment") != null or std.mem.indexOf(u8, r.stderr, "without an environment") != null);
}

test "a bad flag exits 2 with usage" {
    const gen = try absolutePath(gpa, "docs/synapse/generate-cli-reference.sh");
    defer gpa.free(gen);
    const root = try projectRoot(gpa);
    defer gpa.free(root);

    const r = try adapters.process.run(testing.io, gpa, &.{ "bash", gen, "--nonsense" }, .{ .cwd = .{ .path = root } });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 2), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "Usage:") != null or std.mem.indexOf(u8, r.stderr, "Usage:") != null);
}
