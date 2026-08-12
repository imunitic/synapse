//! `~/.claude/synapse.conf`, read directly.
//!
//! The file is shell -- every component `source`d it -- and it holds one key that
//! matters outside a shell: `OBSIDIAN_VAULT_DIR`. Reading it here is what makes the
//! binaries self-sufficient: a wrapper existed partly to source this and export the
//! result, and a wrapper that does nothing else is a process for nothing.
//!
//! ## Values expand the way a shell expands a path
//!
//! `KEY=value`, `KEY="value"`, comments, blank lines, an `export` prefix -- and inside
//! a value, a leading `~`, `$VAR` and `${VAR}` against whatever the caller's
//! environment holds. Not `$HOME` as a special case: the shipped template happens to
//! write `$HOME`, but a conf saying `$CASA/vault` or `$XDG_DATA_HOME/obsidian` is an
//! ordinary conf and the reader should not need to have anticipated the name.
//!
//! Expanding at all is not optional. Sourcing this file was load-bearing precisely
//! because the template writes `OBSIDIAN_VAULT_DIR="$HOME/Obsidian/YourVault"`, and a
//! reader that took the value literally resolved a vault at `./$HOME/Obsidian/Claude`
//! -- which reported "no namespace covers …", a message that reads like a missing graph
//! rather than a misparsed path. That is what the first version of this file did.
//!
//! An unset variable expands to nothing, which is what a shell does. The resulting
//! path then fails to resolve and the caller says so; substituting a guess would turn
//! a typo in a conf into a vault somewhere unintended.
//!
//! What is deliberately *not* supported, and stays literal: `~user` (a shell resolves
//! that through the password database), `${VAR:-default}` and the rest of the
//! parameter-expansion grammar, command substitution, and arithmetic. A conf using one
//! would be a conf only a shell could read, which is the coupling this removes. `\$`
//! is an escape for a literal `$`, as it is inside a double-quoted shell string.
//!
//! ## Why the pre-rename name is still tried
//!
//! `second-brain.conf` is what this file was called before 2026-08-04. Every script
//! carried the fallback so a component updated ahead of `setup.sh` would find an
//! existing config rather than reporting "no vault", and that reasoning has not
//! expired -- an installed machine may still have only the old name.

const std = @import("std");

/// The two names, in the order they are tried.
pub const file_names = [_][]const u8{ "synapse.conf", "second-brain.conf" };

/// Where a variable's value comes from.
///
/// A parameter rather than a lookup, because `ci/check-layering.sh` forbids `core` from
/// naming `std.process`: this module may reach the system only through an injected `Io`,
/// and the environment is ambient state that would otherwise not appear in any
/// signature. The practical gain is that the expansion below is testable without ever
/// setting a real variable.
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
    // `~` only at the start, and only as the whole value or before a separator --
    // a shell expands `~` at word start and leaves `a~b` alone, and `~user` is a
    // different feature entirely.
    if (raw.len != 0 and raw[0] == '~' and (raw.len == 1 or raw[1] == '/')) {
        if (vars.get("HOME")) |home| try out.appendSlice(gpa, home);
        i = 1;
    }

    while (i < raw.len) {
        // `\$` is a literal `$`, as inside a double-quoted shell string. Any other
        // backslash is left alone: a Windows path in a conf is not an escape sequence.
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
                // Unterminated: literal, because guessing where it ended is worse
                // than leaving a visibly broken value visibly broken.
                try out.append(gpa, raw[i]);
                i += 1;
                continue;
            };
            const name = after[1..close];
            if (!isName(name)) {
                // `${VAR:-default}` and friends: not supported, so not touched.
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
            // A `$` that starts no name -- `$/`, `$1`, a trailing `$` -- is a `$`.
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
        // `export KEY=...` is valid shell and appears in hand-edited configs.
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line[7..], " \t");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = line[key.len..];
        if (rest.len == 0 or rest[0] != '=') continue;
        // Last assignment wins, which is what sourcing the file would have done.
        found = unquote(std.mem.trim(u8, rest[1..], " \t"));
    }
    return found;
}

