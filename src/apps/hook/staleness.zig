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
    const raw_file = (try payload.toolFile(gpa)) orelse return;
    defer gpa.free(raw_file);
    const sid = payload.str("session_id") orelse "default"; // same field stop-nudge reads

    const text = try build(gpa, io, env, vault, raw_file, sid) orelse return;
    defer gpa.free(text);
    try common.emitContext(gpa, io, "PostToolUse", text);
}

/// The command itself, minus payload parsing -- separated so a test can
/// drive it against a real fixture directly, without a real stdin payload.
/// Returns the context text, or null when nothing should be emitted.
/// Caller owns the result.
pub fn build(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    raw_file: []const u8,
    sid: []const u8,
) !?[]u8 {
    // From the edited file's directory, not $PWD -- not always the same repo.
    const ns = common.Namespace.resolve(gpa, io, env, std.fs.path.dirname(raw_file) orelse ".") orelse
        return null;
    defer ns.deinit(gpa);

    const st = Io.Dir.cwd().statFile(io, raw_file, .{}) catch return null; // a delete has nothing to hash
    if (st.kind != .file) return null;

    // Resolved before the prefix strip: repo_root is already symlink-resolved
    // (macOS /tmp -> /private/tmp) but tool_input.file_path may not be.
    const file = try realPath(gpa, io, raw_file);
    defer gpa.free(file);

    const prefix = try std.fmt.allocPrint(gpa, "{s}/", .{ns.repo_root}); // repo-relative, like sources

    defer gpa.free(prefix);
    if (!std.mem.startsWith(u8, file, prefix)) return null;
    const rel = file[prefix.len..];

    if (!try common.namespaceMatches(gpa, io, vault, ns)) return null;

    const work = common.workDir(gpa, env, ns.key) orelse return null;
    defer gpa.free(work);
    const index_path = try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{work});
    defer gpa.free(index_path);

    // Checked before opening -- Map.open answers a missing file with an empty
    // map (deliberate elsewhere), but here that would write out an index
    // nobody built.
    _ = Io.Dir.cwd().statFile(io, index_path, .{}) catch return null;

    var map = core.index_map.Map.open(io, index_path) catch return null;
    defer map.close(io);
    if (map.discarded != null) return null; // an unreadable index is silence too

    var names: [core.index_map.max_nodes_per_path][]const u8 = undefined;
    const owners = map.nodesFor(rel, &names) orelse {
        // New, unclaimed file -- queue for the _unassigned sweep. One
        // idempotent re-encode, not a 27 MB read-modify-write.
        try addUnassigned(gpa, io, &map, index_path, rel);
        return null;
    };
    // Copied out: the blast-radius pass and per-node loop outlive assumptions
    // about the mapping staying put.
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |o| gpa.free(o);
        owned.deinit(gpa);
    }
    for (owners) |o| try owned.append(gpa, try gpa.dupe(u8, o));

    const content = Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(256 << 20)) catch |e| {
        // Already confirmed to exist and be a regular file above -- this is
        // a genuinely unexpected failure, not the ordinary "file is gone" case.
        std.debug.print("synapse-hook: could not read edited file, staleness check skipped ({s}, {t})\n", .{ file, e });
        return null;
    };
    defer gpa.free(content);

    var findings: Io.Writer.Allocating = .init(gpa);
    defer findings.deinit();

    const store_ns = try std.fmt.allocPrint(gpa, "synapse/{s}", .{ns.key});
    defer gpa.free(store_ns);
    var resolved = (try adapters.store_resolve.resolveStore(gpa, io, env, vault, store_ns, null, "")) orelse return null;
    defer resolved.deinit();
    var store = resolved.store();

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
                "\nKeep it incidental. Correct only what this edit actually contradicts. Do NOT re-read the node's other sources, do not verify its remaining claims, and do not start a sweep — that is /synapse-rebuild-diff's job, and turning this into one is how a cheap habit becomes an expensive one. If the prose still holds despite the range moving, just re-point it and move on.",
        );
    }
    if (blast) |b| {
        if (findings.written().len != 0) try text.writer.writeAll("\n\n---\n\n");
        try text.writer.writeAll(b);
    }
    if (text.written().len == 0) return null;
    return try gpa.dupe(u8, text.written());
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
    const bytes = (core.index_map.withUnassigned(gpa, map.view, rel) catch |e| {
        std.debug.print("synapse-hook: could not queue '{s}' as unassigned ({t})\n", .{ rel, e });
        return;
    }) orelse return; // null: already listed

    defer gpa.free(bytes);
    core.index_map.writeFile(gpa, io, index_path, bytes) catch |e| {
        std.debug.print("synapse-hook: could not write the index after queuing '{s}' as unassigned ({t})\n", .{ rel, e });
    };
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
    pruneOldSeenFiles(io, state_dir);
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
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| {
        std.debug.print("synapse-hook: could not open namespace dir, blast-radius check skipped ({s}, {t})\n", .{ dir_path, e });
        return null;
    };
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

