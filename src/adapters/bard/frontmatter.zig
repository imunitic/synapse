//! `synapse-bard`'s real `Extractor`, parsing bible entity frontmatter into
//! `def`/`ref` tags. See `src/adapters/frontmatter_conformance.zig` for
//! the proof-of-seam predecessor this is *not* extended from: that file's
//! YAML subset refuses past one level of nesting and has no
//! list-of-objects support, both of which real bible data needs
//! throughout (`relationships.key_relationships` is a list of `{name,
//! link, kinds, type, dynamic}` objects, three levels deep from root).
//!
//! ## The subset, and why it refuses rather than skips
//!
//! Same philosophy as the predecessor: scalars, block lists (bare-scalar or
//! list-of-objects), flow lists of scalars/wikilinks, arbitrary nested-map
//! depth, wikilink values -- anywhere, including more than one per scalar
//! string. Anchors, aliases, block scalars, flow maps, a second document,
//! tabs, and a flow list containing anything other than scalars/wikilinks
//! all refuse the whole file. A parser that skips unknowns becomes a bad
//! general YAML parser by accretion, silently dropping relationships from
//! notes that look fine; `.unsupported` is visible and recoverable, a
//! missing ref is neither.
//!
//! ## def/ref shape
//!
//! A `def` is the file's own identity: `name:` at the root, `kind` = the
//! root-level `template:` value (searched independently of field order, so
//! this doesn't assume `template:` precedes `name:` in the file). A `ref` is
//! every `[[wikilink]]` found by recursively scanning every scalar and list
//! value in the frontmatter tree -- `kind` is the dotted field path it came
//! from (`relationships.key_relationships.link`, `foreign_relations.enemies`),
//! never inferred about the *target*: resolving what kind of entity a ref
//! actually points at is the caller's job, from the target file's own
//! `template:` field, not this extractor's.
//!
//! `_templates/**`/`_planning/**` exclusion is a caller concern (which
//! `paths` this is invoked with), not this file's -- the `Extractor` port
//! only ever sees the paths it's handed.

