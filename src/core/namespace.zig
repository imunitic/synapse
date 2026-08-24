//! Per-file declared namespace, and the directory-level divergence table it
//! feeds, computed before any inference step reads it.
//!
//! A file's declared namespace is what its own ecosystem says (an in-file
//! declaration keyword, or a build manifest's declared unit name); the
//! directory holding it is what the filesystem says. When the two disagree
//! across most of a directory, searching for the directory's own name later
//! comes back empty, because the code calls itself something else.
//!
//! A rule, not a grammar query: existing tags queries never capture an
//! in-file namespace declaration for every ecosystem, some ecosystems have
//! no such node at all, and some ecosystems' closest capture names a nested
//! sub-unit rather than the library a file belongs to (that lives in a
//! sibling build manifest instead). Every rule is either in the file itself
//! (an in-file declaration line) or in the nearest ancestor build file (a
//! manifest's declared module/crate/package name).
//!
//! A prefix and a terminator, not a regex: every case above is "find the
//! line starting with X, take everything up to Y." A prefix/terminator
//! scan is a handful of `indexOf` calls and needs no subprocess.
//!
//! No per-language curation ships. `Registry` reads
//! `~/.claude/synapse-namespace-rules.conf`, keyed by extension, same
//! discovery contract as the grammar registry: absent means not discovered
//! yet, and a new ecosystem is a config edit, never a code change.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Kind = enum { in_file, build_file };

/// An additional identity on the *same* nearest-ancestor file as the rule's
/// own primary `prefix`/`terminator` -- some ecosystems give one file more
/// than one valid self-reference: an internal name the code calls itself,
/// and a separate published name a dependent's own dependency declaration
/// actually uses, genuinely different strings for the same file.
pub const Alias = struct {
    prefix: []const u8,
    terminator: ?[]const u8 = null,
};

/// One extension's rule. `file` is set only for `.build_file` -- the name to
/// search ancestor directories for. `terminator` null means to end of line
/// (trimmed). `aliases` is a real, unbounded slice -- the conf format is an
/// array because there is no real reason to cap how many identities one
/// file can have; `Registry.ruleFor` allocates it (empty, no allocation,
/// for the overwhelmingly common no-alias case).
pub const Rule = struct {
    kind: Kind,
    file: ?[]const u8 = null,
    prefix: []const u8,
    terminator: ?[]const u8 = null,
    aliases: []const Alias = &.{},
};

/// `~/.claude/synapse-namespace-rules.conf`, keyed by bare extension.
/// Absent or unreadable opens as `{}`, a supported state, not an error.
pub const Registry = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn load(gpa: Allocator, io: Io, path: []const u8) !Registry {
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 << 20)) catch |e| switch (e) {
            error.FileNotFound => try gpa.dupe(u8, "{}"),
            else => return e,
        };
        defer gpa.free(bytes);
        return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
    }

    pub fn deinit(self: *Registry) void {
        self.parsed.deinit();
    }

    /// Whether the registry has any rule -- lets a caller skip the whole
    /// pass rather than walk every file to learn it has no rule.
    pub fn isEmpty(self: Registry) bool {
        return switch (self.parsed.value) {
            .object => |o| o.count() == 0,
            else => true,
        };
    }

    /// `gpa` backs `Rule.aliases` when the rule actually has any -- the
    /// overwhelmingly common no-alias case allocates nothing at all.
    pub fn ruleFor(self: Registry, gpa: Allocator, ext: []const u8) !?Rule {
        const obj = switch (self.parsed.value) {
            .object => |o| o.get(ext) orelse return null,
            else => return null,
        };
        const fields = switch (obj) {
            .object => |o| o,
            else => return null,
        };
        const kind_str = fields.get("kind") orelse return null;
        if (kind_str != .string) return null;
        const kind: Kind = if (std.mem.eql(u8, kind_str.string, "in-file"))
            .in_file
        else if (std.mem.eql(u8, kind_str.string, "build-file"))
            .build_file
        else
            return null;

        const prefix_v = fields.get("prefix") orelse return null;
        if (prefix_v != .string or prefix_v.string.len == 0) return null;

        const file: ?[]const u8 = blk: {
            const v = fields.get("file") orelse break :blk null;
            break :blk if (v == .string and v.string.len != 0) v.string else null;
        };
        if (kind == .build_file and file == null) return null;

        const terminator: ?[]const u8 = blk: {
            const v = fields.get("terminator") orelse break :blk null;
            break :blk if (v == .string and v.string.len != 0) v.string else null;
        };

        var rule: Rule = .{ .kind = kind, .file = file, .prefix = prefix_v.string, .terminator = terminator };

        if (fields.get("aliases")) |aliases_v| if (aliases_v == .array and aliases_v.array.items.len != 0) {
            var built: std.ArrayListUnmanaged(Alias) = .empty;
            for (aliases_v.array.items) |item| {
                if (item != .object) continue;
                const alias_prefix_v = item.object.get("prefix") orelse continue;
                if (alias_prefix_v != .string or alias_prefix_v.string.len == 0) continue;
                const alias_terminator: ?[]const u8 = blk: {
                    const v = item.object.get("terminator") orelse break :blk null;
                    break :blk if (v == .string and v.string.len != 0) v.string else null;
                };
                try built.append(gpa, .{ .prefix = alias_prefix_v.string, .terminator = alias_terminator });
            }
            rule.aliases = try built.toOwnedSlice(gpa);
        };

        return rule;
    }
};