const seen_file_max_age_ns: i96 = 7 * std.time.ns_per_day;

/// Deletes any `synapse-blast-radius-seen-*` file in `state_dir` older than a
/// week -- one per session, and a session ends without ever coming back to
/// clean up after itself.
fn pruneOldSeenFiles(io: Io, state_dir: []const u8) void {
    var dir = Io.Dir.cwd().openDir(io, state_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const now = Io.Timestamp.now(io, .real).nanoseconds;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "synapse-blast-radius-seen-")) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ state_dir, entry.name }) catch continue;
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        if (now - st.mtime.nanoseconds > seen_file_max_age_ns) dir.deleteFile(io, entry.name) catch {};
    }
}

fn appendSeen(gpa: Allocator, io: Io, path: []const u8, key: []const u8) !void {
    const existing = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |e| blk: {
        if (e != error.FileNotFound)
            std.debug.print("synapse-hook: unreadable 'seen' log, rewriting from empty ({s}, {t})\n", .{ path, e });
        break :blk try gpa.dupe(u8, "");
    };
    defer gpa.free(existing);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll(existing);
    if (existing.len != 0 and existing[existing.len - 1] != '\n') try out.writer.writeAll("\n");
    try out.writer.print("{s}\n", .{key});
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() }) catch |e| {
        std.debug.print("synapse-hook: could not write the 'seen' log, this relation may re-nudge ({s}, {t})\n", .{ path, e });
    };
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

/// Real git identity resolution, not an env-var bypass: several of this
/// file's own tests exercise remote/branch matching directly, so they need
/// `common.Namespace.resolve` to actually walk the fixture repo.
const StalenessFixture = struct {
    fx: fixture.Fixture,
    key: []u8 = &.{},
    remote: []u8 = &.{},
    branch: []u8 = &.{},

    fn init(gpa: Allocator) !StalenessFixture {
        const fx = try fixture.Fixture.init(gpa);
        return .{ .fx = fx };
    }

    fn deinit(self: *StalenessFixture) void {
        if (self.key.len != 0) self.fx.gpa.free(self.key);
        if (self.remote.len != 0) self.fx.gpa.free(self.remote);
        if (self.branch.len != 0) self.fx.gpa.free(self.branch);
        self.fx.deinit();
    }

    /// `git init` + one commit adding everything currently staged, then
    /// resolves the real identity once and caches it -- every helper below
    /// addresses `vault/synapse/{key}/...` off this.
    fn commit(self: *StalenessFixture, message: []const u8) !void {
        try self.fx.gitCommit(message);
        const ns = common.Namespace.resolve(self.fx.gpa, self.fx.io(), &self.fx.env, self.fx.repo) orelse
            return error.NoIdentity;
        defer ns.deinit(self.fx.gpa);
        self.key = try self.fx.gpa.dupe(u8, ns.key);
        self.remote = try self.fx.gpa.dupe(u8, ns.remote);
        self.branch = try self.fx.gpa.dupe(u8, ns.branch);
    }

    fn writeIndex(self: *StalenessFixture) !void {
        try self.fx.writeIndex(self.key, self.remote, self.branch);
    }

    fn writeIndexWithRemote(self: *StalenessFixture, remote: []const u8) !void {
        try self.fx.writeIndex(self.key, remote, self.branch);
    }

    fn writeNode(self: *StalenessFixture, name: []const u8, content: []const u8) !void {
        try self.fx.writeNode(self.key, name, content);
    }

    fn readNode(self: *StalenessFixture, gpa: Allocator, name: []const u8) !?[]u8 {
        return self.fx.readNode(gpa, self.key, name);
    }

    fn writeIndexBin(self: *StalenessFixture, pairs: []const core.index_map.Pair) !void {
        try self.fx.writeIndexBin(pairs);
    }

    /// Drives `build()` against a repo-relative edited path, session
    /// `"default"` -- the value every real payload gets when `session_id`
    /// is absent.
    fn edit(self: *StalenessFixture, rel_path: []const u8) !?[]u8 {
        return self.editSession(rel_path, "default");
    }

    fn editSession(self: *StalenessFixture, rel_path: []const u8, sid: []const u8) !?[]u8 {
        const raw_file = try std.fmt.allocPrint(self.fx.gpa, "{s}/{s}", .{ self.fx.repo, rel_path });
        defer self.fx.gpa.free(raw_file);
        return build(self.fx.gpa, self.fx.io(), &self.fx.env, self.fx.vault, raw_file, sid);
    }
};

