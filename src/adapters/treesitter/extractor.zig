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

const std = @import("std");
const model = @import("model");
const ports = @import("ports");
const root = @import("root.zig");
const grammar = @import("grammar.zig");
const tagger_mod = @import("tagger.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Tagger = tagger_mod.Tagger;

pub const TreeSitterExtractor = struct {
    gpa: Allocator,
    registry: root.Registry,
    /// `$SYNAPSE_GRAMMARS_DIR`, default `~/.cache/synapse/grammars`. Repos are
    /// cloned under `repos/`, built libraries cached under `lib/`.
    grammars_dir: []const u8,
    /// ~60s at 200ms a try, matching the shell script's default. Bounds a
    /// wedged lock from a crashed holder, not the clone itself.
    lock_tries: usize = 300,

    /// null means "known unusable" -- resolved once, reported once, then
    /// skipped without re-resolving.
    taggers: std.StringHashMapUnmanaged(?*Tagger) = .empty,

    pub fn init(gpa: Allocator, registry: root.Registry, grammars_dir: []const u8) TreeSitterExtractor {
        return .{ .gpa = gpa, .registry = registry, .grammars_dir = grammars_dir };
    }

    pub fn deinit(self: *TreeSitterExtractor) void {
        var it = self.taggers.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |t| {
                t.deinit();
                self.gpa.destroy(t);
            }
        }
        self.taggers.deinit(self.gpa);
    }

    pub fn port(self: *TreeSitterExtractor) ports.Extractor {
        return .{ .ptr = self, .vtable = &.{ .extract = extractFn } };
    }

    fn extractFn(
        ptr: *anyopaque,
        gpa: Allocator,
        io: Io,
        repo_root: []const u8,
        paths: []const []const u8,
    ) anyerror![]ports.Extractor.Outcome {
        const self: *TreeSitterExtractor = @ptrCast(@alignCast(ptr));

        const out = try gpa.alloc(ports.Extractor.Outcome, paths.len);
        errdefer gpa.free(out);

        for (paths, 0..) |path, i| {
            out[i] = .unsupported;

            const ext = (try grammar_extensionOf(self.gpa, path)) orelse continue;
            defer self.gpa.free(ext);

            const tagger = (try self.taggerFor(io, ext)) orelse continue;

            const full = try std.fs.path.join(gpa, &.{ repo_root, path });
            defer gpa.free(full);
            const src = Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(64 << 20)) catch continue;
            defer gpa.free(src);

            // A file that parses to nothing still gets `.tags` with an empty
            // slice, never `.unsupported`: the two mean different things to
            // the cache, and conflating them re-attempts a readable file on
            // every call forever.
            const tagged = tagger.tagFile(gpa, src) catch continue;
            // The port speaks in Tags; spans exist only for the transitional
            // text renderer. Ownership of every string moves across here, so
            // the Tagged slice is freed and its contents are not.
            defer gpa.free(tagged);
            const tags = try gpa.alloc(model.Tag, tagged.len);
            for (tagged, 0..) |t, n| tags[n] = t.tag;
            out[i] = .{ .tags = tags };
        }
        return out;
    }

    /// Prepared once per extension, then cached -- including the negative,
    /// which is what keeps a repo full of unsupported files from re-resolving
    /// and re-warning per file.
    fn taggerFor(self: *TreeSitterExtractor, io: Io, ext: []const u8) !?*Tagger {
        if (self.taggers.get(ext)) |cached| return cached;

        const owned_ext = try self.gpa.dupe(u8, ext);
        errdefer self.gpa.free(owned_ext);

        const prepared = self.prepare(io, ext) catch |e| {
            std.debug.print("synapse-tags: grammar for .{s} is not usable ({t}) -- those files are skipped\n", .{ ext, e });
            try self.taggers.put(self.gpa, owned_ext, null);
            return null;
        };
        try self.taggers.put(self.gpa, owned_ext, prepared);
        return prepared;
    }

    fn prepare(self: *TreeSitterExtractor, io: Io, ext: []const u8) !?*Tagger {
        const gpa = self.gpa;

        // `scope` is still required for an entry to count as usable, matching
        // the shell script's rule so a registry written for it stays valid --
        // but nothing here consumes it. It existed to pass `--scope` to the
        // CLI, and there is no CLI any more.
        const readiness = self.registry.lookup(ext);
        const repo_url = switch (readiness) {
            .ready => self.registry.repoFor(ext) orelse return null,
            .unusable => {
                std.debug.print("synapse-tags: grammar for .{s} is marked unsupported -- those files are skipped\n", .{ext});
                return null;
            },
            .no_entry => {
                std.debug.print("synapse-tags: no grammar registered for .{s} -- those files are skipped\n", .{ext});
                return null;
            },
        };

        const repos_parent = try std.fs.path.join(gpa, &.{ self.grammars_dir, "repos" });
        defer gpa.free(repos_parent);
        const repo_dir = try grammar.ensureCloned(io, gpa, repo_url, repos_parent, self.lock_tries);
        defer gpa.free(repo_dir);

        const name = grammar.repoNameOf(repo_url);
        const lib_path = try std.fmt.allocPrint(gpa, "{s}/lib/{s}.{s}", .{
            self.grammars_dir, name, grammar.sharedLibExt(),
        });
        defer gpa.free(lib_path);

        try grammar.build(io, gpa, repo_dir, lib_path);

        const symbol = try grammar.symbolFor(gpa, name);
        defer gpa.free(symbol);
        const lang = try grammar.load(gpa, lib_path, symbol);

        const scm_path = try std.fs.path.join(gpa, &.{ repo_dir, "queries", "tags.scm" });
        defer gpa.free(scm_path);
        const scm = try Io.Dir.cwd().readFileAlloc(io, scm_path, gpa, .limited(1 << 20));
        defer gpa.free(scm);

        const t = try gpa.create(Tagger);
        errdefer gpa.destroy(t);
        t.* = try Tagger.init(lang, scm);
        return t;
    }
};

fn grammar_extensionOf(gpa: Allocator, path: []const u8) !?[]u8 {
    return root.extensionOf(gpa, path);
}

const testing = std.testing;

test "an extension with no registry entry is reported once, then skipped" {
    const gpa = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{}", .{});
    defer parsed.deinit();

    var ex: TreeSitterExtractor = .init(gpa, .{ .parsed = parsed }, "/nonexistent");
    defer ex.deinit();

    var t: std.Io.Threaded = .init(gpa, .{});
    defer t.deinit();

    const out = try ex.port().extract(gpa, t.io(), ".", &.{ "a.zz", "b.zz" });
    defer gpa.free(out);

    try testing.expect(out[0] == .unsupported);
    try testing.expect(out[1] == .unsupported);
    // Both files, one resolution: the negative is cached.
    try testing.expectEqual(@as(usize, 1), ex.taggers.count());
}

test "a file with no extension is unsupported without touching the registry" {
    const gpa = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{}", .{});
    defer parsed.deinit();

    var ex: TreeSitterExtractor = .init(gpa, .{ .parsed = parsed }, "/nonexistent");
    defer ex.deinit();
    var t: std.Io.Threaded = .init(gpa, .{});
    defer t.deinit();

    const out = try ex.port().extract(gpa, t.io(), ".", &.{"Makefile"});
    defer gpa.free(out);
    try testing.expect(out[0] == .unsupported);
    try testing.expectEqual(@as(usize, 0), ex.taggers.count());
}
