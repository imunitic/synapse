//! `synapse-bard verify` -- read-only integrity check across the whole
//! graph: every frontmatter ref (`BardFrontmatterExtractor`'s own `.ref`
//! tags) and every prose-body `[[wikilink]]` must resolve to a real entity
//! slug, and every `kinds:` value must be one of the ten settled values.
//! Never writes, never infers a relationship, never proposes a fix -- see
//! `designs/synapse-bard/synapse-bard — Link verification.md`.
//!
//! All three checks resolve against one slug set (`bard_cluster.allEntities`,
//! built once) and reuse `bard_frontmatter.wikilinkTargets` -- the same
//! substring scanner `BardFrontmatterExtractor` itself uses on frontmatter
//! scalars -- for the prose-body scan, rather than a second implementation
//! of wikilink-finding. `computeReport` is the testable core (fixture-based
//! unit tests below, the same tmpDir + `BardGraphStore` pattern
//! `sync_plan.zig`'s own tests use); `run` is a thin CLI door onto it.

const std = @import("std");
const adapters = @import("adapters");
const ports = @import("ports");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: synapse-bard verify
    \\
    \\Checks every entity's frontmatter refs and prose-body [[wikilinks]]
    \\resolve to a real entity, and every kinds: value matches the settled
    \\vocabulary. Read-only -- reports findings, fixes nothing. Exit 1 if
    \\any check found something.
    \\
;

/// The ten values `kinds:` entries are checked against -- settled in the
/// design note, not inferred from any real corpus (no `kinds:` field exists
/// in the real corpus yet).
const settled_kinds = [_][]const u8{
    "romantic_interest", "friend",       "teammate", "chain_of_command", "ally",
    "adversary",         "acquaintance", "family",   "mentor",           "other",
};

pub fn run(gpa: Allocator, io: Io, args: *std.process.Args.Iterator) !u8 {
    if (args.next()) |first| {
        // Help must not need an environment.
        if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
            std.debug.print("{s}", .{usage});
            return 0;
        }
        std.debug.print("synapse-bard verify: unexpected argument '{s}'\n{s}", .{ first, usage });
        return 2;
    }

    const roots = common.Roots.resolve(gpa, io) catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer roots.deinit(gpa);

    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, roots.graph_root);
    defer store.deinit();

    var report = try computeReport(gpa, io, roots.repo_root, store.store());
    defer report.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);

    try w.interface.print("broken frontmatter links: {d}\n", .{report.fm_misses.items.len});
    try w.interface.print("broken prose links: {d}\n", .{report.prose_misses.items.len});
    try w.interface.print("unknown kinds values: {d}\n", .{report.kind_misses.items.len});

    for (report.fm_misses.items) |m| try w.interface.print("{s}:{s} -> {s} (unresolved)\n", .{ m.file, m.field, m.target });
    for (report.prose_misses.items) |m| try w.interface.print("{s}:{s} -> {s} (unresolved)\n", .{ m.file, m.field, m.target });
    for (report.kind_misses.items) |m| try w.interface.print("{s}:{s} -> {s} (unresolved)\n", .{ m.file, m.field, m.target });

    if (report.tally.items.len != 0) {
        try w.interface.print("\nmention counts:\n", .{});
        for (report.tally.items) |t| try w.interface.print("{s}: {d}\n", .{ t.target, t.count });
    }

    try w.interface.flush();
    return if (report.totalFindings() != 0) 1 else 0;
}

/// One finding: `file` (repo-relative) and `target`/`field` are always
/// owned copies, `field` included even where a check has no real field
/// concept (`prose`/`kinds`, fixed labels) so `deinit` can free uniformly.
pub const Miss = struct {
    file: []const u8,
    field: []const u8,
    target: []const u8,
};

/// One resolved prose-body target's mention count -- how many distinct
/// entities' prose links to it, not total occurrences.
pub const Tally = struct {
    target: []const u8,
    count: u32,
};