/// Every frontmatter shape the old `PATCH -H "Target-Type: frontmatter"`
/// call used to mangle: a title long enough to be line-folded, quoted
/// values, and an all-digit `hash` that YAML happily coerces to a float.
fn simpleNode(gpa: Allocator, stale: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "---\ntitle: \"A deliberately long node title that a re-serialising writer would fold across two lines\"\nnode_type: synapse-node\nsources:\n  - path: src/foo.ml\n    hash: 1111111111111111111111111111111111111111\nsources_digest: \"2222222222222222222222222222222222222222222222222222222222222222\"\nstale: {s}\nbuilt_at: \"2026-08-03 16:15\"\n---\n\n# A node\n\nBody text, including a decoy: stale: false\n",
        .{stale},
    );
}

/// `calc.ml` with a stable doc comment on lines 1-2 and numbered lines
/// below, `second_line`/`line5` overridable so a test can move exactly the
/// range it's checking without disturbing the rest of the file.
fn calcMlCustom(gpa: Allocator, second_line: []const u8, line5: usize) ![]u8 {
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try buf.writer.print("(* Computes the premium.\n   {s} *)\n", .{second_line});
    var i: usize = 3;
    while (i <= 12) : (i += 1) {
        const v: usize = if (i == 5) line5 else i;
        try buf.writer.print("let line{d:0>2} = {d}\n", .{ i, v });
    }
    return try gpa.dupe(u8, buf.written());
}

fn calcMl(gpa: Allocator) ![]u8 {
    return calcMlCustom(gpa, "Rounds half-up.", 5);
}

/// A node citing `lib/calc.ml` both as its crux (lines 5-6, sliced into the
/// body) and as a grounding (lines 1-2, recorded as a digest of `calc`'s
/// *original* content -- `calc` is not re-read here, so a caller free to
/// overwrite the repo file afterward without disturbing what was recorded).
fn writeCitedNode(sf: *StalenessFixture, calc: []const u8, stale: bool) !void {
    const digest = core.verify.sha256Hex(core.verify.slice(calc, 1, 2).?);
    const content = try std.fmt.allocPrint(
        sf.fx.gpa,
        "---\ntitle: \"Cited\"\nnode_type: synapse-node\nsources:\n  - path: lib/calc.ml\n    hash: 1111111111111111111111111111111111111111\nsources_digest: \"2222222222222222222222222222222222222222222222222222222222222222\"\nstale: {}\nbuilt_at: \"2026-08-03 16:15\"\ncrux_path: lib/calc.ml\ncrux_lines: \"5-6\"\ngrounded_in:\n  - path: lib/calc.ml\n    lines: \"1-2\"\n    digest: {s}\n---\n\n# Cited\n<!-- synapse:generated:start -->\n\n## Summary\nRounds half-up at two decimals.\n\n## Crux\n```ocaml\nlet line05 = 5\nlet line06 = 6\n```\n— `lib/calc.ml`:5-6\n<!-- synapse:generated:end -->\n\n## Notes\n",
        .{ stale, &digest },
    );
    defer sf.fx.gpa.free(content);
    try sf.writeNode("Cited.md", content);
}

