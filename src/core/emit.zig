//! Emitting a node: the directives a body carries, and the bytes that come out.
//!
//! Central rule: **the body points, the writer slices**. A body carries
//!
//! ```
//! <!-- crux: crates/matcher/src/lib.rs 412-419 -->
//! <!-- grounded_in: src/main/java/Foo.java 10-14 -->
//! ```
//!
//! never the code itself, so a crux can't be a paraphrase that merely looks
//! like a quote. HTML comments so an unexpanded directive renders as nothing
//! rather than a broken code block.
//!
//! The two diverge after slicing: a crux is *display* (fenced into the body
//! with a provenance line under it); a grounding is *provenance* (only
//! `path`/`lines`/sha256 reach frontmatter, directive stripped from the body
//! -- six groundings as six code blocks would bury the prose).
//!
//! Everything here is a function of text: finding/parsing directives,
//! validating a range, guessing a fence language, trimming the body,
//! escaping YAML, assembling the note. Reading files, hashing with git,
//! resolving the namespace and PUTting the result are the command's job --
//! they need the world.
//!
//! Range checks (claimed path, in-file, short) refuse the write rather than
//! degrade it: each would otherwise produce a plausible node that's wrong --
//! code the node doesn't cover, a slice of a shrunk file, a whole function
//! where a decision was asked for. A node nobody can distrust is worse than
//! a write that failed.

const std = @import("std");
const node = @import("node.zig");
const query = @import("query.zig");
const verify = @import("verify.zig");

const Range = verify.Range;

/// A filename the vault can store. A wikilink resolves by filename,
/// so a sanitised title silently breaks every inbound `[[link]]` -- this
/// returns the sanitised form for the caller to *compare* and warn on,
/// rather than quietly renaming.
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

/// What a `crux:` directive said. `none` is a real answer: a node whose
/// logic is spread across files says so and gets a rendered line, rather
/// than being refused.
pub const Crux = union(enum) {
    none,
    span: Span,
};

pub const kind_crux = "crux";
pub const kind_grounded = "grounded_in";

/// The first `<!-- <keyword>: … -->` in `body`, returned whole -- the caller
/// needs the same bytes back to find its line again.
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

/// The text under a `## {heading}` heading, up to the next `## ` heading or
/// the generated-region end marker -- whichever comes first. Null if the
/// heading itself isn't present. Same anchoring `query.edges` uses for
/// `## Links`: only a line that is exactly the heading counts, never a
/// substring match, so `## Crux` doesn't also match a hypothetical
/// `## Cruxes and caveats`.
///
/// Exists so a directive search can be scoped to the one section it
/// legitimately lives in (`crux`, which only ever appears under `## Crux`)
/// instead of the whole body, where prose describing the directive syntax
/// elsewhere would otherwise be indistinguishable from the real thing.
pub fn section(body: []const u8, heading: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "## {s}", .{heading}) catch return null;

    var offset: usize = 0;
    var content_start: ?usize = null;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (content_start) |start| {
            if (std.mem.startsWith(u8, line, "## ") or std.mem.eql(u8, line, node.generated_end))
                return body[start..offset];
        } else if (std.mem.eql(u8, line, marker)) {
            content_start = offset + raw.len + 1;
        }
        offset += raw.len + 1;
    }
    return if (content_start) |start| body[@min(start, body.len)..body.len] else null;
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

/// The part after `<keyword>:`, trimmed, or null if this comment is a
/// different directive (or not one at all). `:` is required, so `cruxes are
/// nice` is prose, not a malformed directive.
pub fn directiveArg(inner: []const u8, keyword: []const u8) ?[]const u8 {
    const s = std.mem.trimStart(u8, inner, " \t");
    if (!std.mem.startsWith(u8, s, keyword)) return null;
    const rest = s[keyword.len..];
    if (rest.len == 0 or rest[0] != ':') return null;
    return std.mem.trim(u8, rest[1..], " \t");
}

