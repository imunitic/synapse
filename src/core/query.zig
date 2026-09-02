//! Reading a node: the parts that are a pure function of its text (not
//! `stale`/`drift`/`symbol`, which need the world). Frontmatter fields, the
//! source list, the body between generated fences, `## Links` edges, module
//! counts. Ported from `synapse-query.sh`'s awk; subtle rules are commented
//! and pinned by a test.

const std = @import("std");
const node_mod = @import("node.zig");

/// The prose a node is *for*, between the generated fences and excluding both
/// marker lines.
///
/// Between the fences rather than after the closing `---`, and the script's
/// comment says why it is strictly better: it excludes the frontmatter *and*
/// `## Notes`. A node built before fencing existed has no markers, and there the
/// caller falls back to everything after the frontmatter and says so on stderr,
/// because `## Notes` will be included and that is worth announcing rather than
/// hiding.
pub fn body(text: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, node_mod.generated_start) orelse return null;
    const after = start + node_mod.generated_start.len;
    const end = std.mem.indexOfPos(u8, text, after, node_mod.generated_end) orelse return null;
    // `sed -n '/start/,/end/p' | sed -e '1d' -e '$d'` deletes the two marker
    // *lines* and nothing more. So exactly one newline comes off each end -- the
    // one that terminated the start marker, and the one that terminated the last
    // content line before the end marker.
    //
    // Trimming *all* leading newlines instead ate the blank line that every real
    // node has between the start marker and `## Summary`, which showed up as one
    // differing line in each of 132 nodes. A body is quoted into prose elsewhere,
    // so a missing leading blank is a rendering change, not a cosmetic one.
    var inner = text[after..end];
    if (inner.len != 0 and inner[0] == '\n') inner = inner[1..];
    if (inner.len != 0 and inner[inner.len - 1] == '\n') inner = inner[0 .. inner.len - 1];
    return inner;
}

/// Everything after the closing `---`, for a node with no fence.
pub fn bodyAfterFrontmatter(text: []const u8) []const u8 {
    var it = FrontmatterIterator.init(text);
    while (it.next()) |_| {}
    return it.after;
}

/// One top-level frontmatter scalar, quotes stripped, or null when absent.
///
/// First match inside the frontmatter only. An absent key is null rather than an
/// error, so a caller can test emptiness without parsing a message -- the script
/// printed nothing and exited 0 for exactly that reason.
///
/// `sources` is refused by the caller rather than here: it is a list of objects,
/// and `sources()` is what asks for it.
pub fn field(text: []const u8, key: []const u8) ?[]const u8 {
    var it = FrontmatterIterator.init(text);
    while (it.next()) |line| {
        if (!isKeyLine(line, key)) continue;
        return stripOneQuote(std.mem.trimStart(u8, line[key.len + 1 ..], " \t"));
    }
    return null;
}

/// Whether `line` is exactly `{key}: ...` at column zero -- `index($0, k
/// ":") == 1` in the original awk, an anchored prefix match, so a lookup
/// for `title` doesn't also match `subtitle:` or `titled:`. Shared by
/// every top-level frontmatter-key lookup in this codebase (`field`,
/// `fieldStreaming`, `scalar`, and `frontmatter.zig`'s own `findKeyLine`),
/// so a change to what counts as "this line owns this key" can't land in
/// only one of them and let a read and a write disagree about the same
/// note.
pub fn isKeyLine(line: []const u8, key: []const u8) bool {
    return std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == ':';
}

/// A column-0 `key: value` line's key and raw (still-quoted) value, or
/// null for a nested/continuation line (leading space or tab), a line
/// with no `:`, or an empty key. For a caller that classifies every
/// top-level line by key rather than looking up one specific key -- that's
/// `isKeyLine`, above. Shared by `vault_query.frontmatterAsJson` and
/// `patch.documentMap`'s frontmatter-key listing.
pub const KeyValue = struct { key: []const u8, value: []const u8 };
pub fn topLevelKeyValue(line: []const u8) ?KeyValue {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return null;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = std.mem.trim(u8, line[0..colon], " ");
    if (key.len == 0) return null;
    return .{ .key = key, .value = std.mem.trim(u8, line[colon + 1 ..], " ") };
}

