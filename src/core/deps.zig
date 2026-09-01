//! `_deps.tsv`: each tracked file's own declared build/import dependencies,
//! one row per `path <TAB> library` edge -- `core/links.zig`'s import-edge
//! disambiguation signal for a name defined in more than one node (see its
//! own module docstring, "a symbol defined in more than one node is not
//! rare, it is ambiguous").
//!
//! Its own artifact, not a new column on `_refs.tsv`: this is one row per
//! *file*, `_refs.tsv` is one row per reference *occurrence* -- denormalizing
//! a per-file fact onto every ref row from that file would repeat it
//! redundantly across every consumer of `_refs.tsv`, including ones that
//! don't care about import resolution.
//!
//! Reuses `core/namespace.zig`'s `Rule`/`Registry`/`extractField`/`dirOf`/
//! `nearestNamespace`/`buildFileMap` unchanged -- a dependency declaration
//! is extracted the same prefix/terminator way a namespace declaration is,
//! just answering "what does this file depend on" instead of "what is this
//! file." Kept in
//! its own conf file (`synapse-dependency-rules.conf`), not a second key on
//! `synapse-namespace-rules.conf`'s existing rows: an extension can need
//! both facts (what a file *is*, what it *depends on*) at once, and a rule
//! per extension leaves no room for two facts on one key.
//!
//! Ships with no committed rules of its own -- same as `synapse-namespace-
//! rules.conf` and `synapse-grammars.conf` -- so no ecosystem is
//! special-cased in the default install. A rule is real research the first
//! time a language is actually oriented in, verified against a real file,
//! never pre-seeded from general knowledge (see `synapse-orientation`'s own
//! skill doc for the discovery procedure).

const std = @import("std");
const namespace = @import("namespace.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// One file-depends-on-library edge.
pub const Row = struct {
    path: []const u8,
    library: []const u8,
};

/// `path <TAB> library`. The artifact's own contract, parsed the same way
/// `refs.parseRow` parses `_refs.tsv`: a truncated line is skipped, not
/// fatal, since the index is derived and rebuilt.
pub fn parseRow(line: []const u8) ?Row {
    var it = std.mem.splitScalar(u8, line, '\t');
    const path = it.next() orelse return null;
    const library = it.next() orelse return null;
    return .{ .path = path, .library = library };
}

/// The raw prefix-to-terminator span, split into individual library/module
/// names. Whitespace covers a build-file rule whose declared value is a
/// list (`prefix a b c terminator`); a comma is also accepted so a rule for
/// a comma-separated import list needs no extraction-side change, only a
/// conf entry. A plain single-name value comes back as one token either
/// way.
fn splitLibraries(gpa: Allocator, raw: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n,");
    while (it.next()) |tok| try out.append(gpa, tok);
    return out.toOwnedSlice(gpa);
}

/// One `Row` per declared dependency, across every path in `kept` whose
/// extension has a rule in `registry` -- sorted `path` ascending, `library`
/// ascending within a path, so two runs over an unchanged repo are
/// byte-identical. `kept` is repo-relative paths (as `git ls-files` and
/// `synapse enumerate` produce); `root` is the repo's real filesystem root,
/// used only to open files.
pub fn compute(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    root: []const u8,
    kept: []const []const u8,
    registry: namespace.Registry,
) !std.ArrayListUnmanaged(Row) {
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    errdefer rows.deinit(gpa);
    if (registry.isEmpty()) return rows;

    var build_maps: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty;

    for (kept) |p| {
        const base = namespace.baseOf(p);
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse continue;
        if (dot == 0) continue; // a leading-dot file has no extension
        const ext = base[dot + 1 ..];
        const rule = (try registry.ruleFor(arena, ext)) orelse continue;

        const raw: ?[]const u8 = switch (rule.kind) {
            .in_file => blk: {
                const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, p });
                const content = Io.Dir.cwd().readFileAlloc(io, full, arena, .limited(4 << 20)) catch break :blk null;
                break :blk namespace.extractField(content, rule.prefix, rule.terminator);
            },
            .build_file => blk: {
                const file_name = rule.file.?;
                const map = try namespace.buildFileMap(arena, io, root, kept, file_name, rule.prefix, rule.terminator, &build_maps);
                break :blk namespace.nearestNamespace(map, namespace.dirOf(p));
            },
        };
        const value = raw orelse continue;

        const libraries = try splitLibraries(gpa, value);
        defer gpa.free(libraries);
        for (libraries) |lib| try rows.append(gpa, .{ .path = p, .library = lib });
    }

    std.mem.sort(Row, rows.items, {}, lessByPathThenLibrary);
    return rows;
}

