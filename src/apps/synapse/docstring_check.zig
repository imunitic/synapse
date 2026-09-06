//! Tier 2 of docstring staleness detection: a real parse via
//! `treesitter.docstring_pairs.findPairs`, run per file. The only place
//! that ever calls it, and therefore the only place that discovers
//! new/renamed docstrings and commits fresh index entries (ranges
//! included) -- `synapse-hook`'s Tier 1 (`apps/hook/staleness.zig`)
//! deliberately never parses, since it links no libtree-sitter. Shared
//! between `comments-check` (one file, read-time) and `comments-sweep`
//! (every file, on demand) so the two never drift on what "checking a
//! file" means.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const treesitter = @import("treesitter");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Result = struct {
    /// A human-readable report of what changed, or null when this file
    /// has no grammar, no comment-attached declarations, or nothing
    /// changed since it was last checked.
    report: ?[]u8,
    checked: usize,
    updated: usize,
    evicted: usize,
};

pub const no_op: Result = .{ .report = null, .checked = 0, .updated = 0, .evicted = 0 };

/// Checks one repo-relative file: derives its current docstring/declaration
/// pairs, compares them against the index, commits the fresh state
/// (updates and evictions both), and reports what's new or changed.
/// `no_op` when the feature is disabled, the extension has no usable
/// grammar, or the index couldn't be safely written to (`MapFailed`,
/// same refusal `Cache.commit` documents for itself).
pub fn checkFile(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    repo_root: []const u8,
    work: []const u8,
    rel_path: []const u8,
) !Result {
    const vars = adapters.env.vars(env);
    if (!try core.docstring_index.enabled(gpa, io, vars)) return no_op;

    const ext = (try treesitter.extensionOf(gpa, rel_path)) orelse return no_op;
    defer gpa.free(ext);

    var registry = try loadRegistry(gpa, io, env);
    defer registry.deinit();
    const grammars_dir = try grammarsDir(gpa, io, env);
    defer gpa.free(grammars_dir);
    const query_override_dir = try core.conf.resolve(gpa, io, vars, "SYNAPSE_GRAMMARS_QUERY_PATH");
    defer if (query_override_dir) |d| gpa.free(d);
    const lock_tries_raw = try core.conf.resolve(gpa, io, vars, "SYNAPSE_GRAMMAR_LOCK_TRIES");
    defer if (lock_tries_raw) |t| gpa.free(t);
    const lock_tries = if (lock_tries_raw) |t|
        std.fmt.parseInt(usize, t, 10) catch treesitter.grammar.default_lock_tries
    else
        treesitter.grammar.default_lock_tries;

    const lang = (try treesitter.docstring_pairs.resolveLanguage(gpa, io, registry, grammars_dir, ext, lock_tries)) orelse
        return no_op;

    const comment_type = try treesitter.docstring_pairs.resolveCommentTypeName(gpa, io, query_override_dir, ext);
    defer gpa.free(comment_type);
    const declaration_overrides = try treesitter.docstring_pairs.resolveDeclarationOverrides(gpa, io, query_override_dir, ext);
    defer treesitter.docstring_pairs.freeDeclarationOverrides(gpa, declaration_overrides);

    const full_path = try std.fs.path.join(gpa, &.{ repo_root, rel_path });
    defer gpa.free(full_path);
    const content = Io.Dir.cwd().readFileAlloc(io, full_path, gpa, .limited(256 << 20)) catch return no_op;
    defer gpa.free(content);

    const pairs = try treesitter.docstring_pairs.findPairs(gpa, lang, content, comment_type, declaration_overrides);
    defer treesitter.docstring_pairs.freePairs(gpa, pairs);

    const index_path = try std.fmt.allocPrint(gpa, "{s}/_docstring_index.bin", .{work});
    defer gpa.free(index_path);
    var cache = try core.docstring_index.Cache.open(io, index_path);
    defer cache.close(io);
    if (cache.discarded) |d| {
        if (d == error.MapFailed) return no_op;
    }

    // Every currently-derived pair becomes an update, whether or not its
    // hash changed -- Tier 1's next re-hash needs an accurate range even
    // for a pair whose content never moved.
    const updates = try gpa.alloc(core.docstring_index.Update, pairs.len);
    defer gpa.free(updates);
    for (pairs, 0..) |p, i| {
        updates[i] = .{
            .key = .{ .path = rel_path, .name = p.name, .kind = p.kind },
            .entry = .{
                .docstring_hash = core.verify.sha256Raw(p.docstring_text),
                .decl_hash = core.verify.sha256Raw(p.decl_text),
                .docstring_start_line = p.docstring_start_line,
                .docstring_end_line = p.docstring_end_line,
                .decl_start_line = p.decl_start_line,
                .decl_end_line = p.decl_end_line,
            },
        };
    }

    const changed = try cache.needsCheck(gpa, updates);
    defer gpa.free(changed);

    // Evict what the index still holds for this file but the fresh parse
    // no longer found: a declaration renamed (a new name+kind pair, not a
    // match against the old one -- the accepted trade-off the design note
    // states directly), or its docstring removed outright.
    const existing = try cache.entriesForPath(gpa, rel_path);
    defer gpa.free(existing);
    var removals: std.ArrayListUnmanaged(core.docstring_index.Key) = .empty;
    defer removals.deinit(gpa);
    for (existing) |e| {
        var still_present = false;
        for (pairs) |p| {
            if (std.mem.eql(u8, e.name, p.name) and std.mem.eql(u8, e.kind, p.kind)) {
                still_present = true;
                break;
            }
        }
        if (!still_present) try removals.append(gpa, .{ .path = rel_path, .name = e.name, .kind = e.kind });
    }

    const evicted = try cache.commit(gpa, io, updates, removals.items);

    var findings: Io.Writer.Allocating = .init(gpa);
    defer findings.deinit();
    for (changed) |u| {
        try findings.writer.print("- `{s}` ({s}): new or changed since last checked\n", .{ u.key.name, u.key.kind });
        for (pairs) |p| {
            if (std.mem.eql(u8, p.name, u.key.name) and std.mem.eql(u8, p.kind, u.key.kind)) {
                if (core.comment_style_rules.historianPlaguePhrase(p.docstring_text)) |phrase| {
                    try findings.writer.print("  historian-plague tell: \"{s}\"\n", .{phrase});
                }
                break;
            }
        }
    }

    var report: ?[]u8 = null;
    if (findings.written().len != 0) {
        const style_rubric = try core.comment_style_rules.read(gpa, io, vars);
        defer gpa.free(style_rubric);
        var text: Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        try text.writer.writeAll("Docstring staleness (Tier 2): the following changed since last checked:\n");
        try text.writer.writeAll(findings.written());
        if (style_rubric.len != 0) {
            try text.writer.writeAll("\nStyle rubric to judge the affected docstring(s) against:\n");
            try text.writer.writeAll(style_rubric);
        }
        report = try gpa.dupe(u8, text.written());
    }

    return .{ .report = report, .checked = pairs.len, .updated = changed.len, .evicted = evicted };
}