const std = @import("std");
const model = @import("model");
const ports = @import("ports");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const BardFrontmatterExtractor = struct {
    /// The field naming the entity itself, at the frontmatter root.
    identity_field: []const u8 = "name",
    /// The field naming the entity's kind (its `template:` value).
    kind_field: []const u8 = "template",
    /// Transient: set by `refuse()`, read back by `extract()` immediately
    /// after `tagsFor()` returns `error.Refused`, before the next path in
    /// the batch can overwrite it. Not for external reads -- see
    /// `last_refusals` below for the per-path answer.
    current_refusal: ?Refusal = null,
    /// One reason per path from the most recent `extract()` call, `null`
    /// where that path parsed fine. `extract` is batch-shaped (many paths,
    /// one call) precisely so CLI startup cost is paid once -- a single
    /// scalar `last_refusal` would only ever reflect whichever path in the
    /// batch was refused last, not the one the caller is asking about.
    /// Owned by this extractor; freed and reallocated on the next
    /// `extract()` call, or by `deinit`.
    last_refusals: []?Refusal = &.{},

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

    /// One nested-map level on the path from root to whatever field is
    /// currently being read. `indent` is the column its own `key:` line
    /// started at -- popped once a later line's indent is no deeper.
    const Frame = struct {
        indent: usize,
        key: []const u8,
    };

    /// Refuse past this many nested-map levels -- a generous multiple of
    /// what real data actually needs (three: `relationships.key_relationships[].link`),
    /// kept as a safety valve against a runaway indentation bug rather than
    /// a real ceiling anyone should hit.
    const max_frames = 8;

    /// The wrapper idiom: `ports.Extractor.from` generates the
    /// `*anyopaque` cast from `BardFrontmatterExtractor` alone, so it can
    /// never disagree with `.ptr` the way a hand-written vtable literal
    /// could.
    pub fn port(self: *BardFrontmatterExtractor) ports.Extractor {
        return ports.Extractor.from(BardFrontmatterExtractor, self);
    }

    pub fn deinit(self: *BardFrontmatterExtractor, gpa: Allocator) void {
        if (self.last_refusals.len != 0) gpa.free(self.last_refusals);
        self.last_refusals = &.{};
    }

    pub fn extract(
        self: *BardFrontmatterExtractor,
        gpa: Allocator,
        io: Io,
        root: []const u8,
        paths: []const []const u8,
    ) anyerror![]ports.Extractor.Outcome {
        const out = try gpa.alloc(ports.Extractor.Outcome, paths.len);
        errdefer gpa.free(out);

        if (self.last_refusals.len != 0) gpa.free(self.last_refusals);
        self.last_refusals = try gpa.alloc(?Refusal, paths.len);
        @memset(self.last_refusals, null);

        for (paths, 0..) |p, i| {
            out[i] = .unsupported;

            if (!std.mem.endsWith(u8, p, ".md")) {
                self.last_refusals[i] = .not_a_note;
                continue;
            }

            const full = try std.fs.path.join(gpa, &.{ root, p });
            defer gpa.free(full);
            const src = Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(1 << 20)) catch continue;
            defer gpa.free(src);

            const tags = self.tagsFor(gpa, src) catch |e| {
                if (e == error.Refused) {
                    self.last_refusals[i] = self.current_refusal;
                    continue;
                }
                return e;
            };
            out[i] = .{ .tags = tags };
        }
        return out;
    }

    fn refuse(self: *BardFrontmatterExtractor, why: Refusal) error{Refused} {
        self.current_refusal = why;
        return error.Refused;
    }

    fn tagsFor(self: *BardFrontmatterExtractor, gpa: Allocator, src: []const u8) ![]model.Tag {
        var tags: std.ArrayListUnmanaged(model.Tag) = .empty;
        errdefer {
            for (tags.items) |t| freeTag(gpa, t);
            tags.deinit(gpa);
        }

        var lines = std.mem.splitScalar(u8, src, '\n');
        const first = lines.next() orelse return self.refuse(.no_frontmatter);
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), "---"))
            return self.refuse(.no_frontmatter);

        // Independent of field order: `template:` might not precede `name:`.
        const kind_value = try self.rootKindValue(gpa, src);
        defer if (kind_value) |k| gpa.free(k);

        var stack: std.ArrayListUnmanaged(Frame) = .empty;
        defer {
            for (stack.items) |f| gpa.free(f.key);
            stack.deinit(gpa);
        }

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
            const trimmed = std.mem.trim(u8, line, " ");
            if (trimmed.len == 0) continue;
            // A full-line YAML comment -- real templates use these as
            // section dividers (`# --- Identity ---`) throughout. Skipped
            // like a blank line: no structural meaning, no indent/dedent
            // effect. Only a comment-*only* line, not a trailing `# ...`
            // after real content on the same line -- not a pattern this
            // corpus uses, and stripping it unconditionally would break any
            // value that legitimately contains a `#`.
            if (trimmed[0] == '#') continue;

            const indent = line.len - std.mem.trimStart(u8, line, " ").len;
            var body = line[indent..];

            // Pop frames this line has dedented out of -- a frame's own
            // indent is where its `key:` line started, so a line at that
            // indent or shallower is no longer inside it.
            while (stack.items.len > 0 and stack.items[stack.items.len - 1].indent >= indent) {
                const popped = stack.pop().?;
                gpa.free(popped.key);
            }

            var is_list_item = false;
            if (std.mem.startsWith(u8, body, "- ")) {
                is_list_item = true;
                body = body[2..];
            } else if (std.mem.eql(u8, body, "-")) {
                // An empty list item -- nothing to scan, nothing to refuse.
                continue;
            }

            const colon = findTopLevelColon(body);
            if (colon == null) {
                // A bare scalar list entry: `- "[[x]]"` under whatever key
                // owns this list. Not a list item at all with no owning key
                // is a malformed line -- the same case the predecessor refused.
                if (!is_list_item) return self.refuse(.malformed_line);
                const parent = topKey(stack) orelse return self.refuse(.malformed_line);
                try self.scanValue(gpa, &tags, parent, body, row, line);
                continue;
            }

            const key = std.mem.trim(u8, body[0..colon.?], " ");
            if (key.len == 0) return self.refuse(.malformed_line);
            const value = std.mem.trim(u8, body[colon.? + 1 ..], " ");

            if (value.len == 0) {
                // Introduces a nested block -- a map, or a list this loop's
                // later iterations will walk into.
                if (stack.items.len >= max_frames) return self.refuse(.nesting_too_deep);
                try stack.append(gpa, .{ .indent = indent, .key = try gpa.dupe(u8, key) });
                continue;
            }

            switch (value[0]) {
                '&', '*' => return self.refuse(.anchor_or_alias),
                '|', '>' => return self.refuse(.block_scalar),
                '{' => {
                    // `key: {}` (or `key: { }`) -- an empty flow map,
                    // nothing to scan, nothing to refuse. Mirrors
                    // `scanFlowList`'s own tolerance for internal
                    // whitespace on `key: [ ]`; only a *non-empty* flow
                    // map (unsupported) still refuses.
                    if (!std.mem.endsWith(u8, value, "}")) return self.refuse(.flow_collection);
                    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " ");
                    if (inner.len != 0) return self.refuse(.flow_collection);
                    continue;
                },
                '[' => {
                    if (isWikilink(value)) {
                        // A single wikilink is also valid flow syntax
                        // (`[[Target]]`) -- scan it like any scalar rather
                        // than routing it through the list-splitter.
                    } else {
                        // `open_questions: [` routinely spans multiple
                        // physical lines in real data -- the `[` opens here,
                        // each element is its own line, `]` closes several
                        // lines later. Keep consuming lines until closed.
                        var buf: std.ArrayListUnmanaged(u8) = .empty;
                        defer buf.deinit(gpa);
                        try buf.appendSlice(gpa, value);
                        while (!hasTopLevelClose(buf.items)) {
                            const cont_raw = lines.next() orelse return self.refuse(.malformed_line);
                            row += 1;
                            const cont_line = std.mem.trimEnd(u8, cont_raw, "\r");
                            if (std.mem.indexOfScalar(u8, cont_line, '\t') != null) return self.refuse(.tab_indent);
                            const cont_trimmed = std.mem.trim(u8, cont_line, " ");
                            if (std.mem.eql(u8, cont_trimmed, "---")) return self.refuse(.malformed_line);
                            try buf.append(gpa, ' ');
                            try buf.appendSlice(gpa, cont_trimmed);
                        }
                        try self.scanFlowList(gpa, &tags, stack, key, buf.items, row, line);
                        continue;
                    }
                },
                else => {},
            }

            if (stack.items.len == 0 and std.mem.eql(u8, key, self.identity_field)) {
                try tags.append(gpa, .{
                    .name = try gpa.dupe(u8, unquote(value)),
                    .role = .def,
                    .kind = try gpa.dupe(u8, kind_value orelse "entity"),
                    .line = row,
                    .expression = try gpa.dupe(u8, line),
                });
                continue;
            }
            // The root-level kind field itself names no other entity.
            if (stack.items.len == 0 and std.mem.eql(u8, key, self.kind_field)) continue;

            const qualified = try joinPath(gpa, stack, key);
            defer gpa.free(qualified);
            try self.scanValue(gpa, &tags, qualified, value, row, line);
        }

        if (!closed) return self.refuse(.unterminated);
        while (lines.next()) |raw| {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, raw, "\r"), "---"))
                return self.refuse(.second_document);
        }
        return tags.toOwnedSlice(gpa);
    }

    /// Every `[[wikilink]]` substring in `value` becomes its own ref, tagged
    /// with `qualified_key` -- not just a value that's *entirely* one
    /// wikilink. Real data embeds more than one per scalar
    /// (`current_holder: "[[a|A]] (active), [[b|B]] (issued, never used)"`).
    fn scanValue(
        self: *BardFrontmatterExtractor,
        gpa: Allocator,
        tags: *std.ArrayListUnmanaged(model.Tag),
        qualified_key: []const u8,
        value: []const u8,
        row: u32,
        line: []const u8,
    ) !void {
        _ = self;
        const targets = try wikilinkTargets(gpa, unquote(value));
        defer {
            for (targets) |t| gpa.free(t);
            gpa.free(targets);
        }
        for (targets) |target| {
            try tags.append(gpa, .{
                .name = try gpa.dupe(u8, target),
                .role = .ref,
                .kind = try gpa.dupe(u8, qualified_key),
                .line = row,
                .expression = try gpa.dupe(u8, line),
            });
        }
    }

    /// `key: [elem, elem, ...]` -- a flow list. Every element must be a
    /// quoted or bare scalar (itself scanned for wikilinks the same as any
    /// other value) or the whole file refuses: this is deliberately not a
    /// general flow-collection parser, just enough for `tags: ["a", "b"]`,
    /// `kinds: ["romantic_interest", "teammate"]`, and an inline list of
    /// wikilink strings, all of which real data uses throughout.
    fn scanFlowList(
        self: *BardFrontmatterExtractor,
        gpa: Allocator,
        tags: *std.ArrayListUnmanaged(model.Tag),
        stack: std.ArrayListUnmanaged(Frame),
        key: []const u8,
        value: []const u8,
        row: u32,
        line: []const u8,
    ) !void {
        if (!std.mem.endsWith(u8, value, "]")) return self.refuse(.flow_collection);
        const inner = std.mem.trim(u8, value[1 .. value.len - 1], " ");
        if (inner.len == 0) return; // `key: []`

        const qualified = try joinPath(gpa, stack, key);
        defer gpa.free(qualified);

        var in_quote: ?u8 = null;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= inner.len) : (i += 1) {
            const at_end = i == inner.len;
            const c: u8 = if (at_end) ',' else inner[i];
            if (in_quote) |q| {
                if (c == q) in_quote = null;
                continue;
            }
            switch (c) {
                '"', '\'' => in_quote = c,
                '{', '[' => return self.refuse(.flow_collection),
                ',' => {
                    const elem = std.mem.trim(u8, inner[start..i], " ");
                    if (elem.len == 0) return self.refuse(.flow_collection);
                    if (!isScalarElement(elem)) return self.refuse(.flow_collection);
                    try self.scanValue(gpa, tags, qualified, elem, row, line);
                    start = i + 1;
                },
                else => {},
            }
        }
        if (in_quote != null) return self.refuse(.flow_collection);
    }

    /// Scans the raw source for a root-level (column-0) `kind_field:` line,
    /// independent of the main pass and its field order.
    fn rootKindValue(self: *BardFrontmatterExtractor, gpa: Allocator, src: []const u8) !?[]u8 {
        var lines = std.mem.splitScalar(u8, src, '\n');
        _ = lines.next(); // opening `---`
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (std.mem.eql(u8, line, "---")) break;
            if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..colon], " ");
            if (!std.mem.eql(u8, key, self.kind_field)) continue;
            const v = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (v.len == 0) return null;
            return try gpa.dupe(u8, unquote(v));
        }
        return null;
    }
};

