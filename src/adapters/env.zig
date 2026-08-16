//! Bridges `std.process.Environ.Map` to `core.conf.Vars`.
//!
//! `core` may not name `std.process` directly (`ci/check-layering.sh`), so
//! every conf-reading call site needs some `Vars` over the real process
//! environment. This is that bridge, shared instead of hand-rolled per
//! `apps/synapse/*_cmd.zig` file.

const std = @import("std");
const core = @import("core");

pub fn vars(env: *std.process.Environ.Map) core.conf.Vars {
    return .{ .ctx = @ptrCast(env), .getFn = lookup };
}

fn lookup(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const e: *std.process.Environ.Map = @ptrCast(@alignCast(ctx));
    return e.get(name);
}
