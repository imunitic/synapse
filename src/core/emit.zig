//! Emitting a node: the directives a body carries, and the bytes that come out.
//!
//! `synapse-write-node.sh`'s shape, and its central rule: **the body points, the
//! writer slices**. A body carries
//!
//! ```
//! <!-- crux: crates/matcher/src/lib.rs 412-419 -->
//! <!-- grounded_in: src/main/java/Foo.java 10-14 -->
//! ```
//!
//! and never the code itself, so a crux cannot be a paraphrase of the source that
//! merely looks like a quote. An HTML comment because an unexpanded directive then
//! renders as nothing rather than as a broken code block.
//!
//! The two directives diverge after slicing, and deliberately. A crux is *display*:
//! the slice is fenced into the body with a provenance line under it. A grounding is
//! *provenance*: only `path`, `lines` and the slice's sha256 reach frontmatter, and
//! the directive is stripped from the body -- six groundings rendered as six code
//! blocks would bury the prose a human came for.
//!
//! ## What lives here and what cannot
//!
//! Everything that is a function of text: finding directives, parsing them,
//! validating a range against a claimed path list and a line count, guessing a
//! fence language, trimming the body, escaping a YAML scalar, and assembling the
//! note. Reading files, hashing blobs with git, resolving the namespace and PUTting
//! the result are the command's, because they need the world.
//!
//! ## Why the range checks are refusals rather than warnings
//!
//! A crux path must be one the node claims, the range must be inside the file, and
//! it must be short. All three refuse the write instead of degrading it, because
//! each one silently produces a plausible node: code the node does not cover,
//! a slice of a file that has since shrunk, or a whole function where a decision
//! was asked for. A node nobody can distrust is worse than a write that failed.

const std = @import("std");
const node = @import("node.zig");
const query = @import("query.zig");
const verify = @import("verify.zig");

const Range = verify.Range;

/// A filename Obsidian can store, and the reason a caller must compare it to the
/// title it came from.
///
/// Obsidian resolves a wikilink by filename, so a sanitised title silently breaks
/// every inbound `[[link]]`. That is why this returns the sanitised form for the
/// caller to *compare* rather than quietly renaming: the script warns, and the
/// warning is the whole value of the step.
pub fn fileTitle(gpa: std.mem.Allocator, title: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, title);
    for (out) |*c| {
        if (std.mem.indexOfScalar(u8, "/:*?\"<>|", c.*) != null) c.* = '_';
    }
    return out;
}

/// A `path start-end` directive argument, already parsed.
pub const Span = struct {
    path: []const u8,
    start: usize,
    end: usize,

    pub fn lines(self: Span) usize {
        return self.end - self.start + 1;
    }

    pub fn range(self: Span) Range {
        return .{ .start = self.start, .end = self.end };
    }
};

/// What a `crux:` directive said. `none` is a real answer, not a missing one: a
/// node whose logic is spread across files says so, and gets a rendered line
/// saying so, rather than being refused.
pub const Crux = union(enum) {
    none,
    span: Span,
};

pub const kind_crux = "crux";
pub const kind_grounded = "grounded_in";

/// The first `<!-- <keyword>: … -->` in `body`, returned whole.
///
/// The whole comment, because substitution is by *line containing this text* --
/// the awk matched `index($0, marker)` -- and the caller needs the same bytes back
/// to find that line again.
pub fn findDirective(body: []const u8, keyword: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, "<!--")) |open| {
        const close = std.mem.indexOfPos(u8, body, open, "-->") orelse return null;
        const inner = body[open + 4 .. close];
        if (directiveArg(inner, keyword) != null) return body[open .. close + 3];
        at = open + 4;
    }
    return null;
}

/// Every `<!-- <keyword>: … -->` in `body`, in order. `grounded_in` is repeatable.
pub fn directives(body: []const u8, keyword: []const u8) DirectiveIterator {
    return .{ .body = body, .at = 0, .keyword = keyword };
}

pub const DirectiveIterator = struct {
    body: []const u8,
    at: usize,
    keyword: []const u8,

    /// Yields the whole comment, like `findDirective`.
    pub fn next(self: *DirectiveIterator) ?[]const u8 {
        while (std.mem.indexOfPos(u8, self.body, self.at, "<!--")) |open| {
            const close = std.mem.indexOfPos(u8, self.body, open, "-->") orelse return null;
            self.at = open + 4;
            if (directiveArg(self.body[open + 4 .. close], self.keyword) != null)
                return self.body[open .. close + 3];
        }
        return null;
    }
};