/// Parse a directive argument into a span. `L` prefixes are tolerated on
/// either bound (how a range is copied from GitHub or an editor gutter). A
/// range like `10-20-30` reads as `10`..`30` -- not worth an error.
pub fn parseSpan(arg: []const u8) ?Span {
    // Path ends at the first whitespace, range begins after the last -- no
    // whitespace at all means no range, and is malformed.
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

/// Digits only -- no sign, no leading `+` (which `parseInt` would accept and
/// turn a typo into a valid range).
fn parseDigits(s: []const u8) ?usize {
    if (s.len == 0) return null;
    for (s) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

/// Which directive a span came from, and therefore how long it may be.
pub const Kind = enum {
    crux,
    grounded,

    /// Most lines a span of this kind may carry. A grounding is roomier on
    /// purpose -- a doc comment or test body is legitimately longer than the
    /// few lines that carry a decision.
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

/// `paths` must be byte-sorted and deduplicated. `total_lines` is a newline
/// count (see `wcLines`): a final line with no trailing newline isn't
/// countable, so a range ending on it is refused.
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
    // Binary search: a hub node claims hundreds of paths, once per directive.
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

/// Newline count, not the number of lines a reader would count -- a file
/// whose last line has no terminator reports one fewer than it displays.
/// Matches how the range checks count, so the two agree.
pub fn wcLines(content: []const u8) usize {
    return std.mem.count(u8, content, "\n");
}

/// The fence language for a crux block, by extension. Empty when unknown,
/// for a bare ``` fence rather than a guess.
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
        .{ .ext = ".zig", .lang = "zig" },
    };
    for (table) |e| if (std.mem.endsWith(u8, path, e.ext)) return e.lang;
    return "";
}

/// What replaces a `crux:` directive line: a fenced slice and a provenance
/// line. `sliced` ends with a newline unless the file didn't; the closing
/// fence always gets its own line either way.
///
/// `lang` is the caller's resolved fence language (`""` for none) --
/// usually `fence_languages.Registry.languageFor(span.path)`, or plain
/// `languageFor(span.path)` where nothing has a reason to be customizable.
/// Reading a conf file needs the world, which this module deliberately
/// never touches (see the module docstring).
pub fn writeCruxBlock(w: *std.Io.Writer, span: Span, sliced: []const u8, lang: []const u8) !void {
    try w.print("```{s}\n", .{lang});
    try w.writeAll(sliced);
    if (sliced.len > 0 and sliced[sliced.len - 1] != '\n') try w.writeAll("\n");
    try w.writeAll("```\n");
    try w.print("— `{s}`:{d}-{d}\n", .{ span.path, span.start, span.end }); // provenance, not prose
}

/// The line a `<!-- crux: none -->` expands to.
pub const crux_none_text = "_No single span carries this node's logic._";

/// Replace the whole line containing `marker` with `replacement` -- the
/// whole line, not just the directive, so an indented comment doesn't leave
/// a stray blank line behind.
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
            try out.appendSlice(gpa, std.mem.trimEnd(u8, replacement, "\n"));
            done = true;
            continue;
        }
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

/// Drop every `grounded_in` directive from the body. Two passes: a line
/// that's *only* a directive disappears entirely, one embedded in prose is
/// cut out of it without deleting the sentence around it.
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
    // No `-->` inside: otherwise the line holds two comments and the tail
    // isn't a directive at all.
    if (std.mem.indexOf(u8, inner, "-->") != null) return false;
    return directiveArg(inner, keyword) != null;
}

/// The body with leading and trailing blank lines removed. For idempotence:
/// a body is recovered from a node and written back on every reseat, and
/// without this it accretes a blank line per rebuild, forever.
pub fn trimBlankEdges(body: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = body.len;
    while (start < end) {
        const nl = std.mem.indexOfScalarPos(u8, body, start, '\n') orelse break;
        if (std.mem.trim(u8, body[start..nl], " \t\r").len != 0) break;
        start = nl + 1;
    }
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

/// A YAML double-quoted scalar's contents. Backslash before quote, or the
/// escaping escapes itself.
pub fn writeYamlQuoted(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        else => try w.writeByte(c),
    };
}

