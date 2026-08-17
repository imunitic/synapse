//! `synapse-bard query <node> [--inbound]` -- an entity's resolved
//! relationships from `_bard/graph/`, both directions. A thin CLI door onto
//! `BardFrontmatterExtractor`/`BardGraphStore` (`synapse-bard-001`), not new
//! extraction or storage logic (`synapse-bard-002`).
//!
//! `synapse-bard-005`: resolves `<node>` through a cluster's `sources:`
//! manifest to the real source file, then extracts *that* -- `_bard/graph/`
//! no longer has one file per entity to read directly.

const std = @import("std");
const core = @import("core");
const model = @import("model");
const ports = @import("ports");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: synapse-bard query <node> [--inbound]
    \\
    \\  <node>       the wikilink slug, without .md (e.g. calla-starweaver)
    \\  --inbound    backlinks -- who references <node> -- instead of outbound refs
    \\
;

pub fn run(gpa: Allocator, io: Io, args: *std.process.Args.Iterator) !u8 {
    const node_arg = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    var inbound = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--inbound")) {
            inbound = true;
        } else {
            std.debug.print("synapse-bard query: unknown option '{s}'\n{s}", .{ a, usage });
            return 2;
        }
    }

    const roots = common.Roots.resolve(gpa, io) catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer roots.deinit(gpa);

    if (inbound) return runInbound(gpa, io, roots, node_arg);
    return runOutbound(gpa, io, roots, node_arg);
}

fn runOutbound(gpa: Allocator, io: Io, roots: common.Roots, node_arg: []const u8) !u8 {
    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, roots.graph_root);
    defer store.deinit();

    const resolved = (try adapters.bard_cluster.resolveSlug(gpa, io, &store, node_arg)) orelse {
        std.debug.print("{s}: not found\n", .{node_arg});
        return 1;
    };
    defer {
        gpa.free(resolved.slug);
        gpa.free(resolved.path);
    }

    var ex: adapters.bard_frontmatter.BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, io, roots.repo_root, &.{resolved.path});
    defer common.freeOutcomes(gpa, out);

    switch (out[0]) {
        .unsupported => {
            std.debug.print("{s}: unsupported ({t})\n", .{ node_arg, ex.last_refusals[0] orelse .not_a_note });
            return 1;
        },
        .tags => |tags| {
            var buf: [4096]u8 = undefined;
            var w = Io.File.stdout().writer(io, &buf);
            for (tags) |t| if (t.role == .def) {
                try w.interface.print("{s} ({s})\n", .{ t.name, t.kind });
            };
            for (tags) |t| if (t.role == .ref) {
                try w.interface.print("  {s} -> {s}\n", .{ t.kind, t.name });
            };
            try w.interface.flush();
            return 0;
        },
    }
}

fn runInbound(gpa: Allocator, io: Io, roots: common.Roots, node_slug: []const u8) !u8 {
    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, roots.graph_root);
    defer store.deinit();

    // Backlinks require looking at every entity's outbound refs, so this
    // resolves the whole graph rather than one slug -- same data
    // `search`'s new implementation needs, for the same reason.
    const entries = try adapters.bard_cluster.allEntities(gpa, io, &store);
    defer adapters.bard_cluster.freeSourceEntries(gpa, entries);

    var target_found = false;
    for (entries) |e| if (std.mem.eql(u8, e.slug, node_slug)) {
        target_found = true;
        break;
    };
    if (!target_found) {
        std.debug.print("{s}: not found\n", .{node_slug});
        return 1;
    }

    const paths = try gpa.alloc([]const u8, entries.len);
    defer gpa.free(paths);
    for (entries, 0..) |e, i| paths[i] = e.path;

    var ex: adapters.bard_frontmatter.BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, io, roots.repo_root, paths);
    defer common.freeOutcomes(gpa, out);

    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    var found = false;
    for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.slug, node_slug)) continue; // no self-backlink
        const tags = switch (out[i]) {
            .unsupported => continue,
            .tags => |t| t,
        };
        for (tags) |t| {
            if (t.role != .ref) continue;
            if (!std.mem.eql(u8, common.stripMdSuffix(t.name), node_slug)) continue;
            try w.interface.print("{s} <- {s} ({s})\n", .{ node_slug, e.slug, t.kind });
            found = true;
        }
    }
    if (!found) try w.interface.print("{s}: no inbound references found\n", .{node_slug});
    try w.interface.flush();
    return 0;
}