/// Every `[[wikilink]]` substring in `text`, target only (before `|`),
/// in order of appearance, duplicates included -- callers dedupe if
/// they need to. Works line-agnostically, so the same function scans a
/// single frontmatter scalar or a whole multi-line prose body.
pub fn wikilinkTargets(gpa: Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |t| gpa.free(t);
        out.deinit(gpa);
    }

    var rest = text;
    while (std.mem.indexOf(u8, rest, "[[")) |start| {
        const after = rest[start + 2 ..];
        const end = std.mem.indexOf(u8, after, "]]") orelse break;
        const body = after[0..end];
        const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
        const target = std.mem.trim(u8, body[0..pipe], " ");
        if (target.len != 0) try out.append(gpa, try gpa.dupe(u8, target));
        rest = after[end + 2 ..];
    }
    return out.toOwnedSlice(gpa);
}

/// The whole frontmatter block, verbatim, from the opening `---` through the
/// closing `---` inclusive -- what `synapse-bard sync` writes into
/// `_bard/graph/{slug}.md`: a byte-for-byte copy of the source entity's own
/// frontmatter, prose body dropped, no re-serialization. A slice into `src`,
/// not a copy -- the caller owns `src`'s lifetime. `null` when `src` doesn't
/// open with `---` or the frontmatter never closes.
pub fn frontmatterBlock(src: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, src, '\n');
    const first = lines.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), "---")) return null;

    var end: usize = first.len + 1; // bytes consumed so far, including the '\n' splitScalar ate
    while (lines.next()) |raw| {
        end += raw.len + 1;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, raw, "\r"), "---")) {
            return src[0..@min(end, src.len)];
        }
    }
    return null;
}