/// The crux's own pointer, recorded alongside the sliced text. Named (not
/// anonymous) so a caller building one can assign it to a same-shaped field.
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
    /// sha256 of the slice. `digest:`, never `hash:` -- `sources:` above it
    /// uses `hash:`, and confusing the two finds nothing.
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
    /// Omitted, not empty, when HEAD doesn't resolve -- a present-but-blank
    /// `commit:` would be read as a baseline.
    commit: ?[]const u8,
    crux: ?CruxPointer,
    grounded: []const Grounded,
    /// Already grouped and byte-sorted by module name.
    modules: []const query.ModuleCount,
    /// Expanded, stripped, and about to be trimmed.
    body: []const u8,
    /// Everything after the closing fence of the *existing* node, trailing
    /// newlines dropped. Null (or empty) starts a fresh `## Notes`. Re-
    /// emitted verbatim on every rewrite -- why hand-written notes survive a
    /// regeneration nobody reviews.
    tail: ?[]const u8,
};

/// Below this many source files, `## Sources` lists each path directly
/// instead of the module+count rollup -- a handful of files reads better
/// as an exact list than as `` `module` (1) `` rows that hide which file
/// it actually is.
const sources_path_threshold: usize = 5;

/// Frontmatter field order is a deliberate invariant, not incidental:
/// `title`/`summary`/`node_type`/`project`/`branch` -- small, and the ones a
/// single-key lookup asks for most -- are written before `sources:`, which
/// on a large real project can run to hundreds of `path`/`hash` pairs.
/// `core.query.fieldStreaming` stops at the first line matching the key it
/// wants, so a lookup for any of those five never reaches `sources:` at
/// all; reordering them after it would silently turn every such lookup
/// back into a near-full-file scan, with no test failure anywhere to catch
/// it except the one below that pins this order directly. The scan itself
/// stays correct for *any* order -- this is about keeping its good case a
/// guarantee instead of an accident.
pub fn writeNote(w: *std.Io.Writer, n: Note) !void {
    try w.writeAll("---\n");
    try w.print("title: \"{s}\"\n", .{n.title});
    try w.writeAll("summary: \"");
    try writeYamlQuoted(w, n.summary);
    try w.writeAll("\"\n");
    try w.writeAll("node_type: synapse-node\n");
    // Repo and branch separate, matching the namespace's Index.md, so a
    // query can ask for every branch's copy of one node.
    try w.print("project: {s}\n", .{n.project});
    try w.print("branch: {s}\n", .{n.branch});
    try w.writeAll("sources:\n");
    for (n.sources) |s| try w.print("  - path: {s}\n    hash: {s}\n", .{ s.path, s.hash });
    try w.print("sources_digest: {s}\n", .{n.digest});
    try w.writeAll("stale: false\n");
    try w.print("built_at: \"{s}\"\n", .{n.built_at});
    if (n.commit) |c| try w.print("commit: {s}\n", .{c});
    if (n.crux) |c| {
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
    if (n.sources.len < sources_path_threshold) {
        for (n.sources) |s| try w.print("- `{s}`\n", .{s.path});
    } else {
        for (n.modules) |m| try w.print("- `{s}` ({d})\n", .{ m.module, m.count });
    }
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
    try testing.expectEqualStrings("World — entity core", clean); // em dash is legal, left alone

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
    try testing.expectEqual(@as(?[]const u8, null), findDirective("<!-- cruxes are nice -->", kind_crux));
    try testing.expectEqual(@as(?[]const u8, null), findDirective("<!-- TODO -->", kind_crux));
}

test "section slices the text under a heading, stopping at the next ## or the generated-region end" {
    const body = "# Title\n## Summary\nprose\n## Crux\n<!-- crux: src/a.java 10-12 -->\n## Links\n- uses [[X]]\n";
    try testing.expectEqualStrings("<!-- crux: src/a.java 10-12 -->\n", section(body, "Crux").?);

    const at_body_start = "## Crux\n<!-- crux: none -->\n## Notes\n";
    try testing.expectEqualStrings("<!-- crux: none -->\n", section(at_body_start, "Crux").?);

    const to_generated_end = "## Crux\n<!-- crux: none -->\n" ++ node.generated_end ++ "\n\n## Notes\nhand written\n";
    try testing.expectEqualStrings("<!-- crux: none -->\n", section(to_generated_end, "Crux").?);

    const last_heading_no_trailing_content = "## Summary\nprose\n## Crux";
    try testing.expectEqualStrings("", section(last_heading_no_trailing_content, "Crux").?);
}

test "section returns null for a missing heading, and does not prefix-match a longer one" {
    try testing.expectEqual(@as(?[]const u8, null), section("## Summary\nprose\n", "Crux"));
    // "## Cruxes and caveats" is not "## Crux" -- a real heading elsewhere
    // must never be mistaken for the one being searched for.
    try testing.expectEqual(
        @as(?[]const u8, null),
        section("## Cruxes and caveats\nprose\n", "Crux"),
    );
}

test "a quoted directive outside ## Crux is not found once the search is scoped" {
    // The exact shape of the original bug report: a node whose ## Summary
    // quotes the directive syntax as a literal example, with the real
    // directive further down under ## Crux. A whole-body findDirective
    // would match the quoted one first; scoping to the Crux section first
    // means it never sees it.
    const body =
        "## Summary\n" ++
        "A crux directive looks like `<!-- crux: path/to/file.ext 10-20 -->` in prose.\n" ++
        "## Crux\n" ++
        "<!-- crux: src/real.zig 5-8 -->\n" ++
        "## Notes\n";
    const crux_section = section(body, "Crux").?;
    try testing.expectEqualStrings(
        "<!-- crux: src/real.zig 5-8 -->",
        findDirective(crux_section, kind_crux).?,
    );
    // The whole-body scan, unscoped, still finds the quoted one first --
    // confirming this test would have caught the original bug.
    try testing.expectEqualStrings(
        "<!-- crux: path/to/file.ext 10-20 -->",
        findDirective(body, kind_crux).?,
    );
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
    try testing.expectEqual(@as(?Span, null), parseSpan("src/a.java"));
    try testing.expectEqual(@as(?Span, null), parseSpan("src/a.java 412"));
    try testing.expectEqual(@as(?Span, null), parseSpan("src/a.java abc-def"));
    try testing.expectEqual(@as(?Span, null), parseSpan("src/a.java +5-9")); // sign is not a digit run
}

test "a three-bound range reads as first to last, like the shell expansions" {
    const s = parseSpan("f.java 10-20-30").?;
    try testing.expectEqual(@as(usize, 10), s.start);
    try testing.expectEqual(@as(usize, 30), s.end);
}

test "the caps differ by kind, and the count reported is inclusive" {
    const paths = [_][]const u8{"a.java"};
    try testing.expectEqual(
        @as(?SpanProblem, null),
        checkSpan(.{ .path = "a.java", .start = 1, .end = 20 }, .crux, &paths, 100),
    );
    const too = checkSpan(.{ .path = "a.java", .start = 1, .end = 21 }, .crux, &paths, 100).?;
    try testing.expectEqual(@as(usize, 21), too.too_long);

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
    try testing.expectEqualStrings("", languageFor("Makefile"));
    try testing.expectEqualStrings("", languageFor("notes.paramvo"));
}

test "a crux block is the fence, the slice, and a provenance line" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeCruxBlock(&out.writer, .{ .path = "a/b.java", .start = 4, .end = 5 }, "  int x = 1;\n  return x;\n", "java");
    try testing.expectEqualStrings(
        "```java\n  int x = 1;\n  return x;\n```\n— `a/b.java`:4-5\n",
        out.written(),
    );
}