/// The part after `<keyword>:`, trimmed, or null if this comment is a different
/// directive (or not one at all).
///
/// `inner` is the comment's contents, without `<!--` and `-->`. Note that a
/// grounding's keyword contains the crux's nowhere, so no keyword can shadow
/// another -- but the `:` is required, so a comment reading `cruxes are nice`
/// is prose and not a malformed directive.
pub fn directiveArg(inner: []const u8, keyword: []const u8) ?[]const u8 {
    const s = std.mem.trimStart(u8, inner, " \t");
    if (!std.mem.startsWith(u8, s, keyword)) return null;
    const rest = s[keyword.len..];
    if (rest.len == 0 or rest[0] != ':') return null;
    return std.mem.trim(u8, rest[1..], " \t");
}

/// Parse a directive argument into a span.
///
/// `L` prefixes are tolerated on either bound, because that is how a line range
/// is written everywhere a human copies one from (GitHub, an editor's gutter).
/// They are stripped from the whole range rather than from each bound, which is
/// what `${range//L/}` did.
///
/// A range like `10-20-30` reads as `10`..`30`: the first bound ends at the first
/// dash and the last begins after the last one, matching `%%-*` and `##*-`. Not a
/// case worth an error, and inventing one would make this stricter than the script
/// it replaces.
pub fn parseSpan(arg: []const u8) ?Span {
    // The path ends at the first whitespace and the range begins after the last,
    // so an argument with no whitespace at all has no range and is malformed --
    // which is exactly what `[[ "$crux_path" != "$crux_arg" ]]` tested.
    const first_ws = std.mem.indexOfAny(u8, arg, " \t") orelse return null;
    const path = arg[0..first_ws];
    if (path.len == 0) return null;
    const last_ws = std.mem.lastIndexOfAny(u8, arg, " \t").?;
    const raw_range = arg[last_ws + 1 ..];

    var buf: [64]u8 = undefined;
    if (raw_range.len > buf.len) return null;
    var n: usize = 0;
    for (raw_range) |c| {
        if (c == 'L') continue;
        buf[n] = c;
        n += 1;
    }
    const rng = buf[0..n];

    const first_dash = std.mem.indexOfScalar(u8, rng, '-') orelse return null;
    const last_dash = std.mem.lastIndexOfScalar(u8, rng, '-').?;
    const start = parseDigits(rng[0..first_dash]) orelse return null;
    const end = parseDigits(rng[last_dash + 1 ..]) orelse return null;
    return .{ .path = path, .start = start, .end = end };
}

/// `=~ ^[0-9]+$`: digits only, no sign and no leading `+`, which `parseInt` would
/// otherwise accept and turn a typo into a valid range.
fn parseDigits(s: []const u8) ?usize {
    if (s.len == 0) return null;
    for (s) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

/// Which directive a span came from, and therefore how long it may be.
pub const Kind = enum {
    crux,
    grounded,

    /// The most lines a span of this kind may carry.
    ///
    /// A grounding is roomier than a crux on purpose: a doc comment or a test body
    /// is legitimately longer than the few lines that carry a decision.
    pub fn cap(self: Kind) usize {
        return switch (self) {
            .crux => 20,
            .grounded => 40,
        };
    }

    pub fn keyword(self: Kind) []const u8 {
        return switch (self) {
            .crux => kind_crux,
            .grounded => kind_grounded,
        };
    }
};

pub const SpanProblem = union(enum) {
    /// The path is not in the node's own source list.
    not_claimed,
    /// Outside `1..total`, or `end` before `start`.
    out_of_range: usize,
    /// Longer than the kind's cap; carries the actual line count.
    too_long: usize,
};

/// `paths` must be byte-sorted and deduplicated, as `LC_ALL=C sort -u` left it.
///
/// `total_lines` is `wc -l`, which is a newline count -- see `wcLines`. Using the
/// same definition as the script matters at exactly one boundary: a final line with
/// no trailing newline is not countable, so a range ending on it is refused here
/// as it was there.
pub fn checkSpan(
    span: Span,
    kind: Kind,
    paths: []const []const u8,
    total_lines: usize,
) ?SpanProblem {
    if (!claims(paths, span.path)) return .not_claimed;
    if (span.start < 1 or span.end < span.start or span.end > total_lines)
        return .{ .out_of_range = total_lines };
    if (span.lines() > kind.cap()) return .{ .too_long = span.lines() };
    return null;
}

fn claims(paths: []const []const u8, path: []const u8) bool {
    // `grep -qxF` over a sorted list; binary search because a hub node claims
    // hundreds of paths and this runs once per directive.
    var lo: usize = 0;
    var hi: usize = paths.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, paths[mid], path)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return true,
        }
    }
    return false;
}

