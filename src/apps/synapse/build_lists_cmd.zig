//! `synapse build-lists` -- the work half of `claude/lib/synapse/synapse-build-lists.sh`.
//!
//!   build-lists [--reenumerate]   manifest.tsv into one path list per node
//!
//! Reads `$SYNAPSE_WORK_DIR/manifest.tsv` (`title <TAB> include-ERE <TAB>
//! exclude-ERE`), enumerates first, writes `lists/NN.txt`/`NN.title` per
//! line, then `covered.txt`/`all-sorted.txt`/`unassigned.txt` plus coverage counts.
//!
//! `include`/`exclude` stay real `grep -E` (one manifest here uses 233
//! alternations, 60 groups across 32 lines -- reimplementing an ERE engine
//! would silently change which files a node claims). Measured on
//! `syrius-querschnitt-basis` (32 nodes, 4,892 files): of the script's
//! 3166ms, the 64 greps were 329ms; the rest was enumeration and 69 `wc -l`
//! spawns this port removes.
//!
//! Sorting/comparing stays byte-order throughout -- the script needed
//! `LC_ALL=C` on both sorts and `comm`, since `comm` under a UTF-8 locale
//! silently reports every line unique once uppercase filenames appear.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const context = @import("context.zig");
const enumerate_cmd = @import("enumerate_cmd.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var reenumerate = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = usage();
            return 0;
        }
        if (std.mem.eql(u8, arg, "--reenumerate")) {
            reenumerate = true;
        } else return usage();
    }

    if (core.identity.resolve(gpa, io, ".")) |id| {
        id.deinit(gpa);
    } else |_| {
        std.debug.print("synapse-build-lists: not inside a git repo\n", .{});
        return 1;
    }

    const work = (try context.workDir(gpa, io, env, "synapse-build-lists")) orelse return 1;
    defer work.deinit(gpa);
    const work_dir = work.path;

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, work_dir) catch {};

    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.tsv", .{work_dir});
    defer gpa.free(manifest_path);

    // Checked before enumerating: a missing manifest shouldn't cost minutes
    // of work on a 125k-file repo before reporting it.
    const manifest = cwd.readFileAlloc(io, manifest_path, gpa, .limited(16 << 20)) catch {
        std.debug.print("synapse-build-lists: no manifest.tsv in {s}\n", .{work_dir});
        return 1;
    };
    defer gpa.free(manifest);

    var out_buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);

    try enumerate_cmd.ensure(gpa, io, env, work_dir, reenumerate, &out.interface);
    try out.interface.flush();

    const all_path = try std.fmt.allocPrint(gpa, "{s}/all.txt", .{work_dir});
    defer gpa.free(all_path);
    const all = try cwd.readFileAlloc(io, all_path, gpa, .limited(256 << 20));
    defer gpa.free(all);

    const lists_dir = try std.fmt.allocPrint(gpa, "{s}/lists", .{work_dir});
    defer gpa.free(lists_dir);
    // Rebuilt from scratch so a removed manifest line leaves no stale list behind.
    cwd.deleteTree(io, lists_dir) catch {};
    try cwd.createDirPath(io, lists_dir);

    // `covered`'s entries are slices into the per-node grep output, so those
    // buffers must outlive the loop -- a per-iteration `defer` would free
    // them while `covered` still points in (caught in ReleaseSafe as an
    // overflow inside `std.sort.block`, not by design).
    var covered: std.ArrayListUnmanaged([]const u8) = .empty;
    defer covered.deinit(gpa);
    var matched_buffers: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (matched_buffers.items) |b| gpa.free(b);
        matched_buffers.deinit(gpa);
    }

    var node_index: usize = 0;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var cols = std.mem.splitScalar(u8, line, '\t');
        const title = cols.next() orelse continue;
        if (title.len == 0) continue; // blank title = blank line
        const include = cols.next() orelse "";
        const exclude = cols.next() orelse "";

        node_index += 1;
        const slug = try std.fmt.allocPrint(gpa, "{d:0>2}", .{node_index});
        defer gpa.free(slug);

        const title_path = try std.fmt.allocPrint(gpa, "{s}/{s}.title", .{ lists_dir, slug });
        defer gpa.free(title_path);
        const title_body = try std.fmt.allocPrint(gpa, "{s}\n", .{title});
        defer gpa.free(title_body);
        try cwd.writeFile(io, .{ .sub_path = title_path, .data = title_body });

        const matched = try selectPaths(gpa, io, all, include, exclude);
        try matched_buffers.append(gpa, matched);

        const list_path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ lists_dir, slug });
        defer gpa.free(list_path);
        try cwd.writeFile(io, .{ .sub_path = list_path, .data = matched });

        var count: usize = 0;
        var it = std.mem.splitScalar(u8, matched, '\n');
        while (it.next()) |p| {
            if (p.len == 0) continue;
            count += 1;
            try covered.append(gpa, p);
        }
        try out.interface.print("{s}\t{d}\t{s}\n", .{ slug, count, title });
    }

    try out.interface.writeAll("--- coverage\n");
    try writeCoverage(gpa, io, work_dir, all, covered.items, &out.interface);
    try out.interface.flush();
    return 0;
}

