//! `DiskStore`: a `ports.Store` backed by plain markdown files directly on
//! disk, no network dependency at all. `namespace` prefixes every node name
//! so a caller passes a bare title, never a vault path; an empty
//! `namespace` means `node` is already a full vault-relative path (the
//! `frontmatter`/whole-vault case). An extended store composing this exact
//! type for its own `read`/`write`/`list` reuses the same addressing shape.

const std = @import("std");
const ports = @import("ports");
const core = @import("core");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;
const LinkGraph = ports.LinkGraph;
const Renamer = ports.Renamer;

pub const DiskStore = struct {
    gpa: Allocator,
    /// The vault root -- every node path resolves under here.
    vault: []const u8,
    /// `synapse/{repo}@{branch}`, prefixed onto every node name. Empty
    /// means `node` is already a full vault-relative path.
    namespace: []const u8,
    /// A link graph is a whole-vault concept, not a per-namespace one --
    /// composed from `vault` directly regardless of what namespace this
    /// particular `DiskStore` was constructed with.
    link_graph: DiskLinkGraph,
    /// Same vault-wide-always reasoning as `link_graph` -- a rename's
    /// referring-wikilink rewrite is a whole-vault concern too.
    rename_impl: DiskRenamer,
    /// The resolver for finding conf files (`synapse-prompt-stopwords.conf`
    /// for `search`'s own ranking), not a path or a raw environment map --
    /// propagated in, resolved lazily only when actually needed. Defaults
    /// to `.none` (never resolves anything, degrading `search` to
    /// length/digit filtering with no stopword list) so every existing
    /// caller of `init` keeps compiling unchanged; `resolveStore` is the
    /// one real construction site that sets this to the real environment.
    vars: core.conf.Vars = core.conf.Vars.none,

    pub fn init(gpa: Allocator, vault: []const u8, namespace: []const u8) !DiskStore {
        const owned_vault = try gpa.dupe(u8, vault);
        return .{
            .gpa = gpa,
            .vault = owned_vault,
            .namespace = try gpa.dupe(u8, namespace),
            .link_graph = .{ .vault = owned_vault },
            .rename_impl = .{ .vault = owned_vault },
        };
    }

    pub fn deinit(self: *DiskStore) void {
        self.gpa.free(self.vault);
        self.gpa.free(self.namespace);
    }

    /// The wrapper idiom: `Store.from` generates the `*anyopaque` cast from
    /// `DiskStore` alone, so it can never disagree with `.ptr` the way a
    /// hand-written vtable literal could.
    pub fn store(self: *DiskStore) Store {
        return Store.from(DiskStore, self);
    }

    /// One-line delegation to the composed field -- `DiskStore` doesn't
    /// implement any `LinkGraph` method itself.
    pub fn linkGraph(self: *DiskStore) LinkGraph {
        return self.link_graph.linkGraph();
    }

    /// Same one-line delegation, for the composed `DiskRenamer`.
    pub fn renamer(self: *DiskStore) Renamer {
        return self.rename_impl.renamer();
    }

    fn nodePath(self: *DiskStore, gpa: Allocator, node: []const u8) ![]u8 {
        if (!core.node_path.isSafe(node)) return error.UnsafeNodePath;
        if (self.namespace.len == 0) return std.fs.path.join(gpa, &.{ self.vault, node });
        return std.fs.path.join(gpa, &.{ self.vault, self.namespace, node });
    }

    pub fn read(self: *DiskStore, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        const path = try self.nodePath(gpa, node);
        defer gpa.free(path);
        return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)) catch |e| {
            if (e == error.FileNotFound) return null;
            return e;
        };
    }

    pub fn write(self: *DiskStore, io: Io, node: []const u8, body: []const u8) anyerror!Store.WriteResult {
        const path = try self.nodePath(self.gpa, node);
        defer self.gpa.free(path);
        const cwd = Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);

        // Temp file + rename, not a plain in-place write: a reader must
        // never observe a partially-written note. Same pattern
        // `core.tags_cache.Cache.replaceFile` already uses for the Code
        // Cache's own writes.
        const tmp = try std.fmt.allocPrint(self.gpa, "{s}.tmp", .{path});
        defer self.gpa.free(tmp);
        {
            const file = try cwd.createFile(io, tmp, .{});
            defer file.close(io);
            errdefer cwd.deleteFile(io, tmp) catch {};
            var buf: [64 * 1024]u8 = undefined;
            var writer = file.writer(io, &buf);
            try writer.interface.writeAll(body);
            try writer.interface.flush();
        }
        errdefer cwd.deleteFile(io, tmp) catch {};
        try cwd.rename(tmp, cwd, path, io);

        return .{ .accepted = true };
    }

    /// Every `.md` file anywhere under `{vault}/{namespace}`, recursively.
    /// See `listMarkdownFiles` below -- the real implementation.
    pub fn list(self: *DiskStore, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        return listMarkdownFiles(gpa, io, self.vault, self.namespace);
    }

    /// Full-text search over every node's content, a plain-string contract
    /// (no field:value heuristic -- that's `core`-level JsonLogic composition
    /// over `read`/`list`, not this method's job). Rarity-weighted, not
    /// just occurrence-count: a query word rare across the vault
    /// contributes more to a document's score than a word common almost
    /// everywhere, using the exact `distinctivenessScore` formula
    /// `core.gate` already uses (and has already calibrated) for judging a
    /// code-graph cluster's vocabulary distinctiveness -- same underlying
    /// question ("how much does this word tell you"), applied here to
    /// ranking instead of clustering judgment. `tokenizeQuery` filters
    /// through the real `synapse-prompt-stopwords.conf` list, but that's a
    /// cheap first pass, not the mechanism doing the real work: a common
    /// word the list doesn't happen to catch still gets a high measured
    /// document frequency and is discounted by the same formula
    /// automatically. Falls back to the old whole-query substring count
    /// when every query word is too short/all-digits/stopped to survive
    /// filtering (e.g. a query of nothing but short connector words) -- a
    /// real query still gets a real answer instead of silently nothing.
    ///
    /// Recomputed fresh on every call, no persisted index: measured against
    /// this vault directly before settling on this (see the design note),
    /// not assumed -- a vault bounded by what this is actually for (notes,
    /// LLM permanent memory) rather than a general document store.
    pub fn search(self: *DiskStore, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
        return self.searchFiltered(gpa, io, query, null);
    }

    /// Same ranking as `search`, first scoped to whichever candidate paths
    /// pass `path_filter` -- a JsonLogic rule expected to reference nothing
    /// but `path` (`core.vault_query.pathMatches`, the exact mechanism
    /// `core.vault_query.query`'s own path-only short-circuit uses,
    /// applied here to every candidate unconditionally rather than only a
    /// top-level AND's direct children: a search-scoping filter has no
    /// `content`/`frontmatter`/`tags` to combine it with in the first
    /// place, so there's no partial-evaluation question to ask). A
    /// disqualified path is never read at all, same as `query`'s. `null`
    /// behaves exactly like `search` -- every node is a candidate, and
    /// rarity is scored against the whole vault as before; with a filter,
    /// rarity scores against the filtered candidate set instead, since
    /// that's the corpus the caller asked to search within.
    pub fn searchFiltered(
        self: *DiskStore,
        gpa: Allocator,
        io: Io,
        query: []const u8,
        path_filter: ?std.json.Value,
    ) anyerror![]const Store.Hit {
        const all_names = try self.list(gpa, io);
        defer {
            for (all_names) |n| gpa.free(n);
            gpa.free(all_names);
        }

        var kept: std.ArrayListUnmanaged([]const u8) = .empty;
        defer kept.deinit(gpa);
        const names: []const []const u8 = if (path_filter) |pf| blk: {
            for (all_names) |n| if (try core.vault_query.pathMatches(gpa, pf, n)) try kept.append(gpa, n);
            break :blk kept.items;
        } else all_names;

        const terms = try tokenizeQuery(gpa, io, self.vars, query);
        defer freeStrings(gpa, terms);
        if (terms.len == 0) return searchSubstring(self, gpa, io, names, query);

        // One read per file: per-term counts and the first matching line are
        // both captured here, so a match never needs its file read twice.
        const counts = try gpa.alloc([]usize, names.len);
        defer {
            for (counts) |c| gpa.free(c);
            gpa.free(counts);
        }
        const contexts = try gpa.alloc([]const u8, names.len);
        defer {
            for (contexts) |c| gpa.free(c);
            gpa.free(contexts);
        }
        const df = try gpa.alloc(usize, terms.len);
        defer gpa.free(df);
        @memset(df, 0);

        for (names, 0..) |name, i| {
            const body = (try self.read(gpa, io, name)) orelse "";
            defer gpa.free(body);
            // Frontmatter is metadata, not prose -- a code-graph node's
            // `sources:` block (hundreds of path/hash lines) would otherwise
            // get scored and quoted as if it were content. Slicing it off
            // costs nothing (a borrowed subslice of `body`, not a copy).
            const prose = core.query.bodyAfterFrontmatter(body);

            counts[i] = try gpa.alloc(usize, terms.len);
            for (terms, 0..) |t, ti| {
                const c = core.text_search.countIgnoreCase(prose, t);
                counts[i][ti] = c;
                if (c > 0) df[ti] += 1;
            }
            contexts[i] = try gpa.dupe(u8, firstMatchingLineAny(prose, terms) orelse "");
        }

        var out: std.ArrayListUnmanaged(Store.Hit) = .empty;
        errdefer {
            for (out.items) |h| {
                gpa.free(h.node);
                gpa.free(h.context);
            }
            out.deinit(gpa);
        }

        for (names, 0..) |name, i| {
            var score: f64 = 0;
            for (0..terms.len) |ti| {
                if (counts[i][ti] == 0) continue;
                const c: f64 = @floatFromInt(counts[i][ti]);
                score += c * core.gate.distinctivenessScore(df[ti], names.len, distinctiveness_k);
            }
            if (score == 0) continue;
            try out.append(gpa, .{
                .node = try gpa.dupe(u8, name),
                .score = @floatCast(score),
                .context = try gpa.dupe(u8, contexts[i]),
            });
        }

        std.mem.sort(Store.Hit, out.items, {}, higherScoreFirst);
        return out.toOwnedSlice(gpa);
    }
};