/// Same lookup as `field`, but never reads past what it has to.
///
/// `field` takes an already-fully-read `[]const u8` -- every caller that only
/// has a file handle already paid for a full read before calling it. This
/// walks `reader` a line at a time and returns the moment `key` or the
/// closing `---` is seen, so a lookup against a node whose frontmatter runs
/// to hundreds of lines (a code-graph node's `sources:` block, say) costs
/// only however many lines precede the match -- restoring the old
/// `synapse-query.sh` `cmd_field()`'s streaming-with-early-exit behavior that
/// the awk implementation had and the whole-string version above lost.
///
/// Correct for any field order on its own; a caller only sees the speedup
/// this exists for when the key it wants sits before whatever else is in the
/// frontmatter -- see `emit.zig`'s field-order comment for where that's made
/// a real contract for the one format this matters most for.
pub fn fieldStreaming(reader: *std.Io.Reader, key: []const u8) !?[]const u8 {
    const first = (try reader.takeDelimiter('\n')) orelse return null;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), "---")) return null;

    while (try reader.takeDelimiter('\n')) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "---")) return null;
        if (!isKeyLine(line, key)) continue;
        return stripOneQuote(std.mem.trimStart(u8, line[key.len + 1 ..], " \t"));
    }
    return null;
}

/// One leading and one trailing `"`, no more.
///
/// `gsub(/^"|"$/, "")` strips at most one at each end, because `^"` can only match
/// at position zero and `"$` only at the end. Trimming *all* quotes instead would
/// eat the closing quote of a value ending in an escaped one -- `"ends with \""`
/// would come back missing a character, and nothing downstream could tell.
fn stripOneQuote(raw: []const u8) []const u8 {
    var s = raw;
    if (s.len != 0 and s[0] == '"') s = s[1..];
    if (s.len != 0 and s[s.len - 1] == '"') s = s[0 .. s.len - 1];
    return s;
}

/// One frontmatter scalar as a *YAML reader* would see it: escapes resolved.
///
/// `field` deliberately does not do this. Its output is `query field`'s stdout,
/// which has to stay byte-identical to the `awk` that only ever stripped the outer
/// quotes -- so a value containing `\"` printed with the backslash, and callers
/// depend on that.
///
/// This is for the one caller that needs the value rather than the text:
/// `build-project-index` reads each node's `summary` and writes it into the index's
/// prose. It used to get it from the API's JsonLogic search, which parses the YAML,
/// so the round trip was already lossless -- reading from disk instead means doing
/// the unescaping here or silently regressing it. `tests/synapse-build-project-index.bats`
/// pins the case: `Handles "quoted" input and a C:\path.`
///
/// Only what the writer produces is undone (`\\` and `\"`), because that is the
/// only escaping any of these files contain -- `emit.writeYamlQuoted` is the sole
/// writer of a quoted scalar here. A general YAML unescaper would be a second
/// implementation of someone else's spec.
pub fn scalar(gpa: std.mem.Allocator, text: []const u8, key: []const u8) !?[]u8 {
    var it = FrontmatterIterator.init(text);
    while (it.next()) |line| {
        if (!isKeyLine(line, key)) continue;
        const raw = std.mem.trimStart(u8, line[key.len + 1 ..], " \t");
        // Unquoted scalars carry no escapes: a bare `project: fw-core` means what
        // it says, and unescaping it would be inventing a rule.
        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"')
            return try gpa.dupe(u8, raw);

        const inner = raw[1 .. raw.len - 1];
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            if (inner[i] == '\\' and i + 1 < inner.len and
                (inner[i + 1] == '\\' or inner[i + 1] == '"'))
            {
                i += 1;
            }
            try out.append(gpa, inner[i]);
        }
        return try out.toOwnedSlice(gpa);
    }
    return null;
}