fn lessByPathThenLibrary(_: void, a: Row, b: Row) bool {
    return switch (std.mem.order(u8, a.path, b.path)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.library, b.library) == .lt,
    };
}

/// `path <TAB> library`, one line per row.
pub fn writeRow(w: *std.Io.Writer, r: Row) !void {
    try w.print("{s}\t{s}\n", .{ r.path, r.library });
}

const testing = std.testing;

test "parseRow: splits path and library on the tab" {
    const row = parseRow("widget/build.deps\twidget").?;
    try testing.expectEqualStrings("widget/build.deps", row.path);
    try testing.expectEqualStrings("widget", row.library);
}

test "parseRow: a truncated line is null, not a crash" {
    try testing.expectEqual(@as(?Row, null), parseRow("just-a-path"));
}

test "compute: a build-file rule finds the nearest ancestor build file and splits its declared list" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "widget/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "widget/src/build.deps", .data = "name widget\ndepends gadget str\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "widget/src/main.xx", .data = "run\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"xx": {"kind": "build-file", "file": "build.deps", "prefix": "depends "}}
    , .{});
    var reg: namespace.Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const kept = [_][]const u8{ "widget/src/build.deps", "widget/src/main.xx" };
    var rows = try compute(gpa, arena_state.allocator(), io, root, &kept, reg);
    defer rows.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqualStrings("widget/src/main.xx", rows.items[0].path);
    try testing.expectEqualStrings("gadget", rows.items[0].library);
    try testing.expectEqualStrings("widget/src/main.xx", rows.items[1].path);
    try testing.expectEqualStrings("str", rows.items[1].library);
}

test "compute: two extensions' rules sharing a build file, but different prefixes, extract independently" {
    // The exact hazard `namespace.buildFileMap`'s own cache key now closes:
    // before it disambiguated by (file_name, prefix, terminator) instead of
    // file_name alone, the second rule processed against a shared build
    // file silently got the first rule's memoized map here too, the same
    // as it did in namespace.computePerFile.
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "widget/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "widget/src/build.deps", .data = "depends gadget\nrequires thing\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "widget/src/main.xx", .data = "run\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "widget/src/main.yy", .data = "run\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"xx": {"kind": "build-file", "file": "build.deps", "prefix": "depends "},
        \\ "yy": {"kind": "build-file", "file": "build.deps", "prefix": "requires "}}
    , .{});
    var reg: namespace.Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const kept = [_][]const u8{ "widget/src/build.deps", "widget/src/main.xx", "widget/src/main.yy" };
    var rows = try compute(gpa, arena_state.allocator(), io, root, &kept, reg);
    defer rows.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqualStrings("widget/src/main.xx", rows.items[0].path);
    try testing.expectEqualStrings("gadget", rows.items[0].library);
    try testing.expectEqualStrings("widget/src/main.yy", rows.items[1].path);
    try testing.expectEqualStrings("thing", rows.items[1].library);
}

test "compute: a file with no rule for its extension contributes no rows" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"xx": {"kind": "build-file", "file": "build.deps", "prefix": "depends "}}
    , .{});
    var reg: namespace.Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const kept = [_][]const u8{"README.md"};
    var rows = try compute(gpa, arena_state.allocator(), io, root, &kept, reg);
    defer rows.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}

test "compute: an empty registry short-circuits to no rows without touching any file" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var reg = try namespace.Registry.load(gpa, io, "/nonexistent/synapse-dependency-rules.conf");
    defer reg.deinit();

    const kept = [_][]const u8{"widget/src/main.xx"};
    var rows = try compute(gpa, arena_state.allocator(), io, "/nonexistent-root", &kept, reg);
    defer rows.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}

test "compute: an in-file rule reads the file itself, no ancestor search" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/main.yy", .data = "uses alpha, beta\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"yy": {"kind": "in-file", "prefix": "uses "}}
    , .{});
    var reg: namespace.Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const kept = [_][]const u8{"pkg/main.yy"};
    var rows = try compute(gpa, arena_state.allocator(), io, root, &kept, reg);
    defer rows.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqualStrings("alpha", rows.items[0].library);
    try testing.expectEqualStrings("beta", rows.items[1].library);
}
