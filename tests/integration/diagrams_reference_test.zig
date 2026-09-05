//! `docs/synapse/generate-diagrams.sh` -- the .mmd -> .png renderer and its
//! `--check` mode. Spawns the shell script directly, not the compiled
//! `synapse` binary, via `adapters.process.run`'s already-general "any
//! argv" spawn.

const std = @import("std");
const adapters = @import("adapters");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;
const gpa = testing.allocator;

/// The real `generate-diagrams.sh`, copied into a throwaway "docs" layout
/// under the fixture root so nothing here touches the real
/// `docs/synapse/diagrams`. Returns the copy's absolute path (caller frees)
/// and creates `<work>/diagrams/`.
fn setUpGeneratorCopy(fx: *Fixture) ![]u8 {
    try fx.dir.createDirPath(std.testing.io, "docs/diagrams");
    const real_gen = try absolutePath(gpa, "docs/synapse/generate-diagrams.sh");
    defer gpa.free(real_gen);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, real_gen, gpa, .limited(1 << 20));
    defer gpa.free(data);
    try fx.dir.writeFile(std.testing.io, .{
        .sub_path = "docs/generate-diagrams.sh",
        .data = data,
        .flags = .{ .permissions = .executable_file },
    });
    return std.fmt.allocPrint(gpa, "{s}/docs/generate-diagrams.sh", .{fx.root});
}

fn absolutePath(g: std.mem.Allocator, rel: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, std.fs.path.dirname(rel) orelse ".", .{});
    defer dir.close(std.testing.io);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = buf[0..try dir.realPath(std.testing.io, &buf)];
    return std.fmt.allocPrint(g, "{s}/{s}", .{ resolved, std.fs.path.basename(rel) });
}

fn writeMmd(fx: *Fixture, name: []const u8, label: []const u8) !void {
    const path = try std.fmt.allocPrint(fx.gpa, "docs/diagrams/{s}.mmd", .{name});
    defer fx.gpa.free(path);
    const data = try std.fmt.allocPrint(fx.gpa, "flowchart TB\n    A[\"{s}\"] --> B[\"done\"]\n", .{label});
    defer fx.gpa.free(data);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Records the CURRENT hash of `<name>.mmd`, as a successful render would.
fn stamp(fx: *Fixture, name: []const u8) !void {
    const mmd_path = try std.fmt.allocPrint(fx.gpa, "docs/diagrams/{s}.mmd", .{name});
    defer fx.gpa.free(mmd_path);
    const data = try fx.dir.readFileAlloc(std.testing.io, mmd_path, fx.gpa, .limited(1 << 20));
    defer fx.gpa.free(data);
    const hex = sha256Hex(data);
    const line = try std.fmt.allocPrint(fx.gpa, "{s}\t{s}\n", .{ name, hex });
    defer fx.gpa.free(line);

    const existing = fx.dir.readFileAlloc(std.testing.io, "docs/diagrams/.rendered", fx.gpa, .limited(1 << 20)) catch try fx.gpa.dupe(u8, "");
    defer fx.gpa.free(existing);
    const combined = try std.fmt.allocPrint(fx.gpa, "{s}{s}", .{ existing, line });
    defer fx.gpa.free(combined);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "docs/diagrams/.rendered", .data = combined });
}

fn runGen(fx: *Fixture, gen: []const u8, args: []const []const u8) !adapters.process.Result {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(fx.gpa);
    try argv.append(fx.gpa, "bash");
    try argv.append(fx.gpa, gen);
    try argv.appendSlice(fx.gpa, args);
    return adapters.process.run(fx.io(), fx.gpa, argv.items, .{ .cwd = .{ .path = fx.root } });
}

test "check: a source with no png at all is reported" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const gen = try setUpGeneratorCopy(&fx);
    defer gpa.free(gen);
    try writeMmd(&fx, "one", "hello");

    const r = try runGen(&fx, gen, &.{"--check"});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 1), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "one (no .png)") != null or std.mem.indexOf(u8, r.stderr, "one (no .png)") != null);
}

test "check: a png whose source has since changed is reported as stale" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const gen = try setUpGeneratorCopy(&fx);
    defer gpa.free(gen);
    try writeMmd(&fx, "one", "hello");
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "docs/diagrams/one.png", .data = "" });
    try stamp(&fx, "one");

    const r1 = try runGen(&fx, gen, &.{"--check"});
    defer r1.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r1.exitCode());

    try writeMmd(&fx, "one", "hello, revised");
    const r2 = try runGen(&fx, gen, &.{"--check"});
    defer r2.deinit(gpa);
    try testing.expectEqual(@as(?u8, 1), r2.exitCode());
    try testing.expect(std.mem.indexOf(u8, r2.stdout, "source changed since it was rendered") != null or std.mem.indexOf(u8, r2.stderr, "source changed since it was rendered") != null);
}

test "check: passes when every png matches its recorded source hash" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const gen = try setUpGeneratorCopy(&fx);
    defer gpa.free(gen);
    try writeMmd(&fx, "one", "a");
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "docs/diagrams/one.png", .data = "" });
    try stamp(&fx, "one");
    try writeMmd(&fx, "two", "b");
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "docs/diagrams/two.png", .data = "" });
    try stamp(&fx, "two");

    const r = try runGen(&fx, gen, &.{"--check"});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expectEqualStrings("", r.stdout);
}

