//! The node-to-node link graph, computed before any prose exists.
//!
//! A node's `## Links` section is typed relations, not prose. Two of the
//! three types are reference relations the Code Cache already holds, and
//! node titles exist before any prose is written, so the join needs no
//! summary first: `_refs.tsv` gives `name -> def|ref -> path:line`, a
//! path-to-node map gives `path -> node`, and a `ref` in one node's file
//! naming a `def` in another is an edge. `part_of` stays a human judgement
//! -- containment isn't in `_refs.tsv` at all.
//!
//! ## Rarity, counted not summed
//!
//! A symbol referenced from few nodes is informative; one referenced from
//! thirty says nothing about either end of the edge. `rare_max = max(2,
//! N/20)` -- same formula `core/gate.zig` uses for words, `N` = node count.
//! An edge's weight is how many *distinct rare symbols* support it, not a
//! sum of inverse document frequencies -- what separates a real concept
//! from a generic one is whether it has distinctive vocabulary at all, not
//! how much (same reasoning as `core/gate.zig`'s own tf-idf-sum failure).
//!
//! ## A symbol defined in more than one node is not rare, it is ambiguous
//!
//! Joining by bare name (`_refs.tsv` carries no receiver or type) would fan
//! an edge from every reader of a common name (`run`, `open`, `close`) to
//! every node that defines it, most pointing at the wrong one. A name with
//! exactly one definer is unambiguous by construction; a name defined more
//! than once contributes no edges at all -- the false edges a wrong guess
//! would add cost more than the true edges a right guess would keep.
//!
//! `resolveAmbiguous` recovers some of what that drop costs, for the one
//! case with a real signal beyond bare name/path: a reference whose own
//! file declares a dependency on exactly one candidate definition's own
//! library. Still a heuristic over syntax, not real semantic analysis --
//! narrows the candidate set, never guarantees correctness -- so a name
//! that stays genuinely ambiguous even after checking dependency edges is
//! left alone exactly like `compute`'s own drop.

const std = @import("std");
const refs = @import("refs.zig");
const rarity = @import("rarity.zig");

const Allocator = std.mem.Allocator;

/// One candidate edge: `from` references something `to` defines, by way of
/// `symbols`, all of which cleared the rarity bar. `weight` is
/// `symbols.len` before `symbols_shown` truncates the *list shown* --
/// capped for readability, the weight isn't.
pub const Edge = struct {
    /// `from`/`to` are node titles borrowed from `path_to_nodes`, valid as
    /// long as the caller keeps it alive. `symbols` entries borrow
    /// `refs_table` the same way; the `symbols` array itself is owned by
    /// this result, freed by `free`.
    from: []const u8,
    to: []const u8,
    weight: usize,
    symbols: []const []const u8,
};

pub const Options = struct {
    /// Edges kept per `from` node, strongest first. `0` means no cap.
    top: usize = 8,
    /// Symbol names shown per edge, most first (sorted alphabetically among
    /// equals, since none of them outranks another once both are rare).
    /// `0` means no cap.
    symbols_shown: usize = 5,
};

/// Walks `refs_table` (`compute` and `resolveAmbiguous` both take one),
/// parsing each row, keeping only `def`/`ref`, cutting `site` at its last
/// `:` for the bare `path`, and looking that path up in `path_to_nodes` --
/// a row whose path claims no node contributes nothing. `visit` runs once
/// per surviving row; the two callers diverge only in what they do with
/// `(name, is_def, path, owners)` from there.
fn forEachOwnedRow(
    refs_table: []const u8,
    path_to_nodes: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    context: anytype,
    comptime visit: fn (@TypeOf(context), name: []const u8, is_def: bool, path: []const u8, owners: []const []const u8) anyerror!void,
) !void {
    var lines = std.mem.splitScalar(u8, refs_table, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const row = refs.parseRow(line) orelse continue;
        const is_def = std.mem.eql(u8, row.dir, "def");
        const is_ref = std.mem.eql(u8, row.dir, "ref");
        if (!is_def and !is_ref) continue;

        const colon = std.mem.lastIndexOfScalar(u8, row.site, ':') orelse row.site.len;
        const path = row.site[0..colon];
        const owners = path_to_nodes.get(path) orelse continue;
        if (owners.items.len == 0) continue;

        try visit(context, row.name, is_def, path, owners.items);
    }
}

