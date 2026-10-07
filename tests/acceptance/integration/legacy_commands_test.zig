//! The legacy-command migration guard: cross-checking a shipped skill/
//! command doc's mentioned subcommand names against the real binary's own
//! `--help` output, something a text search alone can't do.

const std = @import("std");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;
const Allocator = std.mem.Allocator;

const NameSet = std.StringHashMapUnmanaged(void);

fn freeSet(gpa: Allocator, set: *NameSet) void {
    var it = set.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    set.deinit(gpa);
}

/// Every unique word matching `^  ([a-z][a-z-]*) ` in `text` -- the
/// subcommand names a `--help` listing documents, one per line.
fn parseHelpNames(gpa: Allocator, text: []const u8) !NameSet {
    var set: NameSet = .empty;
    errdefer freeSet(gpa, &set);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len < 3 or !std.mem.startsWith(u8, line, "  ")) continue;
        const rest = line[2..];
        if (rest.len == 0 or rest[0] == ' ' or !std.ascii.isLower(rest[0])) continue;
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isLower(rest[end]) or rest[end] == '-')) end += 1;
        if (end == 0 or end >= rest.len or rest[end] != ' ') continue;
        const name = rest[0..end];
        if (set.contains(name)) continue;
        try set.put(gpa, try gpa.dupe(u8, name), {});
    }
    return set;
}

fn helpNames(fx: *Fixture, gpa: Allocator, extra: []const []const u8) !NameSet {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, extra);
    try argv.append(gpa, "--help");
    const r = try fx.runFake(argv.items);
    defer r.deinit(gpa);
    const combined = try std.fmt.allocPrint(gpa, "{s}\n{s}", .{ r.stdout, r.stderr });
    defer gpa.free(combined);
    return parseHelpNames(gpa, combined);
}

/// Every `.md` basename (no extension) under `packages/synapse/commands/`.
fn shippedCommandNames(gpa: Allocator) !NameSet {
    var set: NameSet = .empty;
    errdefer freeSet(gpa, &set);
    var dir = try std.Io.Dir.cwd().openDir(testing.io, "packages/synapse/commands", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const name = entry.name[0 .. entry.name.len - 3];
        try set.put(gpa, try gpa.dupe(u8, name), {});
    }
    return set;
}

/// The word after `prefix` in the first backtick-delimited span starting
/// with `` `prefix `` -- e.g. `prefix = "synapse query "` extracts `callers`
/// from `` `synapse query callers` ``. Only a run of `[a-z-]` counts.
fn extractAfter(text: []const u8, prefix: []const u8, gpa: Allocator, out: *NameSet) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, prefix)) |start| {
        pos = start + 1;
        const word_start = start + prefix.len;
        // The first character must be a lowercase letter, not a hyphen --
        // otherwise a flag like `--namespace` right after `synapse query `
        // matches as if it were a subcommand name.
        if (word_start >= text.len or !std.ascii.isLower(text[word_start])) continue;
        var end = word_start + 1;
        while (end < text.len and (std.ascii.isLower(text[end]) or text[end] == '-')) end += 1;
        // Must have been preceded by a backtick for the whole prefix.
        if (start == 0 or text[start - 1] != '`') continue;
        const word = text[word_start..end];
        if (out.contains(word)) continue;
        try out.put(gpa, try gpa.dupe(u8, word), {});
    }
}

