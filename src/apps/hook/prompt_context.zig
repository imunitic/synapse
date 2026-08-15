//! `synapse-hook prompt-context` -- UserPromptSubmit.
//!
//! One standing line per turn, in a repo with a namespace: the graph
//! exists, here are the tools that read it. No search, no node list, no
//! network. `SYNAPSE_DISABLE_PROMPT_INJECTION` (any value) disables it.
//!
//! Used to tokenize the prompt into a regexp OR-pattern and search the
//! vault instead: on a real 52-node namespace, "can you explain how
//! BatchRunner dispatches work items" returned 50 of 52 nodes for ~1057
//! tokens, every turn -- `[Ww]ork` matched the substring inside
//! `framework` (1392 occurrences), and one weak term OR'd in destroys the
//! query. A per-turn nudge also survives context compaction, unlike a
//! SessionStart injection.
//!
//! Names the Graph and the Code Cache separately, not "read the graph":
//! collapsing them once cost a real session where the reader skimmed node
//! titles, saw nothing matching, and fell back to grep even though every
//! file was indexed. Each half is announced only when actually present.

const std = @import("std");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    if (env.get("SYNAPSE_DISABLE_PROMPT_INJECTION") != null) return;
    const vault = common.vault(gpa, io, env) orelse return;
    defer gpa.free(vault);

    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();
    _ = payload.str("prompt") orelse return; // an empty prompt exits silently

    const ns = common.Namespace.resolve(gpa, io, env, payload.str("cwd") orelse ".") orelse return;
    defer ns.deinit(gpa);
    const ns_dir = try std.fmt.allocPrint(gpa, "{s}/synapse/{s}", .{ vault, ns.key });
    defer gpa.free(ns_dir);
    const ns_index = try std.fmt.allocPrint(gpa, "{s}/Index.md", .{ns_dir});
    defer gpa.free(ns_index);

    const index_text = Io.Dir.cwd().readFileAlloc(io, ns_index, gpa, .limited(64 << 20)) catch return;
    defer gpa.free(index_text);
    // Remote check, not branch (unlike the write paths): two repos can
    // share a key, and pointing at another project's graph is worse than silence.
    const remote = @import("core").query.field(index_text, "remote") orelse return;
    if (remote.len == 0 or !std.mem.eql(u8, remote, ns.remote)) return;

    const nodes = try countNodes(io, ns_dir);
    if (nodes == 0) return;

    const refs = try std.fmt.allocPrint(gpa, "{s}/_refs.tsv", .{common.workDir(env) orelse ""});
    defer gpa.free(refs);
    const have_cache = blk: {
        if (common.workDir(env) == null) break :blk false;
        _ = Io.Dir.cwd().statFile(io, refs, .{}) catch break :blk false;
        break :blk true;
    };

    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try text.writer.print(
        "Synapse: this repo has a code graph at synapse/{s}/ ({d} nodes). If this turn needs to know how the codebase works, consult Synapse before grepping or opening files -- `synapse query` (body/sources/field/links), `synapse index lookup <path>` for the owning node (authoritative coverage: never infer from titles).",
        .{ ns.key, nodes },
    );
    if (have_cache) try text.writer.writeAll(
        " Separately, and independent of the graph, a Code Cache indexes exact names: `synapse callers <name>` gives repo-wide call sites (no graph needed), `synapse query symbol <name> <node>` scopes that lookup to one node. Prefer either over grep for \"where is X defined/used\"; their line numbers come from the index and can lag the working tree, so re-check a range before relying on it.",
    );
    try text.writer.writeAll(" The synapse-query and synapse-node skills have the procedure.");

    try common.emitContext(gpa, io, "UserPromptSubmit", text.written());
}

/// Every `*.md` directly under the namespace except `Index.md`.
fn countNodes(io: Io, ns_dir: []const u8) !usize {
    var dir = Io.Dir.cwd().openDir(io, ns_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (std.mem.eql(u8, entry.name, "Index.md")) continue;
        n += 1;
    }
    return n;
}
