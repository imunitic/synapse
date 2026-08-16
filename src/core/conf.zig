//! `~/.claude/synapse.conf`, read directly -- shell syntax, one key that matters
//! outside a shell: `OBSIDIAN_VAULT_DIR`.
//!
//! Values expand like a shell expands a path: `KEY=value`, `KEY="value"`,
//! comments, blank lines, an `export` prefix, and inside a value a leading `~`,
//! `$VAR`/`${VAR}` against whatever the caller's environment holds -- not just
//! `$HOME` as a special case. Expansion is required: the shipped template
//! writes `OBSIDIAN_VAULT_DIR="$HOME/Obsidian/YourVault"`, and a literal read
//! resolves a vault at `./$HOME/Obsidian/Claude`. An unset variable expands to
//! nothing, as a shell does; the caller reports the resulting bad path rather
//! than a guess being substituted.
//!
//! Not supported, and left literal: `~user`, `${VAR:-default}` and the rest of
//! parameter expansion, command substitution, arithmetic. `\$` escapes a
//! literal `$`.
//!
//! `second-brain.conf` (this file's name before 2026-08-04) is tried as a
//! fallback, for a machine that hasn't been re-installed since.

const std = @import("std");

/// The two names, in the order they are tried.
pub const file_names = [_][]const u8{ "synapse.conf", "second-brain.conf" };

/// Where a variable's value comes from. A parameter rather than a lookup,
/// since `core` may only reach the system through an injected `Io` -- this
/// keeps expansion testable without a real environment variable.
pub const Vars = struct {
    ctx: *anyopaque,
    getFn: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,

    pub fn get(self: Vars, name: []const u8) ?[]const u8 {
        return self.getFn(self.ctx, name);
    }

    /// A `Vars` that knows nothing, for a caller with no environment to offer.
    pub const none: Vars = .{ .ctx = undefined, .getFn = noneGet };

    fn noneGet(_: *anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }
};

/// One key's value, expanded. The caller owns the result.
pub fn value(
    gpa: std.mem.Allocator,
    text: []const u8,
    key: []const u8,
    vars: Vars,
) !?[]u8 {
    const raw = get(text, key) orelse return null;
    return try expand(gpa, raw, vars);
}

/// A leading `~`, `$VAR` and `${VAR}` replaced; everything else literal.
pub fn expand(gpa: std.mem.Allocator, raw: []const u8, vars: Vars) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    // `~` only at the start, whole value or before `/` -- `a~b` is untouched,
    // and `~user` is a different feature entirely.
    if (raw.len != 0 and raw[0] == '~' and (raw.len == 1 or raw[1] == '/')) {
        if (vars.get("HOME")) |home| try out.appendSlice(gpa, home);
        i = 1;
    }

    while (i < raw.len) {
        // `\$` is a literal `$`; any other backslash is left alone (a Windows
        // path is not an escape sequence).
        if (raw[i] == '\\' and i + 1 < raw.len and raw[i + 1] == '$') {
            try out.append(gpa, '$');
            i += 2;
            continue;
        }
        if (raw[i] != '$') {
            try out.append(gpa, raw[i]);
            i += 1;
            continue;
        }

        const after = raw[i + 1 ..];
        if (after.len != 0 and after[0] == '{') {
            const close = std.mem.indexOfScalar(u8, after, '}') orelse {
                // Unterminated: left literal rather than guessed at.
                try out.append(gpa, raw[i]);
                i += 1;
                continue;
            };
            const name = after[1..close];
            if (!isName(name)) {
                // `${VAR:-default}` and friends: not supported, not touched.
                try out.append(gpa, raw[i]);
                i += 1;
                continue;
            }
            if (vars.get(name)) |v| try out.appendSlice(gpa, v);
            i += 1 + close + 1;
            continue;
        }

        const len = nameLen(after);
        if (len == 0) {
            // A `$` starting no name (`$/`, `$1`, trailing `$`) is just a `$`.
            try out.append(gpa, raw[i]);
            i += 1;
            continue;
        }
        if (vars.get(after[0..len])) |v| try out.appendSlice(gpa, v);
        i += 1 + len;
    }
    return out.toOwnedSlice(gpa);
}

/// `[A-Za-z_][A-Za-z0-9_]*`, the shell's own rule for an unbraced name.
fn nameLen(s: []const u8) usize {
    if (s.len == 0) return 0;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return 0;
    var n: usize = 1;
    while (n < s.len and (std.ascii.isAlphanumeric(s[n]) or s[n] == '_')) n += 1;
    return n;
}