test "a slice with no trailing newline still closes its fence on its own line" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeCruxBlock(&out.writer, .{ .path = "a.txt", .start = 1, .end = 1 }, "last line", "");
    try testing.expectEqualStrings("```\nlast line\n```\n— `a.txt`:1-1\n", out.written());
}

test "substitution replaces the whole line the directive sat on" {
    const gpa = testing.allocator;
    const body = "## Crux\n  <!-- crux: a.java 1-2 -->\nafter\n";
    const got = try substituteLine(gpa, body, "<!-- crux: a.java 1-2 -->", "```\nx\n```\n");
    defer gpa.free(got);
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
    try writeYamlQuoted(&out.writer, "a \"quoted\" path C:\\x"); // backslash first, or escaping escapes itself
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
        \\- `a/A.java`
        \\- `b/B.java`
        \\<!-- synapse:generated:end -->
        \\
        \\## Notes
        \\
        \\
    , out.written());
}

test "the small, frequently-queried scalar fields are written before the large sources list" {
    // Not the golden-content test above's job (that pins one whole note
    // byte-for-byte for an unrelated reason) -- this is specifically about
    // the order `core.query.fieldStreaming` depends on for its speedup,
    // pinned on its own so a reorder fails here with a message that says
    // what broke, not just as collateral damage in a bigger diff.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeNote(&out.writer, baseNote());

    const written = out.written();
    const title_pos = std.mem.indexOf(u8, written, "title:").?;
    const summary_pos = std.mem.indexOf(u8, written, "summary:").?;
    const node_type_pos = std.mem.indexOf(u8, written, "node_type:").?;
    const project_pos = std.mem.indexOf(u8, written, "project:").?;
    const branch_pos = std.mem.indexOf(u8, written, "branch:").?;
    const sources_pos = std.mem.indexOf(u8, written, "sources:").?;

    try testing.expect(title_pos < summary_pos);
    try testing.expect(summary_pos < node_type_pos);
    try testing.expect(node_type_pos < project_pos);
    try testing.expect(project_pos < branch_pos);
    try testing.expect(branch_pos < sources_pos);
}

