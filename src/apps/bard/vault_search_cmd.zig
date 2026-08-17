//! `synapse-bard vault-search <query>` -- full-text search over `_bard/vault/`
//! (design notes, task notes, decisions), ranked by backlink count via
//! `BardVaultStore.search()`. That capability has existed since
//! `synapse-bard-001` with no command surface pointed at it -- the skill
//! layer read/wrote the vault directly with Read/Write/Edit/Glob/Grep, and
//! Grep has no notion of backlink rank, so a search that should surface the
//! vault's most-referenced note first was doing an unranked substring scan
//! instead. This is that command surface.

const std = @import("std");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: synapse-bard vault-search <query>
    \\
    \\  <query>  full-text substring over _bard/vault/, ranked by each
    \\           matching note's backlink count -- most-linked first, node
    \\           path ascending to break a tie
    \\
;

pub fn run(gpa: Allocator, io: Io, args: *std.process.Args.Iterator) !u8 {
    const query = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    // Help must not need an environment -- checked before Roots.resolve
    // below, which requires being inside a git repo.
    if (std.mem.eql(u8, query, "-h") or std.mem.eql(u8, query, "--help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }
    if (args.next()) |extra| {
        std.debug.print("synapse-bard vault-search: unexpected argument '{s}'\n{s}", .{ extra, usage });
        return 2;
    }

    const roots = common.Roots.resolve(gpa, io) catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer roots.deinit(gpa);

    var store: adapters.bard_vault_store.BardVaultStore = try .init(gpa, roots.vault_root);
    defer store.deinit();

    const hits = try store.store().search(gpa, io, query);
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