/// The `sources:` block's `- path:` values, in file order.
///
/// Scoped to that block specifically, and the script's comment explains what
/// goes wrong otherwise: `grounded_in:` entries are also `- path:` pairs in the
/// same frontmatter, and a grounded_in path is required to already be one of the
/// node's own sources -- so an unscoped match double-counts it. The same path
/// hashed twice joins into a digest that never matches what the writer stored,
/// and that false "content changed" fires for every node using grounded_in.
pub fn sources(
    gpa: std.mem.Allocator,
    text: []const u8,
) !std.ArrayListUnmanaged([]const u8) {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);

    var in_sources = false;
    var it = FrontmatterIterator.init(text);
    while (it.next()) |line| {
        // A line starting with a letter or underscore at column zero is a new
        // top-level key, which either opens the block or closes it.
        if (line.len != 0 and (std.ascii.isAlphabetic(line[0]) or line[0] == '_')) {
            in_sources = std.mem.eql(u8, line, "sources:");
            continue;
        }
        if (!in_sources) continue;
        if (parseDashPath(line)) |p| try out.append(gpa, p);
    }
    return out;
}

/// `  - path: X` with any leading whitespace, or null for any other line.
fn parseDashPath(line: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, rest, "-")) return null;
    rest = std.mem.trimStart(u8, rest[1..], " \t");
    if (!std.mem.startsWith(u8, rest, "path:")) return null;
    return std.mem.trimStart(u8, rest["path:".len..], " \t");
}

/// A `module <TAB> count` row.
pub const ModuleCount = struct {
    module: []const u8,
    count: usize,
};

/// Source paths grouped by module, byte-sorted by module name.
///
/// The script piped `module_of` per path into `sort | uniq -c`, which is why the
/// order is the module name's and not the count's -- `sources --modules` is read
/// as a table, not a ranking.
pub fn moduleCounts(
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    chains: []const []const u8,
) ![]ModuleCount {
    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    defer counts.deinit(gpa);
    for (paths) |p| {
        if (p.len == 0) continue;
        const gop = try counts.getOrPut(gpa, node_mod.moduleOf(p, chains));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var out = try gpa.alloc(ModuleCount, counts.count());
    var i: usize = 0;
    var it = counts.iterator();
    while (it.next()) |e| : (i += 1) out[i] = .{ .module = e.key_ptr.*, .count = e.value_ptr.* };
    std.mem.sort(ModuleCount, out, {}, struct {
        fn less(_: void, a: ModuleCount, b: ModuleCount) bool {
            return std.mem.order(u8, a.module, b.module) == .lt;
        }
    }.less);
    return out;
}

/// One `## Links` edge.
pub const Edge = struct {
    relation: []const u8,
    target: []const u8,
};

/// The outbound edges of one node, in file order.
///
/// A line is an edge when it is `- <relation> [[<target>]]`. The relation is
/// everything between the dash and the wikilink; the target is what the brackets
/// hold, with any display text after a `|` left intact because the script left it
/// intact -- a `[[Target|shown]]` link names `Target|shown` as far as this is
/// concerned, and no real node uses one.
pub fn edges(
    gpa: std.mem.Allocator,
    text: []const u8,
) !std.ArrayListUnmanaged(Edge) {
    var out: std.ArrayListUnmanaged(Edge) = .empty;
    errdefer out.deinit(gpa);

    var in_links = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "## Links")) {
            in_links = true;
            continue;
        }
        // Any following `## ` heading ends the section -- `## Sources` in
        // practice, and the awk `exit`ed there rather than reading on.
        if (in_links and std.mem.startsWith(u8, line, "## ")) break;
        if (!in_links) continue;
        if (parseEdge(line)) |e| try out.append(gpa, e);
    }
    return out;
}

