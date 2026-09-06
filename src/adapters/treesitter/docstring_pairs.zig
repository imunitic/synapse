//! Structural comment/declaration pairing -- deliberately independent of
//! the `tags.scm`/`locals.scm`/generated tagger cascade (`tagger.zig`),
//! even though both walk the same parse tree. Docstring staleness
//! detection is a separately opt-in feature (see the design note this
//! implements) and must not share fate with tag extraction's own success
//! or failure for a grammar -- a grammar with no usable `tags.scm` would
//! otherwise silently disable docstring checking too, for a reason that
//! has nothing to do with docstrings. The only genuinely shared step is
//! grammar loading itself (`grammar.resolveAndLoad`) and the registry.
//!
//! Pairing starts structurally, not semantically: from a comment node,
//! walk forward through directly-adjacent (row-consecutive) sibling
//! comment nodes, collecting a contiguous run -- how a real doc comment is
//! written, continuous lines until a blank line or the declaration itself.
//! The run ends one of two ways: a blank line first (a floating comment
//! block, not a docstring), or a directly-adjacent non-comment sibling.
//! That sibling still has to look like a declaration to count, though --
//! "any non-comment sibling qualifies" was the original shape, and it
//! false-positived on ordinary statements inside a function body (an `if`,
//! a `return`, a bare expression) the moment recursion reached one, found
//! live against a real file. The actual signal, still fully
//! language-agnostic, is whether the sibling has a `name` field
//! (`hasNameField`) -- the same heuristic `node_types.zig`'s own
//! tags-independent classification already uses -- with a narrow,
//! verified per-grammar allowlist (`resolveDeclarationOverrides`) for a
//! declaration kind whose grammar author didn't expose `name` for it.
//!
//! The pair's `kind` is the declaration node's raw tree-sitter type name
//! (e.g. `function_declaration`), never normalized through
//! `kind_synonyms.zig` -- nothing here needs to agree with tags.scm's
//! classification. The pair's `name` is the declaration node's own first
//! line of text (its signature/header line) rather than a
//! semantically-extracted identifier: fully grammar-agnostic, and a real
//! signature change is exactly the kind of edit that should count as
//! "this declaration changed, look again" -- a rename already falls under
//! that same umbrella.

const std = @import("std");
const root = @import("root.zig");
const grammar = @import("grammar.zig");

const c = root.c;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{ParseFailed};

/// One comment run paired with the declaration directly following it, no
/// blank line between them. Every field is owned by whoever received the
/// slice `findPairs` returned; free with `freePair`.
pub const Pair = struct {
    /// The declaration's own raw tree-sitter node type name.
    kind: []const u8,
    /// The declaration node's own first line of text.
    name: []const u8,
    /// The comment run's text, every comment node's own text joined by
    /// `\n`, source order.
    docstring_text: []const u8,
    /// The declaration node's full text, start byte to end byte.
    decl_text: []const u8,
    /// 1-based, inclusive -- `core.verify.slice`'s own convention, so
    /// `core.docstring_index.Entry`'s ranges and a later re-hash agree on
    /// what "line 1" means. Tree-sitter points are 0-based rows.
    docstring_start_line: u32,
    docstring_end_line: u32,
    decl_start_line: u32,
    decl_end_line: u32,
};

pub fn freePair(gpa: Allocator, p: Pair) void {
    gpa.free(p.kind);
    gpa.free(p.name);
    gpa.free(p.docstring_text);
    gpa.free(p.decl_text);
}

pub fn freePairs(gpa: Allocator, pairs: []const Pair) void {
    for (pairs) |p| freePair(gpa, p);
    gpa.free(pairs);
}