/// `wc -l`: the number of newlines, not the number of lines a reader would count.
///
/// A file whose last line has no terminator reports one fewer than it displays.
/// Reproduced rather than corrected: the range checks and this count have to agree
/// with each other, and the script's pairing of `wc -l` with `sed -n 'a,bp'` is
/// already what every existing node was validated against.
pub fn wcLines(content: []const u8) usize {
    return std.mem.count(u8, content, "\n");
}

/// The fence language for a crux block, by extension. Empty when unknown, which
/// produces a bare ``` fence rather than a guess.
pub fn languageFor(path: []const u8) []const u8 {
    const table = [_]struct { ext: []const u8, lang: []const u8 }{
        .{ .ext = ".java", .lang = "java" },
        .{ .ext = ".kt", .lang = "kotlin" },
        .{ .ext = ".kts", .lang = "kotlin" },
        .{ .ext = ".rs", .lang = "rust" },
        .{ .ext = ".py", .lang = "python" },
        .{ .ext = ".ts", .lang = "typescript" },
        .{ .ext = ".tsx", .lang = "typescript" },
        .{ .ext = ".js", .lang = "javascript" },
        .{ .ext = ".mjs", .lang = "javascript" },
        .{ .ext = ".cjs", .lang = "javascript" },
        .{ .ext = ".go", .lang = "go" },
        .{ .ext = ".rb", .lang = "ruby" },
        .{ .ext = ".sh", .lang = "bash" },
        .{ .ext = ".bash", .lang = "bash" },
        .{ .ext = ".ml", .lang = "ocaml" },
        .{ .ext = ".mli", .lang = "ocaml" },
        .{ .ext = ".sql", .lang = "sql" },
        .{ .ext = ".xml", .lang = "xml" },
        .{ .ext = ".yml", .lang = "yaml" },
        .{ .ext = ".yaml", .lang = "yaml" },
        .{ .ext = ".json", .lang = "json" },
    };
    for (table) |e| if (std.mem.endsWith(u8, path, e.ext)) return e.lang;
    return "";
}

/// What replaces a `crux:` directive line: a fenced slice and a provenance line.
///
/// `sliced` is `verify.slice`'s output, so it ends with a newline unless the file
/// did not. The closing fence is printed on its own line either way, which is what
/// `printf` after `sed` produced.
pub fn writeCruxBlock(w: *std.Io.Writer, span: Span, sliced: []const u8) !void {
    try w.print("```{s}\n", .{languageFor(span.path)});
    try w.writeAll(sliced);
    if (sliced.len > 0 and sliced[sliced.len - 1] != '\n') try w.writeAll("\n");
    try w.writeAll("```\n");
    // An em dash, and the path in backticks: the line is provenance under the
    // block, not prose, and it is what a later reader re-slices from.
    try w.print("— `{s}`:{d}-{d}\n", .{ span.path, span.start, span.end });
}

/// The line a `<!-- crux: none -->` expands to.
pub const crux_none_text = "_No single span carries this node's logic._";

/// Replace the whole line containing `marker` with `replacement`.
///
/// The line, not the marker: a directive shares its line with nothing, and
/// replacing only the comment would leave a stray blank line where an author had
/// indented it.
pub fn substituteLine(
    gpa: std.mem.Allocator,
    body: []const u8,
    marker: []const u8,
    replacement: []const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var done = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        if (!done and std.mem.indexOf(u8, line, marker) != null) {
            // The replacement carries its own trailing newline; the separator
            // logic above adds the one after it.
            try out.appendSlice(gpa, std.mem.trimEnd(u8, replacement, "\n"));
            done = true;
            continue;
        }
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

/// Drop every `grounded_in` directive from the body.
///
/// Two passes, as in the script: a line that is *only* a directive disappears
/// entirely, and a directive embedded in a line of prose is cut out of it. The
/// distinction matters -- deleting the whole line in the second case would delete
/// the sentence around it.
pub fn stripGrounded(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (onlyDirective(trimmed, kind_grounded)) continue;
        if (!first) try out.append(gpa, '\n');
        first = false;

        var rest = line;
        while (std.mem.indexOf(u8, rest, "<!--")) |open| {
            const close = std.mem.indexOfPos(u8, rest, open, "-->") orelse break;
            if (directiveArg(rest[open + 4 .. close], kind_grounded) == null) {
                try out.appendSlice(gpa, rest[0 .. close + 3]);
                rest = rest[close + 3 ..];
                continue;
            }
            try out.appendSlice(gpa, rest[0..open]);
            rest = rest[close + 3 ..];
        }
        try out.appendSlice(gpa, rest);
    }
    return out.toOwnedSlice(gpa);
}