/// A shell-ish scalar: matched quotes stripped, an unquoted trailing comment cut.
fn unquote(raw: []const u8) []const u8 {
    if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\'') and raw[raw.len - 1] == raw[0])
        return raw[1 .. raw.len - 1];
    // An unquoted value ends at whitespace or a comment, as the shell would have it.
    var end = raw.len;
    for (raw, 0..) |c, i| if (c == '#' or c == ' ' or c == '\t') {
        end = i;
        break;
    };
    return raw[0..end];
}

const testing = std.testing;

test "the shipped template's shape" {
    // What `setup.sh` installs, and what every script sourced.
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
    // The case an unquoted read would silently truncate -- and a vault under
    // `~/Library/Mobile Documents/…` is an ordinary place to put one.
    try testing.expectEqualStrings(
        "/Users/x/My Vault",
        get("OBSIDIAN_VAULT_DIR=\"/Users/x/My Vault\"\n", "OBSIDIAN_VAULT_DIR").?,
    );
}

test "a longer key is not matched by a shorter one" {
    // `OBSIDIAN_VAULT_DIR_OLD=` must not answer a query for `OBSIDIAN_VAULT_DIR`:
    // the `=` check is what makes the prefix match safe.
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

/// The vault directory: the override first, then each conf file in turn.
///
/// The environment wins because that is how a caller pins a vault deliberately -- the
/// bats suite does, against a fixture vault -- and because it is what the shell
/// wrappers exported while sourcing the conf was their job.
///
/// Returns null when nothing names one, which every caller already handles: a command
/// says "no vault" and exits 1, a hook says nothing and exits 0.
/// `vars` supplies both the override and any variable a conf value references.
pub fn vaultDir(gpa: std.mem.Allocator, io: std.Io, vars: Vars) !?[]u8 {
    if (vars.get("OBSIDIAN_VAULT_DIR")) |v| if (v.len != 0) return try gpa.dupe(u8, v);
    const home = vars.get("HOME") orelse return null;
    for (file_names) |name| {
        const path = try std.fmt.allocPrint(gpa, "{s}/.claude/{s}", .{ home, name });
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
    // Verbatim from `claude/synapse.conf.template`, and from the installed conf this
    // was first tested against.
    const tv: TestVars = .{ .pairs = &.{.{ "HOME", "/Users/x" }} };
    const text = "OBSIDIAN_VAULT_DIR=\"$HOME/Obsidian/YourVault\"\n";
    const v = (try value(gpa, text, "OBSIDIAN_VAULT_DIR", tv.vars())).?;
    defer gpa.free(v);
    try testing.expectEqualStrings("/Users/x/Obsidian/YourVault", v);
}

test "any variable expands, not a hardcoded list" {
    const gpa = testing.allocator;
    // The point of the rewrite: a conf naming `$CASA` works without this file having
    // heard of it.
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
        // The last case is the one that catches an off-by-one in the name length.
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
    // The path then fails to resolve and the caller says so. Substituting a guess
    // would turn a typo in a conf into a vault somewhere unintended.
    try testing.expectEqualStrings("/vault", got);
}

test "what stays literal" {
    const gpa = testing.allocator;
    const tv: TestVars = .{ .pairs = &.{ .{ "HOME", "/h" }, .{ "V", "x" } } };
    for ([_][2][]const u8{
        // `~` only at word start, as in a shell.
        .{ "/a/~/b", "/a/~/b" },
        .{ "~user/x", "~user/x" },
        // A `$` that starts no name.
        .{ "/a$/b", "/a$/b" },
        .{ "/a$1/b", "/a$1/b" },
        .{ "trailing$", "trailing$" },
        // Parameter expansion beyond a plain name is not supported, so not touched.
        .{ "${V:-default}", "${V:-default}" },
        .{ "${unterminated", "${unterminated" },
        // An escape for a literal `$`, and a backslash that is not one.
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

