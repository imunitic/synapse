//! A second implementation of the Extractor port, to find out whether it is a
//! port at all.
//!
//! `TreeSitterExtractor` is the only real one, and a port with one
//! implementation is an indirection with extra steps -- the shape it settled
//! into is whatever tree-sitter happened to need, and nobody can tell the
//! difference until something else has to fit through it. This is that
//! something else: bard reads entity notes, where a def is the entity's own
//! identity and a ref is each relationship field, and it shares none of
//! tree-sitter's assumptions. If the port only fits the first product, this
//! file will not compile, and that is the whole point of it existing now
//! rather than when bard is real.
//!
//! **This is a test, not a product.** It is referenced only from `root.zig`'s
//! test block, so Zig's lazy analysis keeps it out of any release build
//! entirely. Bard will need a real frontmatter extractor; writing one now
//! would be building past the decision gate, against a format nothing has
//! pinned yet. What is worth having today is the proof that the seam holds.
//!
//! ## The subset, and why it refuses rather than skips
//!
//! Scalars, lists, one level of nested map, and wikilink values. Anything else
//! -- anchors, aliases, block scalars, flow collections, a second document,
//! tabs, deeper nesting -- makes the whole file `.unsupported`.
//!
//! Refusing is the entire discipline here. A parser that skips what it does
//! not understand becomes a bad general YAML parser by accretion: each unknown
//! construct is individually cheap to ignore, and the result silently drops
//! relationships from notes that look fine. `.unsupported` is a visible,
//! recoverable answer, and the tags cache already records it as one; a missing
//! ref is neither.