/// The first `prefix`-led line in `content`, from `prefix` to `terminator`
/// (or end of line), trimmed. Null when no line matches or the value is
/// blank. Line by line, not a whole-content search, to avoid matching a
/// prefix inside a comment or string. Tracks one bit of "inside `/* */`"
/// across lines -- not a real comment parser, just enough to skip a
/// commented-out declaration (both `Rule.kind == .in_file` ecosystems here
/// use C-style block comments).
pub fn extractField(content: []const u8, prefix: []const u8, terminator: ?[]const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_block_comment = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (in_block_comment) {
            if (std.mem.indexOf(u8, line, "*/") != null) in_block_comment = false;
            continue;
        }
        if (std.mem.indexOf(u8, line, "/*")) |start| {
            // Skip the whole line even if it also closes the comment --
            // sharing a line with `/*` isn't the "alone on its line" shape.
            in_block_comment = std.mem.indexOf(u8, line[start..], "*/") == null;
            continue;
        }
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        const value = if (terminator) |t|
            rest[0 .. std.mem.indexOf(u8, rest, t) orelse continue]
        else
            std.mem.trimEnd(u8, rest, " \t\r");
        const trimmed = std.mem.trim(u8, value, " \t\r");
        if (trimmed.len == 0) continue;
        return trimmed;
    }
    return null;
}

/// Containing directory, repo-relative -- everything before the last `/`,
/// or `""` at the root. Hand-rolled, not `std.fs.path`: these paths come
/// from `git ls-files` and always use `/`, while `std.fs.path` would also
/// split on `\` on Windows.
pub fn dirOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

/// Filename -- everything after the last `/`, or the whole path if none.
pub fn baseOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

/// The namespace recorded for `dir`, or the nearest ancestor's -- walking
/// up one segment at a time to the repo root. `by_dir` maps a build file's
/// directory to its declared namespace, built once up front.
pub fn nearestNamespace(by_dir: *const std.StringHashMapUnmanaged([]const u8), dir: []const u8) ?[]const u8 {
    var at = dir;
    while (true) {
        if (by_dir.get(at)) |ns| return ns;
        if (at.len == 0) return null;
        at = dirOf(at);
    }
}

/// Dir-keyed declared-value map for one build-file rule, memoized in
/// `cache` so a repo with many files sharing one rule (every file under a
/// library scanning the same nearest build file) reads `kept` once per
/// distinct filename. Shared infrastructure: any per-file extraction built
/// on this registry's rule shape needs exactly this "nearest ancestor
/// build file's declared value" walk -- a namespace divergence table, a
/// dependency-edge extraction, or any future one, all the same way.
pub fn buildFileMap(
    arena: Allocator,
    io: Io,
    root: []const u8,
    kept: []const []const u8,
    file_name: []const u8,
    prefix: []const u8,
    terminator: ?[]const u8,
    cache: *std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)),
) !*const std.StringHashMapUnmanaged([]const u8) {
    if (cache.getPtr(file_name)) |m| return m;

    var m: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (kept) |p| {
        if (!std.mem.eql(u8, baseOf(p), file_name)) continue;
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, p });
        const content = Io.Dir.cwd().readFileAlloc(io, full, arena, .limited(4 << 20)) catch continue;
        const raw = extractField(content, prefix, terminator) orelse continue;
        try m.put(arena, dirOf(p), raw);
    }
    try cache.put(arena, file_name, m);
    return cache.getPtr(file_name).?;
}

