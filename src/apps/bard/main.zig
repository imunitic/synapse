//! `synapse-bard` -- the Bible-graph and Writer's notes vault binary for a
//! YAML-templated fiction bible. Imports `model`/`ports`/`core`/`adapters`,
//! never `treesitter`: this binary parses YAML frontmatter only, so it links
//! no libtree-sitter and needs no C compiler. See the compiled task notes
//! `synapse-bard-001`/`synapse-bard-002` and their design notes for the full
//! contract.
//!
//!   synapse-bard query <node> [--inbound]      resolved relationships
//!   synapse-bard field <node> <key>            one raw frontmatter field
//!   synapse-bard search <query>                full-text
//!   synapse-bard search --field <key>:<value>  structured filter
//!
//! No `_bard/vault/` subcommands yet -- the skill layer (`synapse-bard-001`
//! step 7) reads/writes it directly with Read/Write/Edit/Glob/Grep, and
//! nothing has needed a CLI door onto it the way the graph side did.

const std = @import("std");
const query_cmd = @import("query_cmd.zig");
const field_cmd = @import("field_cmd.zig");
const search_cmd = @import("search_cmd.zig");

const usage =
    \\usage: synapse-bard <command>
    \\
    \\  query <node> [--inbound]      resolved relationships (outbound by
    \\                                default, --inbound for backlinks)
    \\  field <node> <key>            one raw frontmatter field, verbatim
    \\  search <query>                full-text
    \\  search --field <key>:<value>  structured filter across the graph
    \\
;

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.next(); // this binary's own invoked path

    const which = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    if (std.mem.eql(u8, which, "-h") or std.mem.eql(u8, which, "--help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }

    const gpa = init.gpa;
    const io = init.io;

    if (std.mem.eql(u8, which, "query")) {
        return query_cmd.run(gpa, io, &args);
    } else if (std.mem.eql(u8, which, "field")) {
        return field_cmd.run(gpa, io, &args);
    } else if (std.mem.eql(u8, which, "search")) {
        return search_cmd.run(gpa, io, &args);
    } else {
        std.debug.print("synapse-bard: unknown command '{s}'\n{s}", .{ which, usage });
        return 2;
    }
}
