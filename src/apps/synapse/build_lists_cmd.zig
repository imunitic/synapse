//! `synapse build-lists` -- the work half of `claude/lib/synapse/synapse-build-lists.sh`.
//!
//!   build-lists [--reenumerate]   manifest.tsv into one path list per node
//!
//! Reads `$SYNAPSE_WORK_DIR/manifest.tsv` (`title <TAB> include-ERE <TAB>
//! exclude-ERE`), enumerates as its first step, and writes `lists/NN.txt` plus
//! `lists/NN.title` per manifest line, then `covered.txt`, `all-sorted.txt` and
//! `unassigned.txt`. Prints a count per node and the coverage arithmetic, so a
//! bad pattern shows up as a number rather than a silent gap.
//!
//! ## The greps stay, and the measurement says that is fine
//!
//! `include` and `exclude` are user-authored EREs, one pair per node, and the
//! one real manifest on this machine uses 233 alternations, 60 groups, `?`, `+`
//! and character classes across 32 lines. There is no reading of those as
//! prefixes, and reimplementing an ERE engine -- or borrowing a different one --
//! would change which files a node claims, silently, on patterns nobody would
//! think to re-test.
//!
//! So they are still `grep -E`, spawned exactly as the script spawned them. That
//! sounds like it forfeits the port, and the measurement says otherwise: of the
//! script's 3166ms on `syrius-querschnitt-basis` (32 nodes, 4,892 files), the 64
//! greps were **329ms**. The other ~2.8s was the enumeration and 69 spawns of
//! `wc -l | tr -d ' '` -- one pair per node, purely to count the lines of a file
//! this process had just written. Those are what the port removes.
//!
//! ## Byte-order sorting is not a locale setting here
//!
//! The script had to write `LC_ALL=C` on both sorts *and* on `comm`, because
//! `comm` validates its inputs against the ambient collation and under a UTF-8
//! locale silently reports every line as unique once uppercase filenames appear
//! -- claiming nothing is covered, with no warning. Sorting bytes is the only
//! behaviour available here, so that hazard is gone by construction rather than
//! by remembering a prefix three times.

const std = @import("std");
const adapters = @import("adapters");
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
        if (std.mem.eql(u8, arg, "--reenumerate")) {
            reenumerate = true;
        } else return usage();
    }

    const work_dir = env.get("SYNAPSE_WORK_DIR") orelse {
        std.debug.print("synapse-build-lists: no SYNAPSE_WORK_DIR\n", .{});
        return 1;
    };

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, work_dir) catch {};

    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.tsv", .{work_dir});
    defer gpa.free(manifest_path);

    // Checked before enumerating, as the script did. A missing manifest is
    // "could not run", and enumerating first would do minutes of work on a
    // 125k-file repo before reporting it.
    const manifest = cwd.readFileAlloc(io, manifest_path, gpa, .limited(16 << 20)) catch {
        std.debug.print("synapse-build-lists: no manifest.tsv in {s}\n", .{work_dir});
        return 1;
    };
    defer gpa.free(manifest);

    var out_buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);

    // Enumeration is this build's first step, sharing the work dir this command
    // already resolved so the two can never disagree about where all.txt lives.
    try enumerate_cmd.ensure(gpa, io, env, work_dir, reenumerate, &out.interface);
    try out.interface.flush();

    const all_path = try std.fmt.allocPrint(gpa, "{s}/all.txt", .{work_dir});
    defer gpa.free(all_path);
    const all = try cwd.readFileAlloc(io, all_path, gpa, .limited(256 << 20));
    defer gpa.free(all);

    const lists_dir = try std.fmt.allocPrint(gpa, "{s}/lists", .{work_dir});
    defer gpa.free(lists_dir);
    // Rebuilt from scratch, so a removed manifest line leaves no stale list
    // behind for build-index to pick up as a node that no longer exists.
    cwd.deleteTree(io, lists_dir) catch {};
    try cwd.createDirPath(io, lists_dir);

    // Every path any node claimed, for the coverage set difference below. These
    // are slices *into* the per-node grep output, so those buffers have to
    // outlive the loop -- freeing one at the end of its own iteration, which is
    // what a `defer` inside the loop body does, leaves every path here dangling.
    // ReleaseSafe caught that as an integer overflow inside `std.sort.block`
    // comparing freed lengths, which is a better failure than a quietly wrong
    // coverage report but still only luck.
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
        // A blank title is a blank line, skipped as `[[ -n "$title" ]]` did.
        if (title.len == 0) continue;
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
        // The script paid `wc -l | tr -d ' '` here, per node, to count a file it
        // had just written.
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

/// `grep -E "$include" all.txt | grep -vE "${exclude:-^$}"`, spawned exactly as
/// the script spawned it so the ERE dialect is the same engine and not merely a
/// compatible one.
///
/// An empty exclude column means "exclude nothing", and the script spelled that
/// `^$` -- a pattern that never matches a path, where an empty pattern would
/// match every line and empty the list. Reproduced rather than special-cased,
/// because `^$` is also what a manifest may contain literally.
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
    // `grep` exits 1 for "no lines matched", which the script absorbed with
    // `|| true`: a pattern that claims nothing is an empty list, not a failure.
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

/// `covered.txt`, `all-sorted.txt` and `unassigned.txt`, plus the two counts.
///
/// All three files are written because the script wrote all three and a caller
/// may read any of them -- `unassigned.txt` is `synapse-build-index.sh`'s input,
/// and the other two are the working set that made the arithmetic checkable by
/// hand.
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

    // `comm -23`: in all-sorted, not in covered. Both sides are byte-sorted, so
    // this is one merge pass rather than a lookup per path.
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
