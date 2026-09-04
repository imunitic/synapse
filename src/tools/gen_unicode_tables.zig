//! Fetches the Unicode Character Database and regenerates the vendored NFC
//! and case-fold tables `core.unicode_tables` compiles in. A tool, not a
//! test -- needs real network access and is run by name only:
//!
//!   zig build gen-unicode-tables
//!
//! Unicode releases are additive (new codepoints, not changed decompositions
//! for existing ones), so this is expected to run once and be re-run only
//! occasionally, never as part of the default build or `zig build test`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ucd_base = "https://www.unicode.org/Public/UCD/latest/ucd/";
const output_path = "src/core/unicode_tables.zig";

const Decomp = struct {
    cp: u21,
    seq: []const u21,
};

const CcEntry = struct {
    cp: u21,
    ccc: u8,
};

const ComposePair = struct {
    a: u21,
    b: u21,
    composed: u21,
};

const FoldEntry = struct {
    cp: u21,
    folded: u21,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    std.debug.print("gen-unicode-tables: fetching UnicodeData.txt\n", .{});
    const unicode_data = try fetchText(gpa, io, ucd_base ++ "UnicodeData.txt");
    defer gpa.free(unicode_data);

    std.debug.print("gen-unicode-tables: fetching CompositionExclusions.txt\n", .{});
    const exclusions_data = try fetchText(gpa, io, ucd_base ++ "CompositionExclusions.txt");
    defer gpa.free(exclusions_data);

    std.debug.print("gen-unicode-tables: fetching CaseFolding.txt\n", .{});
    const case_folding_data = try fetchText(gpa, io, ucd_base ++ "CaseFolding.txt");
    defer gpa.free(case_folding_data);

    var ccc_list: std.ArrayListUnmanaged(CcEntry) = .empty;
    defer ccc_list.deinit(gpa);
    var decomp_list: std.ArrayListUnmanaged(Decomp) = .empty;
    defer {
        for (decomp_list.items) |d| gpa.free(d.seq);
        decomp_list.deinit(gpa);
    }
    try parseUnicodeData(gpa, unicode_data, &ccc_list, &decomp_list);

    var exclusions: std.AutoHashMapUnmanaged(u21, void) = .empty;
    defer exclusions.deinit(gpa);
    try parseExclusions(gpa, exclusions_data, &exclusions);

    var compose_list: std.ArrayListUnmanaged(ComposePair) = .empty;
    defer compose_list.deinit(gpa);
    for (decomp_list.items) |d| {
        if (d.seq.len != 2) continue;
        if (exclusions.contains(d.cp)) continue;
        try compose_list.append(gpa, .{ .a = d.seq[0], .b = d.seq[1], .composed = d.cp });
    }
    std.mem.sort(ComposePair, compose_list.items, {}, struct {
        fn less(_: void, x: ComposePair, y: ComposePair) bool {
            if (x.a != y.a) return x.a < y.a;
            return x.b < y.b;
        }
    }.less);

    var fold_list: std.ArrayListUnmanaged(FoldEntry) = .empty;
    defer fold_list.deinit(gpa);
    try parseCaseFolding(gpa, case_folding_data, &fold_list);

    std.mem.sort(CcEntry, ccc_list.items, {}, struct {
        fn less(_: void, x: CcEntry, y: CcEntry) bool {
            return x.cp < y.cp;
        }
    }.less);
    std.mem.sort(Decomp, decomp_list.items, {}, struct {
        fn less(_: void, x: Decomp, y: Decomp) bool {
            return x.cp < y.cp;
        }
    }.less);
    std.mem.sort(FoldEntry, fold_list.items, {}, struct {
        fn less(_: void, x: FoldEntry, y: FoldEntry) bool {
            return x.cp < y.cp;
        }
    }.less);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try emit(&out.writer, ccc_list.items, decomp_list.items, compose_list.items, fold_list.items);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = out.written() });
    std.debug.print(
        "gen-unicode-tables: wrote {s} ({d} ccc, {d} decompositions, {d} compositions, {d} case folds)\n",
        .{ output_path, ccc_list.items.len, decomp_list.items.len, compose_list.items.len, fold_list.items.len },
    );
    return 0;
}

fn fetchText(gpa: Allocator, io: Io, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &out.writer,
    });
    if (result.status != .ok) {
        std.debug.print("gen-unicode-tables: {s} -> {t}\n", .{ url, result.status });
        return error.FetchFailed;
    }
    return out.toOwnedSlice();
}

