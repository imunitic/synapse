//! Static text/doc consistency checks: no binary spawn, no Zig function
//! under test, just the shipped docs and scripts read directly and compared
//! against each other or against a fixed pattern.

const std = @import("std");
const testing = std.testing;
const Dir = std.Io.Dir;
const io = std.testing.io;

fn readAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20));
}

test "the committed docs/synapse/cli.md keeps every fence on its own line" {
    // `$(...)` strips trailing newlines, so a closing fence printed directly
    // after help text can land on the same line as that text and close
    // nothing -- every block from there on opens where it should have
    // closed, and an unfenced `<file>`/`<node>`/`<s>` then reaches a
    // Markdown renderer as an HTML tag.
    const gpa = testing.allocator;
    const doc = try readAlloc(gpa, "docs/synapse/cli.md");
    defer gpa.free(doc);

    var fence_count: usize = 0;
    var in_fence = false;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.indexOf(u8, line, "```") != null) {
            try testing.expectEqualStrings("```", line);
            fence_count += 1;
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        for (line, 0..) |c, i| {
            if (c != '<') continue;
            const next_c = if (i + 1 < line.len) line[i + 1] else 0;
            if (std.ascii.isAlphabetic(next_c) or next_c == '/') {
                std.debug.print("cli.md:{d}: unfenced angle bracket: {s}\n", .{ line_no, line });
                return error.UnfencedAngleBracket;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), fence_count % 2);
}

test "no shipped .sh hook calls mktemp without an explicit template" {
    // macOS `mktemp`/`mktemp -d` ignore TMPDIR unless given a template, so a
    // bare call writes to the system temp dir regardless of the caller's
    // intent. Every shipped hook is `.cjs` today (Node's own mktemp
    // equivalents already respect TMPDIR) -- this stays in place so it
    // starts checking again the moment a `.sh` hook reappears.
    const gpa = testing.allocator;
    var dir = Dir.cwd().openDir(io, "packages/synapse/lib", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sh")) continue;
        const data = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const at = std.mem.indexOf(u8, line, "mktemp") orelse continue;
            var after = line[at + "mktemp".len ..];
            after = std.mem.trimStart(u8, after, " ");
            if (std.mem.startsWith(u8, after, "-d")) after = std.mem.trimStart(u8, after[2..], " ");
            const bare = after.len == 0 or after[0] == ')' or after[0] == '|';
            if (bare) {
                std.debug.print("{s}: bare mktemp (no template): {s}\n", .{ entry.name, line });
                return error.BareMktemp;
            }
        }
    }
}

fn hasLegacyShellEntryPoint(line: []const u8) bool {
    const prefixes = [_][]const u8{ "synapse", "second-brain" };
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        for (prefixes) |p| {
            if (!std.mem.startsWith(u8, line[i..], p)) continue;
            var j = i + p.len;
            while (j < line.len and (std.ascii.isLower(line[j]) or line[j] == '-')) j += 1;
            if (std.mem.startsWith(u8, line[j..], ".sh")) return true;
        }
    }
    return false;
}

fn hasKnownDeadIdentifier(line: []const u8) bool {
    const needle = "~/.synapse";
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, needle)) |pos| {
        const after = pos + needle.len;
        if (after >= line.len or !(std.ascii.isAlphanumeric(line[after]) or line[after] == '_')) return true;
        start = pos + 1;
    }
    return false;
}

test "no shipped instruction names a deleted shell entry point or a known-dead identifier" {
    // The rewrite deleted every `*.sh` entry point (`synapse-tags-cache.sh`
    // and its siblings) in favor of the compiled binary. Matched with a
    // trailing `.sh` so this never fires on the binary's own subcommands,
    // and so a source comment recording provenance stays legal -- comments
    // are history and belong in the code, but nothing a model or a user is
    // told to run may name one. `~/.synapse` is the pre-npm config path,
    // fixed once already and guarded here so a regression is caught
    // mechanically rather than rediscovered by hand a second time.
    const gpa = testing.allocator;
    var dir = try Dir.cwd().openDir(io, "packages/synapse", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var bad: std.ArrayListUnmanaged(u8) = .empty;
    defer bad.deinit(gpa);

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".md")) continue;
        const data = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(1 << 20));
        defer gpa.free(data);
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (!hasLegacyShellEntryPoint(line) and !hasKnownDeadIdentifier(line)) continue;
            const msg = try std.fmt.allocPrint(gpa, "  packages/synapse/{s}:{d}: {s}\n", .{ entry.path, line_no, line });
            defer gpa.free(msg);
            try bad.appendSlice(gpa, msg);
        }
    }
    try testing.expectEqualStrings("", bad.items);
}