pub const Report = struct {
    fm_misses: std.ArrayListUnmanaged(Miss) = .empty,
    prose_misses: std.ArrayListUnmanaged(Miss) = .empty,
    kind_misses: std.ArrayListUnmanaged(Miss) = .empty,
    tally: std.ArrayListUnmanaged(Tally) = .empty,

    pub fn deinit(self: *Report, gpa: Allocator) void {
        freeMisses(gpa, &self.fm_misses);
        freeMisses(gpa, &self.prose_misses);
        freeMisses(gpa, &self.kind_misses);
        for (self.tally.items) |t| gpa.free(t.target);
        self.tally.deinit(gpa);
    }

    pub fn totalFindings(self: Report) usize {
        return self.fm_misses.items.len + self.prose_misses.items.len + self.kind_misses.items.len;
    }
};

fn freeMisses(gpa: Allocator, list: *std.ArrayListUnmanaged(Miss)) void {
    for (list.items) |m| {
        gpa.free(m.file);
        gpa.free(m.field);
        gpa.free(m.target);
    }
    list.deinit(gpa);
}

/// The three checks, sharing one slug set built from `store` once. `store`
/// is read from only, matching `verify`'s read-only contract.
pub fn computeReport(gpa: Allocator, io: Io, repo_root: []const u8, store: ports.Store) !Report {
    const entries = try adapters.bard_cluster.allEntities(gpa, io, store);
    defer adapters.bard_cluster.freeSourceEntries(gpa, entries);

    var slugs: std.StringHashMapUnmanaged(void) = .empty;
    defer slugs.deinit(gpa);
    for (entries) |e| try slugs.put(gpa, e.slug, {});

    var report: Report = .{};
    errdefer report.deinit(gpa);

    var tally: std.StringHashMapUnmanaged(u32) = .empty;
    defer tally.deinit(gpa);
    defer {
        var it = tally.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
    }

    const paths = try gpa.alloc([]const u8, entries.len);
    defer gpa.free(paths);
    for (entries, 0..) |e, i| paths[i] = e.path;

    var ex: adapters.bard_frontmatter.BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const outcomes = try ex.port().extract(gpa, io, repo_root, paths);
    defer common.freeOutcomes(gpa, outcomes);

    for (entries, 0..) |e, i| {
        // Check 1 -- frontmatter ref resolution.
        switch (outcomes[i]) {
            .unsupported => {},
            .tags => |tags| for (tags) |t| {
                if (t.role != .ref) continue;
                if (slugs.contains(common.stripMdSuffix(t.name))) continue;
                try report.fm_misses.append(gpa, .{
                    .file = try gpa.dupe(u8, e.path),
                    .field = try gpa.dupe(u8, t.kind),
                    .target = try gpa.dupe(u8, t.name),
                });
            },
        }

        const full = try std.fs.path.join(gpa, &.{ repo_root, e.path });
        defer gpa.free(full);
        const src = Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(src);

        // Check 2 -- prose-body wikilink resolution, plus the mention-count
        // tally over resolved targets (near-free: already walking every
        // one to verify it resolves).
        if (proseBody(src)) |body| {
            const targets = try adapters.bard_frontmatter.wikilinkTargets(gpa, body);
            defer {
                for (targets) |t| gpa.free(t);
                gpa.free(targets);
            }

            var counted: std.StringHashMapUnmanaged(void) = .empty;
            defer counted.deinit(gpa);

            for (targets) |raw_target| {
                const target = common.stripMdSuffix(raw_target);
                if (!slugs.contains(target)) {
                    try report.prose_misses.append(gpa, .{
                        .file = try gpa.dupe(u8, e.path),
                        .field = try gpa.dupe(u8, "prose"),
                        .target = try gpa.dupe(u8, raw_target),
                    });
                    continue;
                }
                if (counted.contains(target)) continue; // already tallied for this entity
                try counted.put(gpa, target, {});

                const gop = try tally.getOrPut(gpa, target);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try gpa.dupe(u8, target);
                    gop.value_ptr.* = 0;
                }
                gop.value_ptr.* += 1;
            }
        }

        // Check 3 -- kinds: vocabulary conformance. Root-level field only,
        // same as `field_cmd.zig`'s own read; absent for anything that
        // isn't a character entity, which is exactly the files with no
        // `kinds:` field at all.
        if (try adapters.bard_frontmatter.rawField(gpa, src, "kinds")) |raw| {
            defer gpa.free(raw);
            const values = try kindsValues(gpa, raw);
            defer {
                for (values) |v| gpa.free(v);
                gpa.free(values);
            }
            for (values) |v| {
                if (isSettledKind(v)) continue;
                try report.kind_misses.append(gpa, .{
                    .file = try gpa.dupe(u8, e.path),
                    .field = try gpa.dupe(u8, "kinds"),
                    .target = try gpa.dupe(u8, v),
                });
            }
        }
    }

    var it = tally.iterator();
    while (it.next()) |kv| {
        try report.tally.append(gpa, .{ .target = try gpa.dupe(u8, kv.key_ptr.*), .count = kv.value_ptr.* });
    }
    std.mem.sort(Tally, report.tally.items, {}, tallyGreaterThan);

    return report;
}

