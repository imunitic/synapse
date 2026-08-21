//! Force-inclusion for `common.zig` and every hook module's own tests --
//! none of these are reachable from `main()`'s body in a test build, since
//! nothing calls `main()` there.

const common = @import("common.zig");
const staleness = @import("staleness.zig");
const prompt_context = @import("prompt_context.zig");
const session_start = @import("session_start.zig");
const stop_nudge = @import("stop_nudge.zig");
const db_sync = @import("db_sync.zig");

comptime {
    _ = common;
    _ = staleness;
    _ = prompt_context;
    _ = session_start;
    _ = stop_nudge;
    _ = db_sync;
}