/// Every root-level (column-0) frontmatter key name, in the order they
/// appear -- what `synapse-bard fields` lists so an
/// agent can see which `field <node> <key>` calls are worth making,
/// instead of guessing and taking clean misses one at a time. Meant for a
/// *template* file (`_templates/character_pov_template.md`, all fields
/// present with placeholder values) but works on any frontmatter block --
/// a `# --- Identity ---`-style full-line comment is skipped the same way
/// `tagsFor` skips one, and only column-0 keys count, so a nested block's
/// own sub-fields (`appearance.height`) don't appear as separate entries
/// -- `field <node> appearance` already returns that whole block, so the
/// root-level name is the right granularity to list.
///
/// Independent of `tagsFor`: never refuses, just returns text. `null` when
/// there's no frontmatter at all.
pub fn rootKeys(gpa: Allocator, src: []const u8) !?[][]const u8 {
    var lines = std.mem.splitScalar(u8, src, '\n');
    const first = lines.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), "---")) return null;

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |k| gpa.free(k);
        out.deinit(gpa);
    }

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "---")) break;
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " ");
        if (key.len == 0) continue;
        try out.append(gpa, try gpa.dupe(u8, key));
    }
    return try out.toOwnedSlice(gpa);
}

/// The raw YAML for one root-level frontmatter key, verbatim -- the `key:`
/// line itself plus every line indented deeper than column 0 below it,
/// until indentation returns to column 0 or the frontmatter closes. Not
/// parsed further: a scalar, a flow list, or a multi-line nested block all
/// come back exactly as written, so a caller (an LLM) reads the YAML
/// directly rather than this function re-deriving a structured shape for
/// every possible value type (`images:`'s list of `{path, description,
/// source}` objects being the case that motivated it -- an asset reference
/// with no wikilink in it at all, invisible to `tagsFor`'s def/ref walk by
/// design).
///
/// Independent of `tagsFor`: never refuses, since it isn't building the
/// graph, only returning text. `null` when the file has no frontmatter or
/// `key` doesn't appear at root level. Root-level keys only -- no dotted
/// nested-path lookup (`appearance.height`); add one only if that turns out
/// to be a real, hit-in-practice need, not speculatively.
pub fn rawField(gpa: Allocator, src: []const u8, key: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, src, '\n');
    const first = lines.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), "---")) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var capturing = false;

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "---")) break;

        if (capturing) {
            const trimmed = std.mem.trim(u8, line, " ");
            const indent = line.len - std.mem.trimStart(u8, line, " ").len;
            // A non-blank line back at column 0 ends the block; a blank
            // line inside it (common between list items) doesn't.
            if (trimmed.len != 0 and indent == 0) break;
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
            continue;
        }

        if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const line_key = std.mem.trim(u8, line[0..colon], " ");
        if (!std.mem.eql(u8, line_key, key)) continue;

        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
        capturing = true;
    }

    if (!capturing) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

/// The first `:` outside a quoted span -- `null` if there isn't one, meaning
/// this line is a bare value, not a `key: value` pair.
fn findTopLevelColon(body: []const u8) ?usize {
    var in_quote: ?u8 = null;
    for (body, 0..) |c, i| {
        if (in_quote) |q| {
            if (c == q) in_quote = null;
            continue;
        }
        switch (c) {
            '"', '\'' => in_quote = c,
            ':' => return i,
            else => {},
        }
    }
    return null;
}

