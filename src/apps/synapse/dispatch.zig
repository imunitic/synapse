//! The subcommand dispatch table, shared by `main.zig` and `main_fake.zig` --
//! one `[]const Sub` per binary (parameterized by `Extractor`, the one real
//! difference between the two), instead of the same ~40-branch
//! `if (std.mem.eql(u8, sub, "..."))` cascade hand-duplicated in both.
//!
//! Every entry's `run` has the same signature regardless of what the
//! wrapped command actually needs -- most ignore `argv0`/`trace` entirely,
//! a few need one or the other, `vault-git-pusher` ignores `env` too. That
//! uniformity is what makes one shared table and one shared dispatch loop
//! possible; each wrapper below is the one place that gap is bridged, so
//! nothing about a specific command's own real signature has to change.
//!
//! `Table(Extractor)` is instantiated exactly twice -- `main.zig` with the
//! real `TreeSitterExtractor`, `main_fake.zig` with `FakeExtractor` -- so
//! each wrapper that needs an extractor becomes a concrete, non-generic
//! function once compiled into either binary, with no comptime type
//! threaded through the table itself at the call site.

const std = @import("std");

const tags_cmd = @import("tags.zig");
const tags_cache_cmd = @import("tags_cache_cmd.zig");
const index_cmd = @import("index_cmd.zig");
const enumerate_cmd = @import("enumerate_cmd.zig");
const build_lists_cmd = @import("build_lists_cmd.zig");
const vocab_cmd = @import("vocab_cmd.zig");
const rank_cmd = @import("rank_cmd.zig");
const query_cmd = @import("query_cmd.zig");
const write_node_cmd = @import("write_node_cmd.zig");
const frontmatter_cmd = @import("frontmatter_cmd.zig");
const vault_cmd = @import("vault_cmd.zig");
const refs_cmd = @import("refs_cmd.zig");
const deps_cmd = @import("deps_cmd.zig");
const namespaces_cmd = @import("namespaces_cmd.zig");
const links_cmd = @import("links_cmd.zig");
const brief_cmd = @import("brief_cmd.zig");
const gate_cmd = @import("gate_cmd.zig");
const push_nodes_cmd = @import("push_nodes_cmd.zig");
const project_index_cmd = @import("project_index_cmd.zig");
const graph_cmd = @import("graph_cmd.zig");
const namespace_cmd = @import("namespace_cmd.zig");
const doctor_cmd = @import("doctor_cmd.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvironMap = std.process.Environ.Map;
const ArgsIterator = std.process.Args.Iterator;

/// Every command's uniform entry point, whatever its own real signature
/// looks like underneath.
pub const RunFn = *const fn (
    gpa: Allocator,
    io: Io,
    env: *EnvironMap,
    args: *ArgsIterator,
    argv0: []const u8,
    trace: ?[]const u8,
) anyerror!u8;

pub const Sub = struct {
    name: []const u8,
    run: RunFn,
};

/// The dispatch table for one binary, `Extractor` baked in at comptime --
/// `treesitter.extractor.TreeSitterExtractor` for `synapse`,
/// `fake_grammar.FakeExtractor` for `synapse-fake`. Every wrapper here
/// mirrors exactly the call `main.zig`'s old cascade made for that
/// subcommand; nothing about a command's own behavior changes, only where
/// the string comparison that reaches it lives.
pub fn Table(comptime Extractor: type) type {
    return struct {
        fn tags(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = argv0;
            return tags_cmd.run(Extractor, gpa, io, env, args, trace);
        }
        fn tagsCache(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = argv0;
            return tags_cache_cmd.run(Extractor, gpa, io, env, args, trace);
        }
        fn index(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return index_cmd.run(gpa, io, env, args);
        }
        fn enumerate(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return enumerate_cmd.run(gpa, io, env, args);
        }
        fn buildLists(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return build_lists_cmd.run(gpa, io, env, args);
        }
        fn vocab(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = argv0;
            return vocab_cmd.run(Extractor, gpa, io, env, args, trace);
        }
        fn rank(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return rank_cmd.run(gpa, io, env, args);
        }
        fn query(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return query_cmd.run(Extractor, gpa, io, env, args);
        }
        fn writeNode(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return write_node_cmd.run(Extractor, gpa, io, env, args);
        }
        fn frontmatter(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return frontmatter_cmd.run(gpa, io, env, args);
        }
        fn vaultRead(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runRead(gpa, io, env, args);
        }
        fn vaultWrite(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = trace;
            return vault_cmd.runWrite(gpa, io, env, args, argv0);
        }
        fn vaultList(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runList(gpa, io, env, args);
        }
        fn vaultCheck(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runCheck(gpa, io, env, args);
        }
        fn vaultSearch(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runSearch(gpa, io, env, args);
        }
        fn vaultSearchText(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runSearchText(gpa, io, env, args);
        }
        fn vaultDocMap(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runDocMap(gpa, io, env, args);
        }
        fn vaultPatch(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = trace;
            return vault_cmd.runPatch(gpa, io, env, args, argv0);
        }
        fn vaultBacklinks(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runBacklinks(gpa, io, env, args);
        }
        fn vaultLinks(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runLinks(gpa, io, env, args);
        }
        fn vaultUnresolved(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runUnresolved(gpa, io, env, args);
        }
        fn vaultOrphans(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runOrphans(gpa, io, env, args);
        }
        fn vaultDeadends(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runDeadends(gpa, io, env, args);
        }
        fn vaultAmbiguous(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runAmbiguous(gpa, io, env, args);
        }
        fn vaultGitPusher(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ env, argv0, trace };
            return vault_cmd.runVaultGitPusher(gpa, io, args);
        }
        fn vaultRename(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return vault_cmd.runRename(gpa, io, env, args);
        }
        fn doctor(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return doctor_cmd.run(gpa, io, env, args);
        }
        fn namespace(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return namespace_cmd.run(gpa, io, env, args);
        }
        fn buildIndex(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return index_cmd.runBuildIndex(gpa, io, env, args);
        }
        fn graphClean(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return graph_cmd.runClean(gpa, io, env, args);
        }
        fn graphWipe(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return graph_cmd.runWipe(gpa, io, env, args);
        }
        fn buildProjectIndex(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return project_index_cmd.run(gpa, io, env, args);
        }
        fn pushNodes(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return push_nodes_cmd.run(Extractor, gpa, io, env, args);
        }
        fn gate(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return gate_cmd.run(gpa, io, env, args);
        }
        fn buildRefs(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return refs_cmd.runBuild(gpa, io, env, args);
        }
        fn callers(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return refs_cmd.runCallers(gpa, io, env, args);
        }
        fn buildDeps(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return deps_cmd.run(gpa, io, env, args);
        }
        fn buildNamespaces(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return namespaces_cmd.run(gpa, io, env, args);
        }
        fn linkGraph(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return links_cmd.run(gpa, io, env, args);
        }
        fn brief(gpa: Allocator, io: Io, env: *EnvironMap, args: *ArgsIterator, argv0: []const u8, trace: ?[]const u8) anyerror!u8 {
            _ = .{ argv0, trace };
            return brief_cmd.run(gpa, io, env, args);
        }

        // Order matches the old cascade's, purely so a diff against it reads
        // as a rename rather than a reshuffle -- dispatch itself is a linear
        // scan either way, so nothing here is order-sensitive.
        pub const entries = [_]Sub{
            .{ .name = "tags", .run = tags },
            .{ .name = "tags-cache", .run = tagsCache },
            .{ .name = "index", .run = index },
            .{ .name = "enumerate", .run = enumerate },
            .{ .name = "build-lists", .run = buildLists },
            .{ .name = "vocab", .run = vocab },
            .{ .name = "rank", .run = rank },
            .{ .name = "query", .run = query },
            .{ .name = "write-node", .run = writeNode },
            .{ .name = "frontmatter", .run = frontmatter },
            .{ .name = "vault-read", .run = vaultRead },
            .{ .name = "vault-write", .run = vaultWrite },
            .{ .name = "vault-list", .run = vaultList },
            .{ .name = "vault-check", .run = vaultCheck },
            .{ .name = "vault-search", .run = vaultSearch },
            .{ .name = "vault-search-text", .run = vaultSearchText },
            .{ .name = "vault-doc-map", .run = vaultDocMap },
            .{ .name = "vault-patch", .run = vaultPatch },
            .{ .name = "vault-backlinks", .run = vaultBacklinks },
            .{ .name = "vault-links", .run = vaultLinks },
            .{ .name = "vault-unresolved", .run = vaultUnresolved },
            .{ .name = "vault-orphans", .run = vaultOrphans },
            .{ .name = "vault-deadends", .run = vaultDeadends },
            .{ .name = "vault-ambiguous", .run = vaultAmbiguous },
            // Not documented in `usage`: `GitStore.write()`'s own detached
            // spawn target, the same "not registered as a hook" shape
            // `synapse-hook vault-sync`/`vault-pull` already have.
            .{ .name = "vault-git-pusher", .run = vaultGitPusher },
            .{ .name = "vault-rename", .run = vaultRename },
            .{ .name = "doctor", .run = doctor },
            .{ .name = "namespace", .run = namespace },
            .{ .name = "build-index", .run = buildIndex },
            .{ .name = "graph-clean", .run = graphClean },
            .{ .name = "graph-wipe", .run = graphWipe },
            .{ .name = "build-project-index", .run = buildProjectIndex },
            .{ .name = "push-nodes", .run = pushNodes },
            .{ .name = "gate", .run = gate },
            .{ .name = "build-refs", .run = buildRefs },
            .{ .name = "callers", .run = callers },
            .{ .name = "build-deps", .run = buildDeps },
            .{ .name = "build-namespaces", .run = buildNamespaces },
            .{ .name = "link-graph", .run = linkGraph },
            .{ .name = "brief", .run = brief },
        };
    };
}