/// Descending by mention count; ties broken alphabetically for a
/// deterministic, diff-stable order.
fn tallyGreaterThan(_: void, a: Tally, b: Tally) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.order(u8, a.target, b.target) == .lt;
}

/// Everything after the frontmatter block -- the same split `search_cmd.zig`
/// draws in reverse (it keeps `frontmatterBlock`, this keeps the rest).
/// `null` when `src` has no frontmatter at all (extraction would have
/// already refused it).
fn proseBody(src: []const u8) ?[]const u8 {
    const fm = adapters.bard_frontmatter.frontmatterBlock(src) orelse return null;
    return src[fm.len..];
}

/// `kinds:`'s raw field text (from `rawField`, key line included) parsed
/// into its list values, unquoted -- a flow list on the key's own line
/// (`kinds: ["a", "b"]`) or a block list on the lines below it (`kinds:\n
/// \  - "a"\n  - "b"`), the two shapes real frontmatter data uses for a
/// list of plain strings. Not a general YAML parser, same as the rest of
/// this adapter: just enough for `kinds:`'s own fixed shape.
fn kindsValues(gpa: Allocator, raw: []const u8) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |v| gpa.free(v);
        out.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    const first = lines.next() orelse return out.toOwnedSlice(gpa);
    const colon = std.mem.indexOfScalar(u8, first, ':') orelse return out.toOwnedSlice(gpa);
    const value = std.mem.trim(u8, first[colon + 1 ..], " ");

    if (value.len != 0) {
        if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
            const inner = std.mem.trim(u8, value[1 .. value.len - 1], " ");
            var elems = std.mem.splitScalar(u8, inner, ',');
            while (elems.next()) |elem| {
                const trimmed = std.mem.trim(u8, elem, " ");
                if (trimmed.len == 0) continue;
                try out.append(gpa, try gpa.dupe(u8, unquote(trimmed)));
            }
        }
        return out.toOwnedSlice(gpa);
    }

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (!std.mem.startsWith(u8, trimmed, "- ")) continue;
        try out.append(gpa, try gpa.dupe(u8, unquote(std.mem.trim(u8, trimmed[2..], " "))));
    }
    return out.toOwnedSlice(gpa);
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0])
        return value[1 .. value.len - 1];
    return value;
}

fn isSettledKind(v: []const u8) bool {
    for (settled_kinds) |k| if (std.mem.eql(u8, v, k)) return true;
    return false;
}

const testing = std.testing;

fn writeCluster(gpa: Allocator, store: *adapters.bard_graph_store.BardGraphStore, node: []const u8, title: []const u8, entries: []const adapters.bard_cluster.WriteEntry) !void {
    const body = try adapters.bard_cluster.renderClusterBody(gpa, title, entries, "");
    defer gpa.free(body);
    _ = try store.store().write(testing.io, node, body);
}

test "computeReport reports a dangling frontmatter ref" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.createDirPath(testing.io, "characters");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "characters/a.md",
        .data = "---\nname: A\ntemplate: character\nally: \"[[missing-entity]]\"\n---\n\nProse body.\n",
    });

    const graph_root = try std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{root});
    defer gpa.free(graph_root);
    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, graph_root);
    defer store.deinit();
    try writeCluster(gpa, &store, "Characters.md", "Characters", &.{.{ .slug = "a", .path = "characters/a.md", .name = "A" }});

    var report = try computeReport(gpa, testing.io, root, store.store());
    defer report.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), report.fm_misses.items.len);
    try testing.expectEqualStrings("missing-entity", report.fm_misses.items[0].target);
    try testing.expectEqualStrings("characters/a.md", report.fm_misses.items[0].file);
    try testing.expectEqual(@as(usize, 0), report.prose_misses.items.len);
    try testing.expectEqual(@as(usize, 0), report.kind_misses.items.len);
    try testing.expectEqual(@as(usize, 1), report.totalFindings());
}

