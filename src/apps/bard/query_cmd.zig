//! `synapse-bard query <node> [--inbound]` -- an entity's resolved
//! relationships from `_bard/graph/`, both directions. A thin CLI door onto
//! `BardFrontmatterExtractor`/`BardGraphStore` (`synapse-bard-001`), not new
//! extraction or storage logic (`synapse-bard-002`).

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

    const root = common.graphRoot(gpa, io) catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer gpa.free(root);

    if (inbound) return runInbound(gpa, io, root, node_arg);
    return runOutbound(gpa, io, root, node_arg);
}

fn runOutbound(gpa: Allocator, io: Io, root: []const u8, node_arg: []const u8) !u8 {
    const node = try std.fmt.allocPrint(gpa, "{s}.md", .{node_arg});
    defer gpa.free(node);

    var ex: adapters.bard_frontmatter.BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, io, root, &.{node});
    defer common.freeOutcomes(gpa, out);

    switch (out[0]) {
        .unsupported => {
            std.debug.print("{s}: not found or unsupported ({t})\n", .{ node_arg, ex.last_refusals[0] orelse .not_a_note });
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

fn runInbound(gpa: Allocator, io: Io, root: []const u8, node_slug: []const u8) !u8 {
    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, root);
    defer store.deinit();
    const port = store.store();

    const node = try std.fmt.allocPrint(gpa, "{s}.md", .{node_slug});
    defer gpa.free(node);
    if (try port.read(gpa, io, node)) |body| {
        gpa.free(body);
    } else {
        std.debug.print("{s}: not found\n", .{node_slug});
        return 1;
    }

    const names = try port.list(gpa, io);
    defer common.freeNames(gpa, names);

    var ex: adapters.bard_frontmatter.BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, io, root, names);
    defer common.freeOutcomes(gpa, out);

    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    var found = false;
    for (names, 0..) |from_name, i| {
        if (std.mem.eql(u8, from_name, node)) continue; // no self-backlink
        const tags = switch (out[i]) {
            .unsupported => continue,
            .tags => |t| t,
        };
        for (tags) |t| {
            if (t.role != .ref) continue;
            if (!std.mem.eql(u8, common.stripMdSuffix(t.name), node_slug)) continue;
            const from_slug = common.stripMdSuffix(from_name);
            try w.interface.print("{s} <- {s} ({s})\n", .{ node_slug, from_slug, t.kind });
            found = true;
        }
    }
    if (!found) try w.interface.print("{s}: no inbound references found\n", .{node_slug});
    try w.interface.flush();
    return 0;
}
