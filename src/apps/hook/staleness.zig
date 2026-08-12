//! `synapse-hook staleness` -- PostToolUse on Write|Edit|MultiEdit.
//!
//! Three jobs on one edit, in order: flag every node that covers the file, report any
//! cited evidence in it that stopped matching, and once per session per file name the
//! nodes that depend on its owners.
//!
//! A hook is not an agent turn -- it already knows with certainty which file just
//! changed -- so the flagging is pure bookkeeping. No git-hash verification here;
//! that is `query stale` at read time.
//!
//! ## Opportunistic correction, and why it is narrow on purpose
//!
//! Flagging `stale: true` says "something under this node changed"; it never says the
//! prose is now wrong, and nothing ever goes back to check. This does, but **only
//! where the edit landed on evidence the node explicitly cites**: the file its `crux`
//! was sliced from, or a range it records in `grounded_in`.
//!
//! That narrowness is the whole design. Nudging on any edit to any of a node's files
//! would fire constantly and be tuned out within a day; nudging only when cited
//! evidence actually stopped matching fires rarely and means something every time.
//!
//! It is also free: this is the one moment the model has certainly just read the code,
//! so no re-reading is asked for. Correctness accrues along the paths that get worked
//! in, and dormant subsystems stay as vague as they were -- which is the right trade,
//! since nobody is touching them.
//!
//! ## The blast radius fires at most once per session per file
//!
//! Ownership is not impact: the actual "what might this edit affect" signal is who
//! *depends on* the owning nodes, i.e. their inbound typed relations. Editing the same
//! file repeatedly in one session would otherwise repeat the same information on every
//! edit -- exactly the "fires constantly, gets tuned out" failure the citation nudge
//! was designed to avoid. A fresh session re-learns it once, like a human re-reading a
//! map after a while away.
//!
//! ## What this hook writes, and how
//!
//! One `stale:` line per owning node, by read-modify-write through the API. Never
//! `PATCH -H "Target-Type: frontmatter"` -- see `core.emit.setStaleTrue` for the
//! verified reason, which is a permanent false positive no rebuild can clear.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const vault = common.vault(io, env) orelse return;

    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();
    const raw_file = payload.nested("tool_input", "file_path") orelse
        payload.nested("tool_response", "filePath") orelse return;

    // Identity from the *edited file's* directory, not from `$PWD`: a session's
    // working directory and the file it just wrote are not always in the same repo.
    const ns = common.Namespace.resolve(gpa, io, env, std.fs.path.dirname(raw_file) orelse ".") orelse
        return;
    defer ns.deinit(gpa);

    // The file has to still exist: an edit that deleted it has nothing to hash, and
    // the node's own `sources` will report it gone at read time anyway.
    const st = Io.Dir.cwd().statFile(io, raw_file, .{}) catch return;
    if (st.kind != .file) return;

    // Resolve the *physical* path before the prefix strip: `git rev-parse
    // --show-toplevel` already resolves symlinks in the repo root (macOS /tmp ->
    // /private/tmp), but `tool_input.file_path` may not be, and a raw string-prefix
    // match would silently miss every edit in a project reached through a symlinked
    // path.
    const file = try realPath(gpa, io, raw_file);
    defer gpa.free(file);

    // Repo-relative -- the form every node's `sources` list and every index record is
    // written in.
    const prefix = try std.fmt.allocPrint(gpa, "{s}/", .{ns.repo_root});
    defer gpa.free(prefix);
    if (!std.mem.startsWith(u8, file, prefix)) return;
    const rel = file[prefix.len..];

    if (!try common.namespaceMatches(gpa, io, vault, ns)) return;

    const work = common.workDir(env) orelse return;
    const index_path = try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{work});
    defer gpa.free(index_path);

    // The file has to *exist*, checked before opening. `Map.open` answers a missing
    // file with an empty map rather than an error -- deliberate there, so a reader
    // can treat "no index" as "nothing claimed" -- but here that would queue the
    // edited path into an index nobody built and write it out, creating the file the
    // script's `[ -f ]` guard existed to avoid.
    _ = Io.Dir.cwd().statFile(io, index_path, .{}) catch return;

    var map = core.index_map.Map.open(io, index_path) catch return;
    defer map.close(io);
    // An unreadable index is the same silence: a hook that fails is worse than one
    // that quietly does nothing, and this is a precondition like any other.
    if (map.discarded != null) return;

    var names: [core.index_map.max_nodes_per_path][]const u8 = undefined;
    const owners = map.nodesFor(rel, &names) orelse {
        // Genuinely new file, not yet claimed -- queue it for the `_unassigned`
        // sweep. One idempotent call replaces a 27 MB read-modify-write and a 27 MB
        // PUT; it is a whole re-encode, affordable because it is reached only for a
        // path that is new *and* unlisted, not once per edit.
        try addUnassigned(gpa, io, &map, index_path, rel);
        return;
    };
    // Copied out: the writes below reopen nothing, but the blast-radius pass and the
    // per-node loop both outlive assumptions about the mapping staying put.
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |o| gpa.free(o);
        owned.deinit(gpa);
    }
    for (owners) |o| try owned.append(gpa, try gpa.dupe(u8, o));

    const content = Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(256 << 20)) catch return;
    defer gpa.free(content);

    var findings: Io.Writer.Allocating = .init(gpa);
    defer findings.deinit();

    var store = (try openStore(gpa, io, env, vault, ns)) orelse return;
    defer store.deinit();

    for (owned.items) |node_file| {
        const node_path = try std.fmt.allocPrint(gpa, "{s}/synapse/{s}/{s}", .{ vault, ns.key, node_file });
        defer gpa.free(node_path);
        const node_text = Io.Dir.cwd().readFileAlloc(io, node_path, gpa, .limited(256 << 20)) catch continue;
        defer gpa.free(node_text);

        // Before the staleness write, and regardless of whether it happens: a node
        // already flagged stale can still be citing evidence this edit just
        // invalidated, and skipping the check there would hide exactly the case where
        // the prose has had the longest to go wrong.
        try checkCitedEvidence(gpa, node_text, node_file, rel, content, &findings.writer);

        var next: Io.Writer.Allocating = .init(gpa);
        defer next.deinit();
        const changed = try core.emit.setStaleTrue(&next.writer, node_text);
        // Already stale, or no frontmatter to touch: skip the write rather than churn
        // the file's mtime on every edit.
        if (!changed) continue;
        _ = store.put(io, node_file, next.written()) catch continue;
    }

    // The session id comes from this hook's own payload, the same field stop-nudge
    // reads -- not from the environment, which has no notion of a session.
    const sid = payload.str("session_id") orelse "default";
    const blast = try blastRadius(gpa, io, env, vault, ns, owned.items, rel, sid);
    defer if (blast) |b| gpa.free(b);

    // Nothing to say unless one of the two checks found something. Silence is the
    // common case by design: an edit to a file a node merely covers, with no
    // dependents and no broken citation, produces no output at all.
    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    if (findings.written().len != 0) {
        try text.writer.writeAll(
            "You just edited a file that these Synapse nodes cite as evidence, and the cited range no longer matches what was recorded:\n",
        );
        try text.writer.writeAll(findings.written());
        try text.writer.writeAll(
            "\nYou have the code in front of you right now, so checking is nearly free — this is the one moment correcting a node costs nothing extra. If a sentence in the node is now wrong, fix that sentence and re-point the evidence, following the synapse-node skill: recover the prose with `synapse-query.sh body`, re-emit the crux and grounded_in directives, and write it back with synapse-write-node.sh.\n" ++
                "\nKeep it incidental. Correct only what this edit actually contradicts. Do NOT re-read the node's other sources, do not verify its remaining claims, and do not start a sweep — that is /synapse-rebuild's job, and turning this into one is how a cheap habit becomes an expensive one. If the prose still holds despite the range moving, just re-point it and move on.",
        );
    }
    if (blast) |b| {
        if (findings.written().len != 0) try text.writer.writeAll("\n\n---\n\n");
        try text.writer.writeAll(b);
    }
    if (text.written().len == 0) return;
    try common.emitContext(gpa, io, "PostToolUse", text.written());
}