fn isName(s: []const u8) bool {
    return s.len != 0 and nameLen(s) == s.len;
}

/// One key's raw value from a conf file's text, unexpanded, or null.
pub fn get(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line[7..], " \t");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = line[key.len..];
        if (rest.len == 0 or rest[0] != '=') continue;
        found = unquote(std.mem.trim(u8, rest[1..], " \t")); // last assignment wins
    }
    return found;
}

/// A shell-ish scalar: matched quotes stripped, an unquoted trailing comment cut.
fn unquote(raw: []const u8) []const u8 {
    if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\'') and raw[raw.len - 1] == raw[0])
        return raw[1 .. raw.len - 1];
    var end = raw.len;
    for (raw, 0..) |c, i| if (c == '#' or c == ' ' or c == '\t') {
        end = i;
        break;
    };
    return raw[0..end];
}

const testing = std.testing;

test "the shipped template's shape" {
    const text =
        "# Copy this to ~/.claude/synapse.conf\n" ++
        "OBSIDIAN_VAULT_DIR=\"/Users/x/Obsidian/Claude\"\n";
    try testing.expectEqualStrings("/Users/x/Obsidian/Claude", get(text, "OBSIDIAN_VAULT_DIR").?);
    try testing.expectEqual(@as(?[]const u8, null), get(text, "SOMETHING_ELSE"));
}

test "quoting, comments and export all read the same" {
    try testing.expectEqualStrings("/v", get("OBSIDIAN_VAULT_DIR=/v\n", "OBSIDIAN_VAULT_DIR").?);
    try testing.expectEqualStrings("/v", get("OBSIDIAN_VAULT_DIR='/v'\n", "OBSIDIAN_VAULT_DIR").?);
    try testing.expectEqualStrings("/v", get("export OBSIDIAN_VAULT_DIR=\"/v\"\n", "OBSIDIAN_VAULT_DIR").?);
    try testing.expectEqualStrings("/v", get("OBSIDIAN_VAULT_DIR=/v  # trailing\n", "OBSIDIAN_VAULT_DIR").?);
    try testing.expectEqualStrings("", get("OBSIDIAN_VAULT_DIR=\n", "OBSIDIAN_VAULT_DIR").?);
}

test "a path with a space needs its quotes, and keeps them" {
    try testing.expectEqualStrings(
        "/Users/x/My Vault",
        get("OBSIDIAN_VAULT_DIR=\"/Users/x/My Vault\"\n", "OBSIDIAN_VAULT_DIR").?,
    );
}

test "a longer key is not matched by a shorter one" {
    const text = "OBSIDIAN_VAULT_DIR_OLD=/old\n";
    try testing.expectEqual(@as(?[]const u8, null), get(text, "OBSIDIAN_VAULT_DIR"));
}

test "the last assignment wins, as sourcing would" {
    const text = "OBSIDIAN_VAULT_DIR=/first\nOBSIDIAN_VAULT_DIR=/second\n";
    try testing.expectEqualStrings("/second", get(text, "OBSIDIAN_VAULT_DIR").?);
}

test "a commented-out assignment is not one" {
    try testing.expectEqual(
        @as(?[]const u8, null),
        get("# OBSIDIAN_VAULT_DIR=/nope\n", "OBSIDIAN_VAULT_DIR"),
    );
}

/// Resolves a synapse-*.conf filename to the first tier that exists on
/// disk: `$XDG_CONFIG_HOME/synapse/{name}` (or `~/.config/synapse/{name}`
/// if `XDG_CONFIG_HOME` is unset), then `~/.claude/{name}`. Null if
/// neither exists -- callers decide what "unconfigured" means for their
/// own conf. `$XDG_CONFIG_HOME` is checked, never assumed unset, because
/// that is the one thing that makes tier 1 actually XDG-compliant rather
/// than a hardcoded `~/.config` guess.
///
/// `~/.claude/{name}` survives indefinitely as tier 2, not as a stopgap:
/// every existing install already has its conf there, and an install that
/// never creates an XDG file must keep resolving exactly as it does today,
/// unconditionally. Tier 1 wins when both exist -- `$XDG_CONFIG_HOME/synapse/`
/// (or `~/.config/synapse/`) is namespaced to this tool specifically, so
/// nothing else creates it by accident; the only realistic way it exists is
/// a deliberate choice, and a user who just made that choice expects it to
/// take effect immediately, not to also have to delete the old file.
pub fn resolveConfPath(gpa: std.mem.Allocator, io: std.Io, vars: Vars, name: []const u8) !?[]u8 {
    const home = vars.get("HOME");

    if (vars.get("XDG_CONFIG_HOME")) |xdg| if (xdg.len != 0) {
        if (try tryConfPath(gpa, io, "{s}/synapse/{s}", .{ xdg, name })) |p| return p;
    };
    if (home) |h| {
        if (try tryConfPath(gpa, io, "{s}/.config/synapse/{s}", .{ h, name })) |p| return p;
    }
    if (home) |h| {
        if (try tryConfPath(gpa, io, "{s}/.claude/{s}", .{ h, name })) |p| return p;
    }
    return null;
}