/// `core.gate.DistinctivenessOptions`'s own default -- reused, not
/// re-derived: `k = 20` is `/synapse-init`'s already-calibrated scaling
/// constant, and this is the exact same rarity question in a new context,
/// not a different one that would need its own tuning.
const distinctiveness_k: usize = 20;

fn higherScoreFirst(_: void, a: Store.Hit, b: Store.Hit) bool {
    return a.score > b.score;
}

/// `query`, split into words the same way `core.vocab.splitWords` splits a
/// code symbol (identifier-aware, so a query like "DiskStore" still finds
/// prose written as "disk store" and vice versa), filtered by
/// `core.vocab.keep`'s length/non-digit/stopword rule -- the real
/// `synapse-prompt-stopwords.conf` list, resolved through `vars` (a
/// resolver propagated in, not a path or a raw environment map; `vars ==
/// .none` degrades to length/digit filtering only, never an error). A
/// genuinely common word not caught by the stopword list still gets
/// discounted by its measured document frequency in `search` itself --
/// the two mechanisms overlap on purpose, the stopword list catches the
/// obvious/cheap case, `distinctivenessScore` catches everything else.
/// Deduplicated, so a repeated query word doesn't double-count its own
/// document frequency. Caller-owned.
fn tokenizeQuery(gpa: Allocator, io: Io, vars: core.conf.Vars, query: []const u8) ![]const []const u8 {
    var split: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (split.items) |w| gpa.free(w);
        split.deinit(gpa);
    }
    try core.vocab.splitWords(gpa, query, &split);

    var stopwords = try core.vocab.loadStopwords(gpa, io, vars);
    defer core.vocab.freeStopwords(gpa, &stopwords);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |w| gpa.free(w);
        out.deinit(gpa);
    }
    for (split.items) |w| {
        if (!core.vocab.keep(w, &stopwords)) continue;
        if (containsNode(out.items, w)) continue;
        try out.append(gpa, try gpa.dupe(u8, w));
    }
    return out.toOwnedSlice(gpa);
}

/// The first line in `body` containing any of `terms`, case-insensitive --
/// same role as `core.text_search.firstMatchingLine`, extended to a set of
/// words instead of one literal substring.
fn firstMatchingLineAny(body: []const u8, terms: []const []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        for (terms) |t| {
            if (std.ascii.findIgnoreCase(line, t) != null) return line;
        }
    }
    return null;
}

/// The pre-ranking behavior, kept as the fallback for a query with no
/// surviving term (every word too short or all-digits) -- a real query
/// still gets a real answer instead of silently nothing.
fn searchSubstring(self: *DiskStore, gpa: Allocator, io: Io, names: []const []const u8, query: []const u8) anyerror![]const Store.Hit {
    var out: std.ArrayListUnmanaged(Store.Hit) = .empty;
    errdefer {
        for (out.items) |h| {
            gpa.free(h.node);
            gpa.free(h.context);
        }
        out.deinit(gpa);
    }

    for (names) |name| {
        const body = (try self.read(gpa, io, name)) orelse continue;
        defer gpa.free(body);
        const prose = core.query.bodyAfterFrontmatter(body);
        const count = core.text_search.countIgnoreCase(prose, query);
        if (count == 0) continue;
        try out.append(gpa, .{
            .node = try gpa.dupe(u8, name),
            .score = @floatFromInt(count),
            .context = try gpa.dupe(u8, core.text_search.firstMatchingLine(prose, query) orelse ""),
        });
    }
    return out.toOwnedSlice(gpa);
}