test "## Sources lists paths directly below the threshold, and rolls up at or above it" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const below = baseNote(); // 2 sources, well under the threshold
    try writeNote(&out.writer, below);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\n## Sources\n- `a/A.java`\n- `b/B.java`\n") != null);

    const five_sources = [_]node.Source{
        .{ .path = "a/A.java", .hash = "1111111111111111111111111111111111111111" },
        .{ .path = "b/B.java", .hash = "2222222222222222222222222222222222222222" },
        .{ .path = "c/C.java", .hash = "3333333333333333333333333333333333333333" },
        .{ .path = "d/D.java", .hash = "4444444444444444444444444444444444444444" },
        .{ .path = "e/E.java", .hash = "5555555555555555555555555555555555555555" },
    };
    const five_modules = [_]query.ModuleCount{
        .{ .module = "a", .count = 1 },
        .{ .module = "b", .count = 1 },
        .{ .module = "c", .count = 1 },
        .{ .module = "d", .count = 1 },
        .{ .module = "e", .count = 1 },
    };
    var at_threshold = baseNote();
    at_threshold.sources = &five_sources;
    at_threshold.modules = &five_modules;
    out.clearRetainingCapacity();
    try writeNote(&out.writer, at_threshold);
    try testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "\n## Sources\n- `a` (1)\n- `b` (1)\n- `c` (1)\n- `d` (1)\n- `e` (1)\n",
    ) != null);
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
    // `query.body` returns everything between the fences, including the
    // generated `## Sources` mirror -- a reseat drops that section first,
    // as done here, before writing the body back.
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
/// Returns false when nothing changed (already true, or no frontmatter),
/// so a caller can skip the write.
///
/// **Not** `PATCH -H "Target-Type: frontmatter"` -- that re-serialises the
/// entire YAML block, stripping quotes, folding long lines, and coercing
/// values to other types: an all-digit `hash` becomes
/// `1.1111111111111112e+39`, unrecoverably, permanently desyncing
/// `sources_digest`. Rewriting one line leaves every other byte -- including
/// a megabyte `sources` list on a hub node -- untouched.
pub fn setStaleTrue(w: *std.Io.Writer, text: []const u8) !bool {
    if (!std.mem.startsWith(u8, text, "---\n")) return false; // no frontmatter, nothing to flag

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
            // Absent `stale:` is added just before the closing marker, so a
            // node built before the field existed is still flaggable.
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
        if (lines.index == null and line.len == 0) break; // trailing split piece, not an extra line
        try w.print("{s}\n", .{line});
    }
    return changed;
}