/// A node whose `## Links` section `depends_on <target>` -- for
/// blast-radius tests, where `target` is the node that directly covers the
/// edited file.
fn writeDependentNode(sf: *StalenessFixture, name: []const u8, target: []const u8) !void {
    const content = try std.fmt.allocPrint(
        sf.fx.gpa,
        "---\ntitle: \"Dependent\"\nnode_type: synapse-node\nsources:\n  - path: lib/dependent.ml\n    hash: 3333333333333333333333333333333333333333\nsources_digest: \"4444444444444444444444444444444444444444444444444444444444444444\"\nstale: false\nbuilt_at: \"2026-08-03 16:15\"\n---\n\n# Dependent\n<!-- synapse:generated:start -->\n\n## Summary\nDepends on {s}.\n\n## Links\n- depends_on [[{s}]]\n<!-- synapse:generated:end -->\n\n## Notes\n",
        .{ target, target },
    );
    defer sf.fx.gpa.free(content);
    try sf.writeNode(name, content);
}

/// A real git repo with `lib/calc.ml`, its namespace, an index mapping it
/// to `Cited.md`, and `Cited.md` itself, freshly built (`stale: false`).
fn makeCitedRepo(sf: *StalenessFixture) !void {
    const calc = try calcMl(sf.fx.gpa);
    defer sf.fx.gpa.free(calc);
    try sf.fx.writeRepoFile("lib/calc.ml", calc);
    try sf.commit("calc");
    try sf.writeIndex();
    try sf.writeIndexBin(&.{.{ .path = "lib/calc.ml", .node = "Cited.md" }});
    try writeCitedNode(sf, calc, false);
}

test "file mapped to a node: rewrites that node's stale line, never PATCHes frontmatter" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try sf.commit("init");
    try sf.writeIndex();
    try sf.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo Node.md" }});
    const node = try simpleNode(gpa, "false");
    defer gpa.free(node);
    try sf.writeNode("Foo Node.md", node);

    const text = try sf.edit("src/foo.ml");
    defer if (text) |t| gpa.free(t);

    const written = (try sf.readNode(gpa, "Foo Node.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "stale: true") != null);

    const path = try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{sf.fx.work});
    defer gpa.free(path);
    var map = try core.index_map.Map.open(sf.fx.io(), path);
    defer map.close(sf.fx.io());
    try testing.expectEqual(@as(u32, 0), map.unassignedCount());
}

