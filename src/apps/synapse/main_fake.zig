//! `synapse-fake`: the `synapse` binary with the grammar backend stubbed out.
//! Built by `zig build fake`; the binary the integration suite mostly runs,
//! since it must work with no network, C toolchain or real grammar repo.
//!
//! Thin by design: everything but the one stubbed step (`fake_grammar.zig`)
//! is the same code the real binary runs -- including the subcommand table
//! itself, shared with `main.zig` via `dispatch.zig`. Compiling/loading a
//! grammar and running its `tags.scm` stay uncovered by this suite -- see
//! the Zig unit tests and `ci/differential-tags.sh` instead.

const std = @import("std");
const dispatch = @import("dispatch.zig");
const usage = @import("usage.zig").text;
const fake = @import("fake_grammar.zig");

const table = dispatch.Table(fake.FakeExtractor).entries;

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    const argv0 = args.next() orelse ""; // this binary's own invoked path -- vault-write/vault-patch thread it to GitStore's own Pusher spawn

    const sub = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    // Same listing the real binary prints; docs are generated from this.
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }

    const trace = init.environ_map.get("FAKE_TS_LOG");
    if (dispatch.run(&table, init.gpa, init.io, init.environ_map, &args, argv0, sub, trace)) |result|
        return result;

    std.debug.print("synapse-fake: unknown subcommand '{s}'\n{s}", .{ sub, usage });
    return 2;
}
