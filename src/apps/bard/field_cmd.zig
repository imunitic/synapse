//! `synapse-bard field <node> <key>` -- one entity's raw frontmatter value
//! for a root-level key, verbatim. The plain fallback for anything `query`
//! can't see: `query` only ever surfaces `[[wikilink]]`-bearing fields
//! (that's the whole extraction contract), so ordinary fields like
//! `images`, `appearance.*`, `voice.*` are otherwise invisible to the CLI
//! entirely.
//!
//! `synapse-bard-005`: resolves `<node>` through a cluster's `sources:`
//! manifest to the real source file, then reads *that* -- `_bard/graph/`
//! no longer has one file per entity to read directly.

const std = @import("std");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: synapse-bard field <node> <key>
    \\
    \\  <node>    the wikilink slug, without .md (e.g. aidan-dayne)
    \\  <key>     a root-level frontmatter key (e.g. images) -- no dotted
    \\            nested paths
    \\
;

pub fn run(gpa: Allocator, io: Io, args: *std.process.Args.Iterator) !u8 {
    const node_arg = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    // Help must not need an environment.
    if (std.mem.eql(u8, node_arg, "-h") or std.mem.eql(u8, node_arg, "--help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }
    const key = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    const roots = common.Roots.resolve(gpa, io) catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer roots.deinit(gpa);

    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, roots.graph_root);
    defer store.deinit();

    const resolved = (try adapters.bard_cluster.resolveSlug(gpa, io, store.store(), node_arg)) orelse {
        std.debug.print("{s}: not found\n", .{node_arg});
        return 1;
    };
    defer {
        gpa.free(resolved.slug);
        gpa.free(resolved.path);
    }

    const full = try std.fs.path.join(gpa, &.{ roots.repo_root, resolved.path });
    defer gpa.free(full);
    const src = Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(1 << 20)) catch {
        std.debug.print("{s}: source file unreadable ({s})\n", .{ node_arg, resolved.path });
        return 1;
    };
    defer gpa.free(src);

    const raw = (try adapters.bard_frontmatter.rawField(gpa, src, key)) orelse {
        std.debug.print("{s}: no root-level field '{s}'\n", .{ node_arg, key });
        return 1;
    };
    defer gpa.free(raw);

    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(raw);
    try w.interface.flush();
    return 0;
}