test "computeReport reports a dangling prose-body wikilink" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.createDirPath(testing.io, "characters");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "characters/a.md",
        .data = "---\nname: A\ntemplate: character\n---\n\nSees [[missing-entity]] in the distance.\n",
    });

    const graph_root = try std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{root});
    defer gpa.free(graph_root);
    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, graph_root);
    defer store.deinit();
    try writeCluster(gpa, &store, "Characters.md", "Characters", &.{.{ .slug = "a", .path = "characters/a.md", .name = "A" }});

    var report = try computeReport(gpa, testing.io, root, store.store());
    defer report.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), report.fm_misses.items.len);
    try testing.expectEqual(@as(usize, 1), report.prose_misses.items.len);
    try testing.expectEqualStrings("missing-entity", report.prose_misses.items[0].target);
    try testing.expectEqual(@as(usize, 0), report.kind_misses.items.len);
}

test "computeReport reports an unknown kinds value" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.createDirPath(testing.io, "characters");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "characters/a.md",
        .data = "---\nname: A\ntemplate: character\nkinds: [\"bogus\"]\n---\n\nProse.\n",
    });

    const graph_root = try std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{root});
    defer gpa.free(graph_root);
    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, graph_root);
    defer store.deinit();
    try writeCluster(gpa, &store, "Characters.md", "Characters", &.{.{ .slug = "a", .path = "characters/a.md", .name = "A" }});

    var report = try computeReport(gpa, testing.io, root, store.store());
    defer report.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), report.kind_misses.items.len);
    try testing.expectEqualStrings("bogus", report.kind_misses.items[0].target);
    try testing.expectEqualStrings("kinds", report.kind_misses.items[0].field);
}

test "computeReport finds nothing for a fully-resolving fixture -- zero findings" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.createDirPath(testing.io, "characters");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "characters/a.md",
        .data = "---\nname: A\ntemplate: character\nkinds: [\"friend\"]\nally: \"[[b]]\"\n---\n\nMentions [[b|B]] warmly.\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "characters/b.md",
        .data = "---\nname: B\ntemplate: character\n---\n\nProse only, no links.\n",
    });

    const graph_root = try std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{root});
    defer gpa.free(graph_root);
    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, graph_root);
    defer store.deinit();
    try writeCluster(gpa, &store, "Characters.md", "Characters", &.{
        .{ .slug = "a", .path = "characters/a.md", .name = "A" },
        .{ .slug = "b", .path = "characters/b.md", .name = "B" },
    });

    var report = try computeReport(gpa, testing.io, root, store.store());
    defer report.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), report.totalFindings());
}

test "computeReport's mention tally counts distinct entities, not raw occurrences" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.createDirPath(testing.io, "characters");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "characters/a.md",
        .data = "---\nname: A\ntemplate: character\n---\n\nSees [[c|C]] then [[c]] again -- twice in one file.\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "characters/b.md",
        .data = "---\nname: B\ntemplate: character\n---\n\nAlso mentions [[c|C]].\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "characters/c.md",
        .data = "---\nname: C\ntemplate: character\n---\n\nNothing here.\n",
    });

    const graph_root = try std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{root});
    defer gpa.free(graph_root);
    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, graph_root);
    defer store.deinit();
    try writeCluster(gpa, &store, "Characters.md", "Characters", &.{
        .{ .slug = "a", .path = "characters/a.md", .name = "A" },
        .{ .slug = "b", .path = "characters/b.md", .name = "B" },
        .{ .slug = "c", .path = "characters/c.md", .name = "C" },
    });

    var report = try computeReport(gpa, testing.io, root, store.store());
    defer report.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), report.totalFindings());
    try testing.expectEqual(@as(usize, 1), report.tally.items.len);
    try testing.expectEqualStrings("c", report.tally.items[0].target);
    try testing.expectEqual(@as(u32, 2), report.tally.items[0].count);
}
