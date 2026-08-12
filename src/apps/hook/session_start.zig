//! `synapse-hook session-start` -- SessionStart.
//!
//! Injects the vault's own `Index.md` so a session starts with the map already in
//! context instead of relying on the agent to think to go read it, and does the
//! Synapse pointer check.
//!
//! ## Everything here is a path lookup, never a model call or an HTTP round trip
//!
//! That is what keeps it zero-cost for every repo that never ran `/synapse-init`.
//! Three pieces, in the order they are assembled:
//!
//! 1. **the vault index**, read whole and injected;
//! 2. **the pointer** for this repo's namespace -- verified against the recorded
//!    remote, or an explicit "no namespace covers this" line;
//! 3. **the catalogue** of the *other* namespaces, so a session that later `cd`s into
//!    a different repo knows that repo's graph exists at all. Without it only the
//!    starting repo is ever announced, and one session routinely spans several.
//!
//! The catalogue is built here and stored nowhere: the source of truth is the
//! directory listing plus each namespace index's `remote:` field, so there is nothing
//! to invalidate and it cannot drift. That also keeps this hook read-only against the
//! vault -- only `staleness` writes.
//!
//! ## A mismatched remote is reported, never repaired
//!
//! Two causes, indistinguishable from here: a different repo sharing this basename, or
//! this repo's remote having been changed deliberately -- including by a
//! `url.<base>.insteadOf` rule appearing in git config, which rewrites what `remote
//! get-url` reports without the repo itself changing. Nothing tries to tell them apart
//! or to migrate the namespace: rewriting the recorded remote to match would erase the
//! only provenance signal there is. Both remedies belong to the person who made the
//! change, so both are named.

const std = @import("std");
const core = @import("core");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const label = "Synapse Vault index";

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const vault = env.get("OBSIDIAN_VAULT_DIR") orelse "";
    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();

    var synapse_line: ?[]u8 = null;
    defer if (synapse_line) |s| gpa.free(s);
    var absent: ?[]u8 = null;
    defer if (absent) |s| gpa.free(s);
    var catalogue: ?[]u8 = null;
    defer if (catalogue) |s| gpa.free(s);

    if (vault.len != 0) {
        if (common.Namespace.fromEnv(env)) |ns| {
            const ns_index = try std.fmt.allocPrint(gpa, "{s}/synapse/{s}/Index.md", .{ vault, ns.key });
            defer gpa.free(ns_index);
            if (Io.Dir.cwd().readFileAlloc(io, ns_index, gpa, .limited(64 << 20))) |text| {
                defer gpa.free(text);
                const existing = core.query.field(text, "remote") orelse "";
                if (std.mem.eql(u8, existing, ns.remote)) {
                    synapse_line = try std.fmt.allocPrint(
                        gpa,
                        "Synapse namespace for this repo and branch: synapse/{s}/Index.md -- consult it for existing code-graph nodes before re-exploring from scratch.",
                        .{ns.key},
                    );
                } else {
                    synapse_line = try std.fmt.allocPrint(
                        gpa,
                        "Synapse namespace synapse/{s}/ exists but its remote (\"{s}\") doesn't match this repo's (\"{s}\") -- either a different repo sharing this name, or this repo's remote changed. Skipping the pointer rather than risk cross-project contamination. If the remote changed deliberately, rebuild the namespace with /synapse-rebuild-full.",
                        .{ ns.key, existing, ns.remote },
                    );
                }
            } else |_| {
                // Said, not implied by silence. A namespace covers one branch, so
                // being on a branch without one is ordinary and expected -- but "no
                // namespace" and "a namespace that found nothing" used to be
                // indistinguishable, which is the conflation per-branch keying exists
                // to remove.
                absent = try std.fmt.allocPrint(gpa, "synapse/{s}/", .{ns.key});
            }
        }
        catalogue = try buildCatalogue(gpa, io, vault, if (common.Namespace.fromEnv(env)) |n| n.key else null);
    }

    var base: ?[]u8 = null;
    defer if (base) |b| gpa.free(b);
    if (vault.len != 0) {
        const index_path = try std.fmt.allocPrint(gpa, "{s}/Index.md", .{vault});
        defer gpa.free(index_path);
        if (Io.Dir.cwd().readFileAlloc(io, index_path, gpa, .limited(64 << 20))) |content| {
            defer gpa.free(content);
            base = try std.fmt.allocPrint(
                gpa,
                "{s} ({s}) — read before creating or linking any note; prefer linking to an existing note over duplicating content, and fall back to linking this index if nothing more specific applies:\n\n{s}",
                .{ label, index_path, content },
            );
        } else |_| {}
    }

    // The absent-namespace line is only worth saying alongside something else: on its
    // own it is a hook announcing that it has nothing to announce.
    if (absent) |a| {
        if (base != null or catalogue != null) {
            synapse_line = try std.fmt.allocPrint(
                gpa,
                "No Synapse namespace covers {s} -- this branch has no code graph. That is normal; /synapse-init builds one if it is worth it. Nothing here is stale, there is simply nothing to consult.",
                .{a},
            );
        }
    }

    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    var wrote = false;
    for ([_]?[]u8{ base, synapse_line, catalogue }) |part| {
        const p = part orelse continue;
        if (p.len == 0) continue;
        if (wrote) try text.writer.writeAll("\n\n");
        try text.writer.writeAll(p);
        wrote = true;
    }
    if (!wrote) return;
    try common.emitContext(gpa, io, "SessionStart", text.written());
}

/// `name|remote` for every *other* namespace in the vault, byte-sorted.
///
/// This repo's own namespace is dropped: it already got the verified pointer above,
/// which carries a stronger guarantee than a catalogue line can. Byte-sorted so the
/// injected text is identical across runs and machines -- collation is
/// locale-dependent and a directory's order is not reliably sorted.
fn buildCatalogue(gpa: Allocator, io: Io, vault: []const u8, own: ?[]const u8) !?[]u8 {
    const root = try std.fmt.allocPrint(gpa, "{s}/synapse", .{vault});
    defer gpa.free(root);
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var entries: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (entries.items) |e| gpa.free(e);
        entries.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (own) |o| if (std.mem.eql(u8, entry.name, o)) continue;
        const index_path = try std.fmt.allocPrint(gpa, "{s}/{s}/Index.md", .{ root, entry.name });
        defer gpa.free(index_path);
        const text = Io.Dir.cwd().readFileAlloc(io, index_path, gpa, .limited(64 << 20)) catch continue;
        defer gpa.free(text);
        const remote = core.query.field(text, "remote") orelse continue;
        try entries.append(gpa, try std.fmt.allocPrint(gpa, "{s}|{s}", .{ entry.name, remote }));
    }
    if (entries.items.len == 0) return null;
    std.mem.sort([]u8, entries.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(
        "Other Synapse namespaces in this vault (name | remote). A session that moves into one of these repos can consult synapse/{name}/Index.md for its code graph -- but verify the listed remote against that repo's own `git remote get-url origin` first, since a namespace is keyed by repo and branch and names only the branch it was built from:\n",
    );
    for (entries.items, 0..) |e, i| {
        if (i > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(e);
    }
    return try out.toOwnedSlice();
}