const std = @import("std");
const model = @import("model");
const ports = @import("ports");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const FrontmatterExtractor = struct {
    /// The field naming the entity itself. Everything else carrying a wikilink
    /// is a relationship to another entity.
    identity_field: []const u8 = "title",
    /// The field naming what kind of entity it is, used as the def's `kind`.
    type_field: []const u8 = "type",
    /// Set when a file was refused, so a test can assert on the reason rather
    /// than on `.unsupported` alone. A product would report this to the user.
    last_refusal: ?Refusal = null,

    pub const Refusal = enum {
        not_a_note,
        no_frontmatter,
        unterminated,
        anchor_or_alias,
        block_scalar,
        flow_collection,
        second_document,
        tab_indent,
        nesting_too_deep,
        malformed_line,
    };

    pub fn port(self: *FrontmatterExtractor) ports.Extractor {
        return .{ .ptr = self, .vtable = &.{ .extract = extract } };
    }

    fn extract(
        ptr: *anyopaque,
        gpa: Allocator,
        io: Io,
        root: []const u8,
        paths: []const []const u8,
    ) anyerror![]ports.Extractor.Outcome {
        const self: *FrontmatterExtractor = @ptrCast(@alignCast(ptr));

        const out = try gpa.alloc(ports.Extractor.Outcome, paths.len);
        errdefer gpa.free(out);

        for (paths, 0..) |p, i| {
            out[i] = .unsupported;

            if (!std.mem.endsWith(u8, p, ".md")) {
                self.last_refusal = .not_a_note;
                continue;
            }

            const full = try std.fs.path.join(gpa, &.{ root, p });
            defer gpa.free(full);
            const src = Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(1 << 20)) catch continue;
            defer gpa.free(src);

            const tags = self.tagsFor(gpa, src) catch |e| {
                if (e == error.Refused) continue;
                return e;
            };
            out[i] = .{ .tags = tags };
        }
        return out;
    }

    fn refuse(self: *FrontmatterExtractor, why: Refusal) error{Refused} {
        self.last_refusal = why;
        return error.Refused;
    }

    fn tagsFor(self: *FrontmatterExtractor, gpa: Allocator, src: []const u8) ![]model.Tag {
        var tags: std.ArrayListUnmanaged(model.Tag) = .empty;
        errdefer {
            for (tags.items) |t| freeTag(gpa, t);
            tags.deinit(gpa);
        }

        var lines = std.mem.splitScalar(u8, src, '\n');
        const first = lines.next() orelse return self.refuse(.no_frontmatter);
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), "---"))
            return self.refuse(.no_frontmatter);

        // The key whose nested block we are inside, or null at the top level.
        // One level, so this is a single value rather than a stack -- a stack
        // is what a general parser has, and this is not one.
        var parent: ?[]const u8 = null;
        var closed = false;
        var row: u32 = 0;

        while (lines.next()) |raw| {
            row += 1;
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (std.mem.eql(u8, line, "---")) {
                closed = true;
                break;
            }
            if (std.mem.indexOfScalar(u8, line, '\t') != null) return self.refuse(.tab_indent);
            if (std.mem.trim(u8, line, " ").len == 0) continue;

            const indent = line.len - std.mem.trimStart(u8, line, " ").len;
            const body = line[indent..];
            if (indent > 2) return self.refuse(.nesting_too_deep);
            if (indent == 0) parent = null;

            // A list item under whatever key introduced the block. Each one is
            // its own value, so `- [[Ruth]]` under `children:` is a
            // relationship exactly as `spouse: [[Boaz]]` is.
            if (std.mem.startsWith(u8, body, "- ")) {
                const key = parent orelse return self.refuse(.malformed_line);
                try self.addValue(gpa, &tags, key, body[2..], row, line);
                continue;
            }

            const colon = std.mem.indexOfScalar(u8, body, ':') orelse
                return self.refuse(.malformed_line);
            const key = std.mem.trim(u8, body[0..colon], " ");
            if (key.len == 0) return self.refuse(.malformed_line);
            const value = std.mem.trim(u8, body[colon + 1 ..], " ");

            if (value.len == 0) {
                // A key introducing a block: either a list or a nested map.
                if (indent != 0) return self.refuse(.nesting_too_deep);
                parent = key;
                continue;
            }

            switch (value[0]) {
                '&', '*' => return self.refuse(.anchor_or_alias),
                '|', '>' => return self.refuse(.block_scalar),
                '{', '[' => if (!std.mem.startsWith(u8, value, "[["))
                    return self.refuse(.flow_collection),
                else => {},
            }

            if (indent == 0 and std.mem.eql(u8, key, self.identity_field)) {
                try tags.append(gpa, .{
                    .name = try gpa.dupe(u8, unquote(value)),
                    .role = .def,
                    .kind = try gpa.dupe(u8, self.entityKind(src)),
                    .line = row,
                    .expression = try gpa.dupe(u8, line),
                });
                continue;
            }
            // A nested key keeps its parent in the relationship name, so
            // `dates: { born: ... }` is `dates.born` rather than a bare `born`
            // colliding with every other entity's.
            if (parent) |pkey| {
                const qualified = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ pkey, key });
                defer gpa.free(qualified);
                try self.addValue(gpa, &tags, qualified, value, row, line);
            } else {
                try self.addValue(gpa, &tags, key, value, row, line);
            }
        }

        if (!closed) return self.refuse(.unterminated);
        // Anything after the closing delimiter is prose, except a second
        // `---`, which would be a multi-document stream.
        while (lines.next()) |raw| {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, raw, "\r"), "---"))
                return self.refuse(.second_document);
        }
        return tags.toOwnedSlice(gpa);
    }

    /// Only a wikilink is a relationship. A plain scalar is an attribute of
    /// this entity and names no other one, so emitting a ref for it would
    /// invent edges to things that are not entities -- `born: 1040 BC` is not
    /// a reference to a year.
    fn addValue(
        self: *FrontmatterExtractor,
        gpa: Allocator,
        tags: *std.ArrayListUnmanaged(model.Tag),
        key: []const u8,
        value: []const u8,
        row: u32,
        line: []const u8,
    ) !void {
        _ = self;
        const target = wikilinkTarget(value) orelse return;
        try tags.append(gpa, .{
            .name = try gpa.dupe(u8, target),
            .role = .ref,
            .kind = try gpa.dupe(u8, key),
            .line = row,
            .expression = try gpa.dupe(u8, line),
        });
    }

    fn entityKind(self: *const FrontmatterExtractor, src: []const u8) []const u8 {
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " "), self.type_field)) continue;
            const v = unquote(std.mem.trim(u8, line[colon + 1 ..], " "));
            if (v.len != 0) return v;
        }
        return "entity";
    }
};

/// `[[Target]]` or `[[Target|shown]]` -> `Target`. Anything else is not a
/// relationship.
fn wikilinkTarget(value: []const u8) ?[]const u8 {
    const inner = unquote(value);
    if (!std.mem.startsWith(u8, inner, "[[") or !std.mem.endsWith(u8, inner, "]]")) return null;
    const body = inner[2 .. inner.len - 2];
    const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
    const target = std.mem.trim(u8, body[0..pipe], " ");
    return if (target.len == 0) null else target;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0])
        return value[1 .. value.len - 1];
    return value;
}

fn freeTag(gpa: Allocator, t: model.Tag) void {
    gpa.free(t.name);
    gpa.free(t.kind);
    gpa.free(t.expression);
}

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    buf: [Io.Dir.max_path_bytes]u8 = undefined,

    fn init() Fixture {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
    }

    fn write(f: *Fixture, name: []const u8, body: []const u8) ![]const u8 {
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = body });
        return f.buf[0..try f.tmp.dir.realPath(testing.io, &f.buf)];
    }
};