/// Joins `refs_table` against `path_to_nodes` (path -> claiming node
/// titles, multi-valued) and returns every node's strongest outgoing
/// edges: `from` ascending, `weight` descending, `to` ascending -- a total
/// order, so two runs over an unchanged repo are byte-identical.
///
/// `node_count` is `N` in the rarity formula: every node in the manifest,
/// not just ones appearing in `path_to_nodes`.
pub fn compute(
    gpa: Allocator,
    refs_table: []const u8,
    path_to_nodes: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    node_count: usize,
    opts: Options,
) !std.ArrayListUnmanaged(Edge) {
    const Sets = struct {
        def: std.StringHashMapUnmanaged(void) = .empty,
        ref: std.StringHashMapUnmanaged(void) = .empty,

        fn deinit(self: *@This(), g: Allocator) void {
            self.def.deinit(g);
            self.ref.deinit(g);
        }
    };
    var by_name: std.StringHashMapUnmanaged(Sets) = .empty;
    defer {
        var it = by_name.valueIterator();
        while (it.next()) |s| s.deinit(gpa);
        by_name.deinit(gpa);
    }

    const Ctx = struct { gpa: Allocator, by_name: *std.StringHashMapUnmanaged(Sets) };
    try forEachOwnedRow(refs_table, path_to_nodes, Ctx{ .gpa = gpa, .by_name = &by_name }, struct {
        fn visit(ctx: Ctx, name: []const u8, is_def: bool, _: []const u8, owners: []const []const u8) !void {
            const slot = try ctx.by_name.getOrPut(ctx.gpa, name);
            if (!slot.found_existing) slot.value_ptr.* = .{};
            const set = if (is_def) &slot.value_ptr.def else &slot.value_ptr.ref;
            for (owners) |node| try set.put(ctx.gpa, node, {});
        }
    }.visit);

    const rare_max = @max(@as(usize, 2), node_count / rarity.divisor); // same floor/ratio as core/gate.zig, shared via core.rarity

    // from -> to -> the rare symbols supporting that edge. Nested rather
    // than a joined "from\x00to" key: a joined key would need its own
    // allocation, while these keys are the exact node-title slices
    // `path_to_nodes` already owns -- nothing here to free or dangle.
    var pairs: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8))) = .empty;
    defer {
        var outer = pairs.valueIterator();
        while (outer.next()) |inner| {
            var it = inner.valueIterator();
            while (it.next()) |v| v.deinit(gpa);
            inner.deinit(gpa);
        }
        pairs.deinit(gpa);
    }

    var name_it = by_name.iterator();
    while (name_it.next()) |entry| {
        const sets = entry.value_ptr;
        // Rarity is about who reads it, not who declares it.
        if (sets.ref.count() == 0 or sets.ref.count() > rare_max) continue;
        if (sets.def.count() != 1) continue; // exactly one definer -- see module docstring

        var ref_it = sets.ref.keyIterator();
        while (ref_it.next()) |from_node| {
            var def_it = sets.def.keyIterator();
            while (def_it.next()) |to_node| {
                if (std.mem.eql(u8, from_node.*, to_node.*)) continue;
                const outer = try pairs.getOrPut(gpa, from_node.*);
                if (!outer.found_existing) outer.value_ptr.* = .empty;
                const inner = try outer.value_ptr.getOrPut(gpa, to_node.*);
                if (!inner.found_existing) inner.value_ptr.* = .empty;
                try inner.value_ptr.append(gpa, entry.key_ptr.*);
            }
        }
    }

    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    errdefer edges.deinit(gpa);
    var outer_it = pairs.iterator();
    while (outer_it.next()) |oe| {
        const from = oe.key_ptr.*;
        var inner_it = oe.value_ptr.iterator();
        while (inner_it.next()) |ie| {
            const to = ie.key_ptr.*;
            std.mem.sort([]const u8, ie.value_ptr.items, {}, lessByBytes);
            const weight = ie.value_ptr.items.len;
            const shown = if (opts.symbols_shown == 0) weight else @min(opts.symbols_shown, weight);
            try edges.append(gpa, .{
                .from = from,
                .to = to,
                .weight = weight,
                .symbols = try gpa.dupe([]const u8, ie.value_ptr.items[0..shown]),
            });
        }
    }

    std.mem.sort(Edge, edges.items, {}, lessByRank);

    if (opts.top != 0) capPerNode(gpa, &edges, opts.top);
    return edges;
}

