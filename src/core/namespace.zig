//! Per-file declared namespace, and the directory-level divergence table it
//! feeds, computed before any inference step reads it.
//!
//! A file's declared namespace is what its own ecosystem says (a Java
//! `package`, a Rust crate `name`, a Go `module`); the directory holding it
//! is what the filesystem says. When the two disagree across most of a
//! directory, searching for the directory's own name later comes back
//! empty, because the code calls itself something else.
//!
//! A rule, not a grammar query: existing tags queries never capture
//! `package` (Java/Kotlin), Python has no module node at all, and OCaml's
//! `@definition.module` captures a nested `module Foo = struct end`, not
//! the library a file belongs to (that's in a sibling `dune`). Every rule
//! is either in the file itself (Java/Kotlin's `package` line) or in the
//! nearest ancestor build file (OCaml's `dune`, Rust's `Cargo.toml`, Go's
//! `go.mod`).
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

/// One extension's rule. `file` is set only for `.build_file` -- the name to
/// search ancestor directories for. `terminator` null means to end of line
/// (trimmed).
pub const Rule = struct {
    kind: Kind,
    file: ?[]const u8 = null,
    prefix: []const u8,
    terminator: ?[]const u8 = null,
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

/// The first `prefix`-led line in `content`, from `prefix` to `terminator`
/// (or end of line), trimmed. Null when no line matches or the value is
/// blank. Line by line, not a whole-content search, to avoid matching a
/// prefix inside a comment or string. Tracks one bit of "inside `/* */`"
/// across lines -- not a real comment parser, just enough to skip a
/// commented-out declaration (both `Rule.kind == .in_file` ecosystems here,
/// Java/Kotlin, use C-style block comments).
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
