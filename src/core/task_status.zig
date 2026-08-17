//! The task-note `status:` transition rule, as one tested source of truth
//! instead of a table repeated in two skills' own prose (`synapse-task` for
//! code tasks, `synapse-bard-task-note` for fiction ones) with no guarantee
//! they stay in agreement.
//!
//! Pure, like the rest of `core`: takes checklist counts, not a vault path
//! or raw file body -- parsing a task note out of a `Store` is a caller
//! concern, same split `links.zig` keeps between "compute the edges" and
//! "go fetch `_refs.tsv`."

const std = @import("std");

pub const Status = enum {
    TODO,
    @"IN-PROGRESS",
    REVIEW,
    DONE,
    CANCELED,
    CANCELLED,
};

pub const ChecklistCount = struct {
    total: usize = 0,
    checked: usize = 0,

    /// `synapse-task`'s own guardrail: "if checklist content is ambiguous
    /// or missing, default to IN-PROGRESS." A task note with zero checklist
    /// items is exactly that case -- `checked < total` alone would read
    /// `0 < 0` as false and misreport it as REVIEW, which is backwards: no
    /// checklist means nothing has been verified done, not that everything
    /// has.
    pub fn anyUnchecked(self: ChecklistCount) bool {
        if (self.total == 0) return true;
        return self.checked < self.total;
    }
};

/// `- [ ]` / `- [x]` (case-insensitive `x`) lines in `body`, leading
/// whitespace tolerated so a nested continuation item still counts. Any
/// other dash bullet (`- plain text`, `- \`module\` (3)`) is not a
/// checklist line and isn't counted -- same distinction `core/query.zig`'s
/// own `parseEdge` draws between a `## Links` edge and a `## Sources` row.
pub fn countChecklist(body: []const u8) ChecklistCount {
    var count: ChecklistCount = .{};
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "- [")) continue;
        const rest = trimmed["- [".len..];
        if (rest.len < 2 or rest[1] != ']') continue;
        const mark = rest[0];
        if (mark != ' ' and mark != 'x' and mark != 'X') continue;
        count.total += 1;
        if (mark != ' ') count.checked += 1;
    }
    return count;
}

/// The `status:` this workflow computes from checklist completion --
/// `synapse-task`'s own table: any unchecked (or ambiguous/missing) ->
/// IN-PROGRESS, all checked -> REVIEW. Never DONE: see `isAutomaticTarget`.
pub fn nextStatus(count: ChecklistCount) Status {
    return if (count.anyUnchecked()) .@"IN-PROGRESS" else .REVIEW;
}

/// Whether `to` is a status this automatic workflow may ever write.
/// DONE/CANCELED/CANCELLED are real states a task reaches, but only a
/// human sets them deliberately -- both skills' own guardrail ("never
/// write DONE through this workflow") as code a caller can check and
/// refuse against, not just prose an agent has to remember.
pub fn isAutomaticTarget(to: Status) bool {
    return switch (to) {
        .@"IN-PROGRESS", .REVIEW => true,
        .TODO, .DONE, .CANCELED, .CANCELLED => false,
    };
}

const testing = std.testing;

test "any unchecked item means IN-PROGRESS" {
    try testing.expectEqual(Status.@"IN-PROGRESS", nextStatus(.{ .total = 3, .checked = 1 }));
}

test "every item checked means REVIEW" {
    try testing.expectEqual(Status.REVIEW, nextStatus(.{ .total = 3, .checked = 3 }));
}

test "no checklist items at all is ambiguous, defaults to IN-PROGRESS, not REVIEW" {
    try testing.expectEqual(Status.@"IN-PROGRESS", nextStatus(.{ .total = 0, .checked = 0 }));
}

test "countChecklist counts checked and unchecked, case-insensitive x" {
    const body =
        \\# A task
        \\
        \\- [ ] Step one
        \\- [x] Step two
        \\- [X] Step three
        \\
    ;
    const c = countChecklist(body);
    try testing.expectEqual(@as(usize, 3), c.total);
    try testing.expectEqual(@as(usize, 2), c.checked);
}

test "countChecklist ignores plain dash bullets and Sources-style rows" {
    const body =
        \\## Sources
        \\- `core/foo.zig` (3)
        \\
        \\## Links
        \\- part_of [[Parent]]
        \\
    ;
    const c = countChecklist(body);
    try testing.expectEqual(@as(usize, 0), c.total);
}

test "countChecklist tolerates leading whitespace on a nested item" {
    const body =
        \\- [ ] Outer step
        \\  - [x] Nested detail
        \\
    ;
    const c = countChecklist(body);
    try testing.expectEqual(@as(usize, 2), c.total);
    try testing.expectEqual(@as(usize, 1), c.checked);
}

test "isAutomaticTarget: only IN-PROGRESS and REVIEW are reachable through this workflow" {
    try testing.expect(isAutomaticTarget(.@"IN-PROGRESS"));
    try testing.expect(isAutomaticTarget(.REVIEW));
    try testing.expect(!isAutomaticTarget(.TODO));
    try testing.expect(!isAutomaticTarget(.DONE));
    try testing.expect(!isAutomaticTarget(.CANCELED));
    try testing.expect(!isAutomaticTarget(.CANCELLED));
}