fn onlyDirective(trimmed_line: []const u8, keyword: []const u8) bool {
    if (!std.mem.startsWith(u8, trimmed_line, "<!--")) return false;
    if (!std.mem.endsWith(u8, trimmed_line, "-->")) return false;
    const inner = trimmed_line[4 .. trimmed_line.len - 3];
    // A single directive and nothing else: `-->` may not appear inside, or the
    // line holds two comments and the tail of it is not a directive at all.
    if (std.mem.indexOf(u8, inner, "-->") != null) return false;
    return directiveArg(inner, keyword) != null;
}

/// The body with leading and trailing blank lines removed.
///
/// Idempotence, not tidiness: a body is recovered from a node and written back on
/// every reseat, and the writer puts a blank line on each side of it. Without this
/// a node accretes one more blank line per rebuild, forever.
pub fn trimBlankEdges(body: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = body.len;
    // Leading: skip whole lines that are whitespace only.
    while (start < end) {
        const nl = std.mem.indexOfScalarPos(u8, body, start, '\n') orelse break;
        if (std.mem.trim(u8, body[start..nl], " \t\r").len != 0) break;
        start = nl + 1;
    }
    // Trailing: the same from the other side, tolerating a missing final newline.
    while (end > start) {
        const line_start = if (std.mem.lastIndexOfScalar(u8, body[start..end], '\n')) |nl|
            start + nl + 1
        else
            start;
        if (std.mem.trim(u8, body[line_start..end], " \t\r").len != 0) break;
        if (line_start == start) return "";
        end = line_start - 1;
    }
    return body[start..end];
}

/// A YAML double-quoted scalar's contents.
///
/// Backslash before quote, or the escaping escapes itself. A summary is prose and
/// will eventually contain both.
pub fn writeYamlQuoted(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        else => try w.writeByte(c),
    };
}

/// The crux's own pointer, recorded alongside the sliced text.
///
/// Named rather than anonymous for the reason `verify.Range` is: an anonymous
/// struct is a distinct type per declaration, so a caller building one cannot
/// assign it to a field declared with the same shape.
pub const CruxPointer = struct {
    path: []const u8,
    /// `start-end`, as `crux_lines` stores it.
    lines: []const u8,
};

/// One `grounded_in:` row, as it goes into frontmatter.
pub const Grounded = struct {
    path: []const u8,
    /// `start-end`, unquoted here and quoted by the writer.
    lines: []const u8,
    /// sha256 of the slice. `digest:`, never `hash:` -- the `sources:` entries
    /// above it use `hash:`, and a reader that confuses the two finds nothing.
    digest: []const u8,
};

/// Everything the note is made of, already computed.
pub const Note = struct {
    title: []const u8,
    summary: []const u8,
    project: []const u8,
    branch: []const u8,
    /// Byte-sorted and deduplicated, paired with their blob hashes.
    sources: []const node.Source,
    /// 64 hex characters from `node.sourcesDigest`.
    digest: []const u8,
    built_at: []const u8,
    /// Omitted, not empty, when HEAD does not resolve -- nothing is committed yet,
    /// and a `commit:` field that is present but blank would be read as a baseline.
    commit: ?[]const u8,
    crux: ?CruxPointer,
    grounded: []const Grounded,
    /// Already grouped and byte-sorted by module name.
    modules: []const query.ModuleCount,
    /// Expanded, stripped, and about to be trimmed.
    body: []const u8,
    /// Everything after the closing fence of the *existing* node, with trailing
    /// newlines already dropped. Null (or empty) starts a fresh `## Notes`.
    ///
    /// This is the whole reason a rebuild is safe: the generated region is
    /// replaced and this is re-emitted verbatim, so hand-written notes survive a
    /// regeneration nobody reviews.
    tail: ?[]const u8,
};

