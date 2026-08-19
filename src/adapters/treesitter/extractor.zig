//! The Extractor the `synapse` app wires: registry in, tags out, no CLI.
//! Per extension, once: resolve the registry entry, clone/compile/load the
//! grammar, build a `Tagger` from its `tags.scm`. An unsupported extension
//! is reported once, then skipped without re-resolving.
//!
//! Generic over the grammar backend: `TsBackend` compiles a real grammar;
//! the fake backend behind `synapse-fake` returns scripted tags with no C
//! compiler or real grammar -- so `tests/*.bats` exercises the same shared
//! code either way.

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
        /// Sub-directory holding `src/parser.c`, or null for the repo root.
        sub_path: ?[]const u8,
        /// Explicit `tree_sitter_*` symbol, or null to derive from the repo name.
        sub_symbol: ?[]const u8,
        /// What the registry says backs this extension's tags; `query_override_dir`
        /// below can override it.
        source: root.QuerySource,
        /// Bare extension, no leading dot -- for the override path below.
        ext: []const u8,
        /// `$SYNAPSE_GRAMMARS_QUERY_PATH` (sb-012), or null. `{this}/{ext}.scm`,
        /// when present, wins over `source` entirely.
        query_override_dir: ?[]const u8,
        /// Passed straight to `Tagger.init`.
        kind_rules: core.kind_synonyms.RuleList,
        /// This extension's tree-sitter scope, passed straight to `Tagger.init`.
        scope: []const u8,
    ) !Grammar {
        const symbol = if (sub_symbol) |s| try gpa.dupe(u8, s) else try grammar.symbolFor(gpa, name);
        defer gpa.free(symbol);

        // Keyed by symbol, not repo name: one repo can ship several grammars
        // (tree_sitter_ocaml / tree_sitter_ocaml_interface), and two
        // extensions resolving to one language (kt/kts) share a library.
        const lib_path = try std.fmt.allocPrint(gpa, "{s}/lib/{s}.{s}", .{
            grammars_dir, symbol, grammar.sharedLibExt(),
        });
        defer gpa.free(lib_path);

        // Parser may live under a sub-directory; the tags query stays at the
        // repo root, shared by every sub-grammar.
        const src_root = if (sub_path) |p|
            try std.fs.path.join(gpa, &.{ repo_dir, p })
        else
            try gpa.dupe(u8, repo_dir);
        defer gpa.free(src_root);

        try grammar.build(io, gpa, src_root, lib_path, grammar.default_lock_tries);

        const lang = try grammar.load(gpa, lib_path, symbol);

        // Override (sb-012): checked first, wins over every tier.
        // FileNotFound means no override; anything else propagates.
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
                // `.override`, not `source`: always reads the tags.scm
                // convention regardless of what the registry says.
                t.* = try Tagger.init(lang, scm, .override, kind_rules, scope, null);
                return t;
            }
        }

        // Tier 3 (sb-012): query synthesized from node-types.json beside
        // src/parser.c. Tagger owns `classification` from here on.
        if (source == .generated) {
            const node_types_path = try std.fs.path.join(gpa, &.{ src_root, "src", "node-types.json" });
            defer gpa.free(node_types_path);
            var classification = try node_types.classify(gpa, io, node_types_path);
            // Armed only up to the ownership transfer into `t.classification`
            // below: nothing fallible may sit between `Tagger.init` and
            // `return t`, or this would double-free after the transfer.
            errdefer classification.deinit();

            // `synapse-kind-synonyms.conf` overrides a guessed kind before it's
            // baked into the query string -- same rule list tier 2 already
            // reads, reused here keyed on the grammar's raw node *type name*
            // (e.g. "ContainerDecl") rather than a `local.definition.` suffix.
            // Absent/empty (the default) means every lookup misses and every
            // guess keeps its classifier-derived kind, unchanged from before.
            for (classification.guesses) |*g| {
                if (kind_rules.kindFor(g.type_name, scope)) |k| g.kind = k;
            }

            const generated_query = try node_types.buildQuery(gpa, classification.guesses);
            defer gpa.free(generated_query);

            const t = try gpa.create(Tagger);
            errdefer gpa.destroy(t);
            t.* = try Tagger.init(lang, generated_query, .generated, kind_rules, scope, classification);
            return t;
        }

        // Tier 1/2 (sb-012): static file in the clone; tags.scm/locals.scm
        // never move with a sub-grammar's `sub_path`.
        const scm_filename = switch (source) {
            .tags => "tags.scm",
            .locals => "locals.scm",
            .generated => unreachable, // handled above
            .override => unreachable, // handled above
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
        /// `$SYNAPSE_GRAMMARS_DIR`, default `~/.cache/synapse/grammars`.
        grammars_dir: []const u8,
        /// Kind-synonym rules (sb-012), borrowed for as long as any
        /// `locals.scm`-built `Tagger` might consult them.
        kind_rules: core.kind_synonyms.RuleList,
        /// Bounds a wedged lock from a crashed holder, not the clone itself.
        lock_tries: usize = grammar.default_lock_tries,
        /// `$SYNAPSE_GRAMMARS_QUERY_PATH` (sb-012); when set, `{this}/{ext}.scm`
        /// is tried before every tier, for every extension.
        query_override_dir: ?[]const u8 = null,

        /// null means "known unusable" -- resolved and reported once.
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

        /// Spans included; the port's `Outcome` drops them.
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

                // Absolute paths are used as given -- joining onto the root
                // would produce a nonexistent "./Users/..." path.
                const full = if (std.fs.path.isAbsolute(path))
                    try gpa.dupe(u8, path)
                else
                    try std.fs.path.join(gpa, &.{ repo_root, path });
                defer gpa.free(full);
                const src = Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(64 << 20)) catch continue;
                defer gpa.free(src);

                // A file that parses to nothing still gets an empty tag
                // slice, never `.unsupported` -- conflating the two would
                // re-attempt a readable file on every call forever.
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
                        defer gpa.free(tagged); // string ownership moves; only the slice is freed
                        const tags = try gpa.alloc(model.Tag, tagged.len);
                        for (tagged, 0..) |t, n| tags[n] = t.tag;
                        out[i] = .{ .tags = tags };
                    },
                }
            }
            return out;
        }

        /// Cached per extension, including the negative -- keeps an
        /// unsupported-heavy repo from re-resolving and re-warning per file.
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
    try testing.expectEqual(@as(usize, 1), ex.grammars.count()); // both files, one cached resolution
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