/// Recovers an edge for a name `compute` had to drop for being defined by
/// more than one node, consuming two per-file facts `compute` itself never
/// touches: each candidate definition's own declared identities
/// (`path_to_namespace`, from `synapse-namespace-rules.conf` via
/// `core.namespace.computePerFile` -- a set, not a single string, since a
/// rule's aliases can give one file more than one valid self-reference)
/// and each referencing file's own declared dependencies (`path_to_deps`,
/// from `synapse-dependency-rules.conf` via `core.deps.compute`). A
/// reference in file A resolves to a candidate definition in file D only
/// when exactly one of D's declared identities appears in A's dependency
/// set -- more than one qualifying candidate is still genuinely ambiguous,
/// left alone exactly like `compute`'s own drop. Real signal, not a
/// guarantee: a file can declare a dependency it never actually uses for
/// this specific symbol.
///
/// A reference whose own node *also* defines the name is never resolved to
/// a different node, no matter what its file declares depending on --
/// lexical scoping makes the same-node definition the true answer almost
/// always, so a cross-node resolution here would risk exactly the
/// misattribution this mechanism exists to avoid. Left ambiguous, not
/// attempted.
///
/// Same `Edge` shape as `compute`'s own output, sorted and (if `opts.top
/// != 0`) capped the same way -- concatenate the two results with
/// `mergeEdges` rather than treating this as a second, parallel graph.
pub fn resolveAmbiguous(
    gpa: Allocator,
    refs_table: []const u8,
    path_to_nodes: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    path_to_namespace: *const std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)),
    path_to_deps: *const std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)),
    opts: Options,
) !std.ArrayListUnmanaged(Edge) {
    const Occ = struct { path: []const u8, node: []const u8 };
    const Occs = struct {
        defs: std.ArrayListUnmanaged(Occ) = .empty,
        refs: std.ArrayListUnmanaged(Occ) = .empty,

        fn deinit(self: *@This(), g: Allocator) void {
            self.defs.deinit(g);
            self.refs.deinit(g);
        }
    };
    var by_name: std.StringHashMapUnmanaged(Occs) = .empty;
    defer {
        var it = by_name.valueIterator();
        while (it.next()) |o| o.deinit(gpa);
        by_name.deinit(gpa);
    }

    const Ctx = struct { gpa: Allocator, by_name: *std.StringHashMapUnmanaged(Occs) };
    try forEachOwnedRow(refs_table, path_to_nodes, Ctx{ .gpa = gpa, .by_name = &by_name }, struct {
        fn visit(ctx: Ctx, name: []const u8, is_def: bool, path: []const u8, owners: []const []const u8) !void {
            const slot = try ctx.by_name.getOrPut(ctx.gpa, name);
            if (!slot.found_existing) slot.value_ptr.* = .{};
            const list = if (is_def) &slot.value_ptr.defs else &slot.value_ptr.refs;
            for (owners) |node| try list.append(ctx.gpa, .{ .path = path, .node = node });
        }
    }.visit);

    // from -> to -> the resolved symbols supporting that edge, deduped by
    // name -- same nesting `compute`'s own `pairs` uses, for the same
    // reason (each key already owned elsewhere, nothing here to leak).
    var pairs: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void))) = .empty;
    defer {
        var outer = pairs.valueIterator();
        while (outer.next()) |inner| {
            var it = inner.valueIterator();
            while (it.next()) |v| v.deinit(gpa);
            inner.deinit(gpa);
        }
        pairs.deinit(gpa);
    }

    var name_it = by_name.iterator();
    while (name_it.next()) |entry| {
        const occs = entry.value_ptr;
        if (occs.defs.items.len == 0 or occs.refs.items.len == 0) continue;

        // Distinct definer nodes -- the exact condition `compute` drops on.
        // A name with exactly one definer node is `compute`'s job, not
        // this one's, even if it has several defining files in that node.
        var def_nodes: std.StringHashMapUnmanaged(void) = .empty;
        defer def_nodes.deinit(gpa);
        for (occs.defs.items) |d| try def_nodes.put(gpa, d.node, {});
        if (def_nodes.count() <= 1) continue;

        for (occs.refs.items) |r| {
            // A same-node definition already exists for this name -- lexical
            // scoping makes that the true answer almost always, so resolving
            // to a *different* node here would risk exactly the kind of
            // misattribution this mechanism exists to avoid. Left ambiguous,
            // not attempted, regardless of what `r`'s own file depends on.
            var same_node = false;
            for (occs.defs.items) |d| {
                if (std.mem.eql(u8, r.node, d.node)) {
                    same_node = true;
                    break;
                }
            }
            if (same_node) continue;

            const deps = path_to_deps.get(r.path) orelse continue;

            var resolved_node: ?[]const u8 = null;
            var ambiguous_here = false;
            for (occs.defs.items) |d| {
                const identities = path_to_namespace.get(d.path) orelse continue;
                var qualifies = false;
                var id_it = identities.keyIterator();
                while (id_it.next()) |lib| {
                    if (deps.contains(lib.*)) {
                        qualifies = true;
                        break;
                    }
                }
                if (!qualifies) continue;
                if (resolved_node) |already| {
                    if (!std.mem.eql(u8, already, d.node)) ambiguous_here = true;
                    continue;
                }
                resolved_node = d.node;
            }
            if (ambiguous_here) continue;
            const to_node = resolved_node orelse continue;

            const outer = try pairs.getOrPut(gpa, r.node);
            if (!outer.found_existing) outer.value_ptr.* = .empty;
            const inner = try outer.value_ptr.getOrPut(gpa, to_node);
            if (!inner.found_existing) inner.value_ptr.* = .empty;
            try inner.value_ptr.put(gpa, entry.key_ptr.*, {});
        }
    }

    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    errdefer free(gpa, &edges);
    var outer_it = pairs.iterator();
    while (outer_it.next()) |oe| {
        const from = oe.key_ptr.*;
        var inner_it = oe.value_ptr.iterator();
        while (inner_it.next()) |ie| {
            const to = ie.key_ptr.*;
            var symbols = try gpa.alloc([]const u8, ie.value_ptr.count());
            defer gpa.free(symbols);
            var si: usize = 0;
            var sym_it = ie.value_ptr.keyIterator();
            while (sym_it.next()) |s| : (si += 1) symbols[si] = s.*;
            std.mem.sort([]const u8, symbols, {}, lessByBytes);

            const weight = symbols.len;
            const shown = if (opts.symbols_shown == 0) weight else @min(opts.symbols_shown, weight);
            try edges.append(gpa, .{
                .from = from,
                .to = to,
                .weight = weight,
                .symbols = try gpa.dupe([]const u8, symbols[0..shown]),
            });
        }
    }

    std.mem.sort(Edge, edges.items, {}, lessByRank);
    if (opts.top != 0) capPerNode(gpa, &edges, opts.top);
    return edges;
}