/// `LinkGraph` backed by nothing but the files on disk -- computed by
/// scanning the whole vault directly on every call, no persistent index yet
/// (the design note's own staleness/caching work is a separate, later pass;
/// correctness doesn't depend on it at this vault's measured size). Always
/// vault-wide, never namespace-scoped: a link can point anywhere in the
/// vault, and `synapse/{repo}@{branch}` is excluded outright -- that
/// namespace already has its own cache and its own typed `## Links`
/// resolution, so folding it in here would duplicate one and conflate the
/// other.
///
/// Resolution is case-insensitive against every real file's own title (its
/// filename minus `.md`, kept identical to `title:` frontmatter by this
/// vault's convention). A target matching more than one file is never
/// silently resolved to one: every candidate is counted into
/// `backlinks`/`links`, and the occurrence is separately reported by
/// `ambiguous` instead of being dropped or guessed at.
pub const DiskLinkGraph = struct {
    vault: []const u8,

    pub fn linkGraph(self: *DiskLinkGraph) LinkGraph {
        return LinkGraph.from(DiskLinkGraph, self);
    }

    pub fn backlinks(self: *DiskLinkGraph, gpa: Allocator, io: Io, node: []const u8) anyerror![]const LinkGraph.Backlink {
        const edges = try buildEdges(gpa, io, self.vault);
        defer freeEdges(gpa, edges);

        var counts: std.StringHashMapUnmanaged(usize) = .empty;
        defer counts.deinit(gpa);
        for (edges) |e| {
            if (!containsNode(e.candidates, node)) continue;
            const gop = try counts.getOrPut(gpa, e.source);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }

        var out: std.ArrayListUnmanaged(LinkGraph.Backlink) = .empty;
        errdefer {
            for (out.items) |b| gpa.free(b.node);
            out.deinit(gpa);
        }
        var it = counts.iterator();
        while (it.next()) |entry| {
            try out.append(gpa, .{ .node = try gpa.dupe(u8, entry.key_ptr.*), .count = entry.value_ptr.* });
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn links(self: *DiskLinkGraph, gpa: Allocator, io: Io, node: []const u8) anyerror![]const []const u8 {
        const edges = try buildEdges(gpa, io, self.vault);
        defer freeEdges(gpa, edges);

        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |n| gpa.free(n);
            out.deinit(gpa);
        }
        for (edges) |e| {
            if (!std.mem.eql(u8, e.source, node)) continue;
            for (e.candidates) |c| {
                if (containsNode(out.items, c)) continue;
                try out.append(gpa, try gpa.dupe(u8, c));
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// Zero-candidate edges only -- an edge with more than one candidate is
    /// `ambiguous`'s to report, not this one's; the two are mutually
    /// exclusive by construction (`buildEdges` puts every edge in exactly
    /// one bucket by its own candidate count).
    pub fn unresolved(self: *DiskLinkGraph, gpa: Allocator, io: Io) anyerror![]const LinkGraph.Unresolved {
        const edges = try buildEdges(gpa, io, self.vault);
        defer freeEdges(gpa, edges);
        return groupByTarget(gpa, edges);
    }

    /// More-than-one-candidate edges only -- see `unresolved`'s own note on
    /// why the two never overlap.
    pub fn ambiguous(self: *DiskLinkGraph, gpa: Allocator, io: Io) anyerror![]const LinkGraph.Ambiguous {
        const edges = try buildEdges(gpa, io, self.vault);
        defer freeEdges(gpa, edges);

        var groups: std.StringHashMapUnmanaged(struct {
            candidates: []const []const u8,
            count: usize,
            sources: std.ArrayListUnmanaged([]const u8),
        }) = .empty;
        defer {
            var it = groups.valueIterator();
            while (it.next()) |v| v.sources.deinit(gpa);
            groups.deinit(gpa);
        }

        for (edges) |e| {
            if (e.candidates.len <= 1) continue;
            const gop = try groups.getOrPut(gpa, e.target_text);
            if (!gop.found_existing) gop.value_ptr.* = .{ .candidates = e.candidates, .count = 0, .sources = .empty };
            gop.value_ptr.count += 1;
            if (!containsNode(gop.value_ptr.sources.items, e.source)) {
                try gop.value_ptr.sources.append(gpa, e.source);
            }
        }

        var out: std.ArrayListUnmanaged(LinkGraph.Ambiguous) = .empty;
        errdefer {
            for (out.items) |a| {
                gpa.free(a.target);
                for (a.candidates) |c| gpa.free(c);
                gpa.free(a.candidates);
                for (a.sources) |s| gpa.free(s);
                gpa.free(a.sources);
            }
            out.deinit(gpa);
        }
        var it = groups.iterator();
        while (it.next()) |entry| {
            try out.append(gpa, .{
                .target = try gpa.dupe(u8, entry.key_ptr.*),
                .candidates = try dupeStrings(gpa, entry.value_ptr.candidates),
                .count = entry.value_ptr.count,
                .sources = try dupeStrings(gpa, entry.value_ptr.sources.items),
            });
        }
        return out.toOwnedSlice(gpa);
    }

    /// No backlinks -- every real file that never appears as a candidate for
    /// any edge, vault-wide.
    pub fn orphans(self: *DiskLinkGraph, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        const edges = try buildEdges(gpa, io, self.vault);
        defer freeEdges(gpa, edges);
        const all = try vaultPaths(gpa, io, self.vault);
        defer freeStrings(gpa, all);

        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |n| gpa.free(n);
            out.deinit(gpa);
        }
        for (all) |path| {
            var has_backlink = false;
            for (edges) |e| {
                if (containsNode(e.candidates, path)) {
                    has_backlink = true;
                    break;
                }
            }
            if (!has_backlink) try out.append(gpa, try gpa.dupe(u8, path));
        }
        return out.toOwnedSlice(gpa);
    }

    /// No resolved outgoing links -- every real file whose own body never
    /// contributes a resolved (one-or-more-candidate) edge as a source. A
    /// file with only unresolved (zero-candidate) outgoing links still has
    /// no real destination, so it counts as a deadend too.
    pub fn deadends(self: *DiskLinkGraph, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        const edges = try buildEdges(gpa, io, self.vault);
        defer freeEdges(gpa, edges);
        const all = try vaultPaths(gpa, io, self.vault);
        defer freeStrings(gpa, all);

        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |n| gpa.free(n);
            out.deinit(gpa);
        }
        for (all) |path| {
            var has_outgoing = false;
            for (edges) |e| {
                if (std.mem.eql(u8, e.source, path) and e.candidates.len > 0) {
                    has_outgoing = true;
                    break;
                }
            }
            if (!has_outgoing) try out.append(gpa, try gpa.dupe(u8, path));
        }
        return out.toOwnedSlice(gpa);
    }
};

/// `Renamer` backed by nothing but the files on disk -- the default
/// implementation every `DiskStore` composes. `old_path`/`new_path` are full
/// vault-relative paths, the same addressing `DiskLinkGraph` already uses.
/// Keeps title/filename identity in sync per this vault's own convention:
/// writes the note under its new name with `title:`/H1 brought in line via
/// `syncTitleAndHeading`, rewrites every referring `[[wikilink]]` to match,
/// then removes the old file -- in that order, so every step that still
/// needs the old name to resolve (finding its referrers) runs before the
/// file backing that name is gone.
pub const DiskRenamer = struct {
    vault: []const u8,

    pub fn renamer(self: *DiskRenamer) Renamer {
        return Renamer.from(DiskRenamer, self);
    }

    pub fn rename(self: *DiskRenamer, gpa: Allocator, io: Io, old_path: []const u8, new_path: []const u8) anyerror!void {
        var store = try DiskStore.init(gpa, self.vault, "");
        defer store.deinit();

        const body = (try store.read(gpa, io, old_path)) orelse return error.NodeNotFound;
        defer gpa.free(body);

        // Computed before any write: a referrer's own resolution depends on
        // `old_path` still existing as a real candidate.
        var lg: DiskLinkGraph = .{ .vault = self.vault };
        const referrers = try lg.backlinks(gpa, io, old_path);
        defer {
            for (referrers) |r| gpa.free(r.node);
            gpa.free(referrers);
        }

        const old_title = titleOf(old_path);
        const new_title = titleOf(new_path);

        // The moved note's own body gets the same rewrite any other
        // referrer does -- a self-link is just a referrer that happens to
        // be this file, written to its new location instead of back to
        // itself.
        const wikilinks_rewritten = try core.wikilinks.renameTarget(gpa, body, old_title, new_title);
        defer gpa.free(wikilinks_rewritten);
        const rewritten_self = try syncTitleAndHeading(gpa, wikilinks_rewritten, old_title, new_title);
        defer gpa.free(rewritten_self);
        _ = try store.write(io, new_path, rewritten_self);

        for (referrers) |r| {
            if (std.mem.eql(u8, r.node, old_path)) continue; // handled above
            const referrer_body = (try store.read(gpa, io, r.node)) orelse continue;
            defer gpa.free(referrer_body);
            const rewritten = try core.wikilinks.renameTarget(gpa, referrer_body, old_title, new_title);
            defer gpa.free(rewritten);
            _ = try store.write(io, r.node, rewritten);
        }

        // A case-only rename (`Foo.md` -> `foo.md`) on a case-insensitive
        // filesystem (APFS, NTFS) writes and deletes the same inode: the
        // write above already landed the new content there, so deleting
        // `old_path` now would destroy the note it just wrote. Compare
        // inodes rather than path bytes so this holds regardless of the
        // filesystem's case sensitivity -- a real two-file rename always
        // has distinct inodes and deletes as before.
        if (try sameFile(io, self.vault, old_path, new_path)) return;
        try deleteVaultFile(gpa, io, self.vault, old_path);
    }
};

/// True when `old_path` and `new_path` resolve to the same underlying file
/// -- the case-insensitive-filesystem collision `DiskRenamer.rename` has to
/// guard against. `old_path`'s stat failing (already gone) or the two
/// inodes disagreeing both mean "not the same file, safe to delete".
fn sameFile(io: Io, vault: []const u8, old_path: []const u8, new_path: []const u8) !bool {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const old_full = std.fs.path.join(fba.allocator(), &.{ vault, old_path }) catch return false;
    var buf2: [Io.Dir.max_path_bytes]u8 = undefined;
    var fba2 = std.heap.FixedBufferAllocator.init(&buf2);
    const new_full = std.fs.path.join(fba2.allocator(), &.{ vault, new_path }) catch return false;

    const old_stat = Io.Dir.cwd().statFile(io, old_full, .{}) catch return false;
    const new_stat = Io.Dir.cwd().statFile(io, new_full, .{}) catch return false;
    return old_stat.inode == new_stat.inode;
}

/// Removes a vault-relative file directly -- not a `Store` operation (`Store`
/// stays at exactly four methods, none of them delete), needed only by
/// `DiskRenamer`'s own cleanup step. Absence is ordinary, matching `read`'s
/// own rule: a file already gone (a second rename attempt, a manual delete)
/// is not an error.
fn deleteVaultFile(gpa: Allocator, io: Io, vault: []const u8, path: []const u8) !void {
    if (!core.node_path.isSafe(path)) return error.UnsafeNodePath;
    const full = try std.fs.path.join(gpa, &.{ vault, path });
    defer gpa.free(full);
    Io.Dir.cwd().deleteFile(io, full) catch |e| {
        if (e == error.FileNotFound) return;
        return e;
    };
}

/// One extracted-and-resolved wikilink occurrence. `candidates.len` sorts it
/// into exactly one of three buckets: 0 (unresolved), 1 (cleanly resolved,
/// contributes to `backlinks`/`links` only), or 2+ (ambiguous -- contributes
/// to `backlinks`/`links` for every candidate *and* to `ambiguous`).
const Edge = struct {
    source: []const u8,
    target_text: []const u8,
    candidates: []const []const u8,
};

fn freeEdges(gpa: Allocator, edges: []const Edge) void {
    for (edges) |e| {
        gpa.free(e.source);
        gpa.free(e.target_text);
        freeStrings(gpa, e.candidates);
    }
    gpa.free(edges);
}

fn freeStrings(gpa: Allocator, s: []const []const u8) void {
    for (s) |t| gpa.free(t);
    gpa.free(s);
}

fn dupeStrings(gpa: Allocator, s: []const []const u8) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, s.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |o| gpa.free(o);
        gpa.free(out);
    }
    for (s, 0..) |item, i| {
        out[i] = try gpa.dupe(u8, item);
        filled = i + 1;
    }
    return out;
}