/// `unknown_commands()`'s Zig equivalent: every `` `synapse <sub>` ``,
/// `` `synapse query <sub>` ``, and `` `/synapse-<command>` `` in `text`
/// that doesn't actually exist. Empty return means clean. Caller frees.
fn unknownCommands(fx: *Fixture, gpa: Allocator, text: []const u8) ![]u8 {
    var subs = try helpNames(fx, gpa, &.{});
    defer freeSet(gpa, &subs);
    var qsubs = try helpNames(fx, gpa, &.{"query"});
    defer freeSet(gpa, &qsubs);
    var cmds = try shippedCommandNames(gpa);
    defer freeSet(gpa, &cmds);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    var q_words: NameSet = .empty;
    defer freeSet(gpa, &q_words);
    try extractAfter(text, "synapse query ", gpa, &q_words);
    var qit = q_words.keyIterator();
    while (qit.next()) |w| {
        if (!qsubs.contains(w.*)) {
            const line = try std.fmt.allocPrint(gpa, "  synapse query {s}\n", .{w.*});
            defer gpa.free(line);
            try out.appendSlice(gpa, line);
        }
    }

    var s_words: NameSet = .empty;
    defer freeSet(gpa, &s_words);
    try extractAfter(text, "synapse ", gpa, &s_words);
    var sit = s_words.keyIterator();
    while (sit.next()) |w| {
        if (!subs.contains(w.*)) {
            const line = try std.fmt.allocPrint(gpa, "  synapse {s}\n", .{w.*});
            defer gpa.free(line);
            try out.appendSlice(gpa, line);
        }
    }

    var c_words: NameSet = .empty;
    defer freeSet(gpa, &c_words);
    try extractAfter(text, "/synapse-", gpa, &c_words);
    var cit = c_words.keyIterator();
    while (cit.next()) |w| {
        const full = try std.fmt.allocPrint(gpa, "synapse-{s}", .{w.*});
        defer gpa.free(full);
        if (!cmds.contains(full)) {
            const line = try std.fmt.allocPrint(gpa, "  /synapse-{s}\n", .{w.*});
            defer gpa.free(line);
            try out.appendSlice(gpa, line);
        }
    }

    return out.toOwnedSlice(gpa);
}

/// A node, as the writer would leave it: enough frontmatter for the index
/// builder to read a summary back off it.
fn stageNode(fx: *Fixture, title: []const u8, summary: []const u8) !void {
    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const dir = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}", .{ns});
    defer fx.gpa.free(dir);
    try fx.dir.createDirPath(std.testing.io, dir);

    const path = try std.fmt.allocPrint(fx.gpa, "{s}/{s}.md", .{ dir, title });
    defer fx.gpa.free(path);
    const body = try std.fmt.allocPrint(fx.gpa,
        \\---
        \\title: "{s}"
        \\summary: "{s}"
        \\node_type: synapse-node
        \\project: {s}
        \\sources:
        \\  - path: src/foo.aa
        \\    hash: y
        \\sources_digest: deadbeef
        \\stale: false
        \\built_at: "2026-01-01 00:00"
        \\---
        \\
        \\# {s}
        \\<!-- synapse:generated:start -->
        \\body
        \\<!-- synapse:generated:end -->
        \\
        \\## Notes
        \\
    , .{ title, summary, ns, title });
    defer fx.gpa.free(body);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = body });
}

test "every 'synapse <sub>' a shipped instruction names is a real subcommand" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.makeRepo(null);

    var all_text: std.ArrayListUnmanaged(u8) = .empty;
    defer all_text.deinit(testing.allocator);
    try collectMarkdown(&all_text, "packages/synapse");

    const bad = try unknownCommands(&fx, testing.allocator, all_text.items);
    defer testing.allocator.free(bad);
    try testing.expectEqualStrings("", bad);
}

/// Every `.md` file's contents under `dir`, recursively, concatenated.
fn collectMarkdown(out: *std.ArrayListUnmanaged(u8), dir_path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(testing.io, dir_path, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer testing.allocator.free(full);
        switch (entry.kind) {
            .directory => try collectMarkdown(out, full),
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
                const data = std.Io.Dir.cwd().readFileAlloc(testing.io, full, testing.allocator, .limited(4 << 20)) catch continue;
                defer testing.allocator.free(data);
                try out.appendSlice(testing.allocator, data);
                try out.append(testing.allocator, '\n');
            },
            else => {},
        }
    }
}

