//! The Extractor the `synapse` app wires: registry in, tags out, no CLI.
//!
//! Per extension, once: resolve the registry entry, clone the grammar repo if
//! this is its first use, compile it, load it, and build a `Tagger` from its
//! own `queries/tags.scm`. Everything after that is parse-and-query.
//!
//! An extension that cannot be served is reported once and then remembered as
//! unusable, because the alternative -- retrying per file -- is what made
//! tree-sitter's own eight-lines-per-file warning unreadable at repo scale.
//! One line per extension is all a caller can act on anyway.
//!
//! **Generic over the grammar backend, and that is what the test binary is
//! built from.** Everything a caller can observe from the outside -- which
//! extensions warn, what the warning says, when a clone happens, which files
//! come back `.unsupported` -- lives here and is shared. Only the innermost
//! step differs: `TsBackend` compiles a cloned repo and runs its `tags.scm`,
//! while the fake backend behind `synapse-fake` returns scripted tags without
//! a C compiler or a real grammar. That split is deliberate: `tests/*.bats`
//! asserts the shared half, so a second copy of it for tests would be a copy
//! that drifts, and the drift would be invisible precisely because the tests
//! would keep passing.

const std = @import("std");
const model = @import("model");
const ports = @import("ports");
const core = @import("core");
const root = @import("root.zig");
const grammar = @import("grammar.zig");
const tagger_mod = @import("tagger.zig");
const node_types = @import("node_types.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Tagger = tagger_mod.Tagger;

/// The production backend: `zig cc` the cloned grammar, `dlopen` it, and run
/// the repo's own `queries/tags.scm`.
pub const TsBackend = struct {
    pub const Grammar = *Tagger;

    pub fn load(
        gpa: Allocator,
        io: Io,
        repo_dir: []const u8,
        grammars_dir: []const u8,
        name: []const u8,
        /// The sub-directory holding `src/parser.c`, or null for the repo root.
        /// See `Registry.pathFor`.
        sub_path: ?[]const u8,
        /// An explicit `tree_sitter_*` name, or null to derive it from the repo
        /// name. See `Registry.symbolFor`.
        sub_symbol: ?[]const u8,
        /// What the registry says backs this extension's tags. Overridden by
        /// `query_override_dir` below when that override actually applies --
        /// see there for why `source` alone is not the final word.
        source: root.QuerySource,
        /// This extension, bare, no leading dot -- for building the override
        /// path below. Not used for anything else here; `name`/`sub_path` are
        /// already what locates the grammar itself.
        ext: []const u8,
        /// `$SYNAPSE_GRAMMARS_QUERY_PATH` (sb-012), or null for "no override
        /// configured." `{this}/{ext}.scm`, when it exists, wins over `source`
        /// entirely -- checked first, below, before `source` is ever read.
        query_override_dir: ?[]const u8,
        /// Passed straight to `Tagger.init` -- see its own doc comment.
        kind_rules: core.kind_synonyms.RuleList,
        /// This extension's tree-sitter scope (`Readiness.ready.scope`),
        /// passed straight to `Tagger.init` for the same reason.
        scope: []const u8,
    ) !Grammar {
        const symbol = if (sub_symbol) |s| try gpa.dupe(u8, s) else try grammar.symbolFor(gpa, name);
        defer gpa.free(symbol);

        // Keyed by symbol, not by repo name. One repo can ship several grammars,
        // and they must not compile over each other: `tree_sitter_ocaml` and
        // `tree_sitter_ocaml_interface` come out of the same clone. Two
        // extensions resolving to the same language still share one library,
        // which is what `kt` and `kts` want.
        const lib_path = try std.fmt.allocPrint(gpa, "{s}/lib/{s}.{s}", .{
            grammars_dir, symbol, grammar.sharedLibExt(),
        });
        defer gpa.free(lib_path);

        // The parser may live under a sub-directory. The tags query does not move
        // with it -- it stays at the repo root, shared by every sub-grammar --
        // which is why finding a query proves nothing about finding a parser.
        const src_root = if (sub_path) |p|
            try std.fs.path.join(gpa, &.{ repo_dir, p })
        else
            try gpa.dupe(u8, repo_dir);
        defer gpa.free(src_root);

        try grammar.build(io, gpa, src_root, lib_path);

        const lang = try grammar.load(gpa, lib_path, symbol);

        // Override (sb-012): checked first, wins over every tier including
        // `tags.scm` -- a human placing this file has already done the
        // judgment call the tier cascade below exists to approximate.
        // `error.FileNotFound` is "no override for this extension," the
        // ordinary case; anything else (permission denied, a read failure)
        // propagates rather than silently falling through to the cascade,
        // the same shape `core.namespace.Registry.load` already uses for an
        // absent-vs-broken config file.
        if (query_override_dir) |dir| {
            const override_name = try std.fmt.allocPrint(gpa, "{s}.scm", .{ext});
            defer gpa.free(override_name);
            const override_path = try std.fs.path.join(gpa, &.{ dir, override_name });
            defer gpa.free(override_path);
            const overridden = Io.Dir.cwd().readFileAlloc(io, override_path, gpa, .limited(1 << 20)) catch |e| switch (e) {
                error.FileNotFound => null,
                else => return e,
            };
            if (overridden) |scm| {
                defer gpa.free(scm);
                const t = try gpa.create(Tagger);
                errdefer gpa.destroy(t);
                // `.override`, not `source`: an override always reads the
                // tags.scm convention regardless of what the registry says
                // backs this extension normally -- see `Tagger.tagFile`'s
                // own dispatch comment.
                t.* = try Tagger.init(lang, scm, .override, kind_rules, scope, null);
                return t;
            }
        }

        // Tier 3 (sb-012): no static file to read at all -- the query is
        // synthesized from `node-types.json`, which lives beside
        // `src/parser.c` (i.e. under `src_root`, not `repo_dir`), so a
        // sub-grammar gets its own schema the same way it gets its own
        // parser. `Tagger` owns `classification` from here on (see its own
        // doc comment on that field); this function does not free it.
        if (source == .generated) {
            const node_types_path = try std.fs.path.join(gpa, &.{ src_root, "src", "node-types.json" });
            defer gpa.free(node_types_path);
            var classification = try node_types.classify(gpa, io, node_types_path);
            errdefer classification.deinit();

            const generated_query = try node_types.buildQuery(gpa, classification.guesses);
            defer gpa.free(generated_query);

            const t = try gpa.create(Tagger);
            errdefer gpa.destroy(t);
            t.* = try Tagger.init(lang, generated_query, .generated, kind_rules, scope, classification);
            return t;
        }

        // Tier 1/2 (sb-012): a static file in the clone, same directory
        // either way -- the tags query never moves with a sub-grammar's
        // `sub_path`, and neither does `locals.scm`.
        const scm_filename = switch (source) {
            .tags => "tags.scm",
            .locals => "locals.scm",
            .generated => unreachable, // handled above, already returned
            // Not reachable via the registry (`QuerySource`'s own doc
            // comment) -- the block above is what actually implements
            // `.override`'s effect, ahead of this switch entirely.
            .override => unreachable,
        };
        const scm_path = try std.fs.path.join(gpa, &.{ repo_dir, "queries", scm_filename });
        defer gpa.free(scm_path);
        const scm = try Io.Dir.cwd().readFileAlloc(io, scm_path, gpa, .limited(1 << 20));
        defer gpa.free(scm);

        const t = try gpa.create(Tagger);
        errdefer gpa.destroy(t);
        t.* = try Tagger.init(lang, scm, source, kind_rules, scope, null);
        return t;
    }

    pub fn tagFile(g: Grammar, gpa: Allocator, ext: []const u8, source: []const u8) ![]tagger_mod.Tagged {
        _ = ext;
        return g.tagFile(gpa, source);
    }

    pub fn release(g: Grammar, gpa: Allocator) void {
        g.deinit();
        gpa.destroy(g);
    }
};

pub const TreeSitterExtractor = Extractor(TsBackend);

pub fn Extractor(comptime Backend: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        registry: root.Registry,
        /// `$SYNAPSE_GRAMMARS_DIR`, default `~/.cache/synapse/grammars`. Repos are
        /// cloned under `repos/`, built libraries cached under `lib/`.
        grammars_dir: []const u8,
        /// The kind-synonym rule list (sb-012), required like `registry` --
        /// loaded once by the caller (`core.kind_synonyms.RuleList.load`
        /// tolerates an absent file, so this is never a reason to fail to
        /// construct an `Extractor`) and borrowed for as long as any
        /// `Tagger` built from a `locals.scm` reading might consult it.
        kind_rules: core.kind_synonyms.RuleList,
        /// ~60s at 200ms a try, matching the shell script's default. Bounds a
        /// wedged lock from a crashed holder, not the clone itself.
        lock_tries: usize = 300,
        /// `$SYNAPSE_GRAMMARS_QUERY_PATH` (sb-012), resolved by the caller the
        /// same way `grammars_dir` already is. `null` is the common case --
        /// no override for anything -- and preserves today's behavior exactly.
        /// When set, `{this}/{ext}.scm` is tried before every tier, for every
        /// extension, not just ones a caller singles out.
        query_override_dir: ?[]const u8 = null,

        /// null means "known unusable" -- resolved once, reported once, then
        /// skipped without re-resolving.
        grammars: std.StringHashMapUnmanaged(?Backend.Grammar) = .empty,

        pub fn init(
            gpa: Allocator,
            registry: root.Registry,
            grammars_dir: []const u8,
            kind_rules: core.kind_synonyms.RuleList,
        ) Self {
            return .{ .gpa = gpa, .registry = registry, .grammars_dir = grammars_dir, .kind_rules = kind_rules };
        }

        pub fn deinit(self: *Self) void {
            var it = self.grammars.iterator();
            while (it.next()) |e| {
                self.gpa.free(e.key_ptr.*);
                if (e.value_ptr.*) |g| Backend.release(g, self.gpa);
            }
            self.grammars.deinit(self.gpa);
        }

        pub fn port(self: *Self) ports.Extractor {
            return .{ .ptr = self, .vtable = &.{ .extract = extractFn } };
        }

        /// What a path yielded, spans included. The port's `Outcome` is this with
        /// the spans dropped -- one code path, and the lossy view is the one
        /// declared in the port, since spans are a transitional need of the text
        /// renderer rather than something the graph is built from.
        pub const Result = union(enum) {
            unsupported,
            tagged: []tagger_mod.Tagged,
        };

        /// The real extraction. `extract` is this minus spans.
        pub fn tagWithSpans(
            self: *Self,
            gpa: Allocator,
            io: Io,
            repo_root: []const u8,
            paths: []const []const u8,
        ) ![]Result {
            const out = try gpa.alloc(Result, paths.len);
            errdefer gpa.free(out);

            for (paths, 0..) |path, i| {
                out[i] = .unsupported;

                const ext = (try root.extensionOf(self.gpa, path)) orelse continue;
                defer self.gpa.free(ext);

                const g = (try self.grammarFor(io, ext)) orelse continue;

                // An absolute path is used as given. Joining it onto the root
                // produces "./Users/..." -- a path that does not exist -- and the
                // read then fails into `.unsupported`, reporting a perfectly
                // readable file as having no grammar.
                const full = if (std.fs.path.isAbsolute(path))
                    try gpa.dupe(u8, path)
                else
                    try std.fs.path.join(gpa, &.{ repo_root, path });
                defer gpa.free(full);
                const src = Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(64 << 20)) catch continue;
                defer gpa.free(src);

                // A file that parses to nothing still gets tags with an empty
                // slice, never `.unsupported`: the two mean different things to
                // the cache, and conflating them re-attempts a readable file on
                // every call forever.
                out[i] = .{ .tagged = Backend.tagFile(g, gpa, ext, src) catch continue };
            }
            return out;
        }

        fn extractFn(
            ptr: *anyopaque,
            gpa: Allocator,
            io: Io,
            repo_root: []const u8,
            paths: []const []const u8,
        ) anyerror![]ports.Extractor.Outcome {
            const self: *Self = @ptrCast(@alignCast(ptr));

            const results = try self.tagWithSpans(gpa, io, repo_root, paths);
            defer gpa.free(results);

            const out = try gpa.alloc(ports.Extractor.Outcome, paths.len);
            errdefer gpa.free(out);
            for (results, 0..) |r, i| {
                switch (r) {
                    .unsupported => out[i] = .unsupported,
                    .tagged => |tagged| {
                        // Ownership of every string moves across; only the
                        // Tagged slice itself is freed.
                        defer gpa.free(tagged);
                        const tags = try gpa.alloc(model.Tag, tagged.len);
                        for (tagged, 0..) |t, n| tags[n] = t.tag;
                        out[i] = .{ .tags = tags };
                    },
                }
            }
            return out;
        }

        /// Prepared once per extension, then cached -- including the negative,
        /// which is what keeps a repo full of unsupported files from re-resolving
        /// and re-warning per file.
        fn grammarFor(self: *Self, io: Io, ext: []const u8) !?Backend.Grammar {
            if (self.grammars.get(ext)) |cached| return cached;

            const owned_ext = try self.gpa.dupe(u8, ext);
            errdefer self.gpa.free(owned_ext);

            const prepared = self.prepare(io, ext) catch |e| {
                std.debug.print("synapse-tags: grammar for .{s} is not usable ({t}) -- those files are skipped\n", .{ ext, e });
                try self.grammars.put(self.gpa, owned_ext, null);
                return null;
            };
            try self.grammars.put(self.gpa, owned_ext, prepared);
            return prepared;
        }

        fn prepare(self: *Self, io: Io, ext: []const u8) !?Backend.Grammar {
            const gpa = self.gpa;

            // `scope` was required for an entry to count as usable, matching
            // the shell script's rule so a registry written for it stays valid,
            // but went unconsumed until sb-012: `Tagger` now needs it to resolve
            // a scoped kind-synonym rule for the `locals.scm` reading. `source`
            // says which file backs this extension's tags, and `Backend.load`
            // needs it to find the right one.
            const readiness = self.registry.lookup(ext);
            const ready: root.Ready = switch (readiness) {
                .ready => |r| r,
                .unusable => {
                    std.debug.print("synapse-tags: grammar for .{s} is marked unsupported -- those files are skipped\n", .{ext});
                    return null;
                },
                .no_entry => {
                    std.debug.print("synapse-tags: no grammar registered for .{s} -- those files are skipped\n", .{ext});
                    return null;
                },
            };
            const repo_url = self.registry.repoFor(ext) orelse return null;

            const repos_parent = try std.fs.path.join(gpa, &.{ self.grammars_dir, "repos" });
            defer gpa.free(repos_parent);
            const repo_dir = try grammar.ensureCloned(io, gpa, repo_url, repos_parent, self.lock_tries);
            defer gpa.free(repo_dir);

            return try Backend.load(
                gpa,
                io,
                repo_dir,
                self.grammars_dir,
                grammar.repoNameOf(repo_url),
                self.registry.pathFor(ext),
                self.registry.symbolFor(ext),
                ready.source,
                ext,
                self.query_override_dir,
                self.kind_rules,
                ready.scope,
            );
        }
    };
}