/// The physical path of `path`'s directory, plus its basename.
fn realPath(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    const dir_name = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    var dir = Io.Dir.cwd().openDir(io, dir_name, .{}) catch return gpa.dupe(u8, path);
    defer dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = dir.realPath(io, &buf) catch return gpa.dupe(u8, path);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ buf[0..n], base });
}

fn addUnassigned(
    gpa: Allocator,
    io: Io,
    map: *core.index_map.Map,
    index_path: []const u8,
    rel: []const u8,
) !void {
    // Already listed is a no-op, and an unreadable index is silence rather than an
    // empty file written over a real one.
    var it = map.unassignedIter();
    while (it.next()) |p| if (std.mem.eql(u8, p, rel)) return;
    // Null is "already listed" -- the encoder answers that question itself, so this
    // is idempotent twice over rather than by the check above alone.
    const bytes = (core.index_map.withUnassigned(gpa, map.view, rel) catch return) orelse return;
    defer gpa.free(bytes);
    core.index_map.writeFile(gpa, io, index_path, bytes) catch return;
}

/// Cited evidence in the edited file that no longer matches what was recorded.
///
/// Silent when it still matches, and silent for a node that cites nothing from this
/// file at all.
fn checkCitedEvidence(
    gpa: Allocator,
    node_text: []const u8,
    node_file: []const u8,
    rel: []const u8,
    content: []const u8,
    out: *Io.Writer,
) !void {
    const name = if (std.mem.endsWith(u8, node_file, ".md"))
        node_file[0 .. node_file.len - 3]
    else
        node_file;

    if (core.query.field(node_text, "crux_path")) |cpath| {
        if (std.mem.eql(u8, cpath, rel)) {
            if (core.query.field(node_text, "crux_lines")) |clines| {
                if (parseRange(clines)) |r| {
                    // No digest is stored for the crux -- the sliced text lives in the
                    // note -- so the note's own fenced copy is the stored side.
                    const stored = try core.emit.fencedText(gpa, node_text);
                    defer gpa.free(stored);
                    const actual = core.verify.slice(content, r.start, r.end) orelse "";
                    const same = std.mem.eql(
                        u8,
                        &core.verify.sha256Hex(stored),
                        &core.verify.sha256Hex(actual),
                    );
                    if (!same) try out.print("  - {s} — crux ({s}:{s})\n", .{ name, rel, clines });
                }
            }
        }
    }

    var gs = try core.verify.groundings(gpa, node_text);
    defer gs.deinit(gpa);
    for (gs.items) |g| {
        if (!std.mem.eql(u8, g.path, rel)) continue;
        const r = g.range() orelse continue;
        const actual = core.verify.slice(content, r.start, r.end) orelse "";
        if (std.mem.eql(u8, &core.verify.sha256Hex(actual), g.digest)) continue;
        try out.print("  - {s} — grounding ({s}:{s})\n", .{ name, rel, g.lines });
    }
}