fn containsNode(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// `synapse/{repo}@{branch}` (any top-level `synapse/` segment) is never
/// indexed by this link graph -- see the design note's own Constraints.
fn isSynapseNamespace(path: []const u8) bool {
    const first = if (std.mem.indexOfScalar(u8, path, '/')) |i| path[0..i] else path;
    return std.mem.eql(u8, first, "synapse");
}

/// A path's title -- its filename minus `.md` -- kept identical to `title:`
/// frontmatter by this vault's own convention, and what a bare `[[wikilink]]`
/// actually names.
pub fn titleOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (std.mem.endsWith(u8, base, ".md")) base[0 .. base.len - 3] else base;
}

/// Brings a just-moved note's own identity in line with its new filename:
/// `title:` frontmatter becomes `new_title`, and the H1 becomes
/// `# {new_title}` but only when it still reads `# {old_title}` -- an H1
/// that had already diverged from the title before the rename is left
/// alone, not force-rewritten. A note with no frontmatter block at all
/// (`error.NoFrontmatter`) has no `title:` to sync and passes through
/// unchanged on that half. Used by `DiskRenamer`.
pub fn syncTitleAndHeading(gpa: Allocator, body: []const u8, old_title: []const u8, new_title: []const u8) ![]u8 {
    const with_title = core.frontmatter.set(gpa, body, "title", .{ .scalar = new_title }) catch |err| switch (err) {
        error.NoFrontmatter => try gpa.dupe(u8, body),
        else => return err,
    };
    defer gpa.free(with_title);
    return renameHeading(gpa, with_title, old_title, new_title);
}

/// Rewrites the first line reading exactly `# {old_title}` to `# {new_title}`
/// -- the vault-wide "exactly one top-level heading" convention means there
/// is only ever one real candidate, so later lines are never considered even
/// if they happen to match. Every other line is copied through unchanged.
fn renameHeading(gpa: Allocator, body: []const u8, old_title: []const u8, new_title: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    var pos: usize = 0;
    var replaced = false;
    while (pos < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        const line = body[pos..nl];
        if (!replaced and std.mem.startsWith(u8, line, "# ") and std.mem.eql(u8, line[2..], old_title)) {
            try out.appendSlice(gpa, "# ");
            try out.appendSlice(gpa, new_title);
            replaced = true;
        } else {
            try out.appendSlice(gpa, line);
        }
        if (nl < body.len) {
            try out.append(gpa, '\n');
            pos = nl + 1;
        } else {
            pos = body.len;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Every real vault-relative path, `synapse/` excluded -- the candidate
/// universe every wikilink resolves against. Caller-owned.
fn vaultPaths(gpa: Allocator, io: Io, vault: []const u8) ![]const []const u8 {
    const all = try listMarkdownFiles(gpa, io, vault, "");
    defer freeStrings(gpa, all);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    for (all) |p| {
        if (isSynapseNamespace(p)) continue;
        try out.append(gpa, try gpa.dupe(u8, p));
    }
    return out.toOwnedSlice(gpa);
}

/// `titles` maps a case-folded title to every path sharing it (built once
/// by `buildEdges`, below) -- an O(1) lookup instead of a fresh linear scan
/// of every vault path per pending edge, which made `buildEdges` overall
/// O(edges * paths): quadratic in vault size, the one axis that actually
/// broke at scale (unlike a node's own body size, which doesn't).
fn resolveCandidates(
    gpa: Allocator,
    titles: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    target: []const u8,
) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    const normalized = core.wikilinks.normalizeTarget(target);
    const lower = try std.ascii.allocLowerString(gpa, normalized);
    defer gpa.free(lower);
    if (titles.get(lower)) |paths| {
        for (paths.items) |path| try out.append(gpa, try gpa.dupe(u8, path));
    }
    return out.toOwnedSlice(gpa);
}

/// One `[]const u8` slice holding `path`, the shape `resolveCandidates`
/// itself returns for a single hit -- so a target that resolves by id reads
/// exactly like a target that resolved to exactly one name-matched file.
fn singleCandidate(gpa: Allocator, path: []const u8) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, 1);
    out[0] = try gpa.dupe(u8, path);
    return out;
}

const PendingEdge = struct { source: []const u8, target_text: []const u8 };

fn freePending(gpa: Allocator, pending: []const PendingEdge) void {
    for (pending) |p| {
        gpa.free(p.source);
        gpa.free(p.target_text);
    }
}

