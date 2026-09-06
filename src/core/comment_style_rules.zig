//! The docstring style rubric: plain-English rules applied by inference
//! against a docstring's actual text, not by grep and not machine-parsed --
//! the phrase-grep first filter (historian-plague tells) is separate and
//! cheap; this is the second, judgment-requiring half of the same
//! inspection pass.
//!
//! `synapse-comment-style-rules.conf` ships empty, the same "ship empty,
//! earn every rule" shape every other self-populating `synapse-*.conf`
//! file already has: no rule here presumes one team's stylistic taste is
//! universal. Self-managed by the inspection pass itself -- whenever a
//! human flags a style problem the inference check missed, the agent
//! fixes the instance and appends the rule that would have caught it --
//! but also a plain, human-editable text file, safe to seed or edit by
//! hand any time.

const std = @import("std");
const conf = @import("conf.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const conf_name = "synapse-comment-style-rules.conf";

/// The rubric's raw text, resolved via the same tiered lookup every other
/// `synapse-*.conf` reader uses -- an empty string when nothing resolves
/// anywhere (no conf file at any tier), the same "ships empty" result as a
/// freshly-seeded, still-empty one. A caller judging a docstring by
/// inference reads this text directly; nothing here parses it into rules.
pub fn read(gpa: Allocator, io: Io, vars: conf.Vars) ![]u8 {
    const path = (try conf.resolveConfPath(gpa, io, vars, conf_name)) orelse
        return gpa.dupe(u8, "");
    defer gpa.free(path);
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return e,
    };
}

/// The classic historian-plague tells: a docstring narrating how code
/// changed rather than describing what's true now. A free, cheap first
/// filter over a docstring's own text -- it only catches phrasing that
/// hits one of these words exactly; `read`'s rubric, judged by inference,
/// catches what this misses, in the same inspection pass rather than a
/// second, disconnected mechanism.
const historian_phrases = [_][]const u8{ "no longer", "used to", "any more" };

/// The first historian-plague phrase found in `text`, case-insensitive, or
/// null if none hit.
pub fn historianPlaguePhrase(text: []const u8) ?[]const u8 {
    for (historian_phrases) |phrase| {
        if (containsCaseInsensitive(text, phrase)) return phrase;
    }
    return null;
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

const testing = std.testing;

test "historianPlaguePhrase: catches each configured tell, case-insensitively" {
    try testing.expectEqualStrings("no longer", historianPlaguePhrase("This no longer does X.").?);
    try testing.expectEqualStrings("used to", historianPlaguePhrase("USED TO be simpler.").?);
    try testing.expectEqualStrings("any more", historianPlaguePhrase("Not needed any more.").?);
}

test "historianPlaguePhrase: clean present-tense prose is not flagged" {
    try testing.expectEqual(@as(?[]const u8, null), historianPlaguePhrase("Computes the checksum over the byte range."));
}

test "historianPlaguePhrase: a plain substring match, deliberately not word-boundary-aware" {
    // "used to" is a literal substring of "used tools" -- this is the
    // accepted cost of a cheap first filter, not a bug: the design's own
    // framing is "catches phrasing that hits an exact keyword," never
    // claiming precision. The inference-based rubric check is what tells
    // a real hit apart from this kind of accidental one.
    try testing.expectEqualStrings("used to", historianPlaguePhrase("The bonus edict used tools.").?);
}

test "no conf resolved anywhere reads as empty, not an error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const TestVars = struct {
        home: []const u8,
        fn vars(self: *const @This()) conf.Vars {
            return .{ .ctx = @constCast(@ptrCast(self)), .getFn = lookup };
        }
        fn lookup(ctx: *anyopaque, name: []const u8) ?[]const u8 {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "HOME")) return self.home;
            return null;
        }
    };
    const tv: TestVars = .{ .home = home };

    const text = try read(gpa, testing.io, tv.vars());
    defer gpa.free(text);
    try testing.expectEqualStrings("", text);
}

test "a resolved conf's real text comes back verbatim" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.createDirPath(testing.io, ".claude");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".claude/" ++ conf_name,
        .data = "Never narrate a removed feature's absence.\n",
    });

    const TestVars = struct {
        home: []const u8,
        fn vars(self: *const @This()) conf.Vars {
            return .{ .ctx = @constCast(@ptrCast(self)), .getFn = lookup };
        }
        fn lookup(ctx: *anyopaque, name: []const u8) ?[]const u8 {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "HOME")) return self.home;
            return null;
        }
    };
    const tv: TestVars = .{ .home = home };

    const text = try read(gpa, testing.io, tv.vars());
    defer gpa.free(text);
    try testing.expectEqualStrings("Never narrate a removed feature's absence.\n", text);
}
