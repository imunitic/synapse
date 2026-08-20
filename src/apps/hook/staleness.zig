//! `synapse-hook staleness` -- PostToolUse on Write|Edit|MultiEdit.
//!
//! Three jobs per edit: flag every node covering the file, report any cited
//! evidence that stopped matching, and once per session per file name the
//! nodes that depend on its owners. A hook already knows with certainty
//! which file just changed, so flagging is pure bookkeeping -- no git-hash
//! verification here, that's `query stale` at read time.
//!
//! Opportunistic correction is deliberately narrow: only when the edit
//! landed on evidence a node explicitly cites (its `crux` source, or a
//! `grounded_in` range). Nudging on any edit to any of a node's files would
//! fire constantly and get tuned out; this fires rarely and means something
//! every time. It's also free -- the model just read the code, so no
//! re-reading is asked for.
//!
//! The blast radius (inbound typed relations to the owning nodes) fires at
//! most once per session per file, since editing the same file repeatedly
//! would otherwise repeat the same information every time.
//!
//! Writes one `stale:` line per owning node, by read-modify-write. Never
//! `PATCH -H "Target-Type: frontmatter"` -- see `core.emit.setStaleTrue`
//! for why: a permanent false positive no rebuild can clear.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const vault = common.vault(gpa, io, env) orelse return;
    defer gpa.free(vault);

    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();
    const raw_file = payload.nested("tool_input", "file_path") orelse
        payload.nested("tool_response", "filePath") orelse return;

    // From the edited file's directory, not $PWD -- not always the same repo.
    const ns = common.Namespace.resolve(gpa, io, env, std.fs.path.dirname(raw_file) orelse ".") orelse
        return;
    defer ns.deinit(gpa);

    const st = Io.Dir.cwd().statFile(io, raw_file, .{}) catch return; // a delete has nothing to hash
    if (st.kind != .file) return;

    // Resolved before the prefix strip: repo_root is already symlink-resolved
    // (macOS /tmp -> /private/tmp) but tool_input.file_path may not be.
    const file = try realPath(gpa, io, raw_file);
    defer gpa.free(file);

    const prefix = try std.fmt.allocPrint(gpa, "{s}/", .{ns.repo_root}); // repo-relative, like sources

    defer gpa.free(prefix);
    if (!std.mem.startsWith(u8, file, prefix)) return;
    const rel = file[prefix.len..];

    if (!try common.namespaceMatches(gpa, io, vault, ns)) return;

    const work = common.workDir(env) orelse return;
    const index_path = try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{work});
    defer gpa.free(index_path);

    // Checked before opening -- Map.open answers a missing file with an empty
    // map (deliberate elsewhere), but here that would write out an index
    // nobody built.
    _ = Io.Dir.cwd().statFile(io, index_path, .{}) catch return;

    var map = core.index_map.Map.open(io, index_path) catch return;
    defer map.close(io);
    if (map.discarded != null) return; // an unreadable index is silence too

    var names: [core.index_map.max_nodes_per_path][]const u8 = undefined;
    const owners = map.nodesFor(rel, &names) orelse {
        // New, unclaimed file -- queue for the _unassigned sweep. One
        // idempotent re-encode replaces a 27 MB read-modify-write + PUT.
        try addUnassigned(gpa, io, &map, index_path, rel);
        return;
    };
    // Copied out: the blast-radius pass and per-node loop outlive assumptions
    // about the mapping staying put.
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

        // Before the staleness write regardless of outcome: an already-stale
        // node can still cite evidence this edit just invalidated.
        try checkCitedEvidence(gpa, node_text, node_file, rel, content, &findings.writer);

        var next: Io.Writer.Allocating = .init(gpa);
        defer next.deinit();
        const changed = try core.emit.setStaleTrue(&next.writer, node_text);
        if (!changed) continue; // already stale, or no frontmatter -- don't churn mtime

        _ = store.write(io, node_file, next.written()) catch continue;
    }

    const sid = payload.str("session_id") orelse "default"; // same field stop-nudge reads
    const blast = try blastRadius(gpa, io, env, vault, ns, owned.items, rel, sid);
    defer if (blast) |b| gpa.free(b);

    // Silence by design: an edit with no dependents and no broken citation
    // produces no output.
    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    if (findings.written().len != 0) {
        try text.writer.writeAll(
            "You just edited a file that these Synapse nodes cite as evidence, and the cited range no longer matches what was recorded:\n",
        );
        try text.writer.writeAll(findings.written());
        try text.writer.writeAll(
            "\nYou have the code in front of you right now, so checking is nearly free — this is the one moment correcting a node costs nothing extra. If a sentence in the node is now wrong, fix that sentence and re-point the evidence, following the synapse-node skill: recover the prose with `synapse query body`, re-emit the crux and grounded_in directives, and write it back with `synapse write-node`.\n" ++
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
    var it = map.unassignedIter();
    while (it.next()) |p| if (std.mem.eql(u8, p, rel)) return; // already listed
    const bytes = (core.index_map.withUnassigned(gpa, map.view, rel) catch return) orelse return; // null: already listed

    defer gpa.free(bytes);
    core.index_map.writeFile(gpa, io, index_path, bytes) catch return;
}

/// Cited evidence in the edited file that no longer matches what was
/// recorded. Silent when it still matches, or when the node cites nothing
/// from this file.
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
                    // No digest stored for the crux -- the note's own fenced
                    // copy is the stored side.
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

/// Nodes that depend on this file's owners, at most once per session per file.
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

    // Inbound typed relations, one pass over every node file, no per-file
    // forks -- cheap even on a hub node, ~0.04s at 4.5 MB.
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
                if (std.mem.eql(u8, e.target, target) and !std.mem.eql(u8, src, target)) { // self-link is not a dependent

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

    // Recorded only once something was found, so a no-dependents file is
    // re-checked on a later edit rather than marked seen for nothing.
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
    _ = Io.Dir.cwd().statFile(io, cert, .{}) catch return null; // else every call fails with an unhelpful curl error

    const dir = try std.fmt.allocPrint(gpa, "synapse/{s}", .{ns.key});
    defer gpa.free(dir);
    return try adapters.obsidian.ObsidianStore.init(gpa, port, cert, api_key, dir);
}