// Regression coverage for the SYNAPSE_WORK_DIR bug: production never
// exports it (nothing in hooks.json or fetch-and-run.cjs ever does), but
// every other test in this file runs through StalenessFixture, which sets
// it unconditionally -- so the one env shape that matters, "unset, same as
// a real hook invocation gets," was never once exercised end to end before
// this. Removing the fixture's override alone isn't enough to reproduce the
// bug faithfully: the index/nodes still have to actually live where the
// *default* resolution points, or a broken default and a merely-relocated
// fixture would look identical from the assertions' point of view. A
// symlink from that default path back to the fixture's own work dir makes
// both true at once, with no change to any of the shared write helpers.
test "regression: SYNAPSE_WORK_DIR unset (the real production shape) still finds the index and flags the node" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try sf.commit("init"); // resolves sf.key, needed for the default path below

    try sf.fx.tmp.dir.createDirPath(sf.fx.io(), "home/.cache/synapse/work");
    const default_link = try std.fmt.allocPrint(gpa, "home/.cache/synapse/work/{s}", .{sf.key});
    defer gpa.free(default_link);
    try sf.fx.tmp.dir.symLink(sf.fx.io(), sf.fx.work, default_link, .{ .is_directory = true });

    _ = sf.fx.env.swapRemove("SYNAPSE_WORK_DIR");

    try sf.writeIndex();
    try sf.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo Node.md" }});
    const node = try simpleNode(gpa, "false");
    defer gpa.free(node);
    try sf.writeNode("Foo Node.md", node);

    const text = try sf.edit("src/foo.ml");
    defer if (text) |t| gpa.free(t);

    const written = (try sf.readNode(gpa, "Foo Node.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "stale: true") != null);
}

test "file mapped to two nodes: flags both" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try sf.commit("init");
    try sf.writeIndex();
    try sf.writeIndexBin(&.{
        .{ .path = "src/foo.ml", .node = "Foo Node.md" },
        .{ .path = "src/foo.ml", .node = "Bar Node.md" },
    });
    const node_a = try simpleNode(gpa, "false");
    defer gpa.free(node_a);
    try sf.writeNode("Foo Node.md", node_a);
    const node_b = try simpleNode(gpa, "false");
    defer gpa.free(node_b);
    try sf.writeNode("Bar Node.md", node_b);

    const text = try sf.edit("src/foo.ml");
    defer if (text) |t| gpa.free(t);

    const wa = (try sf.readNode(gpa, "Foo Node.md")).?;
    defer gpa.free(wa);
    try testing.expect(std.mem.indexOf(u8, wa, "stale: true") != null);
    const wb = (try sf.readNode(gpa, "Bar Node.md")).?;
    defer gpa.free(wb);
    try testing.expect(std.mem.indexOf(u8, wb, "stale: true") != null);
}

test "new file not in any node's sources: queued into the unassigned list, no PATCH" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try sf.fx.writeRepoFile("src/other.ml", "let y = 2\n");
    try sf.commit("init");
    try sf.writeIndex();
    try sf.writeIndexBin(&.{.{ .path = "src/other.ml", .node = "Other Node.md" }});

    const text = try sf.edit("src/foo.ml");
    try testing.expectEqual(@as(?[]u8, null), text);

    const path = try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{sf.fx.work});
    defer gpa.free(path);
    var map = try core.index_map.Map.open(sf.fx.io(), path);
    defer map.close(sf.fx.io());
    var found = false;
    var it = map.unassignedIter();
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, "src/foo.ml")) found = true;
    }
    try testing.expect(found);

    var names: [core.index_map.max_nodes_per_path][]const u8 = undefined;
    const owners = map.nodesFor("src/other.ml", &names).?;
    try testing.expectEqual(@as(usize, 1), owners.len);
    try testing.expectEqualStrings("Other Node.md", owners[0]);
}

test "queueing the same new file twice does not grow the list" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try sf.fx.writeRepoFile("src/other.ml", "let y = 2\n");
    try sf.commit("init");
    try sf.writeIndex();
    try sf.writeIndexBin(&.{.{ .path = "src/other.ml", .node = "Other Node.md" }});

    _ = try sf.edit("src/foo.ml");
    _ = try sf.edit("src/foo.ml"); // second edit, same file

    const path = try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{sf.fx.work});
    defer gpa.free(path);
    var map = try core.index_map.Map.open(sf.fx.io(), path);
    defer map.close(sf.fx.io());
    try testing.expectEqual(@as(u32, 1), map.unassignedCount());
}

test "no Synapse namespace for this repo: no-op, no write or PATCH" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try sf.commit("init");
    try sf.writeIndex();
    // No index staged at all.

    const text = try sf.edit("src/foo.ml");
    try testing.expectEqual(@as(?[]u8, null), text);
}

test "edited file outside any git repo: no-op" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    const outside = "/tmp/synapse-staleness-notarepo-test";
    try Io.Dir.cwd().createDirPath(sf.fx.io(), outside);
    defer Io.Dir.cwd().deleteTree(sf.fx.io(), outside) catch {};
    const stray = try std.fmt.allocPrint(gpa, "{s}/stray.txt", .{outside});
    defer gpa.free(stray);
    try Io.Dir.cwd().writeFile(sf.fx.io(), .{ .sub_path = stray, .data = "stray\n" });

    const text = try build(gpa, sf.fx.io(), &sf.fx.env, sf.fx.vault, stray, "default");
    try testing.expectEqual(@as(?[]u8, null), text);
}