pub fn writeNote(w: *std.Io.Writer, n: Note) !void {
    try w.writeAll("---\n");
    try w.print("title: \"{s}\"\n", .{n.title});
    try w.writeAll("summary: \"");
    try writeYamlQuoted(w, n.summary);
    try w.writeAll("\"\n");
    try w.writeAll("node_type: synapse-node\n");
    // Repo and branch as separate fields, matching the namespace's own Index.md:
    // the combined key is already the folder these live in, and splitting them is
    // what lets a query ask for every branch's copy of one node.
    try w.print("project: {s}\n", .{n.project});
    try w.print("branch: {s}\n", .{n.branch});
    try w.writeAll("sources:\n");
    for (n.sources) |s| try w.print("  - path: {s}\n    hash: {s}\n", .{ s.path, s.hash });
    try w.print("sources_digest: {s}\n", .{n.digest});
    try w.writeAll("stale: false\n");
    try w.print("built_at: \"{s}\"\n", .{n.built_at});
    if (n.commit) |c| try w.print("commit: {s}\n", .{c});
    if (n.crux) |c| {
        // The pointer as well as the sliced text: this is what lets a later check
        // re-slice the same range and compare, rather than trust the stored quote.
        try w.print("crux_path: {s}\n", .{c.path});
        try w.print("crux_lines: \"{s}\"\n", .{c.lines});
    }
    if (n.grounded.len > 0) {
        try w.writeAll("grounded_in:\n");
        for (n.grounded) |g|
            try w.print("  - path: {s}\n    lines: \"{s}\"\n    digest: {s}\n", .{ g.path, g.lines, g.digest });
    }
    try w.writeAll("---\n\n");

    try w.print("# {s}\n", .{n.title});
    try w.writeAll(node.generated_start ++ "\n\n");
    const trimmed = trimBlankEdges(n.body);
    try w.writeAll(trimmed);
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] != '\n') try w.writeAll("\n");
    try w.writeAll("\n## Sources\n");
    for (n.modules) |m| try w.print("- `{s}` ({d})\n", .{ m.module, m.count });
    try w.writeAll(node.generated_end ++ "\n");
    if (n.tail) |t| {
        if (t.len > 0) {
            try w.writeAll(t);
            try w.writeAll("\n");
            return;
        }
    }
    try w.writeAll("\n## Notes\n\n");
}

const testing = std.testing;

test "a title is sanitised for the filename, and only where it must be" {
    const gpa = testing.allocator;
    const clean = try fileTitle(gpa, "World — entity core");
    defer gpa.free(clean);
    // An em dash is legal in a filename and is left alone: sanitising it would
    // break the wikilink for nothing.
    try testing.expectEqualStrings("World — entity core", clean);

    const dirty = try fileTitle(gpa, "a/b:c*d?e\"f<g>h|i");
    defer gpa.free(dirty);
    try testing.expectEqualStrings("a_b_c_d_e_f_g_h_i", dirty);
}

test "a directive is found whole, so the caller can match its line again" {
    const body = "prose\n<!-- crux: src/a.java 10-12 -->\nmore\n";
    try testing.expectEqualStrings(
        "<!-- crux: src/a.java 10-12 -->",
        findDirective(body, kind_crux).?,
    );
    try testing.expectEqual(@as(?[]const u8, null), findDirective(body, kind_grounded));
}

test "a comment that is not a directive is prose" {
    // The `:` is required, so a comment merely mentioning the word is left alone.
    try testing.expectEqual(@as(?[]const u8, null), findDirective("<!-- cruxes are nice -->", kind_crux));
    try testing.expectEqual(@as(?[]const u8, null), findDirective("<!-- TODO -->", kind_crux));
}

test "a span parses, with L prefixes tolerated on either bound" {
    const s = parseSpan("src/a.java 412-419").?;
    try testing.expectEqualStrings("src/a.java", s.path);
    try testing.expectEqual(@as(usize, 412), s.start);
    try testing.expectEqual(@as(usize, 419), s.end);
    try testing.expectEqual(@as(usize, 8), s.lines());

    const l = parseSpan("src/a.java L10-L12").?;
    try testing.expectEqual(@as(usize, 10), l.start);
    try testing.expectEqual(@as(usize, 12), l.end);
}

test "a malformed span is rejected rather than guessed at" {
    // No whitespace at all: no range, which is the `$crux_path != $crux_arg` test.
    try testing.expectEqual(@as(?Span, null), parseSpan("src/a.java"));
    try testing.expectEqual(@as(?Span, null), parseSpan("src/a.java 412"));
    try testing.expectEqual(@as(?Span, null), parseSpan("src/a.java abc-def"));
    // A sign is not a digit run: `+5` would otherwise parse and turn a typo into
    // a valid range.
    try testing.expectEqual(@as(?Span, null), parseSpan("src/a.java +5-9"));
}

test "a three-bound range reads as first to last, like the shell expansions" {
    const s = parseSpan("f.java 10-20-30").?;
    try testing.expectEqual(@as(usize, 10), s.start);
    try testing.expectEqual(@as(usize, 30), s.end);
}

test "the caps differ by kind, and the count reported is inclusive" {
    const paths = [_][]const u8{"a.java"};
    // 20 lines exactly is allowed; 21 is not.
    try testing.expectEqual(
        @as(?SpanProblem, null),
        checkSpan(.{ .path = "a.java", .start = 1, .end = 20 }, .crux, &paths, 100),
    );
    const too = checkSpan(.{ .path = "a.java", .start = 1, .end = 21 }, .crux, &paths, 100).?;
    try testing.expectEqual(@as(usize, 21), too.too_long);

    // A grounding of the same length is fine -- a doc comment is longer than a
    // decision.
    try testing.expectEqual(
        @as(?SpanProblem, null),
        checkSpan(.{ .path = "a.java", .start = 1, .end = 40 }, .grounded, &paths, 100),
    );
}