/// Resolves the compiled language for `ext` via the registry, cloning and
/// building it if not already present -- everything `TsBackend.load` does
/// up to `grammar.resolveAndLoad`, and nothing past it: no tags.scm query,
/// no `Tagger`. Null means the registry has nothing usable for this
/// extension, the same graceful-degradation shape every other grammar
/// consumer already has.
pub fn resolveLanguage(
    gpa: Allocator,
    io: Io,
    registry: root.Registry,
    grammars_dir: []const u8,
    ext: []const u8,
    lock_tries: usize,
) !?*const c.TSLanguage {
    switch (registry.lookup(ext)) {
        .ready => {},
        .unusable, .no_entry => return null,
    }
    const repo_url = registry.repoFor(ext) orelse return null;

    const repos_parent = try std.fs.path.join(gpa, &.{ grammars_dir, "repos" });
    defer gpa.free(repos_parent);
    const repo_dir = try grammar.ensureCloned(io, gpa, repo_url, repos_parent, lock_tries);
    defer gpa.free(repo_dir);

    return try grammar.resolveAndLoad(
        gpa,
        io,
        repo_dir,
        grammars_dir,
        grammar.repoNameOf(repo_url),
        registry.pathFor(ext),
        registry.symbolFor(ext),
        lock_tries,
    );
}

/// The comment node's type name to use for `ext`: the generic default
/// `"comment"`, or a verified per-grammar override read from
/// `{query_override_dir}/{ext}.comments.scm`. Unlike `tags.scm`'s query
/// convention, this override is not itself compiled and run as a query --
/// its content is expected to name exactly one node type, in the minimal
/// single-pattern shape `(type_name)` (an optional trailing `@capture`, if
/// present, is ignored), and only the type name is extracted. `FileNotFound`
/// means no override; anything else propagates. Always allocated, so the
/// caller frees the same way regardless of which path was taken.
pub fn resolveCommentTypeName(
    gpa: Allocator,
    io: Io,
    query_override_dir: ?[]const u8,
    ext: []const u8,
) ![]u8 {
    if (query_override_dir) |dir| {
        const override_name = try std.fmt.allocPrint(gpa, "{s}.comments.scm", .{ext});
        defer gpa.free(override_name);
        const override_path = try std.fs.path.join(gpa, &.{ dir, override_name });
        defer gpa.free(override_path);
        const content = Io.Dir.cwd().readFileAlloc(io, override_path, gpa, .limited(4096)) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        if (content) |scm| {
            defer gpa.free(scm);
            if (parseSingleNodeType(scm)) |name| return gpa.dupe(u8, name);
        }
    }
    return gpa.dupe(u8, "comment");
}