fn parseEdge(line: []const u8) ?Edge {
    if (!std.mem.startsWith(u8, line, "-")) return null;
    const after_dash = std.mem.trimStart(u8, line[1..], " \t");
    const open = std.mem.indexOf(u8, after_dash, "[[") orelse return null;
    const close = std.mem.indexOfPos(u8, after_dash, open + 2, "]]") orelse return null;
    const relation = std.mem.trim(u8, after_dash[0..open], " \t");
    // The awk's pattern required a non-space relation before the link, so a bare
    // `- [[Target]]` with no relation is not an edge. Keeping that: a link with
    // no relation says nothing about *how* two nodes relate, which is the only
    // thing this table is for.
    if (relation.len == 0) return null;
    const target = after_dash[open + 2 .. close];
    if (target.len == 0) return null;
    return .{ .relation = relation, .target = target };
}

/// Walks the frontmatter, yielding its lines and leaving `after` pointing at the
/// body.
///
/// A node whose first line is not `---` has no frontmatter at all, and then every
/// field lookup is null rather than a scan of the prose -- which is what the
/// awk's `NR == 1 && $0 == "---"` guard bought.
pub const FrontmatterIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    open: bool,
    after: []const u8,

    pub fn init(text: []const u8) FrontmatterIterator {
        const has_fm = std.mem.startsWith(u8, text, "---\n");
        return .{
            .lines = std.mem.splitScalar(u8, if (has_fm) text[4..] else text, '\n'),
            .open = has_fm,
            .after = if (has_fm) text[4..] else text,
        };
    }

    pub fn next(self: *FrontmatterIterator) ?[]const u8 {
        if (!self.open) return null;
        while (self.lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (std.mem.eql(u8, line, "---")) {
                self.open = false;
                self.after = self.lines.rest();
                return null;
            }
            return line;
        }
        self.open = false;
        self.after = "";
        return null;
    }
};

const testing = std.testing;

const sample =
    \\---
    \\title: "State machine"
    \\node_type: synapse-node
    \\project: fw-core
    \\sources:
    \\  - path: statemachine/src/main/java/com/x/State.java
    \\    hash: 1111111111111111111111111111111111111111
    \\  - path: statemachine/src/main/java/com/x/Transition.java
    \\    hash: 2222222222222222222222222222222222222222
    \\grounded_in:
    \\  - path: statemachine/src/main/java/com/x/State.java
    \\    lines: 1-2
    \\    hash: 3333333333333333333333333333333333333333
    \\sources_digest: "df91a06710f61130522fcd990f82488c047cec570419a31a34ebb3c4c14a7526"
    \\stale: false
    \\built_at: "2026-08-03 16:50"
    \\---
    \\
    \\# State machine
    \\<!-- synapse:generated:start -->
    \\
    \\## Summary
    \\Prose about it.
    \\
    \\## Links
    \\- uses [[Service framework — ServiceContext]]
    \\- part_of [[Framework]]
    \\
    \\## Sources
    \\- `statemachine` (2)
    \\<!-- synapse:generated:end -->
    \\
    \\## Notes
    \\hand written
    \\
;

test "body is what sits between the fences, minus the two marker lines" {
    const b = body(sample).?;
    // The blank line after the start marker survives, because `sed '1d'` deletes
    // the marker *line* and nothing else.
    try testing.expect(std.mem.startsWith(u8, b, "\n## Summary"));
    try testing.expect(std.mem.endsWith(u8, b, "- `statemachine` (2)"));
    // The two things being between the fences buys, rather than reading after
    // the frontmatter: no `title:` and no `## Notes`.
    try testing.expect(std.mem.indexOf(u8, b, "title:") == null);
    try testing.expect(std.mem.indexOf(u8, b, "hand written") == null);
}

test "an unfenced node has no body, so the caller can say so" {
    try testing.expectEqual(@as(?[]const u8, null), body("---\ntitle: x\n---\n\n# T\n\nold style\n"));
    // And the fallback reads everything after the frontmatter, `## Notes` and all
    // -- which is why the script announced it on stderr.
    const after = bodyAfterFrontmatter("---\ntitle: x\n---\n\n# T\n\nold style\n");
    try testing.expectEqualStrings("\n# T\n\nold style\n", after);
}