/// Formats one candidate path and returns it if it exists on disk, freeing
/// it and returning null otherwise -- the one check `resolveConfPath`'s
/// three tiers share.
fn tryConfPath(gpa: std.mem.Allocator, io: std.Io, comptime fmt: []const u8, args: anytype) !?[]u8 {
    const path = try std.fmt.allocPrint(gpa, fmt, args);
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return path else |_| {
        gpa.free(path);
        return null;
    }
}

/// The vault directory: the override first, then each conf file in turn,
/// each resolved through `resolveConfPath`'s tier order. The environment
/// wins since that's how a caller pins a vault deliberately (the bats suite
/// does, against a fixture). Null means nothing names one.
pub fn vaultDir(gpa: std.mem.Allocator, io: std.Io, vars: Vars) !?[]u8 {
    if (vars.get("OBSIDIAN_VAULT_DIR")) |v| if (v.len != 0) return try gpa.dupe(u8, v);
    for (file_names) |name| {
        const path = (try resolveConfPath(gpa, io, vars, name)) orelse continue;
        defer gpa.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(text);
        const found = (try value(gpa, text, "OBSIDIAN_VAULT_DIR", vars)) orelse continue;
        if (found.len == 0) {
            gpa.free(found);
            continue;
        }
        return found;
    }
    return null;
}