/// Every wikilink occurrence across the whole vault (`synapse/` excluded),
/// each resolved to its candidate file(s). One full re-scan per call --
/// see `DiskLinkGraph`'s own doc comment on why that's fine at this vault's
/// measured size, and not yet cached.
///
/// Two passes, not one: the first reads every file exactly once, collecting
/// both its outgoing link targets (resolved later) and its own `note_id`/
/// `task_id` if it has one, into an in-memory (never persisted) id -> path
/// map. Resolution only starts once that map is complete, in the second
/// pass -- a target read early in the first pass can still name a note read
/// later in it. A target matching an id resolves straight to that one path,
/// no ambiguity handling needed (ids are unique by construction); a real
/// duplicate id is a pre-existing data problem this doesn't try to detect,
/// so whichever file the first pass reaches first for a given id wins.
/// Everything else falls through to `resolveCandidates`'s case-insensitive
/// title match, against a title -> path(s) map built once from `all` (no
/// read needed, titles come from the path alone) -- the same shape as the
/// id map above, and for the same reason: a fresh linear scan of every
/// vault path per pending edge is what made this function quadratic in
/// vault size, not the id lookup, which was already O(1).
fn buildEdges(gpa: Allocator, io: Io, vault: []const u8) ![]const Edge {
    const all = try vaultPaths(gpa, io, vault);
    defer freeStrings(gpa, all);

    var store = try DiskStore.init(gpa, vault, "");
    defer store.deinit();

    var ids: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = ids.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        ids.deinit(gpa); // values borrow from `all`, not owned here
    }

    // Every path's title, case-folded, built once from `all` alone -- pure
    // path-string work, no read needed -- so `resolveCandidates` below never
    // has to rescan `all` per pending edge.
    var titles: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    defer {
        var it = titles.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit(gpa);
        }
        titles.deinit(gpa); // list entries borrow from `all`, not owned here
    }
    for (all) |path| {
        const lower = try std.ascii.allocLowerString(gpa, titleOf(path));
        const gop = try titles.getOrPut(gpa, lower);
        if (gop.found_existing) {
            gpa.free(lower);
        } else {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(gpa, path);
    }

    var pending: std.ArrayListUnmanaged(PendingEdge) = .empty;
    defer {
        freePending(gpa, pending.items);
        pending.deinit(gpa);
    }

    for (all) |source| {
        const body = (try store.read(gpa, io, source)) orelse continue;
        defer gpa.free(body);

        if (core.query.field(body, "note_id") orelse core.query.field(body, "task_id")) |id| {
            const owned_id = try gpa.dupe(u8, id);
            const gop = try ids.getOrPut(gpa, owned_id);
            if (gop.found_existing) {
                gpa.free(owned_id);
            } else {
                gop.value_ptr.* = source;
            }
        }

        const targets = try core.wikilinks.extract(gpa, body);
        defer freeStrings(gpa, targets);

        for (targets) |t| {
            try pending.append(gpa, .{
                .source = try gpa.dupe(u8, source),
                .target_text = try gpa.dupe(u8, t),
            });
        }
    }

    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    errdefer {
        for (edges.items) |e| {
            gpa.free(e.source);
            gpa.free(e.target_text);
            freeStrings(gpa, e.candidates);
        }
        edges.deinit(gpa);
    }

    for (pending.items) |p| {
        // Normalized once, shared by both lookups below: an id is never
        // written path-qualified or `.md`-suffixed in practice, so this
        // costs nothing there, and closes the same gap for a `[[Foo.md]]`-
        // or path-qualified id reference on the rare chance one exists.
        const normalized = core.wikilinks.normalizeTarget(p.target_text);
        const candidates = if (ids.get(normalized)) |path|
            try singleCandidate(gpa, path)
        else
            try resolveCandidates(gpa, &titles, p.target_text);
        try edges.append(gpa, .{
            .source = try gpa.dupe(u8, p.source),
            .target_text = try gpa.dupe(u8, p.target_text),
            .candidates = candidates,
        });
    }
    return edges.toOwnedSlice(gpa);
}

/// `unresolved`'s own grouping: zero-candidate edges, by target text,
/// counting occurrences and collecting distinct source files. `ambiguous`
/// needs the same shape plus a `candidates` field, so it groups inline
/// instead of sharing this helper.
fn groupByTarget(gpa: Allocator, edges: []const Edge) ![]const LinkGraph.Unresolved {
    var groups: std.StringHashMapUnmanaged(struct {
        count: usize,
        sources: std.ArrayListUnmanaged([]const u8),
    }) = .empty;
    defer {
        var it = groups.valueIterator();
        while (it.next()) |v| v.sources.deinit(gpa);
        groups.deinit(gpa);
    }

    for (edges) |e| {
        if (e.candidates.len != 0) continue;
        const gop = try groups.getOrPut(gpa, e.target_text);
        if (!gop.found_existing) gop.value_ptr.* = .{ .count = 0, .sources = .empty };
        gop.value_ptr.count += 1;
        if (!containsNode(gop.value_ptr.sources.items, e.source)) {
            try gop.value_ptr.sources.append(gpa, e.source);
        }
    }

    var out: std.ArrayListUnmanaged(LinkGraph.Unresolved) = .empty;
    errdefer {
        for (out.items) |item| {
            gpa.free(item.target);
            freeStrings(gpa, item.sources);
        }
        out.deinit(gpa);
    }
    var it = groups.iterator();
    while (it.next()) |entry| {
        try out.append(gpa, .{
            .target = try gpa.dupe(u8, entry.key_ptr.*),
            .count = entry.value_ptr.count,
            .sources = try dupeStrings(gpa, entry.value_ptr.sources.items),
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Every `.md` file anywhere under `{root}/{namespace}` (or `{root}` when
/// `namespace` is empty), recursively -- the real listing implementation
/// behind `DiskStore.list`.
///
/// Names are returned with `/` separators, relative to the listed root --
/// the same shape a namespace-scoped `node` name already has, just now
/// possibly with path segments in it. Any path component starting with `.`
/// (`.git` and the like) is skipped -- tooling directories, never content.
/// A namespace directory that doesn't exist yet lists as empty, not an
/// error, matching `read`'s own "absence is ordinary" rule.
pub fn listMarkdownFiles(gpa: Allocator, io: Io, root: []const u8, namespace: []const u8) anyerror![]const []const u8 {
    const dir_path = if (namespace.len == 0)
        try gpa.dupe(u8, root)
    else
        try std.fs.path.join(gpa, &.{ root, namespace });
    defer gpa.free(dir_path);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }

    var root_dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| {
        if (e == error.FileNotFound) return out.toOwnedSlice(gpa);
        return e;
    };
    defer root_dir.close(io);

    // Selective, not plain `walk`: a dot-directory (`.git`, `.obsidian`) is
    // never entered at all, instead of being fully read and only filtered
    // out afterward -- `.git` alone can be hundreds of subdirectories on a
    // synced vault, all of them wasted work under the old approach.
    var walker = try root_dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.basename.len != 0 and entry.basename[0] == '.') continue;
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
            continue;
        }
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".md"))
            try out.append(gpa, try gpa.dupe(u8, entry.path));
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

fn freeHits(gpa: Allocator, hits: []const Store.Hit) void {
    for (hits) |h| {
        gpa.free(h.node);
        gpa.free(h.context);
    }
    gpa.free(hits);
}

fn vaultRoot(gpa: Allocator, tmp: *testing.TmpDir) ![]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    return std.fmt.allocPrint(gpa, "{s}/vault", .{base});
}

test "write then read round-trips through the port, namespace-scoped" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "Foo.md", "---\ntitle: Foo\n---\nbody\n");
    const got = (try port.read(gpa, testing.io, "Foo.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("---\ntitle: Foo\n---\nbody\n", got);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "vault/synapse/repo@main/Foo.md", gpa, .limited(1 << 20));
    defer gpa.free(on_disk);
    try testing.expectEqualStrings("---\ntitle: Foo\n---\nbody\n", on_disk);
}

test "a write is atomic: no .tmp sibling survives, and an overwrite leaves no partial file" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "Foo.md", "---\ntitle: Foo\n---\nfirst\n");
    _ = try port.write(testing.io, "Foo.md", "---\ntitle: Foo\n---\nsecond\n");

    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(testing.io, "vault/synapse/repo@main/Foo.md.tmp", .{}),
    );
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "vault/synapse/repo@main/Foo.md", gpa, .limited(1 << 20));
    defer gpa.free(on_disk);
    try testing.expectEqualStrings("---\ntitle: Foo\n---\nsecond\n", on_disk);
}

