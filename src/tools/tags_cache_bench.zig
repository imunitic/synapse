//! Time `Cache.open` + `needsTagging` against a real cache, so the claim the
//! binary format was built on can be checked rather than asserted.
//!
//! The claim: answering "which of these paths changed?" should read the record
//! table and nothing else, making it independent of how much tag text the
//! cache holds. The number to beat is 5.0s, which is what `jq` costs parsing
//! syrius3's 828 MB, 124,837-entry JSON cache to do the same thing.
//!
//! A tool rather than a test, for the same reason `tags-differential` is one:
//! it needs a real cache from a real repository, which a hermetic test cannot
//! have. Built with `zig build bench`, never installed.
//!
//!   tags-cache-bench <cache-file> [sample-count]
//!
//! Requests `sample-count` paths (default: all of them) at their cached hashes
//! -- so every one is current and none needs tagging, which is the common case
//! and the one whose cost matters.

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
