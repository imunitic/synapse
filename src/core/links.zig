//! The node-to-node link graph, computed before any prose exists --
//! synapse-001 (precompute before inference), step 9.
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

        const slot = try by_name.getOrPut(gpa, row.name);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        const set = if (is_def) &slot.value_ptr.def else &slot.value_ptr.ref;
        for (owners.items) |node| try set.put(gpa, node, {});
    }

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
