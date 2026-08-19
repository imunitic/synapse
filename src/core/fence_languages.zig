//! Which fence language a crux block's file extension gets, customizably.
//!
//! `emit.languageFor`'s hardcoded table is the fallback of last resort --
//! used only when no `synapse-fence-languages.conf` resolves at all (before
//! `setup.sh` has run, or a hermetic test environment). Once a real file
//! resolves -- normally seeded verbatim from `plugins/synapse/synapse-fence-languages
//! .conf.template` at install time -- it is authoritative: an extension the
//! file doesn't mention is simply unmapped, never silently filled in from
//! the hardcoded table. Same "resolved file replaces, doesn't merge with,
//! the built-in default" rule `core.conf.vaultDir` already applies.
//!
//! A flat JSON object (`{".ext": "lang"}`), not `kind_synonyms.RuleList`'s
//! ordered-array shape: there is no precedence question here, since a path
//! can only genuinely end in one of the registered extensions at a time
//! (`.kt`/`.kts` don't collide, nor does any other pair in the shipped
//! table) -- a keyed object is the simpler, equally correct shape.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// `~/.claude/synapse-fence-languages.conf` (or wherever it resolved to via
/// `core.conf.resolveConfPath`): a JSON object, `{".ext": "lang", ...}`.
pub const Registry = struct {
    /// Null means no conf resolved anywhere -- `languageFor` falls back to
    /// `emit.languageFor`'s hardcoded table. A resolved-but-malformed file
    /// is a load-time error instead (see `load`), not folded into this.
    parsed: ?std.json.Parsed(std.json.Value),

    pub fn load(gpa: Allocator, io: Io, path: []const u8) !Registry {
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return .{ .parsed = null },
            else => return e,
        };
        defer gpa.free(bytes);
        return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
    }

    pub fn deinit(self: *Registry) void {
        if (self.parsed) |*p| p.deinit();
    }

    /// The fence language for `path`'s extension. A resolved conf is
    /// authoritative -- no match found in it returns `""`, the same "no
    /// fence language" result `emit.languageFor` returns for an unmapped
    /// extension, never a fall-through to the hardcoded table underneath.
    pub fn languageFor(self: Registry, path: []const u8) []const u8 {
        const p = self.parsed orelse return @import("emit.zig").languageFor(path);
        const obj = switch (p.value) {
            .object => |o| o,
            else => return "",
        };
        var it = obj.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            if (std.mem.endsWith(u8, path, entry.key_ptr.*)) return entry.value_ptr.*.string;
        }
        return "";
    }
};

const testing = std.testing;

test "Registry: an absent file falls back to emit.languageFor's built-in table" {
    const gpa = testing.allocator;
    var reg = try Registry.load(gpa, testing.io, "/nonexistent/synapse-fence-languages.conf");
    defer reg.deinit();
    try testing.expectEqualStrings("java", reg.languageFor("x/Foo.java"));
    try testing.expectEqualStrings("zig", reg.languageFor("x/Foo.zig"));
    try testing.expectEqualStrings("", reg.languageFor("x/Foo.md")); // not in the hardcoded table
}

test "Registry: a resolved conf is authoritative, even for an extension the hardcoded table also knows" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{".java": "not-java-anymore", ".zig": "zig"}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();
    try testing.expectEqualStrings("not-java-anymore", reg.languageFor("x/Foo.java"));
    try testing.expectEqualStrings("zig", reg.languageFor("x/Foo.zig"));
}

test "Registry: a resolved conf with no match returns empty, not the hardcoded table's answer" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{".zig": "zig"}
    , .{});
    var reg: Registry = .{ .parsed = parsed };
    defer reg.deinit();
    // Unmapped in this conf -- even though the hardcoded emit.languageFor knows ".java".
    try testing.expectEqualStrings("", reg.languageFor("x/Foo.java"));
}

test "Registry: a malformed file is a load error, not a silent fallback" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "synapse-fence-languages.conf", .data = "not json" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fmt.allocPrint(gpa, "{s}/synapse-fence-languages.conf", .{dir});
    defer gpa.free(path);
    try testing.expectError(error.SyntaxError, Registry.load(gpa, io, path));
}
