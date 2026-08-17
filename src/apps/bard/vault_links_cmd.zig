//! `synapse-bard vault-links <note>` -- every note in `_bard/vault/` that
//! links to `<note>`, resolved through `BardVaultStore.linkingNotes()`
//! (wikilink-resolution rules, not string matching: filename stem, `.md`
//! suffix optional, `|alias` handled, no self-backlink). Fills the same gap
//! `query --inbound` fills on the Bible-graph side: `Grep` can string-match
//! `[[note]]` but can't tell an aliased link from a coincidental substring,
//! and has no notion of "which notes" versus "how many".

const std = @import("std");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: synapse-bard vault-links <note>
    \\
    \\  <note>  a vault-relative path, or just its filename stem (the same
    \\          way a [[wikilink]] itself resolves) -- e.g. both
    \\          "designs/synapse-bard/Bible-graph.md" and "Bible-graph"
    \\          find the same note
    \\
;

pub fn run(gpa: Allocator, io: Io, args: *std.process.Args.Iterator) !u8 {
    const note = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    // Help must not need an environment -- checked before Roots.resolve
    // below, which requires being inside a git repo.
    if (std.mem.eql(u8, note, "-h") or std.mem.eql(u8, note, "--help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }
    if (args.next()) |extra| {
        std.debug.print("synapse-bard vault-links: unexpected argument '{s}'\n{s}", .{ extra, usage });
        return 2;
    }

    const roots = common.Roots.resolve(gpa, io) catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer roots.deinit(gpa);

    var store: adapters.bard_vault_store.BardVaultStore = try .init(gpa, roots.vault_root);
    defer store.deinit();

    const linking = (try store.linkingNotes(gpa, io, note)) orelse {
        std.debug.print("{s}: no note by this name in _bard/vault/\n", .{note});
        return 1;
    };
    defer {
        for (linking) |n| gpa.free(n);
        gpa.free(linking);
    }

    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    if (linking.len == 0) {
        try w.interface.print("{s}: no inbound links found\n", .{note});
    }
    for (linking) |n| {
        try w.interface.print("{s} <- {s}\n", .{ note, n });
    }
    try w.interface.flush();
    return 0;
}