/// Finds `sub` in `entries` and runs it, or returns null for an unknown
/// subcommand -- the caller (each binary's own `main`) decides what an
/// unknown subcommand prints, since the two binaries' error prefixes
/// ("synapse:" vs "synapse-fake:") differ and that's the one thing left
/// that's actually binary-specific.
pub fn run(
    entries: []const Sub,
    gpa: Allocator,
    io: Io,
    env: *EnvironMap,
    args: *ArgsIterator,
    argv0: []const u8,
    sub: []const u8,
    trace: ?[]const u8,
) ?anyerror!u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, sub)) return e.run(gpa, io, env, args, argv0, trace);
    }
    return null;
}

const testing = std.testing;
// Test-only: dispatch.zig's own production code never picks an Extractor --
// that's each binary's job. The fake is dependency-free (no C toolchain, no
// real grammar repo) and already exists for exactly this kind of test.
const FakeExtractor = @import("fake_grammar.zig").FakeExtractor;
const usage = @import("usage.zig").text;

// The one entry deliberately absent from `usage` -- GitStore.write()'s own
// detached Pusher spawn target, not something a user ever types.
const undocumented = [_][]const u8{"vault-git-pusher"};

// A bare substring search would let "vault-search" false-pass on
// "vault-search-text"'s own line -- checks the byte right after the match
// isn't itself part of a longer hyphenated name.
fn hasUsageLineFor(name: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, usage, start, name)) |i| {
        const after = i + name.len;
        const boundary_ok = after >= usage.len or
            !(std.ascii.isLower(usage[after]) or usage[after] == '-');
        const line_start_ok = i >= 2 and std.mem.eql(u8, usage[i - 2 .. i], "  ") and
            (i < 3 or usage[i - 3] == '\n');
        if (boundary_ok and line_start_ok) return true;
        start = i + 1;
    }
    return false;
}

