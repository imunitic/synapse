//! The code profile's Extractor: tags via a statically-linked libtree-sitter
//! behind the port, plus in-process registry resolution and a repo-scoped
//! cache -- what `synapse-tags.sh` delegated to the tree-sitter CLI and `jq`.

const std = @import("std");
const model = @import("model");
const ports = @import("ports");
const tag_line = @import("core").tag_line;

/// libtree-sitter, linked statically. Only this module sees it -- `core`
/// and `adapters` don't, keeping other builds free of it and the C
/// toolchain grammars need.
pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

/// ABI range this libtree-sitter accepts. A grammar newer than the pin is
/// refused with this in the message, rather than crashing in
/// `ts_parser_set_language`.
pub const abi_min = c.TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION;
pub const abi_max = c.TREE_SITTER_LANGUAGE_VERSION;

pub const grammar = @import("grammar.zig");
pub const tagger = @import("tagger.zig");
pub const extractor = @import("extractor.zig");
pub const node_types = @import("node_types.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Extractor = ports.Extractor;

/// Which file backs an extension's tags. `tags`/`locals`/`generated` come
/// from the registry's `"queries"` field (sb-012); `override` is never
/// recorded there -- resolved fresh from `$SYNAPSE_GRAMMARS_QUERY_PATH` on
/// every call and always wins, so callers check for it before `Readiness`.
pub const QuerySource = enum { tags, locals, generated, override };

/// `Readiness.ready`'s payload, named rather than inline since Zig treats
/// two structurally-identical anonymous structs as distinct types, and a
/// caller (`extractor.zig`) needs to hold this past its unwrapping `switch`.
pub const Ready = struct { scope: []const u8, source: QuerySource };

/// What the registry can say about one extension. `no_entry` is a prompt to
/// run grammar discovery and retry; `unusable` is final.
pub const Readiness = union(enum) {
    ready: Ready,
    /// Registered, but marked `unsupported: true`, or missing repo/scope.
    unusable,
    /// No registry entry at all.
    no_entry,
};

pub const Registry = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn load(gpa: Allocator, io: Io, path: []const u8) !Registry {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 << 20)) catch |e| switch (e) {
            error.FileNotFound => try gpa.dupe(u8, "{}"),
            else => return e,
        };
        defer gpa.free(bytes);
        return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
    }

    pub fn deinit(self: *Registry) void {
        self.parsed.deinit();
    }

    pub fn lookup(self: Registry, ext: []const u8) Readiness {
        const root = switch (self.parsed.value) {
            .object => |o| o,
            else => return .no_entry,
        };
        const entry = root.get(ext) orelse return .no_entry;
        const obj = switch (entry) {
            .object => |o| o,
            else => return .unusable,
        };
        if (obj.get("unsupported")) |u| {
            if (u == .bool and u.bool) return .unusable;
        }
        const repo = obj.get("repo") orelse return .unusable;
        const scope = obj.get("scope") orelse return .unusable;
        if (repo != .string or scope != .string) return .unusable;
        if (repo.string.len == 0 or scope.string.len == 0) return .unusable;
        return .{ .ready = .{ .scope = scope.string, .source = queriesFieldFor(obj) } };
    }

    /// The registry's `"queries"` field: `"tags"` (default, so pre-sb-012
    /// entries need no migration), `"locals"`, or `"generated"`. Unrecognised
    /// or wrong-typed falls back to `.tags` rather than refusing an entry
    /// whose `repo`/`scope` already passed validation.
    fn queriesFieldFor(obj: std.json.ObjectMap) QuerySource {
        const v = obj.get("queries") orelse return .tags;
        if (v != .string) return .tags;
        if (std.mem.eql(u8, v.string, "locals")) return .locals;
        if (std.mem.eql(u8, v.string, "generated")) return .generated;
        return .tags;
    }

    /// Clone URL for a usable entry. Separate from `lookup` since only the
    /// proceeding path needs it.
    pub fn repoFor(self: Registry, ext: []const u8) ?[]const u8 {
        const obj = switch (self.parsed.value) {
            .object => |o| o.get(ext) orelse return null,
            else => return null,
        };
        const fields = switch (obj) {
            .object => |o| o,
            else => return null,
        };
        const repo = fields.get("repo") orelse return null;
        return if (repo == .string) repo.string else null;
    }

    /// Sub-directory holding `src/parser.c`, for a repo shipping more than
    /// one grammar (`tree-sitter-ocaml`: no root `src/parser.c`, only
    /// `grammars/ocaml`/`grammars/interface`/`grammars/type`, sharing one
    /// root-level tags query). Null means the repo root. Each sub-grammar
    /// is its own registry entry naming the same repo; the clone is keyed
    /// by repo name, so they share one checkout.
    pub fn pathFor(self: Registry, ext: []const u8) ?[]const u8 {
        return self.stringField(ext, "path");
    }

    /// The `tree_sitter_*` symbol to look up, when not derivable from the
    /// repo name (same multi-grammar repos as `pathFor`). Null means derive it.
    pub fn symbolFor(self: Registry, ext: []const u8) ?[]const u8 {
        return self.stringField(ext, "symbol");
    }

    fn stringField(self: Registry, ext: []const u8, field: []const u8) ?[]const u8 {
        const obj = switch (self.parsed.value) {
            .object => |o| o.get(ext) orelse return null,
            else => return null,
        };
        const fields = switch (obj) {
            .object => |o| o,
            else => return null,
        };
        const v = fields.get(field) orelse return null;
        if (v != .string or v.string.len == 0) return null;
        return v.string;
    }

    /// Every extension with a usable grammar, sorted, deduplicated --
    /// what `synapse-tags.sh --list-extensions` printed.
    pub fn usableExtensions(self: Registry, gpa: Allocator) ![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer out.deinit(gpa);
        const root = switch (self.parsed.value) {
            .object => |o| o,
            else => return out.toOwnedSlice(gpa),
        };
        var it = root.iterator();
        while (it.next()) |e| {
            if (self.lookup(e.key_ptr.*) == .ready) try out.append(gpa, e.key_ptr.*);
        }
        const slice = try out.toOwnedSlice(gpa);
        std.mem.sort([]const u8, slice, {}, lessThanBytes);
        return slice;
    }
};

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Lowercased extension, or null when the basename has none -- matches the
/// script's `ext_of` (`Makefile` has none; `.gitignore` yields `gitignore`).
pub fn extensionOf(gpa: Allocator, path: []const u8) !?[]u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    const ext = base[dot + 1 ..];
    if (ext.len == 0) return null;
    const out = try gpa.alloc(u8, ext.len);
    for (ext, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out;
}