/// Concatenates `extra`'s edges into `edges` -- ownership of each edge's
/// `symbols` slice transfers, so `extra`'s own list is cleared, not freed
/// with `free` (that would double-free what `edges` now owns) -- then
/// re-sorts and (if `top != 0`) re-caps the combined set the same way
/// `compute` orders its own output. The join point for `resolveAmbiguous`'s
/// recovered edges: a caller treats the result as one graph, never two.
pub fn mergeEdges(gpa: Allocator, edges: *std.ArrayListUnmanaged(Edge), extra: *std.ArrayListUnmanaged(Edge), top: usize) !void {
    try edges.appendSlice(gpa, extra.items);
    extra.clearAndFree(gpa);
    std.mem.sort(Edge, edges.items, {}, lessByRank);
    if (top != 0) capPerNode(gpa, edges, top);
}

/// Frees what `compute` returned. Only `symbols` is owned per edge --
/// `from`/`to` borrow `path_to_nodes`.
pub fn free(gpa: Allocator, edges: *std.ArrayListUnmanaged(Edge)) void {
    for (edges.items) |e| gpa.free(e.symbols);
    edges.deinit(gpa);
}

fn lessByBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessByRank(_: void, a: Edge, b: Edge) bool {
    switch (std.mem.order(u8, a.from, b.from)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.weight != b.weight) return a.weight > b.weight;
    return std.mem.order(u8, a.to, b.to) == .lt;
}

/// `edges` is sorted by `from` then descending weight; drops every entry
/// past the first `top` per `from` run, in place.
fn capPerNode(gpa: Allocator, edges: *std.ArrayListUnmanaged(Edge), top: usize) void {
    var write: usize = 0;
    var read: usize = 0;
    while (read < edges.items.len) {
        const from = edges.items[read].from;
        var run: usize = 0;
        while (read < edges.items.len and std.mem.eql(u8, edges.items[read].from, from)) {
            if (run < top) {
                edges.items[write] = edges.items[read];
                write += 1;
                run += 1;
            } else {
                gpa.free(edges.items[read].symbols); // dropped by the cap, otherwise unreachable
            }
            read += 1;
        }
    }
    edges.shrinkRetainingCapacity(write);
}

/// `from <TAB> to <TAB> weight <TAB> symbol symbol ...`.
pub fn writeEdge(w: *std.Io.Writer, e: Edge) !void {
    try w.print("{s}\t{s}\t{d}\t", .{ e.from, e.to, e.weight });
    for (e.symbols, 0..) |s, i| {
        if (i > 0) try w.writeAll(" ");
        try w.writeAll(s);
    }
    try w.writeAll("\n");
}

const testing = std.testing;

fn pathMap(
    gpa: Allocator,
    pairs: []const struct { path: []const u8, nodes: []const []const u8 },
) !std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) {
    var m: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    for (pairs) |p| {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (p.nodes) |n| try list.append(gpa, n);
        try m.put(gpa, p.path, list);
    }
    return m;
}

fn freePathMap(gpa: Allocator, m: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8))) void {
    var it = m.valueIterator();
    while (it.next()) |v| v.deinit(gpa);
    m.deinit(gpa);
}

test "a ref in A to a def in B is an edge A -> B" {
    const gpa = testing.allocator;
    var pm = try pathMap(gpa, &.{
        .{ .path = "a/Widget.java", .nodes = &.{"A"} },
        .{ .path = "b/Gadget.java", .nodes = &.{"B"} },
    });
    defer freePathMap(gpa, &pm);

    const refs_table =
        "Helper\tdef\tclass\tb/Gadget.java:1\tclass Helper {\n" ++
        "Helper\tref\tcall\ta/Widget.java:5\tHelper.run();\n";

    var edges = try compute(gpa, refs_table, &pm, 10, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqualStrings("A", edges.items[0].from);
    try testing.expectEqualStrings("B", edges.items[0].to);
    try testing.expectEqual(@as(usize, 1), edges.items[0].weight);
    try testing.expectEqualStrings("Helper", edges.items[0].symbols[0]);
}

test "a ref and a def in the same node produce no self-edge" {
    const gpa = testing.allocator;
    var pm = try pathMap(gpa, &.{
        .{ .path = "a/One.java", .nodes = &.{"A"} },
        .{ .path = "a/Two.java", .nodes = &.{"A"} },
    });
    defer freePathMap(gpa, &pm);

    const refs_table =
        "Local\tdef\tclass\ta/One.java:1\tclass Local {\n" ++
        "Local\tref\tcall\ta/Two.java:2\tLocal.run();\n";

    var edges = try compute(gpa, refs_table, &pm, 10, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 0), edges.items.len);
}

test "a symbol referenced from too many nodes is not rare, and produces no edge" {
    const gpa = testing.allocator;
    // rare_max = max(2, 10/20) = 2; three referencing nodes exceeds it.
    var pm = try pathMap(gpa, &.{
        .{ .path = "d/Def.java", .nodes = &.{"D"} },
        .{ .path = "a/A.java", .nodes = &.{"A"} },
        .{ .path = "b/B.java", .nodes = &.{"B"} },
        .{ .path = "c/C.java", .nodes = &.{"C"} },
    });
    defer freePathMap(gpa, &pm);

    const refs_table =
        "Common\tdef\tclass\td/Def.java:1\tclass Common {\n" ++
        "Common\tref\tcall\ta/A.java:1\tCommon.run();\n" ++
        "Common\tref\tcall\tb/B.java:1\tCommon.run();\n" ++
        "Common\tref\tcall\tc/C.java:1\tCommon.run();\n";

    var edges = try compute(gpa, refs_table, &pm, 10, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 0), edges.items.len);
}

