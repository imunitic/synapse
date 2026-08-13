//! Per-file declared namespace, and the directory-level divergence table it
//! feeds -- synapse-001 (precompute before inference), step 6.
//!
//! A file's declared namespace is what its own ecosystem says it belongs to: a
//! Java `package`, a Rust crate `name`, a Go `module`. The directory holding it
//! is what the filesystem says. When the two disagree across most of a
//! directory, "the highest-value findings in the whole build" per the
//! orientation skill: every later search for the directory's own name comes
//! back empty, because the code calls itself something else.
//!
//! ## Why this is a rule, not a grammar query
//!
//! Checked against the tags queries already in use: Java captures class,
//! interface and method, never `package`. Kotlin the same shape. Python has
//! nothing to capture -- a module is a file. OCaml's `@definition.module`
//! captures nested `module Foo = struct ... end`, not the library a file
//! belongs to, which lives in a sibling `dune` instead. So a per-extension rule
//! is required, and it has exactly two shapes:
//!
//!   - **In the file itself.** Java and Kotlin declare `package` on one line.
//!   - **In the nearest ancestor build file.** OCaml's library name lives in
//!     the nearest `dune`; Rust and Go have the same shape with `Cargo.toml`
//!     and `go.mod`.
//!
//! ## Why a rule is a prefix and a terminator, not a regular expression
//!
//! Every example above is "find the line starting with X, take everything up
//! to Y" -- `package ` up to `;`, `(name ` up to `)`, `name = "` up to the next
//! `"`, `module ` up to end of line. A regular-expression engine would answer a
//! more general question than this one ever asks, and the two engines this
//! codebase already reaches for elsewhere -- `grep -E` for a user's override
//! pattern, `git grep` for a batched search -- are a subprocess, which the
//! plan's own constraint rules out for a per-file loop over a whole repository.
//! A prefix/terminator scan is a handful of `indexOf` calls, needs neither, and
//! says everything the ecosystems above actually need said.
//!
//! ## No per-language curation ships
//!
//! Nothing in this file knows what Java or OCaml is. `Registry` reads
//! `~/.claude/synapse-namespace-rules.conf`, keyed by bare extension, the same
//! shape and the same discovery contract as the tree-sitter grammar registry:
//! absent means "not discovered yet," not "unsupported forever," and a rule
//! for a new ecosystem is a config edit, never a code change.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Kind = enum { in_file, build_file };

/// One extension's rule. `file` is set only for `.build_file` -- the name to
/// search ancestor directories for. `terminator` null means "to end of line,"
/// trimmed -- `module` in `go.mod` and `package` in Kotlin both have no closing
/// character, unlike `;` in Java or the closing `"`/`)` the other two use.
pub const Rule = struct {
    kind: Kind,
    file: ?[]const u8 = null,
    prefix: []const u8,
    terminator: ?[]const u8 = null,
};

/// `~/.claude/synapse-namespace-rules.conf`, one JSON object keyed by bare
/// extension -- `{"java": {"kind": "in-file", "prefix": "package ", "terminator": ";"}}`.
/// Absent or unreadable opens as `{}` rather than an error, matching the
/// grammar registry: a repo with no rules configured yet is a supported state,
/// not a broken one.
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

    /// Whether the registry has any rule at all -- the "nothing configured
    /// yet" signal a caller uses to skip the whole pass rather than walk every
    /// file to learn it has no rule.
    pub fn isEmpty(self: Registry) bool {
        return switch (self.parsed.value) {
            .object => |o| o.count() == 0,
            else => true,
        };
    }

    pub fn ruleFor(self: Registry, ext: []const u8) ?Rule {
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

        return .{ .kind = kind, .file = file, .prefix = prefix_v.string, .terminator = terminator };
    }
};