/// One file's declared identity -- a namespace, or (via `Rule.aliases`) one
/// of the additional identities the same nearest-ancestor file also
/// declares.
pub const NamespaceRow = struct {
    path: []const u8,
    namespace: []const u8,
};

/// One `prefix`/`terminator` extraction against `p`, `.in_file` or
/// `.build_file` per `kind` -- the switch `computePerFile` needs once per
/// identity (the rule's own primary pair, then each of its aliases), each
/// against its own `cache` so a different prefix on the same nearest
/// ancestor file never collides with another's memoized result.
fn extractOne(
    arena: Allocator,
    io: Io,
    root: []const u8,
    kept: []const []const u8,
    p: []const u8,
    kind: Kind,
    file: ?[]const u8,
    prefix: []const u8,
    terminator: ?[]const u8,
    cache: *std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)),
) !?[]const u8 {
    return switch (kind) {
        .in_file => blk: {
            const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, p });
            const content = Io.Dir.cwd().readFileAlloc(io, full, arena, .limited(4 << 20)) catch break :blk null;
            break :blk extractField(content, prefix, terminator);
        },
        .build_file => blk: {
            const map = try buildFileMap(arena, io, root, kept, file.?, prefix, terminator, cache);
            break :blk nearestNamespace(map, dirOf(p));
        },
    };
}

/// Every path in `kept` mapped to its own declared namespace(s) -- one row
/// per identity that resolved to a real value (more than one when the
/// rule has aliases), kept *per file* rather than aggregated per group the
/// way `synapse vocab`'s own `namespaces.tsv` is. The per-file signal
/// `core/links.zig`'s import-edge resolution needs: which library does a
/// candidate definition's own file actually belong to, under any of the
/// names a dependent might call it. Sorted `path` ascending, `namespace`
/// ascending within a path, so two runs over an unchanged repo are
/// byte-identical.
pub fn computePerFile(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    root: []const u8,
    kept: []const []const u8,
    registry: Registry,
) !std.ArrayListUnmanaged(NamespaceRow) {
    var out: std.ArrayListUnmanaged(NamespaceRow) = .empty;
    errdefer out.deinit(gpa);
    if (registry.isEmpty()) return out;

    var build_maps: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty;
    // One cache per distinct alias *prefix* (not a fixed count): the same
    // (file_name, prefix) pair always extracts the same value, but two
    // different aliases must never share a cache, since `buildFileMap`'s
    // own memoization keys only on `file_name`.
    var alias_build_maps: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8))) = .empty;

    for (kept) |p| {
        const base = baseOf(p);
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse continue;
        if (dot == 0) continue; // a leading-dot file has no extension
        const ext = base[dot + 1 ..];
        const rule = (try registry.ruleFor(arena, ext)) orelse continue;

        if (try extractOne(arena, io, root, kept, p, rule.kind, rule.file, rule.prefix, rule.terminator, &build_maps)) |v| {
            try out.append(gpa, .{ .path = p, .namespace = v });
        }
        for (rule.aliases) |alias| {
            const cache_gop = try alias_build_maps.getOrPut(arena, alias.prefix);
            if (!cache_gop.found_existing) cache_gop.value_ptr.* = .empty;
            if (try extractOne(arena, io, root, kept, p, rule.kind, rule.file, alias.prefix, alias.terminator, cache_gop.value_ptr)) |v| {
                try out.append(gpa, .{ .path = p, .namespace = v });
            }
        }
    }

    std.mem.sort(NamespaceRow, out.items, {}, lessByPathThenNamespace);
    return out;
}

fn lessByPathThenNamespace(_: void, a: NamespaceRow, b: NamespaceRow) bool {
    return switch (std.mem.order(u8, a.path, b.path)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.namespace, b.namespace) == .lt,
    };
}

const testing = std.testing;

test "extractField: prefix to a terminator, trimmed" {
    try testing.expectEqualStrings(
        "com.example.billing",
        extractField("package com.example.billing;\n", "package ", ";").?,
    );
}