test "no context a hook injects names a script or command that does not exist" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.makeRepo("git@github.com:example/repo.git");
    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const remote = try fx.repoRemoteOrPath();
    defer fx.gpa.free(remote);
    try fx.writeSynapseIndex(ns, remote);
    try stageNode(&fx, "Query API", "Conditions and validation.");
    const work_dir = try fx.defaultWorkDir();
    defer fx.gpa.free(work_dir);
    try fx.writeIndexBin(work_dir, &.{.{ .path = "src/foo.aa", .node = "Query API.md" }});

    const refs_path = try std.fmt.allocPrint(fx.gpa, "{s}/_refs.tsv", .{work_dir});
    defer fx.gpa.free(refs_path);
    try std.Io.Dir.cwd().createDirPath(testing.io, work_dir);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = refs_path, .data = "foo\tdef\tfunction\tsrc/foo.aa\t1\tlet foo x =\n" });

    var emitted: std.ArrayListUnmanaged(u8) = .empty;
    defer emitted.deinit(testing.allocator);

    const payload1 = try std.fmt.allocPrint(fx.gpa, "{{\"prompt\":\"how does Query API validate\",\"cwd\":{f}}}", .{std.json.fmt(fx.repo, .{})});
    defer fx.gpa.free(payload1);
    const r1 = try fx.runHookStdin(&.{"prompt-context"}, payload1);
    defer r1.deinit(testing.allocator);
    try emitted.appendSlice(testing.allocator, r1.stdout);
    try emitted.appendSlice(testing.allocator, r1.stderr);

    const payload2 = try std.fmt.allocPrint(fx.gpa, "{{\"cwd\":{f}}}", .{std.json.fmt(fx.repo, .{})});
    defer fx.gpa.free(payload2);
    const r2 = try fx.runHookStdin(&.{"session-start"}, payload2);
    defer r2.deinit(testing.allocator);
    try emitted.appendSlice(testing.allocator, r2.stdout);
    try emitted.appendSlice(testing.allocator, r2.stderr);

    const file_path = try std.fmt.allocPrint(fx.gpa, "{s}/src/foo.aa", .{fx.repo});
    defer fx.gpa.free(file_path);
    const payload3 = try std.fmt.allocPrint(fx.gpa, "{{\"tool_input\":{{\"file_path\":{f}}}}}", .{std.json.fmt(file_path, .{})});
    defer fx.gpa.free(payload3);
    const r3 = try fx.runHookStdin(&.{"staleness"}, payload3);
    defer r3.deinit(testing.allocator);
    try emitted.appendSlice(testing.allocator, r3.stdout);
    try emitted.appendSlice(testing.allocator, r3.stderr);

    try testing.expect(emitted.items.len != 0);

    const bad = try unknownCommands(&fx, testing.allocator, emitted.items);
    defer testing.allocator.free(bad);
    try testing.expectEqualStrings("", bad);
}

test "no generated document names a script or command that does not exist" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.makeRepo("ssh://git@example.com/x/proj.git");
    try fx.setEnv("SYNAPSE_WORK_DIR", fx.work);
    try fx.dir.createDirPath(std.testing.io, "work/lists");
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "work/lists/01.title", .data = "Query API\n" });
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "work/lists/01.txt", .data = "src/foo.aa\n" });
    try stageNode(&fx, "Query API", "Conditions and validation.");

    const r = try fx.runFake(&.{"build-project-index"});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());

    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const index_path = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}/Index.md", .{ns});
    defer fx.gpa.free(index_path);
    const generated = try fx.dir.readFileAlloc(std.testing.io, index_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(generated);
    try testing.expect(std.mem.indexOf(u8, generated, "Reading a node") != null);

    const bad = try unknownCommands(&fx, testing.allocator, generated);
    defer testing.allocator.free(bad);
    try testing.expectEqualStrings("", bad);
}