/// Additional node type names that count as a declaration without needing
/// a `name` field, read from `{query_override_dir}/{ext}.declarations.scm`
/// -- the escape hatch for a real grammar that doesn't expose `name` for
/// every declaration kind it has (found live: a real grammar's top-level
/// `variable_declaration` had no `name` field at all, unlike its
/// `function_declaration`). `hasNameField` stays the always-on default;
/// this is a narrow, additive allowlist for what it misses, verified by
/// checking a real file in that grammar before writing it -- never
/// guessed, the same discipline `.comments.scm`'s override already
/// follows. One pattern per non-empty line, same minimal `(type_name)` or
/// `(type_name) @capture` shape as `.comments.scm`. No override directory,
/// or no file at that path, yields an empty (not null) slice -- there is
/// nothing to add, not an unresolved question. Always allocated
/// (`freeDeclarationOverrides` frees it and every name in it) regardless
/// of which path was taken, so a caller doesn't need to branch on whether
/// anything was actually found.
pub fn resolveDeclarationOverrides(
    gpa: Allocator,
    io: Io,
    query_override_dir: ?[]const u8,
    ext: []const u8,
) ![][]u8 {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }

    if (query_override_dir) |dir| {
        const override_name = try std.fmt.allocPrint(gpa, "{s}.declarations.scm", .{ext});
        defer gpa.free(override_name);
        const override_path = try std.fs.path.join(gpa, &.{ dir, override_name });
        defer gpa.free(override_path);
        const content = Io.Dir.cwd().readFileAlloc(io, override_path, gpa, .limited(4096)) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        if (content) |scm| {
            defer gpa.free(scm);
            var lines = std.mem.splitScalar(u8, scm, '\n');
            while (lines.next()) |line| {
                if (parseSingleNodeType(line)) |name| try out.append(gpa, try gpa.dupe(u8, name));
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeDeclarationOverrides(gpa: Allocator, names: [][]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

/// The bytes between the first `(` and the next `)`, whitespace, or `@` --
/// `(type_name)` or `(type_name) @comment`, whichever the override file
/// contains. Null when the content has no opening paren at all, which
/// leaves the caller to fall back to the generic default rather than
/// silently matching nothing.
fn parseSingleNodeType(scm: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, scm, '(') orelse return null;
    const rest = scm[open + 1 ..];
    var end = rest.len;
    for (rest, 0..) |ch, i| {
        if (ch == ')' or ch == '@' or std.ascii.isWhitespace(ch)) {
            end = i;
            break;
        }
    }
    if (end == 0) return null;
    return rest[0..end];
}

/// Every comment-run/declaration pair in `source`, at any nesting depth.
/// `comment_type_name` is the tree-sitter node type identifying a comment
/// -- `"comment"` by default, or a verified per-grammar override.
/// `extra_declaration_kinds` are additional node type names to accept as a
/// declaration even without a `name` field -- empty by default; see
/// `resolveDeclarationOverrides`.
pub fn findPairs(
    gpa: Allocator,
    lang: *const c.TSLanguage,
    source: []const u8,
    comment_type_name: []const u8,
    extra_declaration_kinds: []const []const u8,
) ![]Pair {
    const parser = c.ts_parser_new() orelse return Error.ParseFailed;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, lang)) return Error.ParseFailed;

    const tree = c.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse
        return Error.ParseFailed;
    defer c.ts_tree_delete(tree);

    var out: std.ArrayListUnmanaged(Pair) = .empty;
    errdefer {
        for (out.items) |p| freePair(gpa, p);
        out.deinit(gpa);
    }

    try walk(gpa, c.ts_tree_root_node(tree), source, comment_type_name, extra_declaration_kinds, &out);
    return out.toOwnedSlice(gpa);
}

/// Whether `node` has a child in the grammar's `name` field slot -- the
/// same "has_name_field" signal `node_types.zig`'s own tags-independent
/// classification already relies on, here checked per-instance via the
/// real tree-sitter API instead of `node-types.json`'s static schema
/// (this module has no reason to load that file at all). A real
/// declaration (function/type/class/variable) almost universally exposes
/// its identifier this way; an ordinary statement (`if`, `return`, a bare
/// expression) essentially never does, which is what actually
/// distinguishes "a declaration" from "code inside a function body" --
/// not depth, and not a per-language list of statement kinds.
fn hasNameField(node: c.TSNode) bool {
    return !c.ts_node_is_null(c.ts_node_child_by_field_name(node, "name", "name".len));
}

/// `hasNameField`, plus the verified per-grammar escape hatch: a node
/// whose own type name is listed in `extra_kinds` counts as a declaration
/// too, regardless of whether it has a `name` field -- see
/// `resolveDeclarationOverrides`.
fn isDeclaration(node: c.TSNode, extra_kinds: []const []const u8) bool {
    if (hasNameField(node)) return true;
    const type_name = std.mem.span(c.ts_node_type(node));
    for (extra_kinds) |k| {
        if (std.mem.eql(u8, k, type_name)) return true;
    }
    return false;
}

fn walk(
    gpa: Allocator,
    node: c.TSNode,
    source: []const u8,
    comment_type_name: []const u8,
    extra_declaration_kinds: []const []const u8,
    out: *std.ArrayListUnmanaged(Pair),
) !void {
    const count = c.ts_node_named_child_count(node);

    var i: u32 = 0;
    while (i < count) {
        const child = c.ts_node_named_child(node, i);
        if (!std.mem.eql(u8, std.mem.span(c.ts_node_type(child)), comment_type_name)) {
            i += 1;
            continue;
        }

        // Collect a contiguous run of directly-adjacent comment siblings.
        var run_end: u32 = i;
        while (run_end + 1 < count) {
            const cur = c.ts_node_named_child(node, run_end);
            const next = c.ts_node_named_child(node, run_end + 1);
            if (!std.mem.eql(u8, std.mem.span(c.ts_node_type(next)), comment_type_name)) break;
            if (c.ts_node_start_point(next).row != c.ts_node_end_point(cur).row + 1) break;
            run_end += 1;
        }

        if (run_end + 1 < count) {
            const decl = c.ts_node_named_child(node, run_end + 1);
            const last_comment = c.ts_node_named_child(node, run_end);
            const adjacent = c.ts_node_start_point(decl).row == c.ts_node_end_point(last_comment).row + 1;
            const decl_is_comment = std.mem.eql(u8, std.mem.span(c.ts_node_type(decl)), comment_type_name);
            if (adjacent and !decl_is_comment and isDeclaration(decl, extra_declaration_kinds)) {
                try emit(gpa, node, i, run_end, decl, source, out);
            }
        }

        i = run_end + 1;
    }

    i = 0;
    while (i < count) : (i += 1) {
        try walk(gpa, c.ts_node_named_child(node, i), source, comment_type_name, extra_declaration_kinds, out);
    }
}

fn emit(
    gpa: Allocator,
    parent: c.TSNode,
    first_comment_idx: u32,
    last_comment_idx: u32,
    decl: c.TSNode,
    source: []const u8,
    out: *std.ArrayListUnmanaged(Pair),
) !void {
    const first_comment = c.ts_node_named_child(parent, first_comment_idx);
    const last_comment = c.ts_node_named_child(parent, last_comment_idx);
    // Tree-sitter rows are 0-based; the index stores 1-based inclusive
    // lines, `core.verify.slice`'s own convention.
    const docstring_start_line = c.ts_node_start_point(first_comment).row + 1;
    const docstring_end_line = c.ts_node_end_point(last_comment).row + 1;
    const decl_start_line = c.ts_node_start_point(decl).row + 1;
    const decl_end_line = c.ts_node_end_point(decl).row + 1;

    var docstring: std.ArrayListUnmanaged(u8) = .empty;
    errdefer docstring.deinit(gpa);
    var idx = first_comment_idx;
    while (idx <= last_comment_idx) : (idx += 1) {
        const cm = c.ts_node_named_child(parent, idx);
        if (idx != first_comment_idx) try docstring.append(gpa, '\n');
        try docstring.appendSlice(gpa, source[c.ts_node_start_byte(cm)..c.ts_node_end_byte(cm)]);
    }
    const docstring_text = try docstring.toOwnedSlice(gpa);
    errdefer gpa.free(docstring_text);

    const decl_slice = source[c.ts_node_start_byte(decl)..c.ts_node_end_byte(decl)];
    const first_line_end = std.mem.indexOfScalar(u8, decl_slice, '\n') orelse decl_slice.len;

    const decl_text = try gpa.dupe(u8, decl_slice);
    errdefer gpa.free(decl_text);
    const name = try gpa.dupe(u8, decl_slice[0..first_line_end]);
    errdefer gpa.free(name);
    const kind = try gpa.dupe(u8, std.mem.span(c.ts_node_type(decl)));
    errdefer gpa.free(kind);

    try out.append(gpa, .{
        .kind = kind,
        .name = name,
        .docstring_text = docstring_text,
        .decl_text = decl_text,
        .docstring_start_line = docstring_start_line,
        .docstring_end_line = docstring_end_line,
        .decl_start_line = decl_start_line,
        .decl_end_line = decl_end_line,
    });
}

const testing = std.testing;

test "resolveCommentTypeName: no override directory falls back to the generic default" {
    const gpa = testing.allocator;
    const name = try resolveCommentTypeName(gpa, testing.io, null, "zig");
    defer gpa.free(name);
    try testing.expectEqualStrings("comment", name);
}

test "resolveCommentTypeName: an absent override file falls back to the generic default" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const name = try resolveCommentTypeName(gpa, testing.io, dir, "zig");
    defer gpa.free(name);
    try testing.expectEqualStrings("comment", name);
}

