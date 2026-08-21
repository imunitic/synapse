//! `synapse-bard search <query>` (full-text) / `synapse-bard search --field
//! <key>:<value>` (structured filter across the whole graph).
//!
//! Before clustering, `_bard/graph/{slug}.md` *was* a
//! verbatim copy of each entity's frontmatter, so scanning `_bard/graph/`
//! itself found real content. A cluster node's body is now just a
//! `sources:` manifest and an `## Entities` link list -- scanning that
//! would stop finding matches inside entity fields entirely. So this
//! resolves every entity across every cluster (`bard_cluster.allEntities`),
//! reads each one's *real* source file, and searches only its
//! `frontmatterBlock()` -- never the prose body, matching the
//! frontmatter-only boundary every other piece of this system holds to
//! (see the design note's Constraints section). Reuses the same
//! line-matching helpers `BardGraphStore` uses internally
//! (`fieldLine`/`firstMatchingLine`, exported `pub` from `graph_store.zig`
//! for exactly this reuse) -- same scanning logic, different bytes.
//!
//! The bare positional `<query>` is always full-text; only `--field
//! key:value` produces a structured filter -- the flag itself disambiguates,
//! so (unlike `BardGraphStore.search()`'s single-string port signature)
//! there's no colon-ambiguity heuristic needed here at all.

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

const Field = struct { key: []const u8, value: []const u8 };

pub fn run(gpa: Allocator, io: Io, args: *std.process.Args.Iterator) !u8 {
    const first = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    // Help must not need an environment -- checked before it can be
    // mistaken for the query itself, and before Roots.resolve below.
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }

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

    var field: ?Field = null;
    if (is_field) {
        const colon = std.mem.indexOfScalar(u8, query, ':') orelse {
            std.debug.print("synapse-bard search: --field needs key:value, got '{s}'\n{s}", .{ query, usage });
            return 2;
        };
        const key = std.mem.trim(u8, query[0..colon], " ");
        const value = std.mem.trim(u8, query[colon + 1 ..], " ");
        if (key.len == 0 or value.len == 0) {
            std.debug.print("synapse-bard search: --field needs key:value, got '{s}'\n{s}", .{ query, usage });
            return 2;
        }
        field = .{ .key = key, .value = value };
    }

    const roots = common.Roots.resolve(gpa, io) catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer roots.deinit(gpa);

    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, roots.graph_root);
    defer store.deinit();

    const entries = try adapters.bard_cluster.allEntities(gpa, io, store.store());
    defer adapters.bard_cluster.freeSourceEntries(gpa, entries);

    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    var any = false;

    for (entries) |e| {
        const full = try std.fs.path.join(gpa, &.{ roots.repo_root, e.path });
        defer gpa.free(full);
        const src = Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(src);
        // Frontmatter only, matching the extraction contract every other
        // piece of this system holds to -- `src` is the whole real file,
        // prose body included, and searching that would let full-text
        // search leak into content `query`/`field`/`sync` all deliberately
        // never touch.
        const body = adapters.bard_frontmatter.frontmatterBlock(src) orelse continue;

        if (field) |f| {
            const line = adapters.bard_graph_store.fieldLine(body, f.key, f.value) orelse continue;
            try w.interface.print("{s} (1)  {s}\n", .{ e.slug, line });
            any = true;
            continue;
        }

        const count = std.mem.count(u8, body, query);
        if (count == 0) continue;
        const line = adapters.bard_graph_store.firstMatchingLine(body, query) orelse "";
        try w.interface.print("{s} ({d})  {s}\n", .{ e.slug, count, line });
        any = true;
    }

    if (!any) try w.interface.print("no matches for '{s}'\n", .{query});
    try w.interface.flush();
    return 0;
}