/// A `Vars` over a fixed table, for the tests.
const TestVars = struct {
    pairs: []const [2][]const u8,

    fn vars(self: *const TestVars) Vars {
        return .{ .ctx = @constCast(@ptrCast(self)), .getFn = lookup };
    }

    fn lookup(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *const TestVars = @ptrCast(@alignCast(ctx));
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
};

test "the real conf's shape: $HOME inside a quoted value" {
    const gpa = testing.allocator;
    const tv: TestVars = .{ .pairs = &.{.{ "HOME", "/Users/x" }} };
    const text = "OBSIDIAN_VAULT_DIR=\"$HOME/Obsidian/YourVault\"\n";
    const v = (try value(gpa, text, "OBSIDIAN_VAULT_DIR", tv.vars())).?;
    defer gpa.free(v);
    try testing.expectEqualStrings("/Users/x/Obsidian/YourVault", v);
}

test "any variable expands, not a hardcoded list" {
    const gpa = testing.allocator;
    const tv: TestVars = .{ .pairs = &.{
        .{ "CASA", "/casa" },
        .{ "XDG_DATA_HOME", "/xdg" },
        .{ "HOME", "/h" },
    } };
    for ([_][2][]const u8{
        .{ "$CASA/vault", "/casa/vault" },
        .{ "${CASA}/vault", "/casa/vault" },
        .{ "$XDG_DATA_HOME/obsidian", "/xdg/obsidian" },
        .{ "~/Obsidian", "/h/Obsidian" },
        .{ "~", "/h" },
        .{ "$HOME/a/$CASA", "/h/a/casa" },
    }, 0..) |case, n| {
        const got = try expand(gpa, case[0], tv.vars());
        defer gpa.free(got);
        // Case 5 catches an off-by-one in the name length.
        if (n == 5) {
            try testing.expectEqualStrings("/h/a//casa", got);
        } else try testing.expectEqualStrings(case[1], got);
    }
}

test "an unset variable expands to nothing, as a shell does" {
    const gpa = testing.allocator;
    const tv: TestVars = .{ .pairs = &.{} };
    const got = try expand(gpa, "$CASA/vault", tv.vars());
    defer gpa.free(got);
    try testing.expectEqualStrings("/vault", got);
}

test "what stays literal" {
    const gpa = testing.allocator;
    const tv: TestVars = .{ .pairs = &.{ .{ "HOME", "/h" }, .{ "V", "x" } } };
    for ([_][2][]const u8{
        .{ "/a/~/b", "/a/~/b" },
        .{ "~user/x", "~user/x" },
        .{ "/a$/b", "/a$/b" },
        .{ "/a$1/b", "/a$1/b" },
        .{ "trailing$", "trailing$" },
        .{ "${V:-default}", "${V:-default}" },
        .{ "${unterminated", "${unterminated" },
        .{ "\\$V", "$V" },
        .{ "C:\\dir", "C:\\dir" },
    }) |case| {
        const got = try expand(gpa, case[0], tv.vars());
        defer gpa.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
}

test "a Vars that knows nothing drops every reference" {
    const gpa = testing.allocator;
    const got = try expand(gpa, "$HOME/x", Vars.none);
    defer gpa.free(got);
    try testing.expectEqualStrings("/x", got);
}

test "resolveConfPath: tier 1 (XDG_CONFIG_HOME) wins over tier 2 (~/.claude) when both exist" {
    const gpa = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];

    const xdg_dir = try std.fmt.allocPrint(gpa, "{s}/xdg/synapse", .{home});
    defer gpa.free(xdg_dir);
    try cwd.createDirPath(io, xdg_dir);
    const xdg_file = try std.fmt.allocPrint(gpa, "{s}/xdg/synapse/foo.conf", .{home});
    defer gpa.free(xdg_file);
    try cwd.writeFile(io, .{ .sub_path = xdg_file, .data = "xdg" });

    const claude_dir = try std.fmt.allocPrint(gpa, "{s}/.claude", .{home});
    defer gpa.free(claude_dir);
    try cwd.createDirPath(io, claude_dir);
    const claude_file = try std.fmt.allocPrint(gpa, "{s}/.claude/foo.conf", .{home});
    defer gpa.free(claude_file);
    try cwd.writeFile(io, .{ .sub_path = claude_file, .data = "claude" });

    const xdg_home = try std.fmt.allocPrint(gpa, "{s}/xdg", .{home});
    defer gpa.free(xdg_home);
    const tv: TestVars = .{ .pairs = &.{ .{ "XDG_CONFIG_HOME", xdg_home }, .{ "HOME", home } } };

    const got = (try resolveConfPath(gpa, io, tv.vars(), "foo.conf")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings(xdg_file, got);
}

test "resolveConfPath: XDG_CONFIG_HOME unset falls back to ~/.config/synapse, still ahead of ~/.claude" {
    const gpa = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];

    const xdg_dir = try std.fmt.allocPrint(gpa, "{s}/.config/synapse", .{home});
    defer gpa.free(xdg_dir);
    try cwd.createDirPath(io, xdg_dir);
    const xdg_file = try std.fmt.allocPrint(gpa, "{s}/.config/synapse/foo.conf", .{home});
    defer gpa.free(xdg_file);
    try cwd.writeFile(io, .{ .sub_path = xdg_file, .data = "dot-config" });

    const claude_dir = try std.fmt.allocPrint(gpa, "{s}/.claude", .{home});
    defer gpa.free(claude_dir);
    try cwd.createDirPath(io, claude_dir);
    const claude_file = try std.fmt.allocPrint(gpa, "{s}/.claude/foo.conf", .{home});
    defer gpa.free(claude_file);
    try cwd.writeFile(io, .{ .sub_path = claude_file, .data = "claude" });

    const tv: TestVars = .{ .pairs = &.{.{ "HOME", home }} }; // no XDG_CONFIG_HOME
    const got = (try resolveConfPath(gpa, io, tv.vars(), "foo.conf")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings(xdg_file, got);
}

test "resolveConfPath: neither XDG location has the file, ~/.claude wins, unchanged from today" {
    const gpa = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];

    const claude_dir = try std.fmt.allocPrint(gpa, "{s}/.claude", .{home});
    defer gpa.free(claude_dir);
    try cwd.createDirPath(io, claude_dir);
    const claude_file = try std.fmt.allocPrint(gpa, "{s}/.claude/foo.conf", .{home});
    defer gpa.free(claude_file);
    try cwd.writeFile(io, .{ .sub_path = claude_file, .data = "claude" });

    const tv: TestVars = .{ .pairs = &.{.{ "HOME", home }} };
    const got = (try resolveConfPath(gpa, io, tv.vars(), "foo.conf")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings(claude_file, got);
}

test "resolveConfPath: null when the file exists nowhere" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];

    const tv: TestVars = .{ .pairs = &.{.{ "HOME", home }} };
    try testing.expectEqual(@as(?[]u8, null), try resolveConfPath(gpa, io, tv.vars(), "foo.conf"));
}
