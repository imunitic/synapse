//! `synapse-fake`: the `synapse` binary with the grammar backend stubbed out.
//!
//! Built by `zig build fake`, never installed, and the binary
//! `tests/*.bats` actually runs. It exists because the bats suite is the CLI
//! specification and has to run without a network, a C toolchain or a real
//! grammar repository -- which is what `tests/fixtures/fake-bin/tree-sitter`
//! used to provide, until linking libtree-sitter left nothing on PATH to
//! intercept.
//!
//! It is deliberately this thin. Argument parsing, registry resolution, exit
//! codes, output shape, warnings, clone-on-first-use and its lock are all the
//! same code the real binary runs; see `fake_grammar.zig` for the one step
//! that differs and `extractor.zig` for why the seam sits there.
//!
//! What that leaves uncovered by bats, stated plainly rather than left to be
//! discovered: compiling a cloned grammar, loading it, and running its
//! `tags.scm`. Those are covered by the Zig unit tests and by
//! `ci/differential-tags.sh`, which checks the real tagger against the
//! `tree-sitter` CLI over real repositories -- a check bats could not perform
//! anyway.

const std = @import("std");
const tags_cmd = @import("tags.zig");
const tags_cache_cmd = @import("tags_cache_cmd.zig");
const index_cmd = @import("index_cmd.zig");
const enumerate_cmd = @import("enumerate_cmd.zig");
const fake = @import("fake_grammar.zig");

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.next(); // argv[0]

    const sub = args.next() orelse return 2;
    const trace = init.environ_map.get("FAKE_TS_LOG");

    if (std.mem.eql(u8, sub, "tags"))
        return tags_cmd.run(fake.FakeExtractor, init.gpa, init.io, init.environ_map, &args, trace);

    if (std.mem.eql(u8, sub, "tags-cache"))
        return tags_cache_cmd.run(fake.FakeExtractor, init.gpa, init.io, init.environ_map, &args, trace);

    // Not stubbed at all, and it needs no `fake` counterpart: the index is a
    // projection of lists the clustering already produced, so nothing about it
    // touches a grammar. This is the same code the real binary runs.
    if (std.mem.eql(u8, sub, "index"))
        return index_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "enumerate"))
        return enumerate_cmd.run(init.gpa, init.io, init.environ_map, &args);

    std.debug.print("synapse-fake: unknown subcommand '{s}'\n", .{sub});
    return 2;
}