test "a symbol defined in two unrelated nodes produces no edge to either" {
    const gpa = testing.allocator;
    // A and B each define `run`; C reads it -- without the def.count()==1
    // guard this would fan out C -> A and C -> B, both false.
    var pm = try pathMap(gpa, &.{
        .{ .path = "a/A.java", .nodes = &.{"A"} },
        .{ .path = "b/B.java", .nodes = &.{"B"} },
        .{ .path = "c/C.java", .nodes = &.{"C"} },
    });
    defer freePathMap(gpa, &pm);

    const refs_table =
        "run\tdef\tmethod\ta/A.java:1\tvoid run() {\n" ++
        "run\tdef\tmethod\tb/B.java:1\tvoid run() {\n" ++
        "run\tref\tcall\tc/C.java:1\trun();\n";

    var edges = try compute(gpa, refs_table, &pm, 10, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 0), edges.items.len);
}

test "weight counts distinct rare symbols, not raw reference occurrences" {
    const gpa = testing.allocator;
    var pm = try pathMap(gpa, &.{
        .{ .path = "b/B.java", .nodes = &.{"B"} },
        .{ .path = "a/A.java", .nodes = &.{"A"} },
    });
    defer freePathMap(gpa, &pm);

    // Two calls to the same symbol: one edge-supporting symbol, not two.
    const refs_table =
        "Widget\tdef\tclass\tb/B.java:1\tclass Widget {\n" ++
        "Widget\tref\tcall\ta/A.java:3\tWidget.run();\n" ++
        "Widget\tref\tcall\ta/A.java:9\tWidget.run();\n";

    var edges = try compute(gpa, refs_table, &pm, 10, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqual(@as(usize, 1), edges.items[0].weight);
}

test "an edge is supported by every rare symbol that crosses it, weight is the count" {
    const gpa = testing.allocator;
    var pm = try pathMap(gpa, &.{
        .{ .path = "b/B.java", .nodes = &.{"B"} },
        .{ .path = "a/A.java", .nodes = &.{"A"} },
    });
    defer freePathMap(gpa, &pm);

    const refs_table =
        "Alpha\tdef\tclass\tb/B.java:1\tclass Alpha {\n" ++
        "Alpha\tref\tcall\ta/A.java:1\tAlpha.run();\n" ++
        "Beta\tdef\tclass\tb/B.java:2\tclass Beta {\n" ++
        "Beta\tref\tcall\ta/A.java:2\tBeta.run();\n";

    var edges = try compute(gpa, refs_table, &pm, 10, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqual(@as(usize, 2), edges.items[0].weight);
    try testing.expectEqualStrings("Alpha", edges.items[0].symbols[0]);
    try testing.expectEqualStrings("Beta", edges.items[0].symbols[1]);
}

test "a path no list claims contributes nothing, not a crash" {
    const gpa = testing.allocator;
    var pm = try pathMap(gpa, &.{
        .{ .path = "b/B.java", .nodes = &.{"B"} },
    });
    defer freePathMap(gpa, &pm);

    const refs_table =
        "Alpha\tdef\tclass\tb/B.java:1\tclass Alpha {\n" ++
        "Alpha\tref\tcall\tunclaimed/X.java:1\tAlpha.run();\n";

    var edges = try compute(gpa, refs_table, &pm, 10, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 0), edges.items.len);
}

test "a path claimed by two nodes fans out edges from both" {
    const gpa = testing.allocator;
    var pm = try pathMap(gpa, &.{
        .{ .path = "b/B.java", .nodes = &.{"B"} },
        .{ .path = "shared/S.java", .nodes = &.{ "A", "C" } },
    });
    defer freePathMap(gpa, &pm);

    const refs_table =
        "Alpha\tdef\tclass\tb/B.java:1\tclass Alpha {\n" ++
        "Alpha\tref\tcall\tshared/S.java:1\tAlpha.run();\n";

    var edges = try compute(gpa, refs_table, &pm, 10, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 2), edges.items.len);
    try testing.expectEqualStrings("A", edges.items[0].from);
    try testing.expectEqualStrings("C", edges.items[1].from);
}