/// Same resolution `tags_cache_cmd.zig`'s own `loadRegistry` uses.
fn loadRegistry(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !treesitter.Registry {
    const home = env.get("HOME") orelse return error.NoHome;
    const p = (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-grammars.conf")) orelse
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-grammars.conf", .{home});
    defer gpa.free(p);
    return treesitter.Registry.load(gpa, io, p);
}

/// Same resolution `tags_cache_cmd.zig`'s own `grammarsDir` uses.
fn grammarsDir(gpa: Allocator, io: Io, env: *std.process.Environ.Map) ![]u8 {
    if (try core.conf.resolve(gpa, io, adapters.env.vars(env), "SYNAPSE_GRAMMARS_DIR")) |d| return d;
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(gpa, "{s}/.cache/synapse/grammars", .{home});
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

// `@embedFile` can't cross a module boundary, so this is its own copy of
// `adapters/treesitter/testdata/fake_docstrings_grammar` -- the same
// duplication `cmd_test_support.zig` already accepts between `hook` and
// `synapse` for the identical reason.
const fake_parser_c = @embedFile("testdata/fake_docstrings_grammar/src/parser.c");
const fake_node_types_json = @embedFile("testdata/fake_docstrings_grammar/src/node-types.json");
const fake_parser_h = @embedFile("testdata/fake_docstrings_grammar/src/tree_sitter/parser.h");
const fake_alloc_h = @embedFile("testdata/fake_docstrings_grammar/src/tree_sitter/alloc.h");
const fake_array_h = @embedFile("testdata/fake_docstrings_grammar/src/tree_sitter/array.h");

/// Sets up `fx` so `checkFile` resolves the real, checked-in
/// `fake_docstrings_grammar` for extension `"fakedoc"`, without touching
/// the network: `grammar.ensureCloned` short-circuits (returns the path
/// unmodified) when the target directory already exists, so writing the
/// fixture's sources directly at the expected clone location stands in
/// for a real clone.
fn setupFakeGrammar(fx: *fixture.Fixture) !void {
    const gpa = fx.gpa;
    const grammars_dir = try std.fmt.allocPrint(gpa, "{s}/grammars", .{fx.root});
    defer gpa.free(grammars_dir);
    try fx.tmp.dir.createDirPath(fx.io(), "grammars");
    try fx.env.put("SYNAPSE_GRAMMARS_DIR", grammars_dir);

    const repo_sub = "grammars/repos/fake-docstrings";
    try fx.tmp.dir.createDirPath(fx.io(), repo_sub ++ "/src/tree_sitter");
    try fx.tmp.dir.writeFile(fx.io(), .{ .sub_path = repo_sub ++ "/src/parser.c", .data = fake_parser_c });
    try fx.tmp.dir.writeFile(fx.io(), .{ .sub_path = repo_sub ++ "/src/node-types.json", .data = fake_node_types_json });
    try fx.tmp.dir.writeFile(fx.io(), .{ .sub_path = repo_sub ++ "/src/tree_sitter/parser.h", .data = fake_parser_h });
    try fx.tmp.dir.writeFile(fx.io(), .{ .sub_path = repo_sub ++ "/src/tree_sitter/alloc.h", .data = fake_alloc_h });
    try fx.tmp.dir.writeFile(fx.io(), .{ .sub_path = repo_sub ++ "/src/tree_sitter/array.h", .data = fake_array_h });

    const registry_json =
        \\{"fakedoc": {"repo": "https://example.com/fake-docstrings.git", "scope": "source.fake_docstrings", "symbol": "tree_sitter_fake_docstrings"}}
    ;
    try fx.tmp.dir.writeFile(fx.io(), .{ .sub_path = "home/.claude/synapse-grammars.conf", .data = registry_json });

    try fx.env.put("SYNAPSE_DOCSTRING_STALENESS_DETECTION", "1");
}

test "checkFile: a new pair with no prior index entry is reported and committed" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try setupFakeGrammar(&fx);

    try fx.writeRepoFile("calc.fakedoc", "// does a thing\nfn foo()\n");

    const result = try checkFile(gpa, fx.io(), &fx.env, fx.repo, fx.work, "calc.fakedoc");
    defer if (result.report) |r| gpa.free(r);

    try testing.expectEqual(@as(usize, 1), result.checked);
    try testing.expectEqual(@as(usize, 1), result.updated);
    try testing.expectEqual(@as(usize, 0), result.evicted);
    try testing.expect(result.report != null);
    try testing.expect(std.mem.indexOf(u8, result.report.?, "new or changed") != null);

    // Committed for real: a second check against unchanged content finds
    // nothing new.
    const again = try checkFile(gpa, fx.io(), &fx.env, fx.repo, fx.work, "calc.fakedoc");
    defer if (again.report) |r| gpa.free(r);
    try testing.expectEqual(@as(usize, 0), again.updated);
    try testing.expectEqual(@as(?[]u8, null), again.report);
}

test "checkFile: a renamed declaration evicts the old entry and reports the new one" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try setupFakeGrammar(&fx);

    try fx.writeRepoFile("calc.fakedoc", "// does a thing\nfn foo()\n");
    const first = try checkFile(gpa, fx.io(), &fx.env, fx.repo, fx.work, "calc.fakedoc");
    if (first.report) |r| gpa.free(r);

    try fx.writeRepoFile("calc.fakedoc", "// does a thing\nfn bar()\n");
    const result = try checkFile(gpa, fx.io(), &fx.env, fx.repo, fx.work, "calc.fakedoc");
    defer if (result.report) |r| gpa.free(r);

    try testing.expectEqual(@as(usize, 1), result.checked); // only "fn bar()" now
    try testing.expectEqual(@as(usize, 1), result.updated); // the new name is a new key
    try testing.expectEqual(@as(usize, 1), result.evicted); // "fn foo()"'s old entry is gone
}

test "checkFile: disabled by default reports nothing and commits nothing" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try setupFakeGrammar(&fx);
    _ = fx.env.swapRemove("SYNAPSE_DOCSTRING_STALENESS_DETECTION");

    try fx.writeRepoFile("calc.fakedoc", "// does a thing\nfn foo()\n");
    const result = try checkFile(gpa, fx.io(), &fx.env, fx.repo, fx.work, "calc.fakedoc");
    try testing.expectEqual(no_op, result);
}

test "checkFile: an unregistered extension is a no-op, not an error" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try setupFakeGrammar(&fx);

    try fx.writeRepoFile("readme.md", "// does a thing\nfn foo()\n");
    const result = try checkFile(gpa, fx.io(), &fx.env, fx.repo, fx.work, "readme.md");
    try testing.expectEqual(no_op, result);
}
