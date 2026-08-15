//! Acceptance check for the tree-sitter port: run the *production* tagger over
//! a file list and emit rows a shell script can compare against the
//! `tree-sitter` CLI's own output.
//!
//! This exists because unit tests prove the cases someone thought of, and the
//! thing that actually has to hold is agreement with the implementation being
//! replaced, over real code, at scale. It is a tool rather than a test because
//! it needs real grammars and real repositories, which a hermetic test may not
//! have.
//!
//! Reads `job.txt`: line 1 the grammar repo directory, line 2 the built
//! library path, line 3 the symbol, then one source path per line. Writes
//! `zig-tags.tsv` as `path<TAB>name<TAB>role<TAB>kind<TAB>row`.

const std = @import("std");
const treesitter = @import("treesitter");

/// Takes `std.process.Init` rather than building its own `Io`. A hand-rolled
/// `Io.Threaded.init(gpa, .{})` gets an empty environment, and PATH lookup then
/// silently falls back to `Threaded.default_PATH` -- so `zig cc` would never be
/// found and this tool would compile grammars with whatever `/usr/bin/cc`
/// happens to be, which is not the compiler the thing it is checking uses.
pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const job = try cwd.readFileAlloc(io, "job.txt", gpa, .unlimited);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, job, "\n"), '\n');
    const repo_dir = lines.next() orelse return 2;
    const lib_path = lines.next() orelse return 2;
    const symbol = lines.next() orelse return 2;

    try treesitter.grammar.build(io, gpa, repo_dir, lib_path);
    const lang = try treesitter.grammar.load(gpa, lib_path, symbol);

    const scm_path = try std.fs.path.join(gpa, &.{ repo_dir, "queries", "tags.scm" });
    const scm = try cwd.readFileAlloc(io, scm_path, gpa, .unlimited);

    // Always tags.scm (line 37 above), so `query_source` is fixed and
    // `kind_rules`/`grammar_scope` are unused -- see `Tagger`'s own doc
    // comments on those fields.
    var tagger = try treesitter.tagger.Tagger.init(lang, scm, .tags, null, "", null);
    defer tagger.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // The CLI's own batch bytes, for a comparison with no normalisation in it
    // at all: path line, then tab-indented rendered tags.
    var raw: std.Io.Writer.Allocating = .init(gpa);
    defer raw.deinit();

    var files: usize = 0;
    var rows: usize = 0;
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        files += 1;
        const src = cwd.readFileAlloc(io, path, gpa, .unlimited) catch continue;
        defer gpa.free(src);

        const tagged = tagger.tagFile(gpa, src) catch continue;
        defer treesitter.tagger.freeTagged(gpa, tagged);

        try raw.writer.print("{s}\n", .{path});
        for (tagged) |entry| {
            const t = entry.tag;
            rows += 1;
            try out.writer.print("{s}\t{s}\t{s}\t{s}\t{d}\n", .{
                path, t.name, t.role.text(), t.kind, t.line,
            });
            try raw.writer.writeAll("\t");
            try treesitter.tagger.renderCliLine(&raw.writer, t, entry.span);
        }
    }

    try cwd.writeFile(io, .{ .sub_path = "zig-tags.tsv", .data = out.written() });
    try cwd.writeFile(io, .{ .sub_path = "zig-batch.txt", .data = raw.written() });
    std.debug.print("{d} files, {d} rows\n", .{ files, rows });
    return 0;
}