fn parseRange(text: []const u8) ?core.verify.Range {
    const dash = std.mem.indexOfScalar(u8, text, '-') orelse return null;
    const start = std.fmt.parseInt(usize, std.mem.trim(u8, text[0..dash], " \t\""), 10) catch return null;
    const end = std.fmt.parseInt(usize, std.mem.trim(u8, text[dash + 1 ..], " \t\""), 10) catch return null;
    if (start == 0 or end < start) return null;
    return .{ .start = start, .end = end };
}

/// The nodes that depend on this file's owners, at most once per session per file.
fn blastRadius(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    ns: common.Namespace,
    owners: []const []u8,
    rel: []const u8,
    sid: []const u8,
) !?[]u8 {
    const home = env.get("HOME") orelse return null;
    const state_dir = try std.fmt.allocPrint(gpa, "{s}/.claude/state", .{home});
    defer gpa.free(state_dir);
    Io.Dir.cwd().createDirPath(io, state_dir) catch {};
    const seen_path = try std.fmt.allocPrint(
        gpa,
        "{s}/synapse-blast-radius-seen-{s}",
        .{ state_dir, sid },
    );
    defer gpa.free(seen_path);
    const key = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ns.key, rel });
    defer gpa.free(key);

    if (Io.Dir.cwd().readFileAlloc(io, seen_path, gpa, .limited(16 << 20))) |seen| {
        defer gpa.free(seen);
        var lines = std.mem.splitScalar(u8, seen, '\n');
        while (lines.next()) |l| if (std.mem.eql(u8, l, key)) return null;
    } else |_| {}

    // Inbound typed relations, the same derivation `query links --inbound` makes: one
    // pass over every node file in the namespace, no per-file forks. Cheap even on a
    // hub node -- ~0.04s at 4.5 MB.
    const dir_path = try std.fmt.allocPrint(gpa, "{s}/synapse/{s}", .{ vault, ns.key });
    defer gpa.free(dir_path);
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var dependents: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (dependents.items) |d| gpa.free(d);
        dependents.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (std.mem.eql(u8, entry.name, "Index.md")) continue;
        const src = entry.name[0 .. entry.name.len - 3];
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name });
        defer gpa.free(p);
        const text = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(256 << 20)) catch continue;
        defer gpa.free(text);
        var edges = try core.query.edges(gpa, text);
        defer edges.deinit(gpa);
        for (edges.items) |e| {
            for (owners) |o| {
                const target = if (std.mem.endsWith(u8, o, ".md")) o[0 .. o.len - 3] else o;
                // `src != tgt`: a node that links to itself is not its own dependent.
                if (std.mem.eql(u8, e.target, target) and !std.mem.eql(u8, src, target)) {
                    try dependents.append(gpa, try gpa.dupe(u8, src));
                    break;
                }
            }
        }
    }
    if (dependents.items.len == 0) return null;

    std.mem.sort([]u8, dependents.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var unique: usize = 0;
    for (dependents.items) |d| {
        if (unique != 0 and std.mem.eql(u8, dependents.items[unique - 1], d)) continue;
        dependents.items[unique] = d;
        unique += 1;
    }

    // Recorded only once something was found, so a file whose owners have no
    // dependents is re-checked on a later edit rather than being marked seen for
    // nothing.
    try appendSeen(gpa, io, seen_path, key);

    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll("This file is covered by a Synapse node that other nodes depend on:\n");
    for (dependents.items[0..@min(5, unique)]) |d| try out.writer.print("  - {s}\n", .{d});
    if (unique > 5) try out.writer.print("  (+{d} more)\n", .{unique - 5});
    try out.writer.writeAll(
        "\nNot necessarily a reason to change anything else — just worth knowing before you finish, in case this edit changes behavior those nodes describe.",
    );
    return try out.toOwnedSlice();
}