const testing = std.testing;

test "an extension with no registry entry is reported once, then skipped" {
    const gpa = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{}", .{});
    defer parsed.deinit();
    var kind_rules = try core.kind_synonyms.RuleList.load(gpa, testing.io, "/nonexistent");
    defer kind_rules.deinit();

    var ex: TreeSitterExtractor = .init(gpa, .{ .parsed = parsed }, "/nonexistent", kind_rules);
    defer ex.deinit();


    const out = try ex.port().extract(gpa, testing.io, ".", &.{ "a.zz", "b.zz" });
    defer gpa.free(out);

    try testing.expect(out[0] == .unsupported);
    try testing.expect(out[1] == .unsupported);
    // Both files, one resolution: the negative is cached.
    try testing.expectEqual(@as(usize, 1), ex.grammars.count());
}

test "a file with no extension is unsupported without touching the registry" {
    const gpa = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{}", .{});
    defer parsed.deinit();
    var kind_rules = try core.kind_synonyms.RuleList.load(gpa, testing.io, "/nonexistent");
    defer kind_rules.deinit();

    var ex: TreeSitterExtractor = .init(gpa, .{ .parsed = parsed }, "/nonexistent", kind_rules);
    defer ex.deinit();

    const out = try ex.port().extract(gpa, testing.io, ".", &.{"Makefile"});
    defer gpa.free(out);
    try testing.expect(out[0] == .unsupported);
    try testing.expectEqual(@as(usize, 0), ex.grammars.count());
}