test "field takes one scalar and strips its quotes" {
    try testing.expectEqualStrings("State machine", field(sample, "title").?);
    try testing.expectEqualStrings("synapse-node", field(sample, "node_type").?);
    try testing.expectEqualStrings("false", field(sample, "stale").?);
    try testing.expectEqualStrings("2026-08-03 16:50", field(sample, "built_at").?);
}

test "an absent field is null, not an error" {
    try testing.expectEqual(@as(?[]const u8, null), field(sample, "crux_path"));
    try testing.expectEqual(@as(?[]const u8, null), field(sample, "nonsense"));
}

test "a field lookup matches a whole key, not a suffix of one" {
    // `index($0, k ":") == 1` was an anchored match. A query for `at` must not
    // find `built_at:`, and one for `title` must not find `subtitle:`.
    try testing.expectEqual(@as(?[]const u8, null), field(sample, "at"));
    try testing.expectEqual(@as(?[]const u8, null), field(sample, "ources"));
}

test "a field is never read from the body" {
    // The frontmatter ends at the closing `---`, so prose that happens to look
    // like a key is not one. `stale: false` also appears as a decoy in the real
    // fixture the bats suite uses.
    const decoy = "---\ntitle: real\n---\n\n# T\ntitle: fake\n";
    try testing.expectEqualStrings("real", field(decoy, "title").?);
}

test "a node with no frontmatter yields no fields at all" {
    try testing.expectEqual(@as(?[]const u8, null), field("# Just prose\ntitle: nope\n", "title"));
}

test "fieldStreaming finds the same value field does, from a reader instead of a string" {
    var r: std.Io.Reader = .fixed(sample);
    try testing.expectEqualStrings("State machine", (try fieldStreaming(&r, "title")).?);
}

test "fieldStreaming matches a whole key, not a suffix of one" {
    var r: std.Io.Reader = .fixed(sample);
    try testing.expectEqual(@as(?[]const u8, null), try fieldStreaming(&r, "at"));
}

test "fieldStreaming returns null for an absent key once the closing --- is seen" {
    var r: std.Io.Reader = .fixed(sample);
    try testing.expectEqual(@as(?[]const u8, null), try fieldStreaming(&r, "nonsense"));
}

test "fieldStreaming never reads a key that only appears in the body" {
    var r: std.Io.Reader = .fixed("---\ntitle: real\n---\n\n# T\ntitle: fake\n");
    try testing.expectEqualStrings("real", (try fieldStreaming(&r, "title")).?);
}

test "fieldStreaming on a node with no frontmatter at all returns null" {
    var r: std.Io.Reader = .fixed("# Just prose\ntitle: nope\n");
    try testing.expectEqual(@as(?[]const u8, null), try fieldStreaming(&r, "title"));
}

test "sources takes only the sources block, never grounded_in's paths" {
    // The failure this exists to prevent: a grounded_in path is required to
    // already be one of the node's sources, so an unscoped `- path:` match
    // returns it twice. The same path hashed twice makes a digest that can never
    // equal what the writer stored, and every node using grounded_in reports a
    // false "content changed" forever.
    const gpa = testing.allocator;
    var got = try sources(gpa, sample);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try testing.expectEqualStrings("statemachine/src/main/java/com/x/State.java", got.items[0]);
    try testing.expectEqualStrings("statemachine/src/main/java/com/x/Transition.java", got.items[1]);
}

test "sources is empty for a node that claims none" {
    const gpa = testing.allocator;
    var got = try sources(gpa, "---\ntitle: t\nsources:\n---\n\n# T\n");
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), got.items.len);
}