fn appendSeen(gpa: Allocator, io: Io, path: []const u8, key: []const u8) !void {
    const existing = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch
        try gpa.dupe(u8, "");
    defer gpa.free(existing);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll(existing);
    if (existing.len != 0 and existing[existing.len - 1] != '\n') try out.writer.writeAll("\n");
    try out.writer.print("{s}\n", .{key});
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() }) catch {};
}

fn openStore(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    ns: common.Namespace,
) !?adapters.obsidian.ObsidianStore {
    const plugin = try std.fmt.allocPrint(
        gpa,
        "{s}/.obsidian/plugins/obsidian-local-rest-api/data.json",
        .{vault},
    );
    defer gpa.free(plugin);
    const text = Io.Dir.cwd().readFileAlloc(io, plugin, gpa, .limited(1 << 20)) catch return null;
    defer gpa.free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const api_key = switch (obj.get("apiKey") orelse .null) {
        .string => |s| s,
        else => "",
    };
    const port: u16 = switch (obj.get("port") orelse .null) {
        .integer => |i| @intCast(i),
        .string => |s| std.fmt.parseInt(u16, s, 10) catch 0,
        else => 0,
    };
    if (api_key.len == 0 or port == 0) return null;
    const cert = try std.fmt.allocPrint(gpa, "{s}/.claude/obsidian-local-rest-api-ca.pem", .{
        env.get("HOME") orelse "",
    });
    defer gpa.free(cert);
    // The certificate has to exist, or every call fails with an unhelpful curl error.
    _ = Io.Dir.cwd().statFile(io, cert, .{}) catch return null;
    const dir = try std.fmt.allocPrint(gpa, "synapse/{s}", .{ns.key});
    defer gpa.free(dir);
    return try adapters.obsidian.ObsidianStore.init(gpa, port, cert, api_key, dir);
}