fn isWikilink(value: []const u8) bool {
    const inner = unquote(value);
    return std.mem.startsWith(u8, inner, "[[") and std.mem.endsWith(u8, inner, "]]");
}

/// Whether `buf` (a flow list's opening line, possibly with continuation
/// lines already appended) contains its closing `]` outside any quoted
/// span -- not necessarily as the last character, just present at the top
/// level, which is enough to know accumulation is done.
fn hasTopLevelClose(buf: []const u8) bool {
    var in_quote: ?u8 = null;
    for (buf) |c| {
        if (in_quote) |q| {
            if (c == q) in_quote = null;
            continue;
        }
        switch (c) {
            '"', '\'' => in_quote = c,
            ']' => return true,
            else => {},
        }
    }
    return false;
}

/// A flow-list element this extractor accepts: a quoted string (optionally
/// containing wikilinks), a bare wikilink, or a bare word/number with no
/// nested-structure characters. Anything that looks like a flow map entry
/// (`a: b`) or another collection refuses the whole list.
fn isScalarElement(elem: []const u8) bool {
    if (elem.len >= 2 and (elem[0] == '"' or elem[0] == '\'') and elem[elem.len - 1] == elem[0])
        return true;
    if (isWikilink(elem)) return true;
    for (elem) |c| {
        if (c == ':' or c == '{' or c == '[' or c == '"' or c == '\'') return false;
    }
    return true;
}

fn topKey(stack: std.ArrayListUnmanaged(BardFrontmatterExtractor.Frame)) ?[]const u8 {
    if (stack.items.len == 0) return null;
    return stack.items[stack.items.len - 1].key;
}

/// Every frame on the stack, dot-joined, then `key` -- `relationships` +
/// `key_relationships` + `link` -> `relationships.key_relationships.link`.
/// Root-level (`stack` empty) is just `key` itself.
fn joinPath(gpa: Allocator, stack: std.ArrayListUnmanaged(BardFrontmatterExtractor.Frame), key: []const u8) ![]u8 {
    if (stack.items.len == 0) return gpa.dupe(u8, key);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (stack.items) |f| {
        try out.appendSlice(gpa, f.key);
        try out.append(gpa, '.');
    }
    try out.appendSlice(gpa, key);
    return out.toOwnedSlice(gpa);
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

fn countRole(tags: []const model.Tag, role: model.Role) usize {
    var n: usize = 0;
    for (tags) |t| if (t.role == role) {
        n += 1;
    };
    return n;
}

fn expectRef(tags: []const model.Tag, name: []const u8, kind: []const u8) !void {
    for (tags) |t| {
        if (t.role != .ref) continue;
        if (!std.mem.eql(u8, t.name, name)) continue;
        if (!std.mem.eql(u8, t.kind, kind)) continue;
        return;
    }
    std.debug.print("no ref named '{s}' kind '{s}'\n", .{ name, kind });
    return error.TestExpectedEqual;
}

// A trimmed-down real shape: relationships.key_relationships is a list of
// objects, three levels deep from root -- exactly what the predecessor
// extractor couldn't parse.
const gael =
    \\---
    \\template: "character_pov"
    \\name: "Gael Varis"
    \\affiliation: "The Radiant Dominion"
    \\tags: ["champion", "heldri", "solar", "flame-hilt", "pov"]
    \\
    \\relationships:
    \\  role_in_team: "The Champion"
    \\  key_relationships:
    \\    - name: "Calla Starweaver"
    \\      link: "[[calla-starweaver]]"
    \\      kinds: ["romantic_interest", "teammate"]
    \\      type: "Romantic interest"
    \\      dynamic: "Solar and Heldri potential recognition"
    \\    - name: "Severen"
    \\      link: "[[severen]]"
    \\      kinds: ["chain_of_command"]
    \\      type: "Superior"
    \\
    \\abilities:
    \\  weapons:
    \\    - name: "Flame hilt"
    \\      link: "[[flame-hilt-dominion]]"
    \\      description: "Dominion-issued artifact"
    \\---
    \\
    \\Prose body, never parsed.
    \\
;

test "a def is the entity's identity, kind is the root template: field" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const dir = try fx.write("gael.md", gael);

    var ex: BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"gael.md"});
    defer freeOutcomes(gpa, out);

    const tags = out[0].tags;
    var defs: usize = 0;
    for (tags) |t| if (t.role == .def) {
        defs += 1;
        try testing.expectEqualStrings("Gael Varis", t.name);
        try testing.expectEqualStrings("character_pov", t.kind);
    };
    try testing.expectEqual(@as(usize, 1), defs);
}