test "an empty namespace addresses a node by its full vault-relative path, unprefixed" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "tasks/synapse/sb-037 — Task.md", "---\ntitle: Task\n---\nbody\n");
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "vault/tasks/synapse/sb-037 — Task.md", gpa, .limited(1 << 20));
    defer gpa.free(on_disk);
    try testing.expectEqualStrings("---\ntitle: Task\n---\nbody\n", on_disk);

    const got = (try port.read(gpa, testing.io, "tasks/synapse/sb-037 — Task.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("---\ntitle: Task\n---\nbody\n", got);
}

test "a node with a .. segment cannot escape the vault, on read or write" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    try testing.expectError(error.UnsafeNodePath, port.write(testing.io, "../../../../etc/passwd", "pwned"));
    try testing.expectError(error.UnsafeNodePath, port.read(gpa, testing.io, "../outside.md"));
    // A `..` buried mid-path, not just a leading one, is caught too.
    try testing.expectError(error.UnsafeNodePath, port.read(gpa, testing.io, "a/../../b.md"));
}

test "an absolute node path is rejected, not treated as vault-relative" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    try testing.expectError(error.UnsafeNodePath, port.write(testing.io, "/etc/passwd", "pwned"));
}

test "a missing node reads as null, not as an error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    try testing.expectEqual(@as(?[]u8, null), try s.store().read(gpa, testing.io, "absent.md"));
}

test "listing a namespace that was never written to is empty, not an error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const names = try s.store().list(gpa, testing.io);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 0), names.len);
}

test "list walks nested subdirectories, not just the top level" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "designs/synapse/sb-001.md", "a\n");
    _ = try port.write(testing.io, "tasks/eon/ecs-001.md", "b\n");

    const names = try port.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 2), names.len);
    var saw_design = false;
    var saw_task = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "designs/synapse/sb-001.md")) saw_design = true;
        if (std.mem.eql(u8, n, "tasks/eon/ecs-001.md")) saw_task = true;
    }
    try testing.expect(saw_design);
    try testing.expect(saw_task);
}

test "list skips dot-prefixed directories like .git" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "designs/x.md", "real content\n");
    _ = try port.write(testing.io, ".config/plugins/foo/data.md", "not vault content\n");

    const names = try port.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("designs/x.md", names[0]);
}

test "rewriting a node replaces it, and list reflects exactly what was written" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "n.md", "first");
    _ = try port.write(testing.io, "n.md", "second");

    const body = (try port.read(gpa, testing.io, "n.md")).?;
    defer gpa.free(body);
    try testing.expectEqualStrings("second", body);

    const names = try port.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("n.md", names[0]);
}

test "list only sees .md files, not other files someone dropped in the directory" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "a.md", "a");
    _ = try port.write(testing.io, "notes.txt", "not a node");

    const names = try port.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("a.md", names[0]);
}

test "full-text search finds a substring by content, case-insensitive" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "a.md", "---\ntitle: A\n---\nmentions the widget factory\n");
    _ = try port.write(testing.io, "b.md", "---\ntitle: B\n---\nmentions nothing relevant\n");

    const hits = try port.search(gpa, testing.io, "widget factory");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("a.md", hits[0].node);
}

test "search ignores frontmatter content, including a query term that only appears there" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    // "widget" only appears inside a.md's frontmatter (a source path) --
    // a code-graph node's own `sources:` block is the real-world shape this
    // guards against. b.md has it in actual prose.
    _ = try port.write(testing.io, "a.md", "---\ntitle: A\nsources:\n  - path: src/widget.zig\n    hash: deadbeef\n---\nunrelated prose\n");
    _ = try port.write(testing.io, "b.md", "---\ntitle: B\n---\nmentions widget directly\n");

    const hits = try port.search(gpa, testing.io, "widget");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("b.md", hits[0].node);
}

test "searchFiltered excludes a candidate that fails the path filter, no matter what its content says" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "designs/x.md", "widget prose here\n");
    _ = try port.write(testing.io, "tasks/y.md", "widget prose here too\n");

    var filter = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"glob": ["designs/*", {"var": "path"}]}
    , .{});
    defer filter.deinit();

    const hits = try s.searchFiltered(gpa, testing.io, "widget", filter.value);
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("designs/x.md", hits[0].node);
}

test "searchFiltered with a null filter behaves exactly like search" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "a.md", "widget prose\n");
    _ = try port.write(testing.io, "b.md", "unrelated\n");

    const via_search = try port.search(gpa, testing.io, "widget");
    defer freeHits(gpa, via_search);
    const via_filtered = try s.searchFiltered(gpa, testing.io, "widget", null);
    defer freeHits(gpa, via_filtered);

    try testing.expectEqual(via_search.len, via_filtered.len);
    try testing.expectEqualStrings(via_search[0].node, via_filtered[0].node);
}

test "the substring fallback also ignores frontmatter content" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    // An all-digit query survives tokenization as zero terms, so this
    // exercises `searchSubstring` specifically, not the ranked path above.
    _ = try port.write(testing.io, "a.md", "---\ntitle: A\nsources:\n  - path: src/x.zig\n    hash: 42424242\n---\nno digits here\n");

    const hits = try port.search(gpa, testing.io, "42424242");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "a query matching nothing returns an empty slice, not an error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "a.md", "nothing matches this");
    const hits = try port.search(gpa, testing.io, "gadget");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "search ranks a document matching a rare word above one matching only a common word" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();

    // "widget" appears in exactly one note; "common" appears in all four --
    // a query mentioning both should rank the widget note first even though
    // neither note repeats its own matching word more than the other.
    _ = try port.write(testing.io, "rare.md", "common widget\n");
    _ = try port.write(testing.io, "other1.md", "common\n");
    _ = try port.write(testing.io, "other2.md", "common\n");
    _ = try port.write(testing.io, "other3.md", "common\n");

    const hits = try port.search(gpa, testing.io, "widget common");
    defer freeHits(gpa, hits);
    try testing.expect(hits.len >= 1);
    try testing.expectEqualStrings("rare.md", hits[0].node);
    if (hits.len > 1) try testing.expect(hits[0].score > hits[1].score);
}

test "search sorts results by score, highest first" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "one-hit.md", "widget\n");
    _ = try port.write(testing.io, "two-hits.md", "widget widget\n");

    const hits = try port.search(gpa, testing.io, "widget");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqualStrings("two-hits.md", hits[0].node);
    try testing.expect(hits[0].score >= hits[1].score);
}

test "a query of only short/all-digit words falls back to a plain substring match" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "a.md", "the id 42 record\n");
    // Neither query word is >= 4 chars and not all-digits, so
    // tokenizeQuery yields nothing and search falls back to a literal
    // substring count of the whole query -- which needs "id 42" to appear
    // contiguously, unlike a real per-word match would.
    const hits = try port.search(gpa, testing.io, "id 42");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("a.md", hits[0].node);
}

test "search resolves DiskStore-style identifiers and prose spelling of the same words alike" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "a.md", "the disk store handles this\n");
    const hits = try port.search(gpa, testing.io, "DiskStore");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("a.md", hits[0].node);
}

// `Store.from(DiskStore, self)` needs all four methods to exist on the type
// to compile -- but only the moment something actually calls `.store()`.
// This test is that reference, exercised end to end.
test "DiskStore.store() compiles, and every op round-trips" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    var store = s.store();

    const wr = try store.write(testing.io, "Foo.md", "body\n");
    try testing.expect(wr.accepted);
    const got = (try store.read(gpa, testing.io, "Foo.md")).?;
    defer gpa.free(got);
    const names = try store.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    const hits = try store.search(gpa, testing.io, "body");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
}

fn freeAmbiguous(gpa: Allocator, rows: []const LinkGraph.Ambiguous) void {
    for (rows) |r| {
        gpa.free(r.target);
        freeStrings(gpa, r.candidates);
        freeStrings(gpa, r.sources);
    }
    gpa.free(rows);
}

fn freeUnresolved(gpa: Allocator, rows: []const LinkGraph.Unresolved) void {
    for (rows) |r| {
        gpa.free(r.target);
        freeStrings(gpa, r.sources);
    }
    gpa.free(rows);
}

