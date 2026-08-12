//! `~/.claude/synapse.conf`, read directly.
//!
//! The file is shell -- every component `source`d it -- and it holds one key that
//! matters outside a shell: `OBSIDIAN_VAULT_DIR`. Reading it here is what makes the
//! binaries self-sufficient: a wrapper existed partly to source this and export the
//! result, and a wrapper that does nothing else is a process for nothing.
//!
//! ## Not a shell parser, but `$HOME` is not optional
//!
//! `KEY=value`, `KEY="value"`, comments, blank lines, an `export` prefix -- and `$HOME`
//! or `${HOME}` inside a value, because the shipped template writes
//! `OBSIDIAN_VAULT_DIR="$HOME/Obsidian/YourVault"` and every installed conf therefore
//! contains one. Sourcing the file was load-bearing for exactly that, and a reader
//! that took the value literally would resolve a vault at `./$HOME/Obsidian/Claude`
//! and report "no namespace covers …" -- which is what it did, against the real conf,
//! before this paragraph existed.
//!
//! Nothing else expands. No other variable, no command substitution, no arithmetic: a
//! conf that used one would be a conf only a shell could read, which is the coupling
//! this removes. A value this cannot parse reads as absent, and absent is already a
//! state every caller handles (silence for a hook, "no vault" for a command).
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

/// One key's value, with `$HOME` expanded. The caller owns the result.
pub fn value(
    gpa: std.mem.Allocator,
    text: []const u8,
    key: []const u8,
    home: ?[]const u8,
) !?[]u8 {
    const raw = get(text, key) orelse return null;
    return try expandHome(gpa, raw, home);
}

/// `$HOME` and `${HOME}` replaced throughout. Every other `$` is literal.
pub fn expandHome(gpa: std.mem.Allocator, raw: []const u8, home: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '$') {
            const rest = raw[i..];
            const form: ?usize = if (std.mem.startsWith(u8, rest, "${HOME}"))
                "${HOME}".len
            else if (std.mem.startsWith(u8, rest, "$HOME"))
                "$HOME".len
            else
                null;
            if (form) |len| {
                // A conf naming `$HOME` on a machine with none is broken in a way no
                // substitution can fix, so the reference is dropped rather than guessed
                // at -- the resulting path then fails to resolve and says so.
                if (home) |h| try out.appendSlice(gpa, h);
                i += len;
                continue;
            }
        }
        try out.append(gpa, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
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
/// `home` is the caller's `$HOME`, and `override` whatever the environment already
/// says. Both are parameters rather than lookups because `core` may not name
/// `std.process` -- `ci/check-layering.sh` enforces that, and it is the same rule that
/// keeps an injected `Io` the only route to the filesystem.
pub fn vaultDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    home: ?[]const u8,
    override: ?[]const u8,
) !?[]u8 {
    if (override) |v| if (v.len != 0) return try gpa.dupe(u8, v);
    const home_dir = home orelse return null;
    for (file_names) |name| {
        const path = try std.fmt.allocPrint(gpa, "{s}/.claude/{s}", .{ home_dir, name });
        defer gpa.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(text);
        const found = (try value(gpa, text, "OBSIDIAN_VAULT_DIR", home_dir)) orelse continue;
        if (found.len == 0) {
            gpa.free(found);
            continue;
        }
        return found;
    }
    return null;
}

test "the real conf's shape: $HOME inside a quoted value" {
    const gpa = testing.allocator;
    // Verbatim from `claude/synapse.conf.template`, and from the installed conf this
    // was first tested against.
    const text = "OBSIDIAN_VAULT_DIR=\"$HOME/Obsidian/YourVault\"\n";
    const v = (try value(gpa, text, "OBSIDIAN_VAULT_DIR", "/Users/x")).?;
    defer gpa.free(v);
    try testing.expectEqualStrings("/Users/x/Obsidian/YourVault", v);
}

test "both spellings expand, and every other dollar is literal" {
    const gpa = testing.allocator;
    const braced = try expandHome(gpa, "${HOME}/a", "/h");
    defer gpa.free(braced);
    try testing.expectEqualStrings("/h/a", braced);

    const bare = try expandHome(gpa, "$HOME/a/$HOME", "/h");
    defer gpa.free(bare);
    try testing.expectEqualStrings("/h/a//h", bare);

    // Not expanded: another variable, and a `$` that starts nothing.
    const other = try expandHome(gpa, "$XDG_DATA_HOME/a", "/h");
    defer gpa.free(other);
    try testing.expectEqualStrings("$XDG_DATA_HOME/a", other);

    const dollar = try expandHome(gpa, "/a$/b", "/h");
    defer gpa.free(dollar);
    try testing.expectEqualStrings("/a$/b", dollar);
}

test "a $HOME reference with no HOME drops rather than guesses" {
    const gpa = testing.allocator;
    const v = try expandHome(gpa, "$HOME/Obsidian", null);
    defer gpa.free(v);
    // The path then fails to resolve and the caller says so, which beats inventing
    // `/root` or the current directory.
    try testing.expectEqualStrings("/Obsidian", v);
}