test "extractField: no terminator means to end of line" {
    try testing.expectEqualStrings(
        "github.com/acme/widget",
        extractField("module github.com/acme/widget\n\ngo 1.22\n", "module ", null).?,
    );
}

test "extractField: leading whitespace before the prefix is skipped" {
    try testing.expectEqualStrings("widget", extractField("  (name widget)\n", "(name ", ")").?);
}

test "extractField: matches the first qualifying line, not a later one" {
    try testing.expectEqualStrings(
        "first",
        extractField("package first;\n// package second;\n", "package ", ";").?,
    );
}

test "extractField: a prefix that never appears is null" {
    try testing.expectEqual(@as(?[]const u8, null), extractField("class Foo {}\n", "package ", ";"));
}

test "extractField: an unterminated prefix line is skipped, not truncated" {
    try testing.expectEqualStrings(
        "real",
        extractField("package com.example\npackage real;\n", "package ", ";").?,
    );
}

test "extractField: a blank extracted value is null, not empty" {
    try testing.expectEqual(@as(?[]const u8, null), extractField("package ;\n", "package ", ";"));
}

test "extractField: a multi-line block comment does not smuggle in a fake declaration" {
    try testing.expectEqualStrings(
        "real",
        extractField(
            "/*\npackage com.example.old;\n*/\npackage real;\n",
            "package ",
            ";",
        ).?,
    );
}

test "extractField: a single-line block comment is skipped too" {
    try testing.expectEqualStrings(
        "real",
        extractField("/* package com.example.old; */\npackage real;\n", "package ", ";").?,
    );
}

test "extractField: no real declaration after a block comment is still null" {
    try testing.expectEqual(
        @as(?[]const u8, null),
        extractField("/*\npackage com.example.old;\n*/\nclass Foo {}\n", "package ", ";"),
    );
}

test "dirOf and baseOf split on the last slash" {
    try testing.expectEqualStrings("src/core", dirOf("src/core/vocab.zig"));
    try testing.expectEqualStrings("vocab.zig", baseOf("src/core/vocab.zig"));
    try testing.expectEqualStrings("", dirOf("README.md"));
    try testing.expectEqualStrings("README.md", baseOf("README.md"));
}

test "nearestNamespace: an exact match wins over a farther ancestor" {
    const gpa = testing.allocator;
    var by_dir: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer by_dir.deinit(gpa);
    try by_dir.put(gpa, "", "root_lib");
    try by_dir.put(gpa, "widget/src", "widget");

    try testing.expectEqualStrings("widget", nearestNamespace(&by_dir, "widget/src").?);
}

test "nearestNamespace: walks up past a directory with no build file" {
    const gpa = testing.allocator;
    var by_dir: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer by_dir.deinit(gpa);
    try by_dir.put(gpa, "widget/src", "widget");

    try testing.expectEqualStrings("widget", nearestNamespace(&by_dir, "widget/src/nested/deep").?);
}

test "nearestNamespace: no ancestor recorded anything is null" {
    const gpa = testing.allocator;
    var by_dir: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer by_dir.deinit(gpa);
    try by_dir.put(gpa, "other/crate", "other");

    try testing.expectEqual(@as(?[]const u8, null), nearestNamespace(&by_dir, "widget/src"));
}

test "Registry: an absent file opens empty, not an error" {
    const gpa = testing.allocator;
    var reg = try Registry.load(gpa, testing.io, "/nonexistent/synapse-namespace-rules.conf");
    defer reg.deinit();
    try testing.expect(reg.isEmpty());
    try testing.expectEqual(@as(?Rule, null), try reg.ruleFor(gpa, "xx"));
}

test "Registry: an in-file rule round-trips every field" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"xx": {"kind": "in-file", "prefix": "package ", "terminator": ";"}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const rule = (try reg.ruleFor(gpa, "xx")).?;
    try testing.expectEqual(Kind.in_file, rule.kind);
    try testing.expectEqualStrings("package ", rule.prefix);
    try testing.expectEqualStrings(";", rule.terminator.?);
    try testing.expectEqual(@as(?[]const u8, null), rule.file);
}

test "Registry: a build-file rule without terminator means end of line" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"yy": {"kind": "build-file", "file": "manifest.yy", "prefix": "module "}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const rule = (try reg.ruleFor(gpa, "yy")).?;
    try testing.expectEqual(Kind.build_file, rule.kind);
    try testing.expectEqualStrings("manifest.yy", rule.file.?);
    try testing.expectEqual(@as(?[]const u8, null), rule.terminator);
}

