//! Force-inclusion for `common.zig` and `session_start.zig`'s own tests --
//! neither is reachable from `main()`'s body in a test build, since nothing
//! calls `main()` there.

const common = @import("common.zig");
const session_start = @import("session_start.zig");

comptime {
    _ = common;
    _ = session_start;
}