test "output is sorted by from, then weight descending, then to ascending" {
    const gpa = testing.allocator;
    var pm = try pathMap(gpa, &.{
        .{ .path = "b/B.java", .nodes = &.{"B"} },
        .{ .path = "c/C.java", .nodes = &.{"C"} },
        .{ .path = "a/A.java", .nodes = &.{"A"} },
    });
    defer freePathMap(gpa, &pm);

    const refs_table =
        "One\tdef\tclass\tb/B.java:1\tclass One {\n" ++
        "One\tref\tcall\ta/A.java:1\tOne.run();\n" ++
        "Two\tdef\tclass\tc/C.java:1\tclass Two {\n" ++
        "Two\tref\tcall\ta/A.java:2\tTwo.run();\n" ++
        "Two\tref\tcall\ta/A.java:3\tTwo.run();\n" ++ // still one symbol, not two
        "Three\tdef\tclass\tc/C.java:2\tclass Three {\n" ++
        "Three\tref\tcall\ta/A.java:4\tThree.run();\n";

    var edges = try compute(gpa, refs_table, &pm, 10, .{});
    defer free(gpa, &edges);
    // A -> C has two symbols (Two, Three), A -> B has one: C ranks first.
    try testing.expectEqual(@as(usize, 2), edges.items.len);
    try testing.expectEqualStrings("C", edges.items[0].to);
    try testing.expectEqual(@as(usize, 2), edges.items[0].weight);
    try testing.expectEqualStrings("B", edges.items[1].to);
    try testing.expectEqual(@as(usize, 1), edges.items[1].weight);
}

test "--top caps edges per from-node, strongest kept" {
    const gpa = testing.allocator;
    var pm = try pathMap(gpa, &.{
        .{ .path = "a/A.java", .nodes = &.{"A"} },
        .{ .path = "b/B.java", .nodes = &.{"B"} },
        .{ .path = "c/C.java", .nodes = &.{"C"} },
        .{ .path = "d/D.java", .nodes = &.{"D"} },
    });
    defer freePathMap(gpa, &pm);

    const refs_table =
        "X\tdef\tclass\tb/B.java:1\tclass X {\n" ++
        "X\tref\tcall\ta/A.java:1\tX.run();\n" ++
        "Y\tdef\tclass\tc/C.java:1\tclass Y {\n" ++
        "Y\tref\tcall\ta/A.java:2\tY.run();\n" ++
        "Z\tdef\tclass\td/D.java:1\tclass Z {\n" ++
        "Z\tref\tcall\ta/A.java:3\tZ.run();\n";

    var edges = try compute(gpa, refs_table, &pm, 10, .{ .top = 2 });
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 2), edges.items.len);
}

test "a symbol with no def anywhere contributes nothing" {
    const gpa = testing.allocator;
    var pm = try pathMap(gpa, &.{
        .{ .path = "a/A.java", .nodes = &.{"A"} },
    });
    defer freePathMap(gpa, &pm);

    const refs_table = "Ghost\tref\tcall\ta/A.java:1\tGhost.run();\n";

    var edges = try compute(gpa, refs_table, &pm, 10, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 0), edges.items.len);
}

test "writeEdge is tab-separated with a space-joined symbol list" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeEdge(&out.writer, .{
        .from = "A",
        .to = "B",
        .weight = 2,
        .symbols = &.{ "Alpha", "Beta" },
    });
    try testing.expectEqualStrings("A\tB\t2\tAlpha Beta\n", out.written());
}

test "compute: no edge is ever a self-edge, and weight is never smaller than the symbol list shown" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *testing.Smith) anyerror!void {
            const gpa = testing.allocator;
            const num_nodes: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 2, 4, 0));
            const num_symbols: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 1, 3, 1));

            var node_names: [4][8]u8 = undefined;
            var paths: [4][8]u8 = undefined;
            for (0..num_nodes) |i| {
                _ = std.fmt.bufPrint(&node_names[i], "N{d}", .{i}) catch unreachable;
                _ = std.fmt.bufPrint(&paths[i], "n{d}.ext", .{i}) catch unreachable;
            }

            var pm: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
            defer {
                var it = pm.valueIterator();
                while (it.next()) |l| l.deinit(gpa);
                pm.deinit(gpa);
            }
            for (0..num_nodes) |i| {
                var owners: std.ArrayListUnmanaged([]const u8) = .empty;
                try owners.append(gpa, node_names[i][0..2]);
                try pm.put(gpa, paths[i][0..6], owners);
            }

            var table: std.Io.Writer.Allocating = .init(gpa);
            defer table.deinit();
            var hash: u32 = 2;
            for (0..num_symbols) |s| {
                for (0..num_nodes) |i| {
                    if (smith.valueWithHash(bool, hash)) {
                        try table.writer.print("S{d}\tdef\tk\t{s}:1\tx\n", .{ s, paths[i][0..6] });
                    }
                    hash += 1;
                    if (smith.valueWithHash(bool, hash)) {
                        try table.writer.print("S{d}\tref\tk\t{s}:1\tx\n", .{ s, paths[i][0..6] });
                    }
                    hash += 1;
                }
            }

            var edges = try compute(gpa, table.written(), &pm, num_nodes, .{});
            defer free(gpa, &edges);

            for (edges.items) |e| {
                try testing.expect(!std.mem.eql(u8, e.from, e.to));
                try testing.expect(e.weight >= e.symbols.len);
            }
        }
    }.testOne, .{});
}

/// `path -> {value, ...}` -- the shape both `path_to_deps` (a file's own
/// declared dependencies) and `path_to_namespace` (a file's own declared
/// identities) share, so one builder serves both in tests.
fn pathSetsMap(
    gpa: Allocator,
    pairs: []const struct { path: []const u8, values: []const []const u8 },
) !std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) {
    var m: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
    for (pairs) |p| {
        var set: std.StringHashMapUnmanaged(void) = .empty;
        for (p.values) |v| try set.put(gpa, v, {});
        try m.put(gpa, p.path, set);
    }
    return m;
}