test "list-of-objects three levels deep: each field keeps its own dotted path" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const dir = try fx.write("gael.md", gael);

    var ex: BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"gael.md"});
    defer freeOutcomes(gpa, out);

    try expectRef(out[0].tags, "calla-starweaver", "relationships.key_relationships.link");
    try expectRef(out[0].tags, "severen", "relationships.key_relationships.link");
    try expectRef(out[0].tags, "flame-hilt-dominion", "abilities.weapons.link");
    // kinds: [...] is a flow list of plain strings -- no wikilinks, no refs,
    // and critically: not a refusal.
    try testing.expectEqual(@as(usize, 3), countRole(out[0].tags, .ref));
}

test "flow list of plain strings (tags:) causes no refusal and no refs" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const dir = try fx.write("gael.md", gael);

    var ex: BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"gael.md"});
    defer freeOutcomes(gpa, out);
    try testing.expect(out[0] == .tags);
}

test "multiple wikilinks in one scalar each become their own ref" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const body =
        \\---
        \\template: "item"
        \\name: "Flame Hilt"
        \\current_holder: "[[gael-varis|Gael Varis]] (active), [[calla-starweaver|Calla Starweaver]] (issued, never used)"
        \\---
        \\
    ;
    const dir = try fx.write("hilt.md", body);

    var ex: BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"hilt.md"});
    defer freeOutcomes(gpa, out);

    try expectRef(out[0].tags, "gael-varis", "current_holder");
    try expectRef(out[0].tags, "calla-starweaver", "current_holder");
    try testing.expectEqual(@as(usize, 2), countRole(out[0].tags, .ref));
}

test "flow list mixing prose and wikilinks (faction relationships) resolves each element" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const body =
        \\---
        \\template: "country"
        \\name: "The Radiant Dominion"
        \\foreign_relations:
        \\  enemies: ["[[Veridia]] (declared external threat)", "[[ember-guard|Ember Guard]] (internal resistance)"]
        \\---
        \\
    ;
    const dir = try fx.write("dominion.md", body);

    var ex: BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"dominion.md"});
    defer freeOutcomes(gpa, out);

    try expectRef(out[0].tags, "Veridia", "foreign_relations.enemies");
    try expectRef(out[0].tags, "ember-guard", "foreign_relations.enemies");
}

test "a bare scalar block list qualifies every entry by the same parent key" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const body =
        \\---
        \\template: "item"
        \\name: "Ravens' Hunting Knife"
        \\previous_holders:
        \\  - "Grayford/Kaldriv shopkeeper (sold)"
        \\  - "[[drisdan-noor|Drisdan Noor]] (pocketed before wrapping, left anonymously)"
        \\---
        \\
    ;
    const dir = try fx.write("knife.md", body);

    var ex: BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"knife.md"});
    defer freeOutcomes(gpa, out);

    try expectRef(out[0].tags, "drisdan-noor", "previous_holders");
    try testing.expectEqual(@as(usize, 1), countRole(out[0].tags, .ref));
}

test "no template: field falls back to entity, same as the predecessor's default" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const dir = try fx.write("bare.md", "---\nname: Bare\n---\n");

    var ex: BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"bare.md"});
    defer freeOutcomes(gpa, out);
    try testing.expectEqualStrings("entity", out[0].tags[0].kind);
}

test "everything outside the subset is refused, not skipped" {
    const cases = [_]struct { why: BardFrontmatterExtractor.Refusal, body: []const u8 }{
        .{ .why = .anchor_or_alias, .body = "---\nname: A\nbase: &anchor x\n---\n" },
        .{ .why = .anchor_or_alias, .body = "---\nname: A\nsame_as: *anchor\n---\n" },
        .{ .why = .block_scalar, .body = "---\nname: A\nsummary: |\n  a paragraph\n---\n" },
        .{ .why = .block_scalar, .body = "---\nname: A\nsummary: >\n  folded\n---\n" },
        .{ .why = .flow_collection, .body = "---\nname: A\nrefs: {a: b}\n---\n" },
        .{ .why = .flow_collection, .body = "---\nname: A\nrefs: [a: b]\n---\n" },
        .{ .why = .second_document, .body = "---\nname: A\n---\nprose\n---\n" },
        .{ .why = .tab_indent, .body = "---\nname: A\nlist:\n\t- x\n---\n" },
        .{ .why = .unterminated, .body = "---\nname: A\ntemplate: person\n" },
        .{ .why = .no_frontmatter, .body = "# Just prose\n\nNo frontmatter here.\n" },
        .{ .why = .malformed_line, .body = "---\nname: A\nno colon on this line\n---\n" },
        .{ .why = .malformed_line, .body = "---\n- Orphan\n---\n" },
    };

    for (cases, 0..) |c, i| {
        const gpa2 = testing.allocator;
        var fx = Fixture.init();
        defer fx.deinit();
        const dir = try fx.write("Case.md", c.body);

        var ex: BardFrontmatterExtractor = .{};
        defer ex.deinit(gpa2);
        const out = try ex.port().extract(gpa2, testing.io, dir, &.{"Case.md"});
        defer freeOutcomes(gpa2, out);

        testing.expect(out[0] == .unsupported) catch |e| {
            std.debug.print("case {d} ({t}) was accepted, not refused\n", .{ i, c.why });
            return e;
        };
        testing.expectEqual(c.why, ex.last_refusals[0].?) catch |e| {
            std.debug.print("case {d}: expected {t}, got {t}\n", .{ i, c.why, ex.last_refusals[0].? });
            return e;
        };
    }
}