test "resolveCommentTypeName: a present override file's node type wins, with or without a capture" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zig.comments.scm", .data = "(line_comment) @comment\n" });
    const name = try resolveCommentTypeName(gpa, testing.io, dir, "zig");
    defer gpa.free(name);
    try testing.expectEqualStrings("line_comment", name);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "py.comments.scm", .data = "(comment)" });
    const name2 = try resolveCommentTypeName(gpa, testing.io, dir, "py");
    defer gpa.free(name2);
    try testing.expectEqualStrings("comment", name2);
}

test "resolveDeclarationOverrides: no override directory or absent file is an empty slice, not an error" {
    const gpa = testing.allocator;

    const none = try resolveDeclarationOverrides(gpa, testing.io, null, "zig");
    defer freeDeclarationOverrides(gpa, none);
    try testing.expectEqual(@as(usize, 0), none.len);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const absent = try resolveDeclarationOverrides(gpa, testing.io, dir, "zig");
    defer freeDeclarationOverrides(gpa, absent);
    try testing.expectEqual(@as(usize, 0), absent.len);
}

test "resolveDeclarationOverrides: one node type per non-empty line" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "zig.declarations.scm",
        .data = "(variable_declaration) @declaration\n\n(return_statement)\n",
    });
    const names = try resolveDeclarationOverrides(gpa, testing.io, dir, "zig");
    defer freeDeclarationOverrides(gpa, names);

    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("variable_declaration", names[0]);
    try testing.expectEqualStrings("return_statement", names[1]);
}