test "a node title with special characters (spaces, an em dash) writes to the right file untouched" {
    // `store.write` is plain disk I/O now -- no URL, so no percent-encoding
    // concern survives; this pins that the title reaches the filesystem
    // byte-for-byte instead.
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try sf.commit("init");
    try sf.writeIndex();
    try sf.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "World — entity_component_resource core.md" }});
    const node = try simpleNode(gpa, "false");
    defer gpa.free(node);
    try sf.writeNode("World — entity_component_resource core.md", node);

    const text = try sf.edit("src/foo.ml");
    defer if (text) |t| gpa.free(t);

    const written = (try sf.readNode(gpa, "World — entity_component_resource core.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "stale: true") != null);
}

test "node already stale: no write at all" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try sf.commit("init");
    try sf.writeIndex();
    try sf.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo Node.md" }});
    const node = try simpleNode(gpa, "true");
    defer gpa.free(node);
    try sf.writeNode("Foo Node.md", node);
    const before = (try sf.readNode(gpa, "Foo Node.md")).?;
    defer gpa.free(before);

    const text = try sf.edit("src/foo.ml");
    defer if (text) |t| gpa.free(t);

    // Already true -> the hook must skip the write rather than churn the file.
    const after = (try sf.readNode(gpa, "Foo Node.md")).?;
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
}

test "node listed in the index but missing from the vault: no-op, no crash" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try sf.commit("init");
    try sf.writeIndex();
    try sf.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Ghost Node.md" }});
    // deliberately no writeNode -- the indexed node file doesn't exist on disk

    const text = try sf.edit("src/foo.ml");
    try testing.expectEqual(@as(?[]u8, null), text);
}

test "namespace belongs to a different remote: no write at all" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const add_res = try sf.fx.git(&.{ "remote", "add", "origin", "ssh://git@example.com/mine.git" });
    add_res.deinit(gpa);
    try sf.commit("init");
    try sf.writeIndexWithRemote("ssh://git@example.com/SOMEONE-ELSE.git");
    try sf.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo Node.md" }});
    const node = try simpleNode(gpa, "false");
    defer gpa.free(node);
    try sf.writeNode("Foo Node.md", node);

    const text = try sf.edit("src/foo.ml");
    try testing.expectEqual(@as(?[]u8, null), text);

    const written = (try sf.readNode(gpa, "Foo Node.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "stale: false") != null);
}

test "namespace Index.md with no remote line: treated as a mismatch, not a match on empty" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const add_res = try sf.fx.git(&.{ "remote", "add", "origin", "ssh://git@example.com/mine.git" });
    add_res.deinit(gpa);
    try sf.commit("init");

    const idx_dir = try std.fmt.allocPrint(gpa, "vault/synapse/{s}", .{sf.key});
    defer gpa.free(idx_dir);
    try sf.fx.tmp.dir.createDirPath(testing.io, idx_dir);
    const idx_path = try std.fmt.allocPrint(gpa, "{s}/Index.md", .{idx_dir});
    defer gpa.free(idx_path);
    try sf.fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = idx_path,
        .data = "---\ntitle: \"no remote here\"\n---\n# index\n",
    });
    try sf.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo Node.md" }});
    const node = try simpleNode(gpa, "false");
    defer gpa.free(node);
    try sf.writeNode("Foo Node.md", node);

    const text = try sf.edit("src/foo.ml");
    try testing.expectEqual(@as(?[]u8, null), text);
}