/// Splits batch output into per-path outcomes, one per requested path, same
/// order. An unindented line is a path; tab-indented lines under it are its
/// tags. A path absent entirely means the CLI couldn't parse it
/// (`unsupported`); one present with no tag lines parsed to nothing --
/// collapsing the two would cache a readable file as unparseable.
pub fn attribute(
    gpa: Allocator,
    raw: []const u8,
    paths: []const []const u8,
) ![]Extractor.Outcome {
    var seen: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(model.Tag)) = .empty;
    defer {
        var it = seen.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        seen.deinit(gpa);
    }

    var current: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] != '\t') {
            current = line;
            const gop = try seen.getOrPut(gpa, line);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            continue;
        }
        const path = current orelse continue;
        const tag = tag_line.parse(line[1..]) orelse continue; // leading tab is framing, not content
        const gop = try seen.getOrPut(gpa, path);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, tag);
    }

    const out = try gpa.alloc(Extractor.Outcome, paths.len);
    errdefer gpa.free(out);
    for (paths, 0..) |p, i| {
        if (seen.getPtr(p)) |tags| {
            out[i] = .{ .tags = try gpa.dupe(model.Tag, tags.items) };
        } else {
            out[i] = .unsupported;
        }
    }
    return out;
}

const testing = std.testing;

test {
    _ = grammar;
    _ = tagger;
    _ = extractor;
    _ = node_types;
}

test "libtree-sitter is linked, and its ABI range covers the grammars in use" {
    try testing.expect(abi_min <= 14 and 14 <= abi_max);
    try testing.expect(c.ts_parser_new() != null);
}