fn usage() u8 {
    std.debug.print(
        \\usage: synapse build-lists [--reenumerate]
        \\
    , .{});
    return 2;
}

/// `grep -E "$include" all.txt | grep -vE "${exclude:-^$}"`. Empty exclude
/// means "exclude nothing", spelled `^$` (a pattern matching no path) rather
/// than special-cased, since `^$` is also valid manifest content.
pub fn selectPaths(
    gpa: Allocator,
    io: Io,
    all: []const u8,
    include: []const u8,
    exclude: []const u8,
) ![]u8 {
    const included = try adapters.process.run(io, gpa, &.{ "grep", "-E", include }, .{
        .stdin = all,
    });
    defer gpa.free(included.stderr);
    errdefer gpa.free(included.stdout);
    if (included.exitCode() == null or included.exitCode().? > 1) {
        gpa.free(included.stdout);
        return error.GrepFailed;
    }
    if (included.stdout.len == 0) return included.stdout;

    const pattern = if (exclude.len == 0) "^$" else exclude;
    defer gpa.free(included.stdout);
    const kept = try adapters.process.run(io, gpa, &.{ "grep", "-vE", pattern }, .{
        .stdin = included.stdout,
    });
    defer gpa.free(kept.stderr);
    if (kept.exitCode() == null or kept.exitCode().? > 1) {
        gpa.free(kept.stdout);
        return error.GrepFailed;
    }
    return kept.stdout;
}

/// `covered.txt`, `all-sorted.txt` and `unassigned.txt`, plus the two
/// counts. `unassigned.txt` is `synapse-build-index.sh`'s input.
fn writeCoverage(
    gpa: Allocator,
    io: Io,
    work_dir: []const u8,
    all: []const u8,
    covered_paths: []const []const u8,
    out: *Io.Writer,
) !void {
    const covered = try gpa.dupe([]const u8, covered_paths);
    defer gpa.free(covered);
    std.mem.sort([]const u8, covered, {}, lessByBytes);
    const covered_unique = dedupe(covered);

    var all_sorted: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_sorted.deinit(gpa);
    var it = std.mem.splitScalar(u8, all, '\n');
    while (it.next()) |p| {
        if (p.len != 0) try all_sorted.append(gpa, p);
    }
    std.mem.sort([]const u8, all_sorted.items, {}, lessByBytes);

    try writeLines(gpa, io, work_dir, "covered.txt", covered_unique);
    try writeLines(gpa, io, work_dir, "all-sorted.txt", all_sorted.items);

    // `comm -23`: in all-sorted, not in covered. One merge pass over byte-sorted sides.
    var unassigned: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unassigned.deinit(gpa);
    var i: usize = 0;
    var j: usize = 0;
    while (i < all_sorted.items.len) {
        const a = all_sorted.items[i];
        if (j >= covered_unique.len) {
            try unassigned.append(gpa, a);
            i += 1;
            continue;
        }
        switch (std.mem.order(u8, a, covered_unique[j])) {
            .lt => {
                try unassigned.append(gpa, a);
                i += 1;
            },
            .eq => i += 1,
            .gt => j += 1,
        }
    }

    try writeLines(gpa, io, work_dir, "unassigned.txt", unassigned.items);
    try out.print("covered:    {d}\nunassigned: {d}\n", .{ covered_unique.len, unassigned.items.len });
}

fn lessByBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// In place, on an already-sorted slice: `sort -u`'s second half.
fn dedupe(sorted: [][]const u8) [][]const u8 {
    var n: usize = 0;
    for (sorted, 0..) |s, k| {
        if (k > 0 and std.mem.eql(u8, sorted[k - 1], s)) continue;
        sorted[n] = s;
        n += 1;
    }
    return sorted[0..n];
}

fn writeLines(
    gpa: Allocator,
    io: Io,
    work_dir: []const u8,
    name: []const u8,
    lines: []const []const u8,
) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ work_dir, name });
    defer gpa.free(path);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    for (lines) |l| try body.writer.print("{s}\n", .{l});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.written() });
}