test "Registry: a build-file rule missing 'file' is not a rule" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"yy": {"kind": "build-file", "prefix": "module "}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    try testing.expectEqual(@as(?Rule, null), try reg.ruleFor(gpa, "yy"));
}

test "Registry: a dependency-declaration rule (multi-token value) needs no shape change -- extractField returns the whole span" {
    // A dependency declaration's value is a list, not a single scalar --
    // confirming the existing Rule/extractField shape already handles this
    // (space-separated, split by the caller) is what lets
    // `synapse-dependency-rules.conf` reuse this registry unchanged rather
    // than needing a second rule type.
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"xx": {"kind": "build-file", "file": "build.deps", "prefix": "depends ", "terminator": ")"}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const rule = (try reg.ruleFor(gpa, "xx")).?;
    try testing.expectEqual(Kind.build_file, rule.kind);
    try testing.expectEqualStrings("build.deps", rule.file.?);

    const value = extractField("depends widget str)\n", rule.prefix, rule.terminator).?;
    try testing.expectEqualStrings("widget str", value);
}

test "Registry: an unregistered extension is null, and the registry is not empty because of it" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"xx": {"kind": "in-file", "prefix": "package ", "terminator": ";"}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    try testing.expectEqual(@as(?Rule, null), try reg.ruleFor(gpa, "zz"));
    try testing.expect(!reg.isEmpty());
}

test "computePerFile: a build-file rule resolves every file under it to the nearest ancestor's declared value" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "widget/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "widget/src/build.deps", .data = "name widget\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "widget/src/main.xx", .data = "run\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"xx": {"kind": "build-file", "file": "build.deps", "prefix": "name "}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const kept = [_][]const u8{ "widget/src/build.deps", "widget/src/main.xx" };
    var out = try computePerFile(gpa, arena_state.allocator(), io, root, &kept, reg);
    defer out.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("widget/src/main.xx", out.items[0].path);
    try testing.expectEqualStrings("widget", out.items[0].namespace);
}

test "computePerFile: an empty registry short-circuits to no rows without touching any file" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var reg = try Registry.load(gpa, io, "/nonexistent/synapse-namespace-rules.conf");
    defer reg.deinit();

    const kept = [_][]const u8{"widget/src/main.xx"};
    var out = try computePerFile(gpa, arena_state.allocator(), io, "/nonexistent-root", &kept, reg);
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "computePerFile: an in-file rule reads the file itself, no ancestor search" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/main.yy", .data = "package pkg.widget\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"yy": {"kind": "in-file", "prefix": "package "}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const kept = [_][]const u8{"pkg/main.yy"};
    var out = try computePerFile(gpa, arena_state.allocator(), io, root, &kept, reg);
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("pkg.widget", out.items[0].namespace);
}

test "computePerFile: a rule's aliases add extra identities for the same file, from the same nearest-ancestor build file" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "widget/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "widget/src/build.deps", .data = "name widget\npublic widget-pub\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "widget/src/main.xx", .data = "run\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"xx": {"kind": "build-file", "file": "build.deps", "prefix": "name ",
        \\        "aliases": [{"prefix": "public "}]}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const kept = [_][]const u8{ "widget/src/build.deps", "widget/src/main.xx" };
    var out = try computePerFile(gpa, arena_state.allocator(), io, root, &kept, reg);
    defer out.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("widget/src/main.xx", out.items[0].path);
    try testing.expectEqualStrings("widget", out.items[0].namespace);
    try testing.expectEqualStrings("widget/src/main.xx", out.items[1].path);
    try testing.expectEqualStrings("widget-pub", out.items[1].namespace);
}

test "computePerFile: an alias with no match for this file contributes nothing, primary value still returned" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "widget/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "widget/src/build.deps", .data = "name widget\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "widget/src/main.xx", .data = "run\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"xx": {"kind": "build-file", "file": "build.deps", "prefix": "name ",
        \\        "aliases": [{"prefix": "public "}]}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const kept = [_][]const u8{ "widget/src/build.deps", "widget/src/main.xx" };
    var out = try computePerFile(gpa, arena_state.allocator(), io, root, &kept, reg);
    defer out.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("widget", out.items[0].namespace);
}
