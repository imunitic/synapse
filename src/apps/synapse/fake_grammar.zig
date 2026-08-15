//! The grammar backend behind `synapse-fake`: scripted tags, no grammar.
//! Reproduces `tests/fixtures/fake-bin/tree-sitter`'s old behaviour, which
//! the bats fixtures are written against:
//!
//!   * `.ml`/`.java`/`.py` are taggable; anything else yields no grammar
//!     silently (distinct from a registry "no", which warns).
//!   * Every taggable file yields one `FAKE_NAME` definition, plus one per
//!     `symbol:<Name>` (def) / `ref:<Name>` (ref) line in the file itself.
//!   * A bare `notags` line parses to nothing -- the parsed-but-empty case,
//!     distinct from no-grammar.
//!
//! Everything else -- registry resolution, warnings, negative caching, the
//! clone and its lock -- runs for real through the shared `Extractor`. Only
//! compile-and-load is stubbed.

const std = @import("std");
const model = @import("model");
const core = @import("core");
const treesitter = @import("treesitter");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Tagged = treesitter.tagger.Tagged;

pub const FakeBackend = struct {
    /// Nothing to hold: no library to keep open.
    pub const Grammar = void;

    const taggable = [_][]const u8{ "ml", "java", "py" };

    pub fn load(
        gpa: Allocator,
        io: Io,
        repo_dir: []const u8,
        grammars_dir: []const u8,
        name: []const u8,
        sub_path: ?[]const u8,
        sub_symbol: ?[]const u8,
        source: treesitter.QuerySource,
        ext: []const u8,
        query_override_dir: ?[]const u8,
        kind_rules: core.kind_synonyms.RuleList,
        scope: []const u8,
    ) !Grammar {
        _ = .{ gpa, io, repo_dir, grammars_dir, name, sub_path, sub_symbol, source, ext, query_override_dir, kind_rules, scope };
    }

    pub fn release(g: Grammar, gpa: Allocator) void {
        _ = .{ g, gpa };
    }

    pub fn tagFile(g: Grammar, gpa: Allocator, ext: []const u8, source: []const u8) ![]Tagged {
        _ = g;

        var known = false;
        for (taggable) |e| {
            if (std.mem.eql(u8, e, ext)) known = true;
        }
        if (!known) return error.NoGrammar; // not a warned .unsupported: the registry had an entry

        var out: std.ArrayListUnmanaged(Tagged) = .empty;
        errdefer {
            for (out.items) |t| treesitter.tagger.freeTag(gpa, t.tag);
            out.deinit(gpa);
        }

        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (std.mem.eql(u8, line, "notags")) return out.toOwnedSlice(gpa);
        }

        try append(&out, gpa, "FAKE_NAME", .def, "function");

        lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (std.mem.startsWith(u8, line, "symbol:")) {
                const name = line["symbol:".len..];
                if (name.len != 0) try append(&out, gpa, name, .def, "function");
            } else if (std.mem.startsWith(u8, line, "ref:")) {
                const name = line["ref:".len..];
                if (name.len != 0) try append(&out, gpa, name, .ref, "call");
            }
        }

        return out.toOwnedSlice(gpa);
    }

    /// Span/expression match the old fake's exactly: `(0, 0) - (0, 1)`,
    /// `fake source line`. Several tests parse these columns.
    fn append(
        out: *std.ArrayListUnmanaged(Tagged),
        gpa: Allocator,
        name: []const u8,
        role: model.Role,
        kind: []const u8,
    ) !void {
        try out.append(gpa, .{
            .tag = .{
                .name = try gpa.dupe(u8, name),
                .role = role,
                .kind = try gpa.dupe(u8, kind),
                .line = 0,
                .expression = try gpa.dupe(u8, "fake source line"),
            },
            .span = .{ .start_row = 0, .start_col = 0, .end_row = 0, .end_col = 1 },
        });
    }
};

pub const FakeExtractor = treesitter.extractor.Extractor(FakeBackend);
