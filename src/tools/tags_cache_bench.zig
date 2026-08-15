//! Times `Cache.open` + `needsTagging` against a real cache, checking the
//! claim the binary format was built on: answering "which paths changed?"
//! should read the record table only, independent of tag-text size. Number
//! to beat: 5.0s, what `jq` cost parsing syrius3's 828 MB JSON equivalent.
//!
//! A tool, not a test -- needs a real cache from a real repo. Built with
//! `zig build bench`, never installed.
//!
//!   tags-cache-bench <cache-file> [sample-count]
//!
//! Requests `sample-count` paths (default: all) at their cached hashes, so
//! none needs tagging -- the common case, and the one whose cost matters.

const std = @import("std");
const core = @import("core");

const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse {
        std.debug.print("usage: tags-cache-bench <cache-file> [sample-count]\n", .{});
        return 2;
    };
    const limit: ?usize = if (args.next()) |n| std.fmt.parseInt(usize, n, 10) catch null else null;

    const opened_at: Io.Timestamp = .now(io, .awake);
    var cache = try core.tags_cache.Cache.open(io, path);
    defer cache.close(io);
    const open_ns = elapsed(io, opened_at);

    if (cache.discarded) |e| {
        std.debug.print("cache not usable: {t}\n", .{e});
        return 1;
    }

    const n = @min(cache.count(), limit orelse cache.count());
    var requested = try gpa.alloc(core.tags_cache.PathHash, n);
    defer gpa.free(requested);
    for (0..n) |i| {
        const r = cache.view.record(@intCast(i));
        requested[i] = .{ .path = cache.view.path(r), .hash = r.hash };
    }

    const asked_at: Io.Timestamp = .now(io, .awake);
    const need = try cache.needsTagging(gpa, requested);
    defer gpa.free(need);
    const need_ns = elapsed(io, asked_at);

    std.debug.print(
        \\entries      {d}
        \\requested    {d}
        \\needs tagging {d}
        \\open         {d:.1} ms
        \\needsTagging {d:.1} ms
        \\
    , .{
        cache.count(),
        n,
        need.len,
        @as(f64, @floatFromInt(open_ns)) / 1e6,
        @as(f64, @floatFromInt(need_ns)) / 1e6,
    });
    return 0;
}

fn elapsed(io: Io, since: Io.Timestamp) u64 {
    const now: Io.Timestamp = .now(io, .awake);
    return @intCast(now.nanoseconds - since.nanoseconds);
}