test "an empty flow list and an empty scalar list-of-scalars key are both fine" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const dir = try fx.write("empty.md", "---\nname: A\ntags: []\nsecrets: []\n---\n");

    var ex: BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"empty.md"});
    defer freeOutcomes(gpa, out);
    try testing.expect(out[0] == .tags);
    try testing.expectEqual(@as(usize, 0), countRole(out[0].tags, .ref));
}

test "an empty flow map is fine; a non-empty one still refuses" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const dir = try fx.write("empty_map.md", "---\nname: A\nroles: {}\nproficiency: { }\n---\n");

    var ex: BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"empty_map.md"});
    defer freeOutcomes(gpa, out);
    try testing.expect(out[0] == .tags);
    try testing.expectEqual(@as(usize, 0), countRole(out[0].tags, .ref));

    var ex2: BardFrontmatterExtractor = .{};
    defer ex2.deinit(gpa);
    const dir2 = try fx.write("nonempty_map.md", "---\nname: A\nrefs: {a: b}\n---\n");
    const out2 = try ex2.port().extract(gpa, testing.io, dir2, &.{"nonempty_map.md"});
    defer freeOutcomes(gpa, out2);
    try testing.expectEqual(BardFrontmatterExtractor.Refusal.flow_collection, ex2.last_refusals[0].?);
}

test "a flow list spanning multiple physical lines (open_questions:) closes correctly" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const body =
        \\---
        \\template: "character_pov"
        \\name: "Calla Starweaver"
        \\open_questions: [
        \\  "What happened to Calla's parents?",
        \\  "Is Calla related to [[maren-solveig|Maren]] by blood?"
        \\]
        \\status: "Alive"
        \\---
        \\
    ;
    const dir = try fx.write("calla.md", body);

    var ex: BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"calla.md"});
    defer freeOutcomes(gpa, out);

    try testing.expect(out[0] == .tags);
    // The field after the multi-line list must still parse -- proof the
    // continuation loop consumed exactly through the closing `]` and no
    // further.
    var defs: usize = 0;
    for (out[0].tags) |t| if (t.role == .def) {
        defs += 1;
    };
    try testing.expectEqual(@as(usize, 1), defs);
    try expectRef(out[0].tags, "maren-solveig", "open_questions");
}

test "full-line YAML comments (real templates' section dividers) are skipped, not refused" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const body =
        \\---
        \\template: "character_pov"
        \\# --- Identity ---
        \\name: "Callista Starweaver"
        \\name_meaning: "Starweaver is the Sol translation if her clan name"
        \\
        \\# --- Appearance ---
        \\appearance:
        \\  height: "Short"
        \\  hair_color: "Red"
        \\---
        \\
    ;
    const dir = try fx.write("calla.md", body);

    var ex: BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, testing.io, dir, &.{"calla.md"});
    defer freeOutcomes(gpa, out);

    try testing.expect(out[0] == .tags);
    var defs: usize = 0;
    for (out[0].tags) |t| if (t.role == .def) {
        defs += 1;
        try testing.expectEqualStrings("Callista Starweaver", t.name);
    };
    try testing.expectEqual(@as(usize, 1), defs);
}

test "a batch call reports each path's own refusal reason, not the last one in the batch" {
    const gpa = testing.allocator;
    var fx = Fixture.init();
    defer fx.deinit();
    const dir = try fx.write("a.md", "---\nname: A\nsummary: |\n  block scalar\n---\n");
    _ = try fx.write("b.md", "---\nname: B\nrefs: {a: b}\n---\n");
    _ = try fx.write("c.md", "no frontmatter at all\n");

    var ex: BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const out = try ex.port().extract(gpa, testing.io, dir, &.{ "a.md", "b.md", "c.md" });
    defer freeOutcomes(gpa, out);

    try testing.expectEqual(BardFrontmatterExtractor.Refusal.block_scalar, ex.last_refusals[0].?);
    try testing.expectEqual(BardFrontmatterExtractor.Refusal.flow_collection, ex.last_refusals[1].?);
    try testing.expectEqual(BardFrontmatterExtractor.Refusal.no_frontmatter, ex.last_refusals[2].?);
}