test "every dispatchable subcommand is named in the usage text, except the deliberately undocumented one" {
    entry_loop: for (Table(FakeExtractor).entries) |e| {
        for (undocumented) |u| if (std.mem.eql(u8, e.name, u)) continue :entry_loop;
        if (!hasUsageLineFor(e.name)) {
            std.debug.print("dispatch table names '{s}', missing its own line in usage.zig\n", .{e.name});
            return error.SubcommandUndocumented;
        }
    }
}

test "every table entry's name is unique" {
    const entries = Table(FakeExtractor).entries;
    for (entries, 0..) |a, i| {
        for (entries[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "run finds a real entry by name and returns null for an unknown one" {
    const entries = comptime blk: {
        const Dummy = struct {
            fn ok(_: Allocator, _: Io, _: *EnvironMap, _: *ArgsIterator, _: []const u8, _: ?[]const u8) anyerror!u8 {
                return 7;
            }
        };
        break :blk [_]Sub{.{ .name = "ok", .run = Dummy.ok }};
    };

    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var args: ArgsIterator = .{ .inner = .{ .remaining = &.{} } };

    const found = run(&entries, testing.allocator, testing.io, &env, &args, "argv0", "ok", null);
    try testing.expectEqual(@as(u8, 7), try found.?);
    try testing.expectEqual(@as(?anyerror!u8, null), run(&entries, testing.allocator, testing.io, &env, &args, "argv0", "nope", null));
}
