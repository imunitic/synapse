//! `synapse-hook session-start` -- SessionStart.
//!
//! Injects the vault's `Index.md` so a session starts with the map already
//! in context, plus the Synapse pointer check. Everything here is a path
//! lookup, never a model call or HTTP round trip, which keeps it zero-cost
//! for a repo that never ran `/synapse-init`. Three pieces: the vault
//! index; this repo's namespace pointer (verified against the recorded
//! remote, or an explicit "no namespace" line); and a catalogue of the
//! *other* namespaces, so a session that later `cd`s elsewhere knows that
//! repo's graph exists too.
//!
//! The catalogue is built here and stored nowhere -- the directory listing
//! plus each index's `remote:` field is the source of truth, so nothing to
//! invalidate, and this hook stays read-only against the vault (only
//! `staleness` writes).
//!
//! A mismatched remote is reported, never repaired: it could mean a
//! different repo sharing this basename, or this repo's remote changed
//! deliberately (including via a `url.<base>.insteadOf` git config rule).
//! Nothing here tries to tell those apart or auto-migrate -- both remedies
//! belong to the person who made the change.

const std = @import("std");
const core = @import("core");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const label = "Synapse Vault index";

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv0: []const u8) !void {
    const vault = common.vault(gpa, io, env) orelse ""; // one guard below, not two paths
    defer if (vault.len != 0) gpa.free(vault);
    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();

    var synapse_line: ?[]u8 = null;
    defer if (synapse_line) |s| gpa.free(s);
    var absent: ?[]u8 = null;
    defer if (absent) |s| gpa.free(s);
    var catalogue: ?[]u8 = null;
    defer if (catalogue) |s| gpa.free(s);

    // Independent of vault configuration entirely -- this is Synapse's own
    // standing instructions, not vault content. `CLAUDE_PLUGIN_ROOT` is a
    // real exported environment variable on the spawned hook process
    // ("regardless of how it was launched", per Claude Code's own hooks
    // reference) -- checked first when running as a plugin. Falls back to
    // resolving relative to this binary's own invoked path (`argv0`), one
    // directory up, for the pre-plugin `setup.sh` install, which has no
    // `CLAUDE_PLUGIN_ROOT` at all: `~/.claude/bin/synapse-hook` next to
    // `~/.claude/synapse-claude.md` today. No frontmatter to strip --
    // unlike a skill file, this one has none.
    var claude_md: ?[]u8 = null;
    defer if (claude_md) |s| gpa.free(s);
    const claude_md_path: ?[]u8 = if (env.get("CLAUDE_PLUGIN_ROOT")) |root|
        try std.fmt.allocPrint(gpa, "{s}/synapse-claude.md", .{root})
    else if (std.fs.path.dirname(argv0)) |bin_dir|
        try std.fmt.allocPrint(gpa, "{s}/../synapse-claude.md", .{bin_dir})
    else
        null;
    if (claude_md_path) |path| {
        defer gpa.free(path);
        if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20))) |content| {
            claude_md = content;
        } else |_| {}
    }

    // The one precondition every other section here silently depends on.
    // Said, not implied by silence: there's no install-time prompt to catch
    // this instead (a plugin install just clones files, nothing prints
    // anything), so this hook is the only place it can ever get said.
    var vault_warning: ?[]u8 = null;
    defer if (vault_warning) |s| gpa.free(s);
    if (vault.len == 0) {
        vault_warning = try gpa.dupe(
            u8,
            "Synapse Vault isn't configured, or its directory isn't reachable -- code-graph and vault-note features are unavailable until synapse.conf's OBSIDIAN_VAULT_DIR points at a real directory. Create or edit synapse.conf at $XDG_CONFIG_HOME/synapse/synapse.conf (or ~/.config/synapse/synapse.conf if that variable isn't set), or ~/.claude/synapse.conf.",
        );
    }

    // The catalogue below needs the key to drop this repo's own namespace.
    const maybe_ns = if (vault.len != 0)
        common.Namespace.resolve(gpa, io, env, payload.str("cwd") orelse ".")
    else
        null;
    defer if (maybe_ns) |ns| ns.deinit(gpa);

    if (vault.len != 0) {
        if (maybe_ns) |ns| {
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
                // Said, not implied by silence -- a branch with no namespace
                // is ordinary, but must stay distinguishable from "a
                // namespace that found nothing".
                absent = try std.fmt.allocPrint(gpa, "synapse/{s}/", .{ns.key});
            }
        }
        catalogue = try buildCatalogue(gpa, io, vault, if (maybe_ns) |ns| ns.key else null);
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
        } else |_| {
            // `vault` is already confirmed to exist and be a real directory
            // by common.vault() above, so a read failure here can only mean
            // Index.md itself is missing -- not an unreachable vault. Offer,
            // don't seed: this is the agent's call to make, not this hook's.
            base = try std.fmt.allocPrint(
                gpa,
                "No Index.md found at {s} -- the configured Synapse Vault has no index yet. Offer to seed it from the shipped default (claude/Index.md.template in the Synapse repo) before creating or linking any note.",
                .{index_path},
            );
        }
    }

    // Only worth saying alongside something else -- alone it's a hook
    // announcing it has nothing to announce.
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
    for ([_]?[]u8{ claude_md, vault_warning, base, synapse_line, catalogue }) |part| {
        const p = part orelse continue;
        if (p.len == 0) continue;
        if (wrote) try text.writer.writeAll("\n\n");
        try text.writer.writeAll(p);
        wrote = true;
    }
    if (!wrote) return;
    try common.emitContext(gpa, io, "SessionStart", text.written());
}

/// `name|remote` for every *other* namespace in the vault, byte-sorted (this
/// repo's own is dropped -- it already got the stronger verified pointer
/// above). Byte-sorted, not locale-collated, so the text is identical
/// across machines.
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