const TemplateItem = struct { schema: []const u8, item: []const u8 };

/// Every fenced ``` block containing a `schema: vault-*` line in `text`, as
/// one `{schema, "field:<name>"}`/`{schema, "heading:<text>"}` entry per
/// frontmatter field or Markdown heading found inside it. Leading
/// indentation is stripped per line first, since a template embedded inside
/// a numbered list step is indented, unlike a top-level one. Keyed by
/// schema id rather than file position, so a file embedding more than one
/// template compares each against its own counterpart in the mirror, not
/// whichever template happens to come first in either file. Caller frees
/// both the slice and each `.item`.
fn templateFieldsAndHeadings(gpa: std.mem.Allocator, text: []const u8) ![]TemplateItem {
    var out: std.ArrayListUnmanaged(TemplateItem) = .empty;
    errdefer {
        for (out.items) |it| gpa.free(it.item);
        out.deinit(gpa);
    }

    var in_fence = false;
    var fm = false;
    var schema: []const u8 = "";
    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    defer items.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (std.mem.startsWith(u8, line, "```")) {
            if (in_fence) {
                if (schema.len != 0) {
                    for (items.items) |it| try out.append(gpa, .{ .schema = schema, .item = it });
                } else {
                    for (items.items) |it| gpa.free(it);
                }
                items.clearRetainingCapacity();
                in_fence = false;
            } else {
                in_fence = true;
                schema = "";
                fm = false;
            }
            continue;
        }
        if (!in_fence) continue;
        if (std.mem.eql(u8, line, "---")) {
            fm = !fm;
            continue;
        }
        if (fm and std.mem.startsWith(u8, line, "schema: ")) {
            schema = line["schema: ".len..];
            continue;
        }
        if (fm) {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const key = line[0..colon];
                var is_field_key = key.len != 0;
                for (key) |c| {
                    if (!(std.ascii.isLower(c) or c == '_')) {
                        is_field_key = false;
                        break;
                    }
                }
                if (is_field_key) {
                    try items.append(gpa, try std.fmt.allocPrint(gpa, "field:{s}", .{key}));
                    continue;
                }
            }
        }
        if (line.len != 0 and line[0] == '#') {
            var i: usize = 0;
            while (i < line.len and line[i] == '#') i += 1;
            if (i < line.len and line[i] == ' ') {
                try items.append(gpa, try std.fmt.allocPrint(gpa, "heading:{s}", .{line}));
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

fn freeTemplateItems(gpa: std.mem.Allocator, items: []TemplateItem) void {
    for (items) |it| gpa.free(it.item);
    gpa.free(items);
}

test "every canonical command's note template has every field and heading in its Codex mirror" {
    // A Codex skill silently dropping a step its canonical command has is
    // the same drift class caught mechanically here instead of by
    // inspection -- scoped to what's actually safe to compare structurally
    // (the embedded note template each command produces), not the
    // surrounding prose, which legitimately differs between a
    // positional-argument slash command and Codex's own invocation style.
    const gpa = testing.allocator;
    var dir = try Dir.cwd().openDir(io, "packages/synapse/commands", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();

    var bad: std.ArrayListUnmanaged(u8) = .empty;
    defer bad.deinit(gpa);

    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const name = entry.name[0 .. entry.name.len - 3];
        const mirror_path = try std.fmt.allocPrint(gpa, "packages/synapse/harness/codex/skills/{s}/SKILL.md", .{name});
        defer gpa.free(mirror_path);
        const mirror_data = readAlloc(gpa, mirror_path) catch continue;
        defer gpa.free(mirror_data);

        const canon_data = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(canon_data);

        const canon_items = try templateFieldsAndHeadings(gpa, canon_data);
        defer freeTemplateItems(gpa, canon_items);
        if (canon_items.len == 0) continue;

        const mirror_items = try templateFieldsAndHeadings(gpa, mirror_data);
        defer freeTemplateItems(gpa, mirror_items);

        for (canon_items) |ci| {
            var found = false;
            for (mirror_items) |mi| {
                if (std.mem.eql(u8, ci.schema, mi.schema) and std.mem.eql(u8, ci.item, mi.item)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const msg = try std.fmt.allocPrint(gpa, "  {s}: {s} missing {s}\t{s}\n", .{ name, mirror_path, ci.schema, ci.item });
                defer gpa.free(msg);
                try bad.appendSlice(gpa, msg);
            }
        }
    }
    try testing.expectEqualStrings("", bad.items);
}
