//! Force-inclusion for `common.zig` and `session_start.zig`'s own tests --
//! neither is reachable from `main()`'s body in a test build, since nothing
//! calls `main()` there.

const common = @import("common.zig");
const session_start = @import("session_start.zig");
const stop_nudge = @import("stop_nudge.zig");

comptime {
    _ = common;
    _ = session_start;
    _ = stop_nudge;
}