fn freePathSetsMap(gpa: Allocator, m: *std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void))) void {
    var it = m.valueIterator();
    while (it.next()) |v| v.deinit(gpa);
    m.deinit(gpa);
}

test "resolveAmbiguous: a reference resolves to the one candidate its own file actually depends on" {
    const gpa = testing.allocator;
    // `Shared` is defined in both B and C; A references it and declares a
    // dependency on B's own library, not C's.
    var pm = try pathMap(gpa, &.{
        .{ .path = "a/A.ext", .nodes = &.{"A"} },
        .{ .path = "b/B.ext", .nodes = &.{"B"} },
        .{ .path = "c/C.ext", .nodes = &.{"C"} },
    });
    defer freePathMap(gpa, &pm);
    var ns = try pathSetsMap(gpa, &.{
        .{ .path = "b/B.ext", .values = &.{"lib_b"} },
        .{ .path = "c/C.ext", .values = &.{"lib_c"} },
    });
    defer freePathSetsMap(gpa, &ns);
    var deps = try pathSetsMap(gpa, &.{
        .{ .path = "a/A.ext", .values = &.{"lib_b"} },
    });
    defer freePathSetsMap(gpa, &deps);

    const refs_table =
        "Shared\tdef\tclass\tb/B.ext:1\tclass Shared {\n" ++
        "Shared\tdef\tclass\tc/C.ext:1\tclass Shared {\n" ++
        "Shared\tref\tcall\ta/A.ext:5\tShared.run();\n";

    var edges = try resolveAmbiguous(gpa, refs_table, &pm, &ns, &deps, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqualStrings("A", edges.items[0].from);
    try testing.expectEqualStrings("B", edges.items[0].to);
    try testing.expectEqualStrings("Shared", edges.items[0].symbols[0]);
}

test "resolveAmbiguous: no matching dependency edge leaves the reference ambiguous" {
    const gpa = testing.allocator;
    var pm = try pathMap(gpa, &.{
        .{ .path = "a/A.ext", .nodes = &.{"A"} },
        .{ .path = "b/B.ext", .nodes = &.{"B"} },
        .{ .path = "c/C.ext", .nodes = &.{"C"} },
    });
    defer freePathMap(gpa, &pm);
    var ns = try pathSetsMap(gpa, &.{
        .{ .path = "b/B.ext", .values = &.{"lib_b"} },
        .{ .path = "c/C.ext", .values = &.{"lib_c"} },
    });
    defer freePathSetsMap(gpa, &ns);
    // A depends on neither candidate's library.
    var deps = try pathSetsMap(gpa, &.{
        .{ .path = "a/A.ext", .values = &.{"lib_unrelated"} },
    });
    defer freePathSetsMap(gpa, &deps);

    const refs_table =
        "Shared\tdef\tclass\tb/B.ext:1\tclass Shared {\n" ++
        "Shared\tdef\tclass\tc/C.ext:1\tclass Shared {\n" ++
        "Shared\tref\tcall\ta/A.ext:5\tShared.run();\n";

    var edges = try resolveAmbiguous(gpa, refs_table, &pm, &ns, &deps, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 0), edges.items.len);
}

test "resolveAmbiguous: a candidate in the reference's own node is never a resolution target" {
    const gpa = testing.allocator;
    // `Shared` is defined in both A (the reference's own node) and B. Even
    // though A's own declared library would also match A's own deps
    // (self-reference), the true answer already lived in A's own node --
    // never resolved to an edge, same as `compute`'s own self-edge drop.
    var pm = try pathMap(gpa, &.{
        .{ .path = "a/A.ext", .nodes = &.{"A"} },
        .{ .path = "b/B.ext", .nodes = &.{"B"} },
    });
    defer freePathMap(gpa, &pm);
    var ns = try pathSetsMap(gpa, &.{
        .{ .path = "a/A.ext", .values = &.{"lib_a"} },
        .{ .path = "b/B.ext", .values = &.{"lib_b"} },
    });
    defer freePathSetsMap(gpa, &ns);
    var deps = try pathSetsMap(gpa, &.{
        .{ .path = "a/A.ext", .values = &.{ "lib_a", "lib_b" } },
    });
    defer freePathSetsMap(gpa, &deps);

    const refs_table =
        "Shared\tdef\tclass\ta/A.ext:1\tclass Shared {\n" ++
        "Shared\tdef\tclass\tb/B.ext:1\tclass Shared {\n" ++
        "Shared\tref\tcall\ta/A.ext:5\tShared.run();\n";

    var edges = try resolveAmbiguous(gpa, refs_table, &pm, &ns, &deps, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 0), edges.items.len);
}