/// The text inside ``` fences, concatenated -- the node's own copy of its
/// crux. A toggle, not a parser, so several fenced blocks all contribute.
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

/// The hand-written `## Notes` body: what follows the closing fence, minus
/// its own heading and surrounding blank lines. `graph-wipe` uses it to ask
/// whether a node carries anything a rebuild can't regenerate. Empty means
/// nothing at risk.
pub fn notesBody(text: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, text, node.generated_end) orelse return "";
    var rest = text[at + node.generated_end.len ..];
    if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| rest = rest[nl + 1 ..] else return "";

    rest = skipBlankLines(rest);
    // The heading itself isn't content -- but a differently-worded heading
    // is, since something wrote it deliberately.
    if (std.mem.startsWith(u8, rest, "## Notes")) {
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        if (std.mem.trim(u8, rest[0..line_end], " \t\r").len == "## Notes".len)
            rest = if (line_end == rest.len) rest[rest.len..] else rest[line_end + 1 ..];
    }
    rest = skipBlankLines(rest);

    var end = rest.len;
    while (end > 0) {
        const line_start = if (std.mem.lastIndexOfScalar(u8, rest[0..end], '\n')) |nl|
            nl + 1
        else
            0;
        if (std.mem.trim(u8, rest[line_start..end], " \t\r").len != 0) break;
        if (line_start == 0) return "";
        end = line_start - 1;
    }
    return rest[0..end];
}

fn skipBlankLines(s: []const u8) []const u8 {
    var rest = s;
    while (rest.len != 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        if (std.mem.trim(u8, rest[0..nl], " \t\r").len != 0) break;
        if (nl == rest.len) return rest[rest.len..];
        rest = rest[nl + 1 ..];
    }
    return rest;
}

test "notesBody finds hand-written content and strips the scaffolding" {
    const written =
        "# T\n" ++ node.generated_start ++ "\nprose\n" ++ node.generated_end ++
        "\n\n## Notes\n\nThe thing nobody else knows.\nSecond line.\n\n";
    try testing.expectEqualStrings(
        "The thing nobody else knows.\nSecond line.",
        notesBody(written),
    );
}

test "an empty Notes section risks nothing" {
    try testing.expectEqualStrings("", notesBody(
        "# T\n" ++ node.generated_end ++ "\n\n## Notes\n\n",
    ));
    try testing.expectEqualStrings("", notesBody("# T\n" ++ node.generated_end ++ "\n"));
    try testing.expectEqualStrings("", notesBody("# T\nno fence here\n"));
}

test "content before the heading, or a different heading, still counts" {
    try testing.expectEqualStrings(
        "loose line",
        notesBody("# T\n" ++ node.generated_end ++ "\nloose line\n"),
    );
    try testing.expectEqualStrings(
        "## Other\nkept",
        notesBody("# T\n" ++ node.generated_end ++ "\n\n## Other\nkept\n"),
    );
}