test "repo with no remote at all: falls back to the repo root and still matches" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try sf.commit("init"); // no remote argument
    try sf.writeIndex();
    try sf.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo Node.md" }});
    const node = try simpleNode(gpa, "false");
    defer gpa.free(node);
    try sf.writeNode("Foo Node.md", node);

    const text = try sf.edit("src/foo.ml");
    defer if (text) |t| gpa.free(t);

    const written = (try sf.readNode(gpa, "Foo Node.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "stale: true") != null);
}

test "correction: silent when the cited evidence still matches" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try makeCitedRepo(&sf);

    const text = try sf.edit("lib/calc.ml");
    try testing.expectEqual(@as(?[]u8, null), text);

    // the staleness flag is still written -- the nudge is additive, not a replacement
    const written = (try sf.readNode(gpa, "Cited.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "stale: true") != null);
}

test "correction: silent for an edit to a file the node cites nothing from" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try makeCitedRepo(&sf);
    try sf.fx.writeRepoFile("lib/elsewhere.ml", "let other = 1\n");
    try sf.writeIndexBin(&.{.{ .path = "lib/elsewhere.ml", .node = "Cited.md" }});

    const text = try sf.edit("lib/elsewhere.ml");
    try testing.expectEqual(@as(?[]u8, null), text);
}

test "correction: a changed grounding range produces a nudge naming the node" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try makeCitedRepo(&sf);
    const changed = try calcMlCustom(gpa, "Truncates toward zero.", 5);
    defer gpa.free(changed);
    try sf.fx.writeRepoFile("lib/calc.ml", changed);

    const text = (try sf.edit("lib/calc.ml")).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Cited") != null);
    try testing.expect(std.mem.indexOf(u8, text, "grounding (lib/calc.ml:1-2)") != null);
}

test "correction: a changed crux range produces a nudge too" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try makeCitedRepo(&sf);
    const changed = try calcMlCustom(gpa, "Rounds half-up.", 999);
    defer gpa.free(changed);
    try sf.fx.writeRepoFile("lib/calc.ml", changed);

    const text = (try sf.edit("lib/calc.ml")).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "crux (lib/calc.ml:5-6)") != null);
}

test "correction: the nudge tells the model to stay incidental" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try makeCitedRepo(&sf);
    const changed = try calcMlCustom(gpa, "Something else entirely.", 5);
    defer gpa.free(changed);
    try sf.fx.writeRepoFile("lib/calc.ml", changed);

    const text = (try sf.edit("lib/calc.ml")).?;
    defer gpa.free(text);
    // the guardrail is the point: without it this becomes an unbounded sweep
    try testing.expect(std.mem.indexOf(u8, text, "Keep it incidental") != null);
    try testing.expect(std.mem.indexOf(u8, text, "do not start a sweep") != null);
    try testing.expect(std.mem.indexOf(u8, text, "synapse-rebuild") != null);
}

test "correction: an already-stale node is still checked" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();

    // A node flagged stale earlier has had the LONGEST time to go wrong, so
    // skipping it would hide the very case worth catching.
    const calc = try calcMl(gpa);
    defer gpa.free(calc);
    try sf.fx.writeRepoFile("lib/calc.ml", calc);
    try sf.commit("calc");
    try sf.writeIndex();
    try sf.writeIndexBin(&.{.{ .path = "lib/calc.ml", .node = "Cited.md" }});
    try writeCitedNode(&sf, calc, true);
    const before = (try sf.readNode(gpa, "Cited.md")).?;
    defer gpa.free(before);

    const changed = try calcMlCustom(gpa, "Truncates toward zero.", 5);
    defer gpa.free(changed);
    try sf.fx.writeRepoFile("lib/calc.ml", changed);

    const text = (try sf.edit("lib/calc.ml")).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "grounding (lib/calc.ml:1-2)") != null);

    // and no redundant write, since stale was already true
    const after = (try sf.readNode(gpa, "Cited.md")).?;
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
}

test "blast radius: silent when the owning node has no dependents" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try makeCitedRepo(&sf);
    // calc.ml is untouched -- no citation break either, so this isolates the
    // "no dependents" case rather than piggybacking on the correction check.
    const text = try sf.edit("lib/calc.ml");
    try testing.expectEqual(@as(?[]u8, null), text);
}

