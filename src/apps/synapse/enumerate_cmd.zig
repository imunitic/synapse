//! `synapse enumerate` -- the work half of `claude/lib/synapse/synapse-enumerate.sh`.
//!
//!   enumerate [--reenumerate]   tracked files worth graphing, into the work dir
//!
//! Writes `$SYNAPSE_WORK_DIR/all.txt` (`git ls-files` order) and
//! `oversize.txt` (`size<TAB>path`). An existing non-empty `all.txt` is
//! reused unless `--reenumerate` forces a rebuild.
//!
//! The script stays in front for identity resolution (`synapse-identity.sh`,
//! still bash); the work dir arrives via `SYNAPSE_WORK_DIR`, and its absence
//! is an error, not a guess.
//!
//! Measured on syrius3: bash spent 15.9s / 65 spawns (45 of them `sed`, one
//! per conf line) enumerating 124,817 of 125,351 tracked files; this is one
//! `git ls-files` plus one `statFile` per path. `git ls-files` stays a real
//! spawn (git owns that binary format); the extension/lockfile filters moved
//! into `core/enumerate.zig`, but the user's own EREs stay on real `grep -vE`
//! rather than a reimplemented dialect that would disagree at the edges.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const context = @import("context.zig");

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

    // Outside a repo, say so rather than letting `git ls-files` fail with its own wording.
    if (core.identity.resolve(gpa, io, ".")) |id| {
        id.deinit(gpa);
    } else |_| {
        std.debug.print("synapse-enumerate: not inside a git repo\n", .{});
        return 1;
    }

    const work = (try context.workDir(gpa, io, env, "synapse-enumerate")) orelse return 1;
    defer work.deinit(gpa);
    const work_dir = work.path;
    if (work_dir.len == 0) {
        std.debug.print("synapse-enumerate: empty SYNAPSE_WORK_DIR\n", .{});
        return 1;
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    try ensure(gpa, io, env, work_dir, reenumerate, &out.interface);
    try out.interface.flush();
    return 0;
}

/// Brings `all.txt`/`oversize.txt` up to date and reports: the rebuild
/// banner when a rebuild happens, the oversize report if anything was
/// skipped, `enumerated: N` always. Shared with `build-lists` (writes to
/// the caller's own writer) rather than spawned, since
/// `tests/synapse-build-lists.bats` asserts on where these lines land.
pub fn ensure(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    work_dir: []const u8,
    reenumerate: bool,
    out: *Io.Writer,
) !void {
    const all_path = try std.fmt.allocPrint(gpa, "{s}/all.txt", .{work_dir});
    defer gpa.free(all_path);
    const oversize_path = try std.fmt.allocPrint(gpa, "{s}/oversize.txt", .{work_dir});
    defer gpa.free(oversize_path);

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, work_dir) catch {};

    // Checked by size, not existence: a zero-byte all.txt from an
    // interrupted run is not a usable enumeration.
    const existing: u64 = if (cwd.statFile(io, all_path, .{})) |st| st.size else |_| 0;
    if (existing == 0 or reenumerate) {
        try out.writeAll("--- enumerating tracked files\n");
        try out.flush();
        try enumerateInto(gpa, io, env, all_path, oversize_path);
    }

    try reportOversize(gpa, io, env, out, oversize_path);

    const kept = countLines(gpa, io, all_path) catch 0;
    try out.print("enumerated: {d}\n", .{kept});
}

fn usage() u8 {
    std.debug.print(
        \\usage: synapse enumerate [--reenumerate]
        \\
    , .{});
    return 2;
}

/// A `core.conf.Vars` over this process's environment. Indirection exists
/// because `core` may not name `std.process` (`ci/check-layering.sh`).
fn envVars(env: *std.process.Environ.Map) core.conf.Vars {
    return .{ .ctx = @ptrCast(env), .getFn = envLookup };
}

fn envLookup(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const env: *std.process.Environ.Map = @ptrCast(@alignCast(ctx));
    return env.get(name);
}

/// Default cap (`SYNAPSE_MAX_FILE_BYTES`). Skips are reported, not silent --
/// a silent skip would make `enumerated` disagree with the repo.
const default_max_file_bytes: u64 = 1048576;

fn maxFileBytes(env: *std.process.Environ.Map) u64 {
    const raw = env.get("SYNAPSE_MAX_FILE_BYTES") orelse return default_max_file_bytes;
    return std.fmt.parseInt(u64, raw, 10) catch default_max_file_bytes;
}

