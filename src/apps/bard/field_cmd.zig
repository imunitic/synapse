//! `synapse-bard field <node> <key>` -- one entity's raw frontmatter value
//! for a root-level key, verbatim. The plain fallback for anything `query`
//! can't see: `query` only ever surfaces `[[wikilink]]`-bearing fields
//! (that's the whole extraction contract), so ordinary fields like
//! `images`, `appearance.*`, `voice.*` are otherwise invisible to the CLI
//! entirely.

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
    const key = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    const root = common.graphRoot(gpa, io) catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer gpa.free(root);

    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, root);
    defer store.deinit();
    const port = store.store();

    const node = try std.fmt.allocPrint(gpa, "{s}.md", .{node_arg});
    defer gpa.free(node);

    const body = (try port.read(gpa, io, node)) orelse {
        std.debug.print("{s}: not found\n", .{node_arg});
        return 1;
    };
    defer gpa.free(body);

    const raw = (try adapters.bard_frontmatter.rawField(gpa, body, key)) orelse {
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