fn freeBacklinks(gpa: Allocator, rows: []const LinkGraph.Backlink) void {
    for (rows) |r| gpa.free(r.node);
    gpa.free(rows);
}

test "DiskLinkGraph.links resolves a bare wikilink to the real file, unambiguous" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "designs/A.md", "links to [[B]]\n");
    _ = try port.write(testing.io, "designs/B.md", "target\n");

    var lg = s.linkGraph();
    const links_out = try lg.links(gpa, testing.io, "designs/A.md");
    defer freeStrings(gpa, links_out);
    try testing.expectEqual(@as(usize, 1), links_out.len);
    try testing.expectEqualStrings("designs/B.md", links_out[0]);
}

test "DiskLinkGraph.backlinks counts how many times the source links to the target" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "A.md", "[[B]] and [[B]] again\n");
    _ = try port.write(testing.io, "B.md", "target\n");

    var lg = s.linkGraph();
    const bl = try lg.backlinks(gpa, testing.io, "B.md");
    defer freeBacklinks(gpa, bl);
    try testing.expectEqual(@as(usize, 1), bl.len);
    try testing.expectEqualStrings("A.md", bl[0].node);
    try testing.expectEqual(@as(usize, 2), bl[0].count);
}

test "resolution is case-insensitive: [[b]] finds B.md" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "A.md", "[[b]]\n");
    _ = try port.write(testing.io, "B.md", "target\n");

    var lg = s.linkGraph();
    const links_out = try lg.links(gpa, testing.io, "A.md");
    defer freeStrings(gpa, links_out);
    try testing.expectEqual(@as(usize, 1), links_out.len);
    try testing.expectEqualStrings("B.md", links_out[0]);
}

test "resolution strips a .md suffix and a leading path: [[dir/B.md]] finds B.md" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "A.md", "[[B.md]]\n");
    _ = try port.write(testing.io, "C.md", "[[dir/B.md]]\n");
    _ = try port.write(testing.io, "B.md", "target\n");

    var lg = s.linkGraph();
    const a_links = try lg.links(gpa, testing.io, "A.md");
    defer freeStrings(gpa, a_links);
    try testing.expectEqual(@as(usize, 1), a_links.len);
    try testing.expectEqualStrings("B.md", a_links[0]);

    const c_links = try lg.links(gpa, testing.io, "C.md");
    defer freeStrings(gpa, c_links);
    try testing.expectEqual(@as(usize, 1), c_links.len);
    try testing.expectEqualStrings("B.md", c_links[0]);
}

test "a link matching no real file is unresolved, not silently dropped" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "A.md", "[[Nowhere]]\n");

    var lg = s.linkGraph();
    const un = try lg.unresolved(gpa, testing.io);
    defer freeUnresolved(gpa, un);
    try testing.expectEqual(@as(usize, 1), un.len);
    try testing.expectEqualStrings("Nowhere", un[0].target);
    try testing.expectEqual(@as(usize, 1), un[0].count);
    try testing.expectEqual(@as(usize, 1), un[0].sources.len);
    try testing.expectEqualStrings("A.md", un[0].sources[0]);

    const amb = try lg.ambiguous(gpa, testing.io);
    defer freeAmbiguous(gpa, amb);
    try testing.expectEqual(@as(usize, 0), amb.len);
}

test "a link matching two real files is ambiguous: both count as backlinks, and it's reported, not dropped or guessed" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "source.md", "[[Duplicate]]\n");
    _ = try port.write(testing.io, "designs/Duplicate.md", "one\n");
    _ = try port.write(testing.io, "research/Duplicate.md", "two\n");

    var lg = s.linkGraph();

    // Both real files see the ambiguous link as a backlink -- an ambiguous
    // edge is never silently dropped or resolved to just one candidate.
    const bl_design = try lg.backlinks(gpa, testing.io, "designs/Duplicate.md");
    defer freeBacklinks(gpa, bl_design);
    try testing.expectEqual(@as(usize, 1), bl_design.len);
    try testing.expectEqualStrings("source.md", bl_design[0].node);

    const bl_research = try lg.backlinks(gpa, testing.io, "research/Duplicate.md");
    defer freeBacklinks(gpa, bl_research);
    try testing.expectEqual(@as(usize, 1), bl_research.len);

    // Not reported as unresolved -- it has real candidates, just too many.
    const un = try lg.unresolved(gpa, testing.io);
    defer freeUnresolved(gpa, un);
    try testing.expectEqual(@as(usize, 0), un.len);

    const amb = try lg.ambiguous(gpa, testing.io);
    defer freeAmbiguous(gpa, amb);
    try testing.expectEqual(@as(usize, 1), amb.len);
    try testing.expectEqualStrings("Duplicate", amb[0].target);
    try testing.expectEqual(@as(usize, 2), amb[0].candidates.len);
    try testing.expectEqual(@as(usize, 1), amb[0].count);
    try testing.expectEqual(@as(usize, 1), amb[0].sources.len);
    try testing.expectEqualStrings("source.md", amb[0].sources[0]);
}

test "a link matching a note_id resolves straight to that file, bypassing name matching entirely" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "source.md", "[[wg-001|Widget design]]\n");
    _ = try port.write(testing.io, "designs/Widget design.md", "---\nnote_id: wg-001\n---\ntarget\n");

    var lg = s.linkGraph();
    const links_out = try lg.links(gpa, testing.io, "source.md");
    defer freeStrings(gpa, links_out);
    try testing.expectEqual(@as(usize, 1), links_out.len);
    try testing.expectEqualStrings("designs/Widget design.md", links_out[0]);
}

test "an id-matched link stays unambiguous even when its own display text also matches another file's title" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "source.md", "[[wg-001]]\n");
    _ = try port.write(testing.io, "designs/Real.md", "---\nnote_id: wg-001\n---\none\n");
    _ = try port.write(testing.io, "research/wg-001.md", "a decoy file that just happens to be titled the same as the id\n");

    var lg = s.linkGraph();
    const links_out = try lg.links(gpa, testing.io, "source.md");
    defer freeStrings(gpa, links_out);
    try testing.expectEqual(@as(usize, 1), links_out.len);
    try testing.expectEqualStrings("designs/Real.md", links_out[0]);

    const amb = try lg.ambiguous(gpa, testing.io);
    defer freeAmbiguous(gpa, amb);
    try testing.expectEqual(@as(usize, 0), amb.len);
}

test "task_id resolves a link the same way note_id does" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "source.md", "[[sb-047|the task]]\n");
    _ = try port.write(testing.io, "tasks/synapse/sb-047 — Something.md", "---\ntask_id: sb-047\n---\nchecklist\n");

    var lg = s.linkGraph();
    const links_out = try lg.links(gpa, testing.io, "source.md");
    defer freeStrings(gpa, links_out);
    try testing.expectEqual(@as(usize, 1), links_out.len);
    try testing.expectEqualStrings("tasks/synapse/sb-047 — Something.md", links_out[0]);
}

test "with no id match, resolution falls back unchanged to name matching" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "source.md", "[[Plain Title]]\n");
    _ = try port.write(testing.io, "designs/Plain Title.md", "---\nnote_id: wg-002\n---\nno id in the link, so this still resolves by name\n");

    var lg = s.linkGraph();
    const links_out = try lg.links(gpa, testing.io, "source.md");
    defer freeStrings(gpa, links_out);
    try testing.expectEqual(@as(usize, 1), links_out.len);
    try testing.expectEqualStrings("designs/Plain Title.md", links_out[0]);
}

test "orphans lists a real file no other note links to" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "A.md", "[[B]]\n");
    _ = try port.write(testing.io, "B.md", "target\n");
    _ = try port.write(testing.io, "Lonely.md", "no one links here\n");

    var lg = s.linkGraph();
    const orph = try lg.orphans(gpa, testing.io);
    defer freeStrings(gpa, orph);
    try testing.expectEqual(@as(usize, 2), orph.len);
    var saw_lonely = false;
    var saw_a = false;
    for (orph) |n| {
        if (std.mem.eql(u8, n, "Lonely.md")) saw_lonely = true;
        if (std.mem.eql(u8, n, "A.md")) saw_a = true;
    }
    try testing.expect(saw_lonely);
    try testing.expect(saw_a); // nothing links to A.md either
}