test "resolveAmbiguous: more than one qualifying candidate library stays ambiguous" {
    const gpa = testing.allocator;
    var pm = try pathMap(gpa, &.{
        .{ .path = "a/A.ext", .nodes = &.{"A"} },
        .{ .path = "b/B.ext", .nodes = &.{"B"} },
        .{ .path = "c/C.ext", .nodes = &.{"C"} },
    });
    defer freePathMap(gpa, &pm);
    var ns = try pathSetsMap(gpa, &.{
        .{ .path = "b/B.ext", .values = &.{"lib_b"} },
        .{ .path = "c/C.ext", .values = &.{"lib_c"} },
    });
    defer freePathSetsMap(gpa, &ns);
    // A depends on both candidates' libraries -- still genuinely ambiguous.
    var deps = try pathSetsMap(gpa, &.{
        .{ .path = "a/A.ext", .values = &.{ "lib_b", "lib_c" } },
    });
    defer freePathSetsMap(gpa, &deps);

    const refs_table =
        "Shared\tdef\tclass\tb/B.ext:1\tclass Shared {\n" ++
        "Shared\tdef\tclass\tc/C.ext:1\tclass Shared {\n" ++
        "Shared\tref\tcall\ta/A.ext:5\tShared.run();\n";

    var edges = try resolveAmbiguous(gpa, refs_table, &pm, &ns, &deps, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 0), edges.items.len);
}

test "resolveAmbiguous: two aliases for the same candidate still resolve to a single edge" {
    const gpa = testing.allocator;
    // B's file is known under two identities (a rule's primary value and
    // one alias) -- A's dependency matches only the alias, and the
    // candidate still resolves, exactly once.
    var pm = try pathMap(gpa, &.{
        .{ .path = "a/A.ext", .nodes = &.{"A"} },
        .{ .path = "b/B.ext", .nodes = &.{"B"} },
        .{ .path = "c/C.ext", .nodes = &.{"C"} },
    });
    defer freePathMap(gpa, &pm);
    var ns = try pathSetsMap(gpa, &.{
        .{ .path = "b/B.ext", .values = &.{ "lib_b", "lib_b_pub" } },
        .{ .path = "c/C.ext", .values = &.{"lib_c"} },
    });
    defer freePathSetsMap(gpa, &ns);
    var deps = try pathSetsMap(gpa, &.{
        .{ .path = "a/A.ext", .values = &.{"lib_b_pub"} },
    });
    defer freePathSetsMap(gpa, &deps);

    const refs_table =
        "Shared\tdef\tclass\tb/B.ext:1\tclass Shared {\n" ++
        "Shared\tdef\tclass\tc/C.ext:1\tclass Shared {\n" ++
        "Shared\tref\tcall\ta/A.ext:5\tShared.run();\n";

    var edges = try resolveAmbiguous(gpa, refs_table, &pm, &ns, &deps, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqualStrings("B", edges.items[0].to);
}

test "resolveAmbiguous: a reference with no declared dependency data at all is left ambiguous" {
    const gpa = testing.allocator;
    var pm = try pathMap(gpa, &.{
        .{ .path = "a/A.ext", .nodes = &.{"A"} },
        .{ .path = "b/B.ext", .nodes = &.{"B"} },
        .{ .path = "c/C.ext", .nodes = &.{"C"} },
    });
    defer freePathMap(gpa, &pm);
    var ns: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
    defer freePathSetsMap(gpa, &ns);
    var deps: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
    defer freePathSetsMap(gpa, &deps);

    const refs_table =
        "Shared\tdef\tclass\tb/B.ext:1\tclass Shared {\n" ++
        "Shared\tdef\tclass\tc/C.ext:1\tclass Shared {\n" ++
        "Shared\tref\tcall\ta/A.ext:5\tShared.run();\n";

    var edges = try resolveAmbiguous(gpa, refs_table, &pm, &ns, &deps, .{});
    defer free(gpa, &edges);
    try testing.expectEqual(@as(usize, 0), edges.items.len);
}

test "mergeEdges: concatenates, re-sorts, and re-caps -- ownership of extra's edges transfers" {
    const gpa = testing.allocator;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    try edges.append(gpa, .{ .from = "A", .to = "B", .weight = 1, .symbols = try gpa.dupe([]const u8, &.{"One"}) });

    var extra: std.ArrayListUnmanaged(Edge) = .empty;
    try extra.append(gpa, .{ .from = "A", .to = "C", .weight = 5, .symbols = try gpa.dupe([]const u8, &.{"Two"}) });

    try mergeEdges(gpa, &edges, &extra, 0);
    defer free(gpa, &edges);

    try testing.expectEqual(@as(usize, 0), extra.items.len);
    try testing.expectEqual(@as(usize, 2), edges.items.len);
    // Sorted by from asc, weight desc, to asc -- the higher-weight A->C edge first.
    try testing.expectEqualStrings("C", edges.items[0].to);
    try testing.expectEqualStrings("B", edges.items[1].to);
}

test "mergeEdges: a nonzero top re-applies the per-node cap across the combined set" {
    const gpa = testing.allocator;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    try edges.append(gpa, .{ .from = "A", .to = "B", .weight = 1, .symbols = try gpa.dupe([]const u8, &.{"One"}) });

    var extra: std.ArrayListUnmanaged(Edge) = .empty;
    try extra.append(gpa, .{ .from = "A", .to = "C", .weight = 5, .symbols = try gpa.dupe([]const u8, &.{"Two"}) });

    try mergeEdges(gpa, &edges, &extra, 1);
    defer free(gpa, &edges);

    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqualStrings("C", edges.items[0].to);
}
