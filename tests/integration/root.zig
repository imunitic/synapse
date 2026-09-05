//! Aggregates every integration test file so one `zig build test-integration`
//! run covers all of them -- the same transitive test-discovery mechanism
//! `build.zig`'s own per-module unit-test loop already relies on for
//! `core`/`ports`/etc.: `zig test` walks every `@import` reachable from this
//! file's root and picks up every `test` block it finds along the way.

comptime {
    _ = @import("support.zig");
    _ = @import("cli_usage_test.zig");
    _ = @import("pipeline_test.zig");
    _ = @import("write_node_test.zig");
    _ = @import("prompt_context_test.zig");
    _ = @import("staleness_test.zig");
    _ = @import("grounding_test.zig");
    _ = @import("graph_wipe_test.zig");
    _ = @import("callers_test.zig");
    _ = @import("query_test.zig");
    _ = @import("legacy_commands_test.zig");
    _ = @import("tags_lock_test.zig");
    _ = @import("git_store_test.zig");
    _ = @import("rebuild_diff_test.zig");
    _ = @import("rebuild_diff_doc_test.zig");
    _ = @import("diagrams_reference_test.zig");
    _ = @import("cli_reference_test.zig");
}

