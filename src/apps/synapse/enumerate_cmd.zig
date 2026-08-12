//! `synapse enumerate` -- the work half of `claude/lib/synapse/synapse-enumerate.sh`.
//!
//!   enumerate [--reenumerate]   tracked files worth graphing, into the work dir
//!
//! Writes `$SYNAPSE_WORK_DIR/all.txt` (one path per line, `git ls-files` order)
//! and `$SYNAPSE_WORK_DIR/oversize.txt` (`size<TAB>path`, encounter order). An
//! existing non-empty `all.txt` is reused unless `--reenumerate` forces a
//! rebuild, so a caller that only needs the list pays nothing.
//!
//! The script stays in front of this, for the same reason
//! `synapse-build-index.sh` does: it resolves the namespace through
//! `synapse-identity.sh`, which is bash until the last sourcer is ported, and
//! nothing here resolves it a second time. The work dir arrives already
//! decided, via `SYNAPSE_WORK_DIR`, and its absence is an error rather than a
//! guess.
//!
//! ## What this removes, measured
//!
//! The bash spent 15.9s on syrius3 (124,817 files enumerated of 125,351
//! tracked) and 65 process spawns. 45 of those spawns were `sed`, one per line
//! of `synapse-ignore-files.conf` -- including its comment lines, which is
//! every line in the shipped default. The rest of the time went on a bash
//! `while read` loop running `[[ -f ]]` over 125k paths and on `xargs` batches
//! of `stat`. In process it is one `git ls-files`, one `statFile` per path, and
//! nothing else.
//!
//! ## `git ls-files` is spawned, and the two other filters are not
//!
//! Reading git's index would mean parsing a binary format that git owns and
//! versions, to answer a question git answers in one call. That is the trade
//! `core/index_map` refused for the reverse index and accepts here, and the
//! difference is who owns the format.
//!
//! The extension and lockfile filters moved into `core/enumerate.zig` as a
//! suffix test and a basename test -- they were only EREs because `grep -vE`
//! was the tool at hand. The user's own patterns stay with `grep -vE`, spawned
//! once and only when there are any: an ERE means whatever `grep` says it
//! means, and a reimplemented subset would be a second dialect that disagrees
//! at the edges.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");

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
        std.debug.print("synapse-enumerate: no SYNAPSE_WORK_DIR\n", .{});
        return 1;
    };
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

/// Bring `all.txt` and `oversize.txt` up to date and report, writing the same
/// three lines the script printed: the `--- enumerating tracked files` banner
/// when a rebuild happens, the oversize report when anything was skipped, and
/// `enumerated: N` always.
///
/// Shared with `build-lists` rather than spawned by it. The script called
/// `synapse-enumerate.sh` as a subprocess and its stdout landed in the caller's
/// output, which `tests/synapse-build-lists.bats` asserts on -- so the lines
/// have to appear in exactly the same place, and the cheapest way to guarantee
/// that is one implementation writing to the caller's own writer.
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

    // An existing non-empty all.txt is the answer unless a rebuild is asked
    // for. Checked by size rather than existence, matching `[[ ! -s ]]`: a
    // zero-byte all.txt from an interrupted run is not a usable enumeration.
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

/// The shipped default, matching the script's `SYNAPSE_MAX_FILE_BYTES`. A cap
/// rather than a pattern, because no extension or name rule anticipates a
/// generated monster -- and reported rather than dropped silently, because a
/// silent skip makes `enumerated` a number that quietly disagrees with the repo.
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
    // Truncated up front, so a rebuild that finds nothing oversized leaves an
    // empty file rather than the previous run's findings.
    try cwd.writeFile(io, .{ .sub_path = oversize_path, .data = "" });

    // Run in the inherited cwd, exactly as the script does. `git ls-files` from
    // a subdirectory lists that subdirectory relative to itself, and every
    // caller invokes this from the repo root -- reproducing the behaviour
    // rather than correcting it keeps the two implementations comparable.
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

        // One `statFile` answers both questions the script asked separately: is
        // this a regular file (a submodule gitlink is one ls-files entry but a
        // directory on disk, and `git hash-object` fails the whole batch on
        // one), and how big is it. The script needed `[[ -f ]]` plus a batched
        // `stat` because a per-file `wc -c` measured 21s for 3,000 files.
        // Symlinks followed, matching `[[ -f ]]`. One divergence, stated: for
        // a tracked symlink the script's `stat` measured the link and this
        // measures the target, which only shows up if the target crosses the
        // cap. Neither fw-core nor syrius3 tracks a symlink at all.
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
/// `~/.claude/synapse-ignore-files.conf`, applied by one `grep -vE`.
///
/// Returns the input untouched when there are no patterns, which is the common
/// case -- the shipped conf is all comments. The script OR'd an empty pattern
/// set into `^$` for the same reason this returns early: an empty ERE matches
/// every line, so a missing guard would enumerate zero files.
fn applyUserPatterns(
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
        const conf = try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-ignore-files.conf", .{home});
        defer gpa.free(conf);
        if (Io.Dir.cwd().readFileAlloc(io, conf, gpa, .limited(1 << 20))) |text| {
            defer gpa.free(text);
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |raw| {
                // Comment stripped at the first `#` and both ends trimmed, as
                // the script's `${pat%%#*}` and `sed` did -- without the fork
                // per line that cost 45 of its 65 spawns.
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
    // `grep -v` exits 1 when every line matched, i.e. everything was excluded.
    // That is a legitimate empty result, not a failure -- the same case the
    // script's own pipeline had to survive.
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

/// `skipped N file(s) over CAP bytes (largest first):` and the five biggest,
/// byte-identical to the script's `sort -rn | head -5 | awk` formatting.
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
