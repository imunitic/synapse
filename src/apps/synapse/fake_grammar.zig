//! The grammar backend behind `synapse-fake`: scripted tags, no grammar.
//!
//! This replaces `tests/fixtures/fake-bin/tree-sitter`, which stopped
//! intercepting anything the moment libtree-sitter was linked instead of
//! spawned. It reproduces that fake's behaviour exactly, because the bats
//! suite's fixtures are written against it:
//!
//!   * `.ml`, `.java` and `.py` are the extensions it can tag. Anything else
//!     yields no grammar -- silently, the way an extension the CLI could not
//!     parse used to, and distinct from the registry saying no, which warns.
//!   * Every taggable file yields one `FAKE_NAME` definition, plus one per
//!     `symbol:<Name>` line (a def) and `ref:<Name>` line (a ref) in the file
//!     itself. That lets a test about *vocabulary* author the symbols it wants
//!     as ordinary fixture content.
//!   * A file containing a bare `notags` line parses fine and has nothing in
//!     it -- the parsed-but-empty case, which must stay distinguishable from
//!     no-grammar.
//!
//! What it does NOT fake is everything around it. Registry resolution, the
//! warnings, negative caching, the clone and its lock all come from the shared
//! `Extractor` and run for real here, against `tests/fixtures/fake-bin/git`.
//! Only the compile-and-load step is missing, which is the step that needs a C
//! toolchain and a real grammar repository.

const std = @import("std");
const model = @import("model");
const treesitter = @import("treesitter");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Tagged = treesitter.tagger.Tagged;

pub const FakeBackend = struct {
    /// Nothing to hold: the registry entry and the clone are the shared
    /// Extractor's business, and there is no library to keep open.
    pub const Grammar = void;

    const taggable = [_][]const u8{ "ml", "java", "py" };

    pub fn load(
        gpa: Allocator,
        io: Io,
        repo_dir: []const u8,
        grammars_dir: []const u8,
        name: []const u8,
    ) !Grammar {
        _ = .{ gpa, io, repo_dir, grammars_dir, name };
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
        // Not `.unsupported` via a warning: the registry had an entry, this
        // stand-in simply cannot parse the language, which is what the CLI
        // failing to tag a file looked like.
        if (!known) return error.NoGrammar;

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

    /// The span and expression the old fake printed, unchanged: `(0, 0) - (0,
    /// 1)` and `fake source line`. Several tests parse those columns.
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
