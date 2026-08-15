//! Which namespaces a clean may remove, and which it must only report.
//!
//! `synapse-graph-clean` is the only destructive tool in Synapse, which is
//! why it's a command run deliberately rather than a hook -- these are notes
//! in a permanent vault. This file is the inference, separated from the
//! deletion so it's testable without a vault or a repo.
//!
//! Three verdicts:
//! - **remove** -- had an upstream and it's gone. Merged and deleted.
//! - **report** -- absent locally, no upstream confirmable. Covers both a
//!   never-pushed branch deleted by hand and a branch whose config went with
//!   it -- indistinguishable after the fact, so a human decides.
//! - **keep** -- anything else, including work in progress never pushed.
//!
//! `has_remote` is asked of `git remote` directly, not derived from
//! `synapse_remote` (which falls back to the repo root path and is never
//! empty) -- without that, the first run in a remoteless repo would
//! classify every namespace as deleted upstream and wipe the lot.
//!
//! Upstream is read from `branch.<name>.remote`/`branch.<name>.merge` and
//! the remote-tracking ref, not `@{upstream}`: that stops resolving once the
//! ref is pruned, so it can't distinguish "had one, now gone" from "never
//! had one" -- exactly the `remove` vs `report` distinction.

const std = @import("std");

pub const Verdict = union(enum) {
    keep,
    remove: struct { upstream_remote: []const u8, upstream_branch: []const u8 },
    report: Reason,

    pub const Reason = enum {
        /// The namespace's `Index.md` has no `branch:` field.
        no_branch_field,
        /// The branch is gone and the repo has no remote at all.
        gone_no_remote,
        /// The branch is absent locally and had no upstream configured.
        gone_no_upstream,
    };
};

pub const Facts = struct {
    /// From the namespace's own `branch:` field, **never** the directory
    /// name -- that translation isn't reversible (`feature-CORE-1` could be
    /// `feature/CORE-1` or a literal branch name).
    branch: ?[]const u8,
    /// Does this repo have any remote configured?
    has_remote: bool,
    /// Does `refs/heads/<branch>` exist?
    local_exists: bool,
    /// `branch.<name>.remote`, or null when unset.
    upstream_remote: ?[]const u8,
    /// `branch.<name>.merge` with `refs/heads/` stripped, or null when unset.
    upstream_branch: ?[]const u8,
    /// Does `refs/remotes/<upstream_remote>/<upstream_branch>` exist?
    upstream_ref_exists: bool,
};

pub fn classify(f: Facts) Verdict {
    const branch = f.branch orelse return .{ .report = .no_branch_field };
    if (branch.len == 0) return .{ .report = .no_branch_field };

    if (!f.has_remote) {
        if (f.local_exists) return .keep;
        return .{ .report = .gone_no_remote };
    }

    if (f.upstream_remote) |ur| if (f.upstream_branch) |ub| {
        if (ur.len != 0 and ub.len != 0) {
            if (f.upstream_ref_exists) return .keep; // still on the remote: alive
            return .{ .remove = .{ .upstream_remote = ur, .upstream_branch = ub } };
        }
    };

    // No upstream configured: never pushed, or the config went with the
    // branch -- indistinguishable now.
    if (f.local_exists) return .keep;
    return .{ .report = .gone_no_upstream };
}

/// The reason text, byte-identical to what the script printed.
pub fn reasonText(reason: Verdict.Reason, branch: []const u8, w: *std.Io.Writer) !void {
    switch (reason) {
        .no_branch_field => try w.writeAll("no branch field -- cannot tell which branch it describes"),
        .gone_no_remote => try w.print("branch {s} is gone and the repo has no remote", .{branch}),
        .gone_no_upstream => try w.print(
            "branch {s} is absent locally and had no upstream configured",
            .{branch},
        ),
    }
}

const testing = std.testing;

test "a configured upstream that is gone is the case this exists for" {
    const v = classify(.{
        .branch = "feature/x",
        .has_remote = true,
        .local_exists = false,
        .upstream_remote = "origin",
        .upstream_branch = "feature/x",
        .upstream_ref_exists = false,
    });
    try testing.expectEqualStrings("origin", v.remove.upstream_remote);
    try testing.expectEqualStrings("feature/x", v.remove.upstream_branch);
}

test "an upstream still on the remote is kept, even with no local branch" {
    try testing.expectEqual(Verdict.keep, classify(.{
        .branch = "main",
        .has_remote = true,
        .local_exists = false,
        .upstream_remote = "origin",
        .upstream_branch = "main",
        .upstream_ref_exists = true,
    }));
}

test "never pushed and still here is active work" {
    try testing.expectEqual(Verdict.keep, classify(.{
        .branch = "wip",
        .has_remote = true,
        .local_exists = true,
        .upstream_remote = null,
        .upstream_branch = null,
        .upstream_ref_exists = false,
    }));
}

test "never pushed and gone is reported, not removed" {
    const v = classify(.{
        .branch = "wip",
        .has_remote = true,
        .local_exists = false,
        .upstream_remote = null,
        .upstream_branch = null,
        .upstream_ref_exists = false,
    });
    try testing.expectEqual(Verdict.Reason.gone_no_upstream, v.report);
}

test "a remoteless repo falls back to local existence" {
    try testing.expectEqual(Verdict.keep, classify(.{
        .branch = "main",
        .has_remote = false,
        .local_exists = true,
        .upstream_remote = null,
        .upstream_branch = null,
        .upstream_ref_exists = false,
    }));
    const gone = classify(.{
        .branch = "old",
        .has_remote = false,
        .local_exists = false,
        .upstream_remote = null,
        .upstream_branch = null,
        .upstream_ref_exists = false,
    });
    try testing.expectEqual(Verdict.Reason.gone_no_remote, gone.report);
}

test "no branch field cannot be judged at all" {
    const absent = classify(.{
        .branch = null,
        .has_remote = true,
        .local_exists = false,
        .upstream_remote = "origin",
        .upstream_branch = "x",
        .upstream_ref_exists = false,
    });
    try testing.expectEqual(Verdict.Reason.no_branch_field, absent.report);
    const empty = classify(.{
        .branch = "",
        .has_remote = false,
        .local_exists = false,
        .upstream_remote = null,
        .upstream_branch = null,
        .upstream_ref_exists = false,
    });
    try testing.expectEqual(Verdict.Reason.no_branch_field, empty.report);
}

test "a half-configured upstream is treated as none" {
    // remote set, merge missing: a broken config, not a gone upstream --
    // removing on it would delete a namespace on a half-written setting.
    const v = classify(.{
        .branch = "x",
        .has_remote = true,
        .local_exists = false,
        .upstream_remote = "origin",
        .upstream_branch = null,
        .upstream_ref_exists = false,
    });
    try testing.expectEqual(Verdict.Reason.gone_no_upstream, v.report);
}

test "the reason texts are the script's own" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try reasonText(.no_branch_field, "", &out.writer);
    try out.writer.writeAll("\n");
    try reasonText(.gone_no_remote, "old", &out.writer);
    try out.writer.writeAll("\n");
    try reasonText(.gone_no_upstream, "wip", &out.writer);
    try testing.expectEqualStrings(
        "no branch field -- cannot tell which branch it describes\n" ++
            "branch old is gone and the repo has no remote\n" ++
            "branch wip is absent locally and had no upstream configured",
        out.written(),
    );
}