/// Fields: codepoint; name; category; combining class; bidi; decomposition; ...
/// A decomposition with a leading `<tag>` is a compatibility mapping, not
/// the canonical one NFC uses -- skipped, same as an absent decomposition.
fn parseUnicodeData(
    gpa: Allocator,
    text: []const u8,
    ccc_list: *std.ArrayListUnmanaged(CcEntry),
    decomp_list: *std.ArrayListUnmanaged(Decomp),
) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const cp_field = fields.next() orelse continue;
        const cp = std.fmt.parseInt(u21, cp_field, 16) catch continue;
        _ = fields.next(); // name
        _ = fields.next(); // category
        const ccc_field = fields.next() orelse continue;
        const ccc = std.fmt.parseInt(u8, ccc_field, 10) catch 0;
        if (ccc != 0) try ccc_list.append(gpa, .{ .cp = cp, .ccc = ccc });
        _ = fields.next(); // bidi
        const decomp_field = fields.next() orelse continue;
        if (decomp_field.len == 0) continue;
        if (decomp_field[0] == '<') continue; // compatibility mapping, not canonical

        var seq: std.ArrayListUnmanaged(u21) = .empty;
        errdefer seq.deinit(gpa);
        var it = std.mem.splitScalar(u8, decomp_field, ' ');
        while (it.next()) |tok| {
            if (tok.len == 0) continue;
            const dcp = std.fmt.parseInt(u21, tok, 16) catch continue;
            try seq.append(gpa, dcp);
        }
        if (seq.items.len == 0) {
            seq.deinit(gpa);
            continue;
        }
        try decomp_list.append(gpa, .{ .cp = cp, .seq = try seq.toOwnedSlice(gpa) });
    }
}

/// One codepoint per data line, optionally followed by a `#` comment.
fn parseExclusions(gpa: Allocator, text: []const u8, out: *std.AutoHashMapUnmanaged(u21, void)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const before_comment = if (std.mem.indexOfScalar(u8, line, '#')) |i| line[0..i] else line;
        const trimmed = std.mem.trim(u8, before_comment, " \t");
        if (trimmed.len == 0) continue;
        const cp = std.fmt.parseInt(u21, trimmed, 16) catch continue;
        try out.put(gpa, cp, {});
    }
}

/// Fields: codepoint; status (C/F/S/T); mapping; # comment. Only C
/// (common) and S (simple) are "simple case folding" -- F is a multi-
/// codepoint full-folding expansion and T is Turkish-locale-specific,
/// neither of which an equality comparison needs.
fn parseCaseFolding(gpa: Allocator, text: []const u8, out: *std.ArrayListUnmanaged(FoldEntry)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const cp_field = fields.next() orelse continue;
        const cp = std.fmt.parseInt(u21, std.mem.trim(u8, cp_field, " \t"), 16) catch continue;
        const status = std.mem.trim(u8, fields.next() orelse continue, " \t");
        if (!(std.mem.eql(u8, status, "C") or std.mem.eql(u8, status, "S"))) continue;
        const mapping_field = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const folded = std.fmt.parseInt(u21, mapping_field, 16) catch continue;
        try out.append(gpa, .{ .cp = cp, .folded = folded });
    }
}

fn emit(
    w: *Io.Writer,
    ccc: []const CcEntry,
    decomp: []const Decomp,
    compose: []const ComposePair,
    fold: []const FoldEntry,
) !void {
    try w.writeAll(
        \\//! Generated by `zig build gen-unicode-tables` from the Unicode Character
        \\//! Database (UnicodeData.txt, CompositionExclusions.txt, CaseFolding.txt).
        \\//! Do not edit by hand -- re-run the generator instead.
        \\
        \\pub const CccEntry = struct { cp: u21, ccc: u8 };
        \\pub const DecompEntry = struct { cp: u21, seq: []const u21 };
        \\pub const ComposeEntry = struct { a: u21, b: u21, composed: u21 };
        \\pub const FoldEntry = struct { cp: u21, folded: u21 };
        \\
        \\
    );

    try w.print("pub const ccc_table = [_]CccEntry{{\n", .{});
    for (ccc) |e| try w.print("    .{{ .cp = {d}, .ccc = {d} }},\n", .{ e.cp, e.ccc });
    try w.writeAll("};\n\n");

    try w.print("pub const decomp_table = [_]DecompEntry{{\n", .{});
    for (decomp) |d| {
        try w.print("    .{{ .cp = {d}, .seq = &.{{", .{d.cp});
        for (d.seq, 0..) |c, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{d}", .{c});
        }
        try w.writeAll("} },\n");
    }
    try w.writeAll("};\n\n");

    try w.print("pub const compose_table = [_]ComposeEntry{{\n", .{});
    for (compose) |c| try w.print("    .{{ .a = {d}, .b = {d}, .composed = {d} }},\n", .{ c.a, c.b, c.composed });
    try w.writeAll("};\n\n");

    try w.print("pub const casefold_table = [_]FoldEntry{{\n", .{});
    for (fold) |f| try w.print("    .{{ .cp = {d}, .folded = {d} }},\n", .{ f.cp, f.folded });
    try w.writeAll("};\n");
}