test "a span must be claimed and must fit the file" {
    const paths = [_][]const u8{ "a.java", "b.java", "c.java" };
    try testing.expectEqual(
        @as(?SpanProblem, .not_claimed),
        checkSpan(.{ .path = "z.java", .start = 1, .end = 2 }, .crux, &paths, 100),
    );
    const past = checkSpan(.{ .path = "b.java", .start = 99, .end = 101 }, .crux, &paths, 100).?;
    try testing.expectEqual(@as(usize, 100), past.out_of_range);
    try testing.expect(checkSpan(.{ .path = "b.java", .start = 5, .end = 4 }, .crux, &paths, 100) != null);
}

test "wcLines counts newlines, so an unterminated last line is not one" {
    try testing.expectEqual(@as(usize, 3), wcLines("a\nb\nc\n"));
    try testing.expectEqual(@as(usize, 2), wcLines("a\nb\nc"));
    try testing.expectEqual(@as(usize, 0), wcLines(""));
}

test "the fence language comes from the extension, or is absent" {
    try testing.expectEqualStrings("java", languageFor("x/Foo.java"));
    try testing.expectEqualStrings("kotlin", languageFor("build.gradle.kts"));
    try testing.expectEqualStrings("bash", languageFor("bin/run.sh"));
    try testing.expectEqualStrings("ocaml", languageFor("lib/x.mli"));
    // Unknown stays empty: a bare fence is honest, a guessed language is not.
    try testing.expectEqualStrings("", languageFor("Makefile"));
    try testing.expectEqualStrings("", languageFor("notes.paramvo"));
}

test "a crux block is the fence, the slice, and a provenance line" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeCruxBlock(&out.writer, .{ .path = "a/b.java", .start = 4, .end = 5 }, "  int x = 1;\n  return x;\n");
    try testing.expectEqualStrings(
        "```java\n  int x = 1;\n  return x;\n```\n— `a/b.java`:4-5\n",
        out.written(),
    );
}

test "a slice with no trailing newline still closes its fence on its own line" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeCruxBlock(&out.writer, .{ .path = "a.txt", .start = 1, .end = 1 }, "last line");
    try testing.expectEqualStrings("```\nlast line\n```\n— `a.txt`:1-1\n", out.written());
}

test "substitution replaces the whole line the directive sat on" {
    const gpa = testing.allocator;
    const body = "## Crux\n  <!-- crux: a.java 1-2 -->\nafter\n";
    const got = try substituteLine(gpa, body, "<!-- crux: a.java 1-2 -->", "```\nx\n```\n");
    defer gpa.free(got);
    // The indentation goes with the line: leaving it would put a stray two spaces
    // where the author had indented the comment.
    try testing.expectEqualStrings("## Crux\n```\nx\n```\nafter\n", got);
}

test "only the first directive is substituted" {
    const gpa = testing.allocator;
    const got = try substituteLine(gpa, "<!-- m -->\n<!-- m -->\n", "<!-- m -->", "X\n");
    defer gpa.free(got);
    try testing.expectEqualStrings("X\n<!-- m -->\n", got);
}

test "a grounding on its own line disappears; one inside prose is cut out" {
    const gpa = testing.allocator;
    const body =
        "## Summary\n" ++
        "  <!-- grounded_in: a.java 10-14 -->\n" ++
        "It holds <!-- grounded_in: b.java 1-2 --> because of the test.\n" ++
        "end\n";
    const got = try stripGrounded(gpa, body);
    defer gpa.free(got);
    try testing.expectEqualStrings(
        "## Summary\nIt holds  because of the test.\nend\n",
        got,
    );
}

test "stripping leaves other comments alone" {
    const gpa = testing.allocator;
    const got = try stripGrounded(gpa, "<!-- keep me -->\n<!-- grounded_in: a 1-2 -->\n");
    defer gpa.free(got);
    try testing.expectEqualStrings("<!-- keep me -->\n", got);
}

test "blank edges are trimmed so a reseat is idempotent" {
    try testing.expectEqualStrings("## Summary\nx", trimBlankEdges("\n\n  \n## Summary\nx\n\n \n"));
    try testing.expectEqualStrings("x", trimBlankEdges("x"));
    try testing.expectEqualStrings("", trimBlankEdges("\n \n\t\n"));
    try testing.expectEqualStrings("", trimBlankEdges(""));
}

