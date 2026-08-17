//! `synapse-bard` -- the Bible-graph and Writer's notes vault binary for a
//! YAML-templated fiction bible. Imports `model`/`ports`/`core`/`adapters`,
//! never `treesitter`: this binary parses YAML frontmatter only, so it links
//! no libtree-sitter and needs no C compiler. See the compiled task notes
//! `synapse-bard-001` through `synapse-bard-005` and their design notes for
//! the full contract.
//!
//!   synapse-bard sync                          populate _bard/graph/ from source
//!   synapse-bard query <node> [--inbound]      resolved relationships
//!   synapse-bard field <node> <key>            one raw frontmatter field
//!   synapse-bard fields <node>                 a template's own field names
//!   synapse-bard fields --template <name>      same, by template name directly
//!   synapse-bard search <query>                full-text
//!   synapse-bard search --field <key>:<value>  structured filter
//!
//! `_bard/graph/` holds one node per *cluster* (a source folder), not one
//! per entity (`synapse-bard-005`) -- `sync` groups entities by folder,
//! `query`/`field`/`search` resolve a slug through a cluster's `sources:`
//! manifest to the real source file rather than reading a per-entity node
//! directly. See `src/adapters/bard/cluster.zig`.
//!
//! No `_bard/vault/` subcommands yet -- the skill layer (`synapse-bard-001`
//! step 7) reads/writes it directly with Read/Write/Edit/Glob/Grep, and
//! nothing has needed a CLI door onto it the way the graph side did.

const std = @import("std");
const sync_cmd = @import("sync_cmd.zig");
const query_cmd = @import("query_cmd.zig");
const field_cmd = @import("field_cmd.zig");
const fields_cmd = @import("fields_cmd.zig");
const search_cmd = @import("search_cmd.zig");

const usage =
    \\usage: synapse-bard <command>
    \\
    \\  sync                          populate _bard/graph/ from the bible's
    \\                                source tree (always a full re-ingest)
    \\  query <node> [--inbound]      resolved relationships (outbound by
    \\                                default, --inbound for backlinks)
    \\  field <node> <key>            one raw frontmatter field, verbatim
    \\  fields <node>                 a template's own field names, so you
    \\                                know which `field` calls are worth
    \\                                making instead of guessing
    \\  fields --template <name>      same, by template name directly
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

    if (std.mem.eql(u8, which, "sync")) {
        return sync_cmd.run(gpa, io, &args);
    } else if (std.mem.eql(u8, which, "query")) {
        return query_cmd.run(gpa, io, &args);
    } else if (std.mem.eql(u8, which, "field")) {
        return field_cmd.run(gpa, io, &args);
    } else if (std.mem.eql(u8, which, "fields")) {
        return fields_cmd.run(gpa, io, &args);
    } else if (std.mem.eql(u8, which, "search")) {
        return search_cmd.run(gpa, io, &args);
    } else {
        std.debug.print("synapse-bard: unknown command '{s}'\n{s}", .{ which, usage });
        return 2;
    }
}