/// A tiny real grammar (generated with `tree-sitter generate`, checked in
/// under `testdata/fake_docstrings_grammar`) -- `source_file` of
/// `function_declaration`/`struct_item`, plus a `//`-style `comment`
/// declared as an `extras` rule, matching how a real doc comment sits in
/// an actual grammar. `tagger.zig`'s own `fake3_grammar` has no comment
/// rule at all, so it can't exercise this module.
fn writeFakeDocstringsFixture(io: std.Io, tmp_dir: std.Io.Dir) !void {
    try tmp_dir.createDirPath(io, "src/tree_sitter");
    try tmp_dir.writeFile(io, .{ .sub_path = "src/parser.c", .data = @embedFile("testdata/fake_docstrings_grammar/src/parser.c") });
    try tmp_dir.writeFile(io, .{ .sub_path = "src/node-types.json", .data = @embedFile("testdata/fake_docstrings_grammar/src/node-types.json") });
    try tmp_dir.writeFile(io, .{ .sub_path = "src/tree_sitter/parser.h", .data = @embedFile("testdata/fake_docstrings_grammar/src/tree_sitter/parser.h") });
    try tmp_dir.writeFile(io, .{ .sub_path = "src/tree_sitter/alloc.h", .data = @embedFile("testdata/fake_docstrings_grammar/src/tree_sitter/alloc.h") });
    try tmp_dir.writeFile(io, .{ .sub_path = "src/tree_sitter/array.h", .data = @embedFile("testdata/fake_docstrings_grammar/src/tree_sitter/array.h") });
}

fn testLang(gpa: Allocator, io: std.Io, dir: []const u8) !*const c.TSLanguage {
    const lib = try std.fmt.allocPrint(gpa, "{s}/fake_docstrings.{s}", .{ dir, grammar.sharedLibExt() });
    defer gpa.free(lib);
    try grammar.build(io, gpa, dir, lib, grammar.default_lock_tries);
    return grammar.load(gpa, lib, "tree_sitter_fake_docstrings");
}

test "a single-line comment directly above a declaration pairs with it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFakeDocstringsFixture(io, tmp.dir);
    const lang = try testLang(gpa, io, dir);

    const source = "// does a thing\nfn foo()\n";
    const pairs = try findPairs(gpa, lang, source, "comment", &.{});
    defer freePairs(gpa, pairs);

    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqualStrings("function_declaration", pairs[0].kind);
    try testing.expectEqualStrings("fn foo()", pairs[0].name);
    try testing.expectEqualStrings("// does a thing", pairs[0].docstring_text);
    try testing.expectEqualStrings("fn foo()", pairs[0].decl_text);
    try testing.expectEqual(@as(u32, 1), pairs[0].docstring_start_line);
    try testing.expectEqual(@as(u32, 1), pairs[0].docstring_end_line);
    try testing.expectEqual(@as(u32, 2), pairs[0].decl_start_line);
    try testing.expectEqual(@as(u32, 2), pairs[0].decl_end_line);
}

test "a multi-line stacked comment run pairs as one docstring, joined by newline" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFakeDocstringsFixture(io, tmp.dir);
    const lang = try testLang(gpa, io, dir);

    const source = "// line one\n// line two\nfn foo()\n";
    const pairs = try findPairs(gpa, lang, source, "comment", &.{});
    defer freePairs(gpa, pairs);

    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqualStrings("// line one\n// line two", pairs[0].docstring_text);
    try testing.expectEqual(@as(u32, 1), pairs[0].docstring_start_line);
    try testing.expectEqual(@as(u32, 2), pairs[0].docstring_end_line);
    try testing.expectEqual(@as(u32, 3), pairs[0].decl_start_line);
    try testing.expectEqual(@as(u32, 3), pairs[0].decl_end_line);
}