test "a summary is escaped for a double-quoted YAML scalar" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    // Backslash first, then quote: escaping the quote first would then escape its
    // own escape.
    try writeYamlQuoted(&out.writer, "a \"quoted\" path C:\\x");
    try testing.expectEqualStrings("a \\\"quoted\\\" path C:\\\\x", out.written());
}

const sample_sources = [_]node.Source{
    .{ .path = "a/A.java", .hash = "1111111111111111111111111111111111111111" },
    .{ .path = "b/B.java", .hash = "2222222222222222222222222222222222222222" },
};
const sample_modules = [_]query.ModuleCount{
    .{ .module = "a", .count = 1 },
    .{ .module = "b", .count = 1 },
};

fn baseNote() Note {
    return .{
        .title = "State machine",
        .summary = "How states advance",
        .project = "fw-core",
        .branch = "master",
        .sources = &sample_sources,
        .digest = "df91a067",
        .built_at = "2026-08-12 18:00",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .crux = null,
        .grounded = &.{},
        .modules = &sample_modules,
        .body = "## Summary\nprose\n",
        .tail = null,
    };
}

test "a fresh node gets an empty Notes section" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeNote(&out.writer, baseNote());
    try testing.expectEqualStrings(
        \\---
        \\title: "State machine"
        \\summary: "How states advance"
        \\node_type: synapse-node
        \\project: fw-core
        \\branch: master
        \\sources:
        \\  - path: a/A.java
        \\    hash: 1111111111111111111111111111111111111111
        \\  - path: b/B.java
        \\    hash: 2222222222222222222222222222222222222222
        \\sources_digest: df91a067
        \\stale: false
        \\built_at: "2026-08-12 18:00"
        \\commit: 0123456789abcdef0123456789abcdef01234567
        \\---
        \\
        \\# State machine
        \\<!-- synapse:generated:start -->
        \\
        \\## Summary
        \\prose
        \\
        \\## Sources
        \\- `a` (1)
        \\- `b` (1)
        \\<!-- synapse:generated:end -->
        \\
        \\## Notes
        \\
        \\
    , out.written());
}

test "an existing tail is re-emitted instead of a fresh Notes section" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var n = baseNote();
    n.tail = "\n## Notes\nhand written, must survive";
    try writeNote(&out.writer, n);
    try testing.expect(std.mem.endsWith(
        u8,
        out.written(),
        node.generated_end ++ "\n\n## Notes\nhand written, must survive\n",
    ));
}

test "an absent commit omits the field rather than writing an empty one" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var n = baseNote();
    n.commit = null;
    try writeNote(&out.writer, n);
    // A present-but-blank `commit:` would read as a baseline and `drift` would
    // try to diff against it.
    try testing.expect(std.mem.indexOf(u8, out.written(), "commit:") == null);
}

test "crux and grounded_in fields appear only when there are any" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var n = baseNote();
    n.crux = .{ .path = "a/A.java", .lines = "10-12" };
    n.grounded = &.{
        .{ .path = "a/A.java", .lines = "1-4", .digest = "aaaa" },
        .{ .path = "b/B.java", .lines = "7-9", .digest = "bbbb" },
    };
    try writeNote(&out.writer, n);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "crux_path: a/A.java\ncrux_lines: \"10-12\"\n") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        text,
        "grounded_in:\n  - path: a/A.java\n    lines: \"1-4\"\n    digest: aaaa\n",
    ) != null);
}

test "a recovered body written back produces the same bytes" {
    // The property the blank-line trim exists for: a reseat recovers a body from a
    // node and writes it back, and the second write must be byte-identical to the
    // first. Without the trim the body gains a blank line on each side per rebuild,
    // forever, and nobody reviews a regeneration.
    //
    // What `query.body` returns is everything *between the fences*, which includes
    // the generated `## Sources` mirror -- so a caller reseating a body drops that
    // section first, exactly as done here. The mirror is computed from the path
    // list on every write and is not authored content.
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var n = baseNote();
    n.body = "## Summary\nprose\n\n## Links\n- uses [[Other]]\n";
    try writeNote(&out.writer, n);

    const recovered = query.body(out.written()).?;
    const authored = recovered[0 .. std.mem.lastIndexOf(u8, recovered, "\n## Sources\n") orelse recovered.len];

    var again: std.Io.Writer.Allocating = .init(gpa);
    defer again.deinit();
    var m = n;
    m.body = authored;
    try writeNote(&again.writer, m);
    try testing.expectEqualStrings(out.written(), again.written());
}