fn enumerateInto(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    all_path: []const u8,
    oversize_path: []const u8,
) !void {
    const cwd = Io.Dir.cwd();
    // Truncated up front so a clean rebuild doesn't keep the previous run's findings.
    try cwd.writeFile(io, .{ .sub_path = oversize_path, .data = "" });

    // Inherited cwd, matching the script: every caller invokes from the repo root.
    const listed = try adapters.process.run(io, gpa, &.{ "git", "ls-files" }, .{});
    defer listed.deinit(gpa);
    if (!listed.ok()) return error.GitLsFilesFailed;

    const candidates = try applyUserPatterns(gpa, io, env, listed.stdout);
    defer if (candidates.ptr != listed.stdout.ptr) gpa.free(candidates);

    var all: std.Io.Writer.Allocating = .init(gpa);
    defer all.deinit();
    var oversize: std.Io.Writer.Allocating = .init(gpa);
    defer oversize.deinit();

    const cap = maxFileBytes(env);
    var it = std.mem.splitScalar(u8, candidates, '\n');
    while (it.next()) |path| {
        if (path.len == 0) continue;
        if (core.enumerate.isExcluded(path)) continue;

        // One statFile answers both is-it-a-regular-file (a submodule gitlink
        // is an ls-files entry but a directory on disk) and how big. Symlinks
        // followed: measures the target, not the link, unlike the script.
        const st = cwd.statFile(io, path, .{}) catch continue;
        if (st.kind != .file) continue;
        if (st.size > cap) {
            try oversize.writer.print("{d}\t{s}\n", .{ st.size, path });
        } else {
            try all.writer.print("{s}\n", .{path});
        }
    }

    try cwd.writeFile(io, .{ .sub_path = all_path, .data = all.written() });
    try cwd.writeFile(io, .{ .sub_path = oversize_path, .data = oversize.written() });
}

/// `$SYNAPSE_EXTRA_EXCLUDE_RE` OR'd with every pattern line of
/// `~/.claude/synapse-ignore-files.conf`, applied by one `grep -vE`. Returns
/// the input untouched when there are no patterns (the common case) --
/// an empty ERE matches every line, so a missing guard would enumerate zero files.
pub fn applyUserPatterns(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    listing: []u8,
) ![]u8 {
    var pattern: std.Io.Writer.Allocating = .init(gpa);
    defer pattern.deinit();

    if (env.get("SYNAPSE_EXTRA_EXCLUDE_RE")) |re| {
        if (re.len != 0) try pattern.writer.writeAll(re);
    }

    if (env.get("HOME")) |home| {
        const conf = (try core.conf.resolveConfPath(gpa, io, envVars(env), "synapse-ignore-files.conf")) orelse
            try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-ignore-files.conf", .{home});
        defer gpa.free(conf);
        if (Io.Dir.cwd().readFileAlloc(io, conf, gpa, .limited(1 << 20))) |text| {
            defer gpa.free(text);
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |raw| {
                const uncommented = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
                const pat = std.mem.trim(u8, uncommented, " \t\r");
                if (pat.len == 0) continue;
                if (pattern.written().len != 0) try pattern.writer.writeAll("|");
                try pattern.writer.writeAll(pat);
            }
        } else |_| {}
    }

    if (pattern.written().len == 0) return listing;

    const res = try adapters.process.run(io, gpa, &.{ "grep", "-vE", pattern.written() }, .{
        .stdin = listing,
    });
    defer gpa.free(res.stderr);
    // grep exits 1 when every line matched (everything excluded) -- a
    // legitimate empty result, not a failure.
    if (res.exitCode()) |code| {
        if (code > 1) {
            gpa.free(res.stdout);
            return error.GrepFailed;
        }
    } else {
        gpa.free(res.stdout);
        return error.GrepFailed;
    }
    return res.stdout;
}

/// `skipped N file(s) over CAP bytes (largest first):` and the five biggest.
fn reportOversize(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
    oversize_path: []const u8,
) !void {
    const text = Io.Dir.cwd().readFileAlloc(io, oversize_path, gpa, .limited(64 << 20)) catch return;
    defer gpa.free(text);
    if (text.len == 0) return;

    const Row = struct { size: u64, path: []const u8 };
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer rows.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const size = std.fmt.parseInt(u64, line[0..tab], 10) catch continue;
        try rows.append(gpa, .{ .size = size, .path = line[tab + 1 ..] });
    }
    if (rows.items.len == 0) return;

    try out.print("skipped {d} file(s) over {d} bytes (largest first):\n", .{
        rows.items.len,
        maxFileBytes(env),
    });
    std.mem.sort(Row, rows.items, {}, struct {
        fn desc(_: void, a: Row, b: Row) bool {
            return a.size > b.size;
        }
    }.desc);
    for (rows.items[0..@min(5, rows.items.len)]) |r|
        try out.print("  {d: >10}  {s}\n", .{ r.size, r.path });
}

fn countLines(gpa: Allocator, io: Io, path: []const u8) !usize {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20));
    defer gpa.free(text);
    return std.mem.count(u8, text, "\n");
}