/// The first `prefix`-led line in `content`, from `prefix` to `terminator` (or
/// end of line when `terminator` is null), trimmed. Null when no line starts
/// with `prefix` after leading whitespace, or the extracted value is blank.
///
/// Line by line rather than a whole-content search: a real declaration is
/// alone on its line at the top of the file, and searching the raw bytes would
/// risk matching the prefix text sitting inside a comment or string literal
/// later on.
pub fn extractField(content: []const u8, prefix: []const u8, terminator: ?[]const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
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

/// The path's containing directory, repo-relative -- everything before the
/// last `/`, or `""` for a repository-root file. Hand-rolled rather than
/// `std.fs.path`, for the reason `core.vocab.artifactOf` already gives: these
/// paths come from `git ls-files` and always use `/`, while `std.fs.path`
/// would also split on `\` when built for Windows and disagree with itself
/// across platforms on the same repository.
pub fn dirOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

/// The path's filename, repo-relative input or not -- everything after the
/// last `/`, or the whole path when there is none. Same hand-rolled reasoning
/// as `dirOf`.
pub fn baseOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

/// The namespace recorded for `dir` itself, or the nearest ancestor's --
/// walking up one path segment at a time until a match is found or the
/// repository root (`""`) is exhausted. `by_dir` maps a build file's own
/// directory to the namespace it declared, built once from every build file
/// in the repository before this is called for any source file.
pub fn nearestNamespace(by_dir: *const std.StringHashMapUnmanaged([]const u8), dir: []const u8) ?[]const u8 {
    var at = dir;
    while (true) {
        if (by_dir.get(at)) |ns| return ns;
        if (at.len == 0) return null;
        at = dirOf(at);
    }
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
    try testing.expectEqualStrings("eon_edn", extractField("  (name eon_edn)\n", "(name ", ")").?);
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
    // `package com.example` with no `;` anywhere on the line is not a
    // definition to trust half of -- the awk-style prefix/terminator contract
    // has no "close enough" reading of a malformed declaration.
    try testing.expectEqualStrings(
        "real",
        extractField("package com.example\npackage real;\n", "package ", ";").?,
    );
}

test "extractField: a blank extracted value is null, not empty" {
    try testing.expectEqual(@as(?[]const u8, null), extractField("package ;\n", "package ", ";"));
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
    try by_dir.put(gpa, "eon_edn/src", "eon_edn");

    try testing.expectEqualStrings("eon_edn", nearestNamespace(&by_dir, "eon_edn/src").?);
}

test "nearestNamespace: walks up past a directory with no build file" {
    const gpa = testing.allocator;
    var by_dir: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer by_dir.deinit(gpa);
    try by_dir.put(gpa, "eon_edn/src", "eon_edn");

    try testing.expectEqualStrings("eon_edn", nearestNamespace(&by_dir, "eon_edn/src/nested/deep").?);
}

test "nearestNamespace: no ancestor recorded anything is null" {
    const gpa = testing.allocator;
    var by_dir: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer by_dir.deinit(gpa);
    try by_dir.put(gpa, "other/crate", "other");

    try testing.expectEqual(@as(?[]const u8, null), nearestNamespace(&by_dir, "eon_edn/src"));
}

test "Registry: an absent file opens empty, not an error" {
    const gpa = testing.allocator;
    var reg = try Registry.load(gpa, testing.io, "/nonexistent/synapse-namespace-rules.conf");
    defer reg.deinit();
    try testing.expect(reg.isEmpty());
    try testing.expectEqual(@as(?Rule, null), reg.ruleFor("java"));
}

test "Registry: an in-file rule round-trips every field" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"java": {"kind": "in-file", "prefix": "package ", "terminator": ";"}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const rule = reg.ruleFor("java").?;
    try testing.expectEqual(Kind.in_file, rule.kind);
    try testing.expectEqualStrings("package ", rule.prefix);
    try testing.expectEqualStrings(";", rule.terminator.?);
    try testing.expectEqual(@as(?[]const u8, null), rule.file);
}

test "Registry: a build-file rule without terminator means end of line" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"go": {"kind": "build-file", "file": "go.mod", "prefix": "module "}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    const rule = reg.ruleFor("go").?;
    try testing.expectEqual(Kind.build_file, rule.kind);
    try testing.expectEqualStrings("go.mod", rule.file.?);
    try testing.expectEqual(@as(?[]const u8, null), rule.terminator);
}

test "Registry: a build-file rule missing 'file' is not a rule" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"go": {"kind": "build-file", "prefix": "module "}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    try testing.expectEqual(@as(?Rule, null), reg.ruleFor("go"));
}

test "Registry: an unregistered extension is null, and the registry is not empty because of it" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"java": {"kind": "in-file", "prefix": "package ", "terminator": ";"}}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();

    try testing.expectEqual(@as(?Rule, null), reg.ruleFor("py"));
    try testing.expect(!reg.isEmpty());
}
