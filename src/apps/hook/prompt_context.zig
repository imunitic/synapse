//! `synapse-hook prompt-context` -- UserPromptSubmit.
//!
//! One standing line per turn, in a repo that has a namespace: the graph exists, and
//! here are the tools that read it. No search, no node list, no network.
//! `SYNAPSE_DISABLE_PROMPT_INJECTION` (any value) disables it entirely.
//!
//! ## Why a nudge and not a search
//!
//! This hook used to tokenise the prompt, build a regexp OR-pattern, POST it to the
//! vault's search endpoint and inject the matching nodes. Measured against a real
//! 52-node namespace, "can you explain how BatchRunner dispatches work items"
//! returned **50 of 52 nodes for ~1057 tokens, on every turn**.
//!
//! The cause was not a tunable: `[Ww]ork` matched 50 nodes because it matched the
//! substring inside `framework`, which appears 1392 times across the namespace's
//! `sources`. Word boundaries only brought the union from 50 to 25. One weak term
//! OR'd into a pattern destroys the query, and an ordinary sentence nearly always
//! contains one.
//!
//! What could not be replaced by pulling is the reminder itself: a SessionStart
//! injection ages out once context is compacted, a per-turn line does not.
//!
//! ## Two tools, not one
//!
//! The line names the Graph and the Code Cache separately because they are separate:
//! `callers` reads `_refs.tsv` and answers in a repo where clustering never ran.
//! Collapsing both into "read the graph" cost a real session -- the reader skimmed
//! node titles, saw nothing matching the subject, concluded Synapse did not cover the
//! area, and fell back to grep. Every file was indexed; the titles were simply
//! misleading about ownership. Hence naming the reverse index as the coverage check.
//!
//! Both halves are announced only when actually present -- the node count is counted
//! and the Code Cache line appears only if `_refs.tsv` exists. Naming a capability in
//! the abstract sends the reader to a tool that answers "no reference index".

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
    // An empty prompt exits silently, so a payload field rename degrades to "does
    // nothing" rather than to a wrong injection.
    _ = payload.str("prompt") orelse return;

    // `cwd` comes from the payload -- a SessionStart or a prompt arrives with the
    // session's directory, which is not necessarily this process's.
    const ns = common.Namespace.resolve(gpa, io, env, payload.str("cwd") orelse ".") orelse return;
    defer ns.deinit(gpa);
    const ns_dir = try std.fmt.allocPrint(gpa, "{s}/synapse/{s}", .{ vault, ns.key });
    defer gpa.free(ns_dir);
    const ns_index = try std.fmt.allocPrint(gpa, "{s}/Index.md", .{ns_dir});
    defer gpa.free(ns_index);

    const index_text = Io.Dir.cwd().readFileAlloc(io, ns_index, gpa, .limited(64 << 20)) catch return;
    defer gpa.free(index_text);
    // The remote check every component makes before trusting a namespace: two repos
    // can share a key, and pointing at another project's graph is worse than saying
    // nothing. Branch is not checked here, unlike on the write paths -- this is the
    // check the script made, and widening it would change which repos get a pointer.
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

/// Every `*.md` directly under the namespace except `Index.md` -- the map is not a
/// node.
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
