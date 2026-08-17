//! `synapse-bard search <query>` (full-text) / `synapse-bard search --field
//! <key>:<value>` (structured filter across the whole graph) -- a thin CLI
//! wrapper over `BardGraphStore.search()`, which already implements both
//! modes. Argument parsing only: no new search logic.
//!
//! The bare positional `<query>` is **always** full-text, never reinterpreted
//! as `key:value` even if it happens to contain exactly one colon (a book
//! title, `"The Knife: Book One"`) -- `BardGraphStore.search()`'s own
//! single-string heuristic exists because the *port*'s signature has only
//! one string to work with; a real CLI has flags and doesn't need to guess.
//! Only `--field key:value` can produce a structured filter.

const std = @import("std");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: synapse-bard search <query>
    \\       synapse-bard search --field <key>:<value>
    \\
    \\  <query>              full-text substring, always -- never treated as
    \\                       key:value even if it contains a colon
    \\  --field <key>:<value>  exact match on a root-level frontmatter field
    \\                       across every entity, e.g. --field faction:"The
    \\                       Radiant Dominion"
    \\
;

pub fn run(gpa: Allocator, io: Io, args: *std.process.Args.Iterator) !u8 {
    const first = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    var query: []const u8 = undefined;
    var is_field = false;
    if (std.mem.eql(u8, first, "--field")) {
        is_field = true;
        query = args.next() orelse {
            std.debug.print("synapse-bard search: --field needs a key:value argument\n{s}", .{usage});
            return 2;
        };
    } else {
        query = first;
    }
    if (args.next()) |extra| {
        std.debug.print("synapse-bard search: unexpected argument '{s}'\n{s}", .{ extra, usage });
        return 2;
    }

    const root = common.graphRoot(gpa, io) catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer gpa.free(root);

    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, root);
    defer store.deinit();
    const port = store.store();

    const hits = if (is_field)
        try port.search(gpa, io, query)
    else
        try store.searchText(gpa, io, query);
    defer {
        for (hits) |h| {
            gpa.free(h.node);
            gpa.free(h.context);
        }
        gpa.free(hits);
    }

    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    if (hits.len == 0) {
        try w.interface.print("no matches for '{s}'\n", .{query});
    }
    for (hits) |h| {
        try w.interface.print("{s} ({d})  {s}\n", .{ h.node, h.score, h.context });
    }
    try w.interface.flush();
    return 0;
}