test "registry: ready, unsupported, and absent are three different answers" {
    const json =
        \\{"java":{"repo":"https://x/tree-sitter-java","scope":"source.java"},
        \\ "sh":{"unsupported":true},
        \\ "broken":{"repo":"https://x/y"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const reg: Registry = .{ .parsed = parsed };

    try testing.expectEqualStrings("source.java", reg.lookup("java").ready.scope);
    try testing.expect(reg.lookup("sh") == .unusable);
    try testing.expect(reg.lookup("broken") == .unusable); // repo without scope
    try testing.expect(reg.lookup("rs") == .no_entry);
}

test "queries field: absent means tags, and the recognised values parse" {
    const json =
        \\{"java":{"repo":"r","scope":"s"},
        \\ "ml":{"repo":"r","scope":"s","queries":"locals"},
        \\ "zig":{"repo":"r","scope":"s","queries":"generated"},
        \\ "go":{"repo":"r","scope":"s","queries":"typo"},
        \\ "rs":{"repo":"r","scope":"s","queries":42}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const reg: Registry = .{ .parsed = parsed };

    try testing.expectEqual(QuerySource.tags, reg.lookup("java").ready.source);
    try testing.expectEqual(QuerySource.locals, reg.lookup("ml").ready.source);
    try testing.expectEqual(QuerySource.generated, reg.lookup("zig").ready.source);
    try testing.expectEqual(QuerySource.tags, reg.lookup("go").ready.source); // unrecognised falls back
    try testing.expectEqual(QuerySource.tags, reg.lookup("rs").ready.source);
}

test "path and symbol are optional, and absent means derive them" {
    // Two extensions served by one multi-grammar repo (tree-sitter-ocaml).
    const json =
        \\{"java":{"repo":"https://x/tree-sitter-java","scope":"source.java"},
        \\ "ml":{"repo":"https://x/tree-sitter-ocaml","scope":"source.ocaml",
        \\       "path":"grammars/ocaml"},
        \\ "mli":{"repo":"https://x/tree-sitter-ocaml","scope":"source.ocaml.interface",
        \\        "path":"grammars/interface","symbol":"tree_sitter_ocaml_interface"},
        \\ "empty":{"repo":"r","scope":"s","path":"","symbol":""}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const reg: Registry = .{ .parsed = parsed };

    try testing.expect(reg.pathFor("java") == null);
    try testing.expect(reg.symbolFor("java") == null);

    try testing.expectEqualStrings("grammars/ocaml", reg.pathFor("ml").?);
    try testing.expect(reg.symbolFor("ml") == null); // derivable from repo name

    try testing.expectEqualStrings("grammars/interface", reg.pathFor("mli").?);
    try testing.expectEqualStrings("tree_sitter_ocaml_interface", reg.symbolFor("mli").?);

    try testing.expect(reg.pathFor("empty") == null); // empty string is not a real value
    try testing.expect(reg.symbolFor("empty") == null);

    try testing.expect(reg.pathFor("rs") == null);
}

test "list-extensions is the registry filtered to usable, sorted" {
    const json =
        \\{"py":{"repo":"r","scope":"source.python"},
        \\ "java":{"repo":"r","scope":"source.java"},
        \\ "sh":{"unsupported":true}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const reg: Registry = .{ .parsed = parsed };

    const exts = try reg.usableExtensions(testing.allocator);
    defer testing.allocator.free(exts);
    try testing.expectEqual(@as(usize, 2), exts.len);
    try testing.expectEqualStrings("java", exts[0]);
    try testing.expectEqualStrings("py", exts[1]);
}

test "extensions are lowercased, and a dotless name has none" {
    const gpa = testing.allocator;
    const java = (try extensionOf(gpa, "src/Main.JAVA")).?;
    defer gpa.free(java);
    try testing.expectEqualStrings("java", java);
    try testing.expectEqual(@as(?[]u8, null), try extensionOf(gpa, "Makefile"));
    try testing.expectEqual(@as(?[]u8, null), try extensionOf(gpa, "dir.d/README"));
}

test "attribution: a parsed-empty file keeps its path line, an unparseable one is absent" {
    const raw =
        "a.java\n" ++
        "\tToken     \t | class   \tdef (15, 13) - (15, 18) `public class Token {`\n" ++
        "empty.java\n";

    const out = try attribute(testing.allocator, raw, &.{ "a.java", "empty.java", "gone.bin" });
    defer {
        for (out) |o| if (o == .tags) testing.allocator.free(o.tags);
        testing.allocator.free(out);
    }

    try testing.expectEqual(@as(usize, 1), out[0].tags.len);
    try testing.expectEqualStrings("Token", out[0].tags[0].name);
    try testing.expectEqual(@as(usize, 0), out[1].tags.len); // parsed, nothing in it
    try testing.expect(out[2] == .unsupported); // never appeared
}

test "attribution keeps each path's tags with that path" {
    const raw =
        "a.java\n" ++
        "\tA         \t | class   \tdef (1, 0) - (1, 1) `class A {}`\n" ++
        "b.java\n" ++
        "\tB         \t | class   \tdef (2, 0) - (2, 1) `class B {}`\n" ++
        "\tc         \t | call    \tref (3, 0) - (3, 1) `c();`\n";

    const out = try attribute(testing.allocator, raw, &.{ "a.java", "b.java" });
    defer {
        for (out) |o| if (o == .tags) testing.allocator.free(o.tags);
        testing.allocator.free(out);
    }

    try testing.expectEqual(@as(usize, 1), out[0].tags.len);
    try testing.expectEqualStrings("A", out[0].tags[0].name);
    try testing.expectEqual(@as(usize, 2), out[1].tags.len);
    try testing.expectEqualStrings("B", out[1].tags[0].name);
    try testing.expectEqualStrings("c", out[1].tags[1].name);
}

test "a tag line before any path line is dropped, not attributed to nothing" {
    const raw = "\tOrphan    \t | class   \tdef (1, 0) - (1, 1) `x`\na.java\n";
    const out = try attribute(testing.allocator, raw, &.{"a.java"});
    defer {
        for (out) |o| if (o == .tags) testing.allocator.free(o.tags);
        testing.allocator.free(out);
    }
    try testing.expectEqual(@as(usize, 0), out[0].tags.len);
}
