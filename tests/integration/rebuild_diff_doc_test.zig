//! The branch-identity check quoted verbatim in `/synapse-rebuild-diff`'s
//! own Prerequisites section, extracted from the shipped doc text itself
//! and actually run against a real repo -- not a hand-copied mirror of it,
//! since a hand-copy can drift from the doc silently. `/synapse-rebuild-diff`
//! is prose, not a script, so there is no binary to spawn; what's testable
//! is the shell snippet the doc tells a reader to run.

const std = @import("std");
const adapters = @import("adapters");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;
const gpa = testing.allocator;

/// The fenced ```sh block under "Branch-identity check" in the shipped
/// command doc. Caller frees.
fn extractSnippet(doc: []const u8) ![]const u8 {
    const anchor = std.mem.indexOf(u8, doc, "Branch-identity check") orelse return error.SnippetNotFound;
    const fence_start = std.mem.indexOfPos(u8, doc, anchor, "```sh") orelse return error.SnippetNotFound;
    const body_start = 1 + (std.mem.indexOfScalarPos(u8, doc, fence_start, '\n') orelse return error.SnippetNotFound);
    const fence_end = std.mem.indexOfPos(u8, doc, body_start, "```") orelse return error.SnippetNotFound;
    return doc[body_start..fence_end];
}

/// Runs the doc's own branch-identity snippet against `ns_dir/Index.md`,
/// appending the comparison the doc's prose describes but does not fence as
/// code (`if they don't match, refuse`). Real `git symbolic-ref`, real file
/// read -- exactly what a reader following the doc would run.
fn branchIdentityCheck(fx: *Fixture, ns_dir: []const u8) !bool {
    const doc = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "packages/synapse/commands/synapse-rebuild-diff.md", gpa, .limited(1 << 20));
    defer gpa.free(doc);
    const snippet = try extractSnippet(doc);

    const placeholder = "\"synapse/{repo}@{branch}/Index.md\"";
    const index_path = try std.fmt.allocPrint(gpa, "\"{s}/Index.md\"", .{ns_dir});
    defer gpa.free(index_path);
    const at = std.mem.indexOf(u8, snippet, placeholder) orelse return error.PlaceholderNotFound;
    const script = try std.fmt.allocPrint(gpa, "{s}{s}{s}\n[ \"$current_branch\" = \"$ns_branch\" ]\n", .{
        snippet[0..at], index_path, snippet[at + placeholder.len ..],
    });
    defer gpa.free(script);

    const r = try adapters.process.run(fx.io(), fx.gpa, &.{ "sh", "-c", script }, .{ .cwd = .{ .path = fx.repo } });
    defer r.deinit(gpa);
    return r.ok();
}

test "branch-identity check passes when the namespace describes the current checkout's branch" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.makeRepo(null);
    const ns = try fx.repoName();
    defer gpa.free(ns);
    const remote = try fx.repoRemoteOrPath();
    defer gpa.free(remote);
    try fx.writeSynapseIndex(ns, remote);

    const ns_dir = try std.fmt.allocPrint(gpa, "{s}/vault/synapse/{s}", .{ fx.root, ns });
    defer gpa.free(ns_dir);
    try testing.expect(try branchIdentityCheck(&fx, ns_dir));
}

test "branch-identity check fails when the namespace describes a different branch" {
    // A namespace that legitimately exists (built on another branch, or
    // copied by hand) but does not describe the branch currently checked
    // out. Two namespaces existing is exactly the case that invites the
    // mistake -- the check must catch it regardless of whether the
    // mismatched namespace is otherwise well-formed.
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.makeRepo(null);
    const repo_ns = try fx.nsRepo();
    defer gpa.free(repo_ns);
    const remote = try fx.repoRemoteOrPath();
    defer gpa.free(remote);

    const ns = try std.fmt.allocPrint(gpa, "{s}@other-branch", .{repo_ns});
    defer gpa.free(ns);
    const ns_dir = try std.fmt.allocPrint(gpa, "{s}/vault/synapse/{s}", .{ fx.root, ns });
    defer gpa.free(ns_dir);
    const ns_rel = try std.fmt.allocPrint(gpa, "vault/synapse/{s}", .{ns});
    defer gpa.free(ns_rel);
    try fx.dir.createDirPath(std.testing.io, ns_rel);
    const index_body = try std.fmt.allocPrint(gpa,
        \\---
        \\title: "{s} — Synapse index"
        \\node_type: synapse-index
        \\project: {s}
        \\branch: other-branch
        \\remote: "{s}"
        \\built_at: "test"
        \\---
        \\# {s}
        \\
    , .{ ns, repo_ns, remote, ns });
    defer gpa.free(index_body);
    const index_rel = try std.fmt.allocPrint(gpa, "vault/synapse/{s}/Index.md", .{ns});
    defer gpa.free(index_rel);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = index_rel, .data = index_body });

    try testing.expect(!try branchIdentityCheck(&fx, ns_dir));
}

test "branch-identity check fails after a rename -- the directory key alone is not enough" {
    // Same trap `graph_cmd.zig`'s own native tests document for its branch
    // field: the directory name is sanitized and not reversible, so only
    // the field can answer. Here the namespace's own field still says the
    // old branch after HEAD moved.
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.makeRepo(null);
    (try fx.git(&.{ "checkout", "-q", "-b", "feature-a" })).deinit(gpa);
    const ns = try fx.repoName();
    defer gpa.free(ns);
    const remote = try fx.repoRemoteOrPath();
    defer gpa.free(remote);
    try fx.writeSynapseIndex(ns, remote);
    const ns_dir = try std.fmt.allocPrint(gpa, "{s}/vault/synapse/{s}", .{ fx.root, ns });
    defer gpa.free(ns_dir);

    (try fx.git(&.{ "checkout", "-q", "-b", "feature-b" })).deinit(gpa);

    try testing.expect(!try branchIdentityCheck(&fx, ns_dir));
}