test "module counts are keyed by module and sorted by its name" {
    const gpa = testing.allocator;
    const chains = [_][]const u8{"src/main/java"};
    const rows = try moduleCounts(gpa, &.{
        "b/src/main/java/X.java",
        "a/src/main/java/Y.java",
        "a/src/main/java/Z.java",
        "docs/readme.md",
    }, &chains);
    defer gpa.free(rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("a", rows[0].module);
    try testing.expectEqual(@as(usize, 2), rows[0].count);
    try testing.expectEqualStrings("b", rows[1].module);
    try testing.expectEqualStrings("docs", rows[2].module);
}

test "edges are the Links section only, and stop at the next heading" {
    const gpa = testing.allocator;
    var got = try edges(gpa, sample);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try testing.expectEqualStrings("uses", got.items[0].relation);
    try testing.expectEqualStrings("Service framework — ServiceContext", got.items[0].target);
    try testing.expectEqualStrings("part_of", got.items[1].relation);
    try testing.expectEqualStrings("Framework", got.items[1].target);
}

test "a link with no relation is not an edge" {
    // The awk required a non-space relation before the wikilink. A bare link says
    // nothing about *how* two nodes relate, which is the only thing the table is
    // for -- and `## Sources` rows are `- \`module\` (n)`, which must not parse
    // as edges either.
    const gpa = testing.allocator;
    var got = try edges(gpa, "## Links\n- [[Target]]\n- `mod` (3)\n- uses [[Real]]\n");
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqualStrings("Real", got.items[0].target);
}

test "a node with no Links section has no edges" {
    const gpa = testing.allocator;
    var got = try edges(gpa, "# T\n\n## Summary\nprose\n\n## Sources\n- `a` (1)\n");
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), got.items.len);
}

test "field strips one quote at each end, not every quote" {
    const text = "---\ntitle: \"ends with a quote \\\"\"\nother: plain\n---\n";
    // The escaped quote survives, because only the outer pair is structural. Trimming
    // all quotes would return `ends with a quote \\` and lose a character silently.
    try testing.expectEqualStrings("ends with a quote \\\"", field(text, "title").?);
    try testing.expectEqualStrings("plain", field(text, "other").?);
}

test "scalar resolves the escaping field deliberately leaves alone" {
    const gpa = testing.allocator;
    // The case `tests/synapse-build-project-index.bats` pins: a summary with a
    // quoted phrase and a Windows path, stored escaped by the writer.
    const text = "---\nsummary: \"Handles \\\"quoted\\\" input and a C:\\\\path.\"\n---\n";
    const got = (try scalar(gpa, text, "summary")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("Handles \"quoted\" input and a C:\\path.", got);
    // And `field` still returns the text, escapes and all -- that is `query field`'s
    // frozen output.
    try testing.expectEqualStrings("Handles \\\"quoted\\\" input and a C:\\\\path.", field(text, "summary").?);
}

test "an unquoted scalar is returned as written" {
    const gpa = testing.allocator;
    const text = "---\nproject: fw-core\ncommit: 0123abc\n---\n";
    const p = (try scalar(gpa, text, "project")).?;
    defer gpa.free(p);
    try testing.expectEqualStrings("fw-core", p);
    try testing.expectEqual(@as(?[]u8, null), try scalar(gpa, text, "absent"));
}

test "isKeyLine anchors at column zero, not a substring match anywhere in the line" {
    try testing.expect(isKeyLine("title: State machine", "title"));
    try testing.expect(!isKeyLine("subtitle: nope", "title"));
    try testing.expect(!isKeyLine("built_at: 2026-08-03", "at"));
    try testing.expect(!isKeyLine("title", "title")); // no colon at all
    try testing.expect(!isKeyLine("titles: [a, b]", "title")); // key is a prefix, not the whole key
}

test "topLevelKeyValue splits a column-0 line, and skips nested/continuation lines" {
    const kv = topLevelKeyValue("tags: [synapse, vault-infra]").?;
    try testing.expectEqualStrings("tags", kv.key);
    try testing.expectEqualStrings("[synapse, vault-infra]", kv.value);

    try testing.expectEqual(@as(?KeyValue, null), topLevelKeyValue("  - path: src/main.zig"));
    try testing.expectEqual(@as(?KeyValue, null), topLevelKeyValue("\tindented: value"));
    try testing.expectEqual(@as(?KeyValue, null), topLevelKeyValue("no colon here"));
    try testing.expectEqual(@as(?KeyValue, null), topLevelKeyValue(""));
}