/// Rewrite the one `stale:` line in the frontmatter to `stale: true`.
///
/// Returns false when nothing changed -- already true, or no frontmatter to touch
/// -- so a caller can skip the write and not churn a file's mtime on every edit.
///
/// **Not** `PATCH -H "Target-Type: frontmatter"`, and this is the sharpest edge in
/// the whole system. That call is not field-local: it re-serialises the entire YAML
/// block, stripping quotes from every value, folding long `title:` lines across two
/// lines, and YAML-coercing anything that looks like another type. Verified
/// 2026-08-03 on a node-shaped fixture: an all-digit `hash` became
/// `1.1111111111111112e+39`, unrecoverably. A corrupted hash makes `sources_digest`
/// disagree with its own `sources` forever, so that is a permanent false positive
/// no rebuild can clear.
///
/// Rewriting one line leaves every other byte -- including the exhaustive `sources`
/// list, megabytes of it on a hub node -- untouched.
pub fn setStaleTrue(w: *std.Io.Writer, text: []const u8) !bool {
    // No frontmatter at all: nothing to flag, and inventing a block would turn a
    // hand-written file into something the readers would then trust.
    if (!std.mem.startsWith(u8, text, "---\n")) return false;

    var changed = false;
    var done = false;
    var in_fm = false;
    var first = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (first) {
            first = false;
            in_fm = true;
            try w.print("{s}\n", .{line});
            continue;
        }
        if (in_fm and std.mem.eql(u8, line, "---")) {
            // Absent `stale:` is added just before the closing marker rather than
            // skipped: a node built before the field existed still has to be
            // flaggable.
            if (!done) {
                try w.writeAll("stale: true\n");
                done = true;
                changed = true;
            }
            in_fm = false;
            try w.print("{s}\n", .{line});
            continue;
        }
        if (in_fm and !done and std.mem.startsWith(u8, line, "stale:")) {
            try w.writeAll("stale: true\n");
            done = true;
            if (!std.mem.eql(u8, std.mem.trim(u8, line["stale:".len..], " \t"), "true"))
                changed = true;
            continue;
        }
        // The final split piece after a trailing newline is empty and must not
        // become an extra line.
        if (lines.index == null and line.len == 0) break;
        try w.print("{s}\n", .{line});
    }
    return changed;
}

/// The text inside ``` fences, concatenated -- the node's own copy of its crux.
///
/// `awk '/^```/ { f = !f; next } f { print }'`: a toggle, not a parser, so a node
/// with several fenced blocks yields all of them. No digest is stored for a crux --
/// the sliced text lives in the note -- so this is the stored side of the
/// comparison against the file as it is now.
pub fn fencedText(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var inside = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            inside = !inside;
            continue;
        }
        if (!inside) continue;
        if (lines.index == null and line.len == 0) break;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "setStaleTrue rewrites one line and leaves every other byte alone" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const text =
        "---\ntitle: \"T\"\nsources:\n  - path: a\n    hash: 1111111111\nstale: false\n---\n\n# T\nbody\n";
    try testing.expect(try setStaleTrue(&out.writer, text));
    try testing.expectEqualStrings(
        "---\ntitle: \"T\"\nsources:\n  - path: a\n    hash: 1111111111\nstale: true\n---\n\n# T\nbody\n",
        out.written(),
    );
}

test "an already-stale node reports no change, so no write happens" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const text = "---\ntitle: \"T\"\nstale: true\n---\n\nbody\n";
    try testing.expect(!try setStaleTrue(&out.writer, text));
    // The output is still the whole file, so a caller that writes anyway is correct
    // -- it is just churning an mtime for nothing.
    try testing.expectEqualStrings(text, out.written());
}

test "a node with no stale field gains one before the closing marker" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expect(try setStaleTrue(&out.writer, "---\ntitle: \"T\"\n---\nbody\n"));
    try testing.expectEqualStrings("---\ntitle: \"T\"\nstale: true\n---\nbody\n", out.written());
}

test "a file with no frontmatter is left alone entirely" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expect(!try setStaleTrue(&out.writer, "# Just prose\nstale: false\n"));
    // Nothing written: the caller compares and skips, and a `stale:` line in the
    // body is not frontmatter.
    try testing.expectEqualStrings("", out.written());
}

test "fencedText is the toggle the awk was, not a parser" {
    const gpa = testing.allocator;
    const with_crux =
        "# T\n## Crux\n```java\nint x = 1;\nreturn x;\n```\n— `a.java`:4-5\n";
    const got = try fencedText(gpa, with_crux);
    defer gpa.free(got);
    try testing.expectEqualStrings("int x = 1;\nreturn x;\n", got);
}

test "several fenced blocks all contribute, as the toggle implies" {
    const gpa = testing.allocator;
    const got = try fencedText(gpa, "```\na\n```\ntext\n```\nb\n```\n");
    defer gpa.free(got);
    try testing.expectEqualStrings("a\nb\n", got);
}