fn freeOutcomes(gpa: Allocator, out: []ports.Extractor.Outcome) void {
    for (out) |o| switch (o) {
        .unsupported => {},
        .tags => |ts| {
            for (ts) |t| freeTag(gpa, t);
            gpa.free(ts);
        },
    };
    gpa.free(out);
}

const ruth =
    \\---
    \\title: Ruth
    \\type: person
    \\spouse: "[[Boaz]]"
    \\mother_in_law: [[Naomi|her mother-in-law]]
    \\born: 1100 BC
    \\appears_in:
    \\  - [[Book of Ruth]]
    \\  - [[Matthew]]
    \\dates:
    \\  died: 1050 BC
    \\  buried_at: [[Bethlehem]]
    \\---
    \\
    \\Ruth the Moabite.
    \\
;

test "a def is the entity's identity, a ref is each relationship field" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const dir = try fx.write("Ruth.md", ruth);

    var ex: FrontmatterExtractor = .{};
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"Ruth.md"});
    defer freeOutcomes(gpa, out);

    const tags = out[0].tags;

    // Exactly one def, and it is the entity itself, kinded by its type.
    var defs: usize = 0;
    for (tags) |t| if (t.role == .def) {
        defs += 1;
        try testing.expectEqualStrings("Ruth", t.name);
        try testing.expectEqualStrings("person", t.kind);
    };
    try testing.expectEqual(@as(usize, 1), defs);

    // Every relationship, and only relationships: `born` is an attribute of
    // Ruth, not an edge to the year 1100 BC.
    try expectRef(tags, "Boaz", "spouse");
    try expectRef(tags, "Naomi", "mother_in_law");
    try expectRef(tags, "Book of Ruth", "appears_in");
    try expectRef(tags, "Matthew", "appears_in");
    try expectRef(tags, "Bethlehem", "dates.buried_at");
    try testing.expectEqual(@as(usize, 5), countRole(tags, .ref));
}

fn expectRef(tags: []const model.Tag, name: []const u8, kind: []const u8) !void {
    for (tags) |t| {
        if (t.role != .ref) continue;
        if (!std.mem.eql(u8, t.name, name)) continue;
        try testing.expectEqualStrings(kind, t.kind);
        return;
    }
    std.debug.print("no ref named '{s}'\n", .{name});
    return error.TestExpectedEqual;
}

fn countRole(tags: []const model.Tag, role: model.Role) usize {
    var n: usize = 0;
    for (tags) |t| {
        if (t.role == role) n += 1;
    }
    return n;
}

test "tags carry the line they came from, and the line's own text" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const dir = try fx.write("Ruth.md", ruth);

    var ex: FrontmatterExtractor = .{};
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"Ruth.md"});
    defer freeOutcomes(gpa, out);

    for (out[0].tags) |t| {
        if (t.role != .def) continue;
        // `title:` is the second line of the file; rows are 0-based, matching
        // what the tree-sitter path carries through unadjusted.
        try testing.expectEqual(@as(u32, 1), t.line);
        try testing.expectEqualStrings("title: Ruth", t.expression);
    }
}

test "the port's batch shape holds: one outcome per path, in order" {
    // The property that made the port batch-shaped in the first place, checked
    // against an implementation with no startup cost to amortise. If it only
    // made sense for tree-sitter it would be tree-sitter's shape, not a port's.
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    _ = try fx.write("Ruth.md", ruth);
    _ = try fx.write("Boaz.md", "---\ntitle: Boaz\ntype: person\n---\n");
    const dir = try fx.write("notes.txt", "not a note");

    var ex: FrontmatterExtractor = .{};
    const out = try ex.port().extract(gpa, testing.io, dir, &.{ "Ruth.md", "notes.txt", "Boaz.md" });
    defer freeOutcomes(gpa, out);

    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(usize, 1), countRole(out[0].tags, .def));
    try testing.expect(out[1] == .unsupported);
    try testing.expectEqual(@as(usize, 1), countRole(out[2].tags, .def));
}

test "a note with no relationships parsed fine, and is not unsupported" {
    // The same distinction the tags cache rests on, reached from the other
    // side: an entity with no edges yet is not a file nothing can read.
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const dir = try fx.write("Lone.md", "---\ntitle: Lone\ntype: place\n---\n\nProse.\n");

    var ex: FrontmatterExtractor = .{};
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"Lone.md"});
    defer freeOutcomes(gpa, out);

    try testing.expect(out[0] == .tags);
    try testing.expectEqual(@as(usize, 0), countRole(out[0].tags, .ref));
    try testing.expectEqual(@as(usize, 1), countRole(out[0].tags, .def));
}