test "a blank line before the declaration means no pairing at all" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFakeDocstringsFixture(io, tmp.dir);
    const lang = try testLang(gpa, io, dir);

    const source = "// floating comment\n\nfn foo()\n";
    const pairs = try findPairs(gpa, lang, source, "comment", &.{});
    defer freePairs(gpa, pairs);

    try testing.expectEqual(@as(usize, 0), pairs.len);
}

test "a declaration with no comment above it is simply not paired" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFakeDocstringsFixture(io, tmp.dir);
    const lang = try testLang(gpa, io, dir);

    const pairs = try findPairs(gpa, lang, "fn foo()\n", "comment", &.{});
    defer freePairs(gpa, pairs);

    try testing.expectEqual(@as(usize, 0), pairs.len);
}

test "two declarations each get their own comment, not the other's" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFakeDocstringsFixture(io, tmp.dir);
    const lang = try testLang(gpa, io, dir);

    const source = "// first\nfn foo()\n// second\nstruct Bar {}\n";
    const pairs = try findPairs(gpa, lang, source, "comment", &.{});
    defer freePairs(gpa, pairs);

    try testing.expectEqual(@as(usize, 2), pairs.len);
    try testing.expectEqualStrings("// first", pairs[0].docstring_text);
    try testing.expectEqualStrings("function_declaration", pairs[0].kind);
    try testing.expectEqualStrings("// second", pairs[1].docstring_text);
    try testing.expectEqualStrings("struct_item", pairs[1].kind);
}

test "a comment directly above a statement inside a function body is not paired" {
    // The live bug this regression test locks in: a comment sitting
    // directly above an ordinary statement satisfies the same adjacency
    // rule a real docstring does (nothing about "adjacent, non-comment
    // sibling" is inherently declaration-specific) -- what actually rules
    // a statement out is that it has no `name` field, unlike a real
    // declaration. `return_statement` here has none (confirmed against
    // this grammar's own node-types.json), matching how an ordinary
    // statement looks in essentially every real grammar.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFakeDocstringsFixture(io, tmp.dir);
    const lang = try testLang(gpa, io, dir);

    const source = "fn foo() {\n// a note about returning\nreturn;\n}\n";
    const pairs = try findPairs(gpa, lang, source, "comment", &.{});
    defer freePairs(gpa, pairs);

    try testing.expectEqual(@as(usize, 0), pairs.len);
}

test "a declaration override brings back a node kind hasNameField alone excludes" {
    // The escape hatch for the exact gap the previous test's fix
    // introduced: `return_statement` has no `name` field, so it's
    // excluded by default, but a verified per-grammar override can name
    // it explicitly when a real grammar's own author didn't expose `name`
    // for a kind that genuinely is a declaration there.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFakeDocstringsFixture(io, tmp.dir);
    const lang = try testLang(gpa, io, dir);

    const source = "fn foo() {\n// a note about returning\nreturn;\n}\n";
    const pairs = try findPairs(gpa, lang, source, "comment", &.{"return_statement"});
    defer freePairs(gpa, pairs);

    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqualStrings("return_statement", pairs[0].kind);
    try testing.expectEqualStrings("// a note about returning", pairs[0].docstring_text);
}


test "an overridden comment type name is honored instead of the generic default" {
    // The registry override (`{ext}.comments.scm`) replaces which node
    // type name counts as a comment; this module takes that name as a
    // plain parameter and does not care where it came from -- simulated
    // here by simply asking for a type name this grammar does not have.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFakeDocstringsFixture(io, tmp.dir);
    const lang = try testLang(gpa, io, dir);

    const source = "// does a thing\nfn foo()\n";
    const pairs = try findPairs(gpa, lang, source, "not_a_real_comment_type", &.{});
    defer freePairs(gpa, pairs);

    try testing.expectEqual(@as(usize, 0), pairs.len);
}