test "check: one stale diagram does not mask the others, and all are named" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const gen = try setUpGeneratorCopy(&fx);
    defer gpa.free(gen);
    try writeMmd(&fx, "one", "a");
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "docs/diagrams/one.png", .data = "" });
    try stamp(&fx, "one");
    try writeMmd(&fx, "two", "b");
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "docs/diagrams/two.png", .data = "" });
    try stamp(&fx, "two");
    try writeMmd(&fx, "three", "c"); // never rendered
    try writeMmd(&fx, "one", "a2"); // edited after rendering

    const r = try runGen(&fx, gen, &.{"--check"});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 1), r.exitCode());
    const combined = try std.fmt.allocPrint(gpa, "{s}{s}", .{ r.stdout, r.stderr });
    defer gpa.free(combined);
    try testing.expect(std.mem.indexOf(u8, combined, "one") != null);
    try testing.expect(std.mem.indexOf(u8, combined, "three") != null);
    try testing.expect(std.mem.indexOf(u8, combined, "2 diagram(s) out of date") != null);
}

test "no .mmd sources at all is an error, not a silent pass" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const gen = try setUpGeneratorCopy(&fx);
    defer gpa.free(gen);

    const r = try runGen(&fx, gen, &.{"--check"});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 1), r.exitCode());
    const combined = try std.fmt.allocPrint(gpa, "{s}{s}", .{ r.stdout, r.stderr });
    defer gpa.free(combined);
    try testing.expect(std.mem.indexOf(u8, combined, "no .mmd sources") != null);
}

test "an unknown flag exits 2, and --help exits 0" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const gen = try setUpGeneratorCopy(&fx);
    defer gpa.free(gen);
    try writeMmd(&fx, "one", "a");

    const r1 = try runGen(&fx, gen, &.{"--bogus"});
    defer r1.deinit(gpa);
    try testing.expectEqual(@as(?u8, 2), r1.exitCode());

    const r2 = try runGen(&fx, gen, &.{"--help"});
    defer r2.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r2.exitCode());
    try testing.expect(std.mem.indexOf(u8, r2.stdout, "Usage:") != null or std.mem.indexOf(u8, r2.stderr, "Usage:") != null);
}

fn realHome(g: std.mem.Allocator) !?[]u8 {
    var env = try std.process.Environ.createMap(std.testing.environ, g);
    defer env.deinit();
    const home = env.get("HOME") orelse return null;
    return try g.dupe(u8, home);
}

fn canRender() bool {
    const home = (realHome(testing.allocator) catch return false) orelse return false;
    defer testing.allocator.free(home);
    const path = std.fmt.allocPrint(testing.allocator, "{s}/.cache/puppeteer", .{home}) catch return false;
    defer testing.allocator.free(path);
    const st = std.Io.Dir.cwd().statFile(testing.io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// `PUPPETEER_CACHE_DIR`/`npm_config_cache` pointed at the *real* $HOME's
/// caches -- mermaid-cli's Chromium and npm's own cache live there, and the
/// fixture's isolated $HOME has neither, so rendering would otherwise try
/// (and fail, with no network) to fetch them fresh.
fn setUpRealCaches(fx: *Fixture) !void {
    const home = (try realHome(fx.gpa)).?;
    defer fx.gpa.free(home);
    const puppeteer = try std.fmt.allocPrint(fx.gpa, "{s}/.cache/puppeteer", .{home});
    defer fx.gpa.free(puppeteer);
    try fx.setEnv("PUPPETEER_CACHE_DIR", puppeteer);
    const npm_cache = try std.fmt.allocPrint(fx.gpa, "{s}/.npm", .{home});
    defer fx.gpa.free(npm_cache);
    try fx.setEnv("npm_config_cache", npm_cache);
}

test "render: produces a png and records the source hash" {
    if (!canRender()) return error.SkipZigTest;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try setUpRealCaches(&fx);
    const gen = try setUpGeneratorCopy(&fx);
    defer gpa.free(gen);
    try writeMmd(&fx, "one", "hello");

    const r = try runGen(&fx, gen, &.{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    const st = try fx.dir.statFile(std.testing.io, "docs/diagrams/one.png", .{});
    try testing.expect(st.size > 0);

    const r2 = try runGen(&fx, gen, &.{"--check"});
    defer r2.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r2.exitCode());
}

test "render: leaves other diagrams' stamps alone" {
    if (!canRender()) return error.SkipZigTest;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try setUpRealCaches(&fx);
    const gen = try setUpGeneratorCopy(&fx);
    defer gpa.free(gen);
    try writeMmd(&fx, "keep", "untouched");
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "docs/diagrams/keep.png", .data = "" });
    try stamp(&fx, "keep");
    try writeMmd(&fx, "new", "fresh");

    const r = try runGen(&fx, gen, &.{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());

    const rendered = try fx.dir.readFileAlloc(std.testing.io, "docs/diagrams/.rendered", gpa, .limited(1 << 20));
    defer gpa.free(rendered);
    try testing.expect(lineStartsWith(rendered, "keep\t"));
    try testing.expect(lineStartsWith(rendered, "new\t"));
}

fn lineStartsWith(body: []const u8, prefix: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) return true;
    return false;
}

test "the repo's own diagrams are current" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const real_gen = try absolutePath(gpa, "docs/synapse/generate-diagrams.sh");
    defer gpa.free(real_gen);
    var cwd_dir = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
    defer cwd_dir.close(std.testing.io);
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const project_root = cwd_buf[0..try cwd_dir.realPath(std.testing.io, &cwd_buf)];

    const r = try adapters.process.run(fx.io(), fx.gpa, &.{ "bash", real_gen, "--check" }, .{ .cwd = .{ .path = project_root } });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
}