test "deadends lists a real file with no resolved outgoing link, including one whose only link is unresolved" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "A.md", "[[B]]\n");
    _ = try port.write(testing.io, "B.md", "no outgoing links\n");
    _ = try port.write(testing.io, "BrokenLink.md", "[[Nowhere]]\n");

    var lg = s.linkGraph();
    const de = try lg.deadends(gpa, testing.io);
    defer freeStrings(gpa, de);
    try testing.expectEqual(@as(usize, 2), de.len);
    var saw_b = false;
    var saw_broken = false;
    for (de) |n| {
        if (std.mem.eql(u8, n, "B.md")) saw_b = true;
        if (std.mem.eql(u8, n, "BrokenLink.md")) saw_broken = true;
    }
    try testing.expect(saw_b);
    try testing.expect(saw_broken);
}

test "synapse/{repo}@{branch} is never indexed: excluded from candidates, sources, orphans, and deadends alike" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    // A real vault note happens to share a title with a code-graph node --
    // the wikilink must resolve to the vault note only, never the
    // synapse/-namespaced one, and the code node itself must never appear
    // in orphans/deadends either.
    _ = try port.write(testing.io, "designs/Shared.md", "the real vault note\n");
    _ = try port.write(testing.io, "synapse/repo@main/Shared.md", "a code-graph node\n");
    _ = try port.write(testing.io, "synapse/repo@main/Other.md", "[[designs/Shared.md's title won't matter]]\n");
    _ = try port.write(testing.io, "linker.md", "[[Shared]]\n");

    var lg = s.linkGraph();
    const links_out = try lg.links(gpa, testing.io, "linker.md");
    defer freeStrings(gpa, links_out);
    try testing.expectEqual(@as(usize, 1), links_out.len);
    try testing.expectEqualStrings("designs/Shared.md", links_out[0]);

    const orph = try lg.orphans(gpa, testing.io);
    defer freeStrings(gpa, orph);
    for (orph) |n| try testing.expect(!std.mem.startsWith(u8, n, "synapse/"));

    const de = try lg.deadends(gpa, testing.io);
    defer freeStrings(gpa, de);
    for (de) |n| try testing.expect(!std.mem.startsWith(u8, n, "synapse/"));
}

test "rename moves the note to its new filename and removes the old one" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "Old.md", "body\n");

    const rn = s.renamer();
    try rn.rename(gpa, testing.io, "Old.md", "New.md");

    try testing.expectEqual(@as(?[]u8, null), try port.read(gpa, testing.io, "Old.md"));
    const got = (try port.read(gpa, testing.io, "New.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("body\n", got);
}

test "renaming a note to a path that resolves to the same file leaves it intact" {
    // The general form of the case-insensitive-filesystem collision
    // (`Foo.md` -> `foo.md` writing and deleting the same inode on APFS/
    // NTFS): old_path and new_path address the same underlying file. CI
    // runs on case-sensitive ext4, so an actual differing-case collision
    // can't be reproduced portably here -- the identical-path case forces
    // the same condition (same inode) on every filesystem, exercising the
    // same `sameFile` guard deterministically. Before that guard existed,
    // this sequence unconditionally deleted the file it had just written.
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "Same.md", "body\n");

    const rn = s.renamer();
    try rn.rename(gpa, testing.io, "Same.md", "Same.md");

    const got = (try port.read(gpa, testing.io, "Same.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("body\n", got);
}

test "rename rewrites every referring wikilink to the new title, preserving alias display text" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "Old.md", "target body\n");
    _ = try port.write(testing.io, "A.md", "see [[Old]] for details\n");
    _ = try port.write(testing.io, "B.md", "see [[Old|a nicer label]] for details\n");
    _ = try port.write(testing.io, "Unrelated.md", "no link here\n");

    const rn = s.renamer();
    try rn.rename(gpa, testing.io, "Old.md", "New.md");

    const a = (try port.read(gpa, testing.io, "A.md")).?;
    defer gpa.free(a);
    try testing.expectEqualStrings("see [[New]] for details\n", a);

    const b = (try port.read(gpa, testing.io, "B.md")).?;
    defer gpa.free(b);
    try testing.expectEqualStrings("see [[New|a nicer label]] for details\n", b);

    const unrelated = (try port.read(gpa, testing.io, "Unrelated.md")).?;
    defer gpa.free(unrelated);
    try testing.expectEqualStrings("no link here\n", unrelated);
}

test "rename rewrites a .md-suffixed and a path-qualified referring wikilink too" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "Old.md", "target body\n");
    _ = try port.write(testing.io, "A.md", "see [[Old.md]] for details\n");
    _ = try port.write(testing.io, "B.md", "see [[dir/Old.md]] for details\n");

    const rn = s.renamer();
    try rn.rename(gpa, testing.io, "Old.md", "New.md");

    const a = (try port.read(gpa, testing.io, "A.md")).?;
    defer gpa.free(a);
    try testing.expectEqualStrings("see [[New]] for details\n", a);

    const b = (try port.read(gpa, testing.io, "B.md")).?;
    defer gpa.free(b);
    try testing.expectEqualStrings("see [[New]] for details\n", b);
}

test "renaming a note with no referrers just moves the file" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "Lonely.md", "body\n");

    const rn = s.renamer();
    try rn.rename(gpa, testing.io, "Lonely.md", "StillLonely.md");

    const got = (try port.read(gpa, testing.io, "StillLonely.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("body\n", got);
}

test "renaming a note that doesn't exist fails clearly, and touches nothing" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();

    const rn = s.renamer();
    try testing.expectError(error.NodeNotFound, rn.rename(gpa, testing.io, "Nope.md", "New.md"));
    try testing.expectEqual(@as(?[]u8, null), try port.read(gpa, testing.io, "New.md"));
}

test "rename syncs the moved note's own title: frontmatter and H1 to the new filename" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "Old.md", "---\ntitle: \"Old\"\n---\n\n# Old\n\nbody\n");

    const rn = s.renamer();
    try rn.rename(gpa, testing.io, "Old.md", "New.md");

    const got = (try port.read(gpa, testing.io, "New.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("---\ntitle: New\n---\n\n# New\n\nbody\n", got);
}

test "rename leaves an H1 that already diverged from the old title alone" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "Old.md", "---\ntitle: \"Old\"\n---\n\n# Something else entirely\n\nbody\n");

    const rn = s.renamer();
    try rn.rename(gpa, testing.io, "Old.md", "New.md");

    const got = (try port.read(gpa, testing.io, "New.md")).?;
    defer gpa.free(got);
    // title: still syncs -- only the H1 rewrite is guarded.
    try testing.expectEqualStrings("---\ntitle: New\n---\n\n# Something else entirely\n\nbody\n", got);
}

test "renaming a note with no frontmatter at all leaves its body untouched" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "Old.md", "# Old\n\nbody\n");

    const rn = s.renamer();
    try rn.rename(gpa, testing.io, "Old.md", "New.md");

    const got = (try port.read(gpa, testing.io, "New.md")).?;
    defer gpa.free(got);
    // No frontmatter block to sync a `title:` into, but the H1 sync is a
    // pure text rule with no such dependency, so it still fires.
    try testing.expectEqualStrings("# New\n\nbody\n", got);
}

test "a self-referencing note's own self-link is renamed too, not left pointing at the old title" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "Old.md", "see also [[Old]] itself\n");

    const rn = s.renamer();
    try rn.rename(gpa, testing.io, "Old.md", "New.md");

    const got = (try port.read(gpa, testing.io, "New.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("see also [[New]] itself\n", got);
}