test "an entity with no type still gets a def" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const dir = try fx.write("Bare.md", "---\ntitle: Bare\n---\n");

    var ex: FrontmatterExtractor = .{};
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"Bare.md"});
    defer freeOutcomes(gpa, out);
    try testing.expectEqualStrings("entity", out[0].tags[0].kind);
}

test "everything outside the subset is refused, not skipped" {
    // The discipline this file exists to hold. Each of these is individually
    // cheap to ignore, and ignoring any of them turns a parser that refuses
    // what it does not understand into one that silently drops relationships.
    const gpa = testing.allocator;
    const cases = [_]struct { why: FrontmatterExtractor.Refusal, body: []const u8 }{
        .{ .why = .anchor_or_alias, .body = "---\ntitle: A\nbase: &anchor x\n---\n" },
        .{ .why = .anchor_or_alias, .body = "---\ntitle: A\nsame_as: *anchor\n---\n" },
        .{ .why = .block_scalar, .body = "---\ntitle: A\nsummary: |\n  a paragraph\n---\n" },
        .{ .why = .block_scalar, .body = "---\ntitle: A\nsummary: >\n  folded\n---\n" },
        .{ .why = .flow_collection, .body = "---\ntitle: A\nrefs: [x, y]\n---\n" },
        .{ .why = .flow_collection, .body = "---\ntitle: A\nrefs: {a: b}\n---\n" },
        .{ .why = .second_document, .body = "---\ntitle: A\n---\nprose\n---\n" },
        .{ .why = .tab_indent, .body = "---\ntitle: A\nlist:\n\t- [[B]]\n---\n" },
        .{ .why = .nesting_too_deep, .body = "---\ntitle: A\na:\n  b:\n    c: [[D]]\n---\n" },
        .{ .why = .unterminated, .body = "---\ntitle: A\ntype: person\n" },
        .{ .why = .no_frontmatter, .body = "# Just prose\n\nNo frontmatter here.\n" },
        .{ .why = .malformed_line, .body = "---\ntitle: A\nno colon on this line\n---\n" },
        .{ .why = .malformed_line, .body = "---\n- [[Orphan]]\n---\n" },
    };

    for (cases, 0..) |c, i| {
        var fx = Fixture.init();
        defer fx.deinit();
        const dir = try fx.write("Case.md", c.body);

        var ex: FrontmatterExtractor = .{};
        const out = try ex.port().extract(gpa, testing.io, dir, &.{"Case.md"});
        defer freeOutcomes(gpa, out);

        testing.expect(out[0] == .unsupported) catch |e| {
            std.debug.print("case {d} ({t}) was accepted, not refused\n", .{ i, c.why });
            return e;
        };
        testing.expectEqual(c.why, ex.last_refusal.?) catch |e| {
            std.debug.print("case {d}: expected {t}, got {t}\n", .{ i, c.why, ex.last_refusal.? });
            return e;
        };
    }
}

test "a refusal does not take the rest of the batch with it" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    _ = try fx.write("Bad.md", "---\ntitle: A\nsummary: |\n  block\n---\n");
    const dir = try fx.write("Ruth.md", ruth);

    var ex: FrontmatterExtractor = .{};
    const out = try ex.port().extract(gpa, testing.io, dir, &.{ "Bad.md", "Ruth.md" });
    defer freeOutcomes(gpa, out);

    try testing.expect(out[0] == .unsupported);
    try testing.expectEqual(@as(usize, 5), countRole(out[1].tags, .ref));
}

test "wikilink targets, display text and quoting" {
    try testing.expectEqualStrings("Boaz", wikilinkTarget("[[Boaz]]").?);
    try testing.expectEqualStrings("Boaz", wikilinkTarget("\"[[Boaz]]\"").?);
    try testing.expectEqualStrings("Naomi", wikilinkTarget("[[Naomi|her mother-in-law]]").?);
    try testing.expectEqualStrings("Book of Ruth", wikilinkTarget("[[Book of Ruth]]").?);
    // Not links, and therefore not relationships.
    try testing.expectEqual(@as(?[]const u8, null), wikilinkTarget("1100 BC"));
    try testing.expectEqual(@as(?[]const u8, null), wikilinkTarget("[[]]"));
    try testing.expectEqual(@as(?[]const u8, null), wikilinkTarget("[[unclosed"));
}