test "rawField returns a single-line scalar verbatim, key included" {
    const gpa = testing.allocator;
    const src = "---\ntemplate: \"character_pov\"\nname: \"Calla\"\n---\n";
    const got = (try rawField(gpa, src, "template")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("template: \"character_pov\"\n", got);
}

test "rawField returns a multi-line nested block, list-of-objects included" {
    const gpa = testing.allocator;
    const src =
        \\---
        \\name: "Aidan"
        \\images:
        \\  - path: "characters/Aidan/images/face.png"
        \\    description: "Face reference"
        \\    source: "Author-generated (AI)"
        \\  - path: "characters/Aidan/images/outfit.png"
        \\    description: "Frontier field outfit"
        \\face_cast:
        \\  - name: "Someone"
        \\---
    ;
    const got = (try rawField(gpa, src, "images")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings(
        "images:\n" ++
            "  - path: \"characters/Aidan/images/face.png\"\n" ++
            "    description: \"Face reference\"\n" ++
            "    source: \"Author-generated (AI)\"\n" ++
            "  - path: \"characters/Aidan/images/outfit.png\"\n" ++
            "    description: \"Frontier field outfit\"\n",
        got,
    );
}

test "rawField stops at the next root-level key, not partway through a blank line inside the block" {
    const gpa = testing.allocator;
    const src =
        \\---
        \\name: "A"
        \\open_questions:
        \\  - "First"
        \\
        \\  - "Second"
        \\status: "Alive"
        \\---
    ;
    const got = (try rawField(gpa, src, "open_questions")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings(
        "open_questions:\n  - \"First\"\n\n  - \"Second\"\n",
        got,
    );
}

test "rawField is null for a key that isn't there, and for a file with no frontmatter" {
    const gpa = testing.allocator;
    const with_fm = "---\nname: \"A\"\n---\n";
    try testing.expectEqual(@as(?[]u8, null), try rawField(gpa, with_fm, "nonexistent"));

    const no_fm = "# Just prose\n";
    try testing.expectEqual(@as(?[]u8, null), try rawField(gpa, no_fm, "name"));
}

test "rawField never refuses -- a block scalar under the requested key comes back raw, not as an error" {
    const gpa = testing.allocator;
    const src = "---\nname: \"A\"\nsummary: |\n  a paragraph\n  more\ntemplate: \"x\"\n---\n";
    const got = (try rawField(gpa, src, "summary")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("summary: |\n  a paragraph\n  more\n", got);
}

test "frontmatterBlock returns the opening through closing --- inclusive, prose body dropped" {
    const src = "---\nname: \"A\"\ntemplate: \"x\"\n---\n\nProse body, never included.\n";
    const got = frontmatterBlock(src).?;
    try testing.expectEqualStrings("---\nname: \"A\"\ntemplate: \"x\"\n---\n", got);
}

test "frontmatterBlock handles a file with no trailing newline after the closing ---" {
    const src = "---\nname: \"A\"\n---";
    const got = frontmatterBlock(src).?;
    try testing.expectEqualStrings("---\nname: \"A\"\n---", got);
}

test "frontmatterBlock is null for no frontmatter or an unterminated block" {
    try testing.expectEqual(@as(?[]const u8, null), frontmatterBlock("# Just prose\n"));
    try testing.expectEqual(@as(?[]const u8, null), frontmatterBlock("---\nname: \"A\"\n"));
}

test "rootKeys lists only column-0 keys, in order, skipping nested sub-fields and comments" {
    const gpa = testing.allocator;
    const src =
        \\---
        \\# --- Identity ---
        \\name: ""
        \\role: ""                    # trailing comment after real content
        \\age: null
        \\appearance:
        \\  height: ""
        \\  build: ""
        \\images:
        \\  - path: ""
        \\    description: ""
        \\---
        \\
    ;
    const keys = (try rootKeys(gpa, src)).?;
    defer {
        for (keys) |k| gpa.free(k);
        gpa.free(keys);
    }
    try testing.expectEqual(@as(usize, 5), keys.len);
    try testing.expectEqualStrings("name", keys[0]);
    try testing.expectEqualStrings("role", keys[1]);
    try testing.expectEqualStrings("age", keys[2]);
    try testing.expectEqualStrings("appearance", keys[3]);
    try testing.expectEqualStrings("images", keys[4]);
}

test "rootKeys is null for a file with no frontmatter" {
    const gpa = testing.allocator;
    try testing.expectEqual(@as(?[][]const u8, null), try rootKeys(gpa, "# Just prose\n"));
}

test "wikilinkTargets finds every [[wikilink]] target in a multi-line string, duplicates included" {
    const gpa = testing.allocator;
    const text = "Mentions [[maren-solveig|Maren]] here, then again as [[maren-solveig]].\nA new line references [[drisdan-noor|Drisdan]].";
    const targets = try wikilinkTargets(gpa, text);
    defer {
        for (targets) |t| gpa.free(t);
        gpa.free(targets);
    }
    try testing.expectEqual(@as(usize, 3), targets.len);
    try testing.expectEqualStrings("maren-solveig", targets[0]);
    try testing.expectEqualStrings("maren-solveig", targets[1]);
    try testing.expectEqualStrings("drisdan-noor", targets[2]);
}

test "wikilinkTargets is empty for text with no wikilinks at all" {
    const gpa = testing.allocator;
    const targets = try wikilinkTargets(gpa, "Plain prose, no brackets here.");
    defer gpa.free(targets);
    try testing.expectEqual(@as(usize, 0), targets.len);
}