test "blast radius: fires once when another node depends on the owning node" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try makeCitedRepo(&sf);
    try writeDependentNode(&sf, "Dependent.md", "Cited");

    const text = (try sf.edit("lib/calc.ml")).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Dependent") != null);
    try testing.expect(std.mem.indexOf(u8, text, "covered by a Synapse node that other nodes depend on") != null);
}

test "blast radius: silent on a second edit to the same file in the same session" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try makeCitedRepo(&sf);
    try writeDependentNode(&sf, "Dependent.md", "Cited");

    const first = try sf.edit("lib/calc.ml");
    defer if (first) |t| gpa.free(t);
    try testing.expect(first != null);

    const second = try sf.edit("lib/calc.ml");
    try testing.expectEqual(@as(?[]u8, null), second);
}

test "blast radius: a different file under the same session still gets its own first nudge" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try makeCitedRepo(&sf);
    try writeDependentNode(&sf, "Dependent.md", "Cited");
    try sf.fx.writeRepoFile("lib/calc2.ml", "(* second file *)\nlet x = 1\n");
    try sf.writeIndexBin(&.{
        .{ .path = "lib/calc.ml", .node = "Cited.md" },
        .{ .path = "lib/calc2.ml", .node = "Cited.md" },
    });

    const first = try sf.edit("lib/calc.ml");
    defer if (first) |t| gpa.free(t);
    try testing.expect(first != null);

    const second = try sf.edit("lib/calc2.ml");
    defer if (second) |t| gpa.free(t);
    try testing.expect(second != null);
}

test "blast radius and correction merge into one context, not two" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try makeCitedRepo(&sf);
    try writeDependentNode(&sf, "Dependent.md", "Cited");
    const changed = try calcMlCustom(gpa, "Truncates toward zero.", 5);
    defer gpa.free(changed);
    try sf.fx.writeRepoFile("lib/calc.ml", changed);

    const text = (try sf.edit("lib/calc.ml")).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "grounding (lib/calc.ml:1-2)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Dependent") != null);
}

test "a malformed index is left alone, not overwritten with nothing" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try sf.commit("init");
    try sf.writeIndex();
    try sf.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo Node.md" }});

    const path = try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{sf.fx.work});
    defer gpa.free(path);
    const bytes = try Io.Dir.cwd().readFileAlloc(sf.fx.io(), path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    const before = try gpa.dupe(u8, bytes[0..@min(40, bytes.len)]);
    defer gpa.free(before);
    try Io.Dir.cwd().writeFile(sf.fx.io(), .{ .sub_path = path, .data = before });

    const text = try sf.edit("src/foo.ml");
    try testing.expectEqual(@as(?[]u8, null), text);

    const after = try Io.Dir.cwd().readFileAlloc(sf.fx.io(), path, gpa, .limited(1 << 20));
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
}

test "pruneOldSeenFiles deletes a week-old seen file but leaves a fresh one and unrelated files alone" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const state_dir = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.writeFile(io, .{ .sub_path = "synapse-blast-radius-seen-old", .data = "x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "synapse-blast-radius-seen-fresh", .data = "y\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "unrelated-file", .data = "z\n" });

    const old_path = try std.fmt.allocPrint(gpa, "{s}/synapse-blast-radius-seen-old", .{state_dir});
    defer gpa.free(old_path);
    const long_ago = Io.Timestamp.now(io, .real).nanoseconds - seen_file_max_age_ns - std.time.ns_per_s;
    try Io.Dir.cwd().setTimestamps(io, old_path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = long_ago } } });

    pruneOldSeenFiles(io, state_dir);

    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "synapse-blast-radius-seen-old", .{}));
    _ = try tmp.dir.statFile(io, "synapse-blast-radius-seen-fresh", .{});
    _ = try tmp.dir.statFile(io, "unrelated-file", .{});
}

test "an absent index is the no-namespace case, and costs nothing" {
    const gpa = testing.allocator;
    var sf = try StalenessFixture.init(gpa);
    defer sf.deinit();
    try sf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try sf.commit("init");
    // No vault Index.md, no _index.bin -- neither piece of the opt-in exists.

    const text = try sf.edit("src/foo.ml");
    try testing.expectEqual(@as(?[]u8, null), text);
}
