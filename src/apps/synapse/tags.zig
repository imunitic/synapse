//! `synapse tags` -- the port of `claude/lib/synapse/synapse-tags.sh`.
//!
//! Same three forms, same output bytes, same exit codes, because
//! `tests/synapse-tags.bats` is the specification and four bash scripts still
//! parse this output during the transition:
//!
//!   0  tags printed. In `--paths` mode this is the outcome whenever the batch
//!      ran, even if some extensions had no grammar -- a mixed repo nearly
//!      always has some, and failing the batch for them would throw away every
//!      language that did work. `--list-extensions` exits 0 on an empty
//!      registry too.
//!   1  not usable right now: no extension, an entry marked unsupported, a
//!      clone or build failure, a missing file. Nothing else to try.
//!   2  the extension has no registry entry at all -- the caller should run
//!      grammar discovery and retry rather than treat it as a hard failure.
//!      Single-file mode only: a batch spanning many extensions has no single
//!      answer, so it warns per extension and returns 0.

const std = @import("std");
const model = @import("model");
const treesitter = @import("treesitter");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const render = treesitter.tagger.renderCliLine;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    const home = env.get("HOME") orelse return 1;

    const registry_path = try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-grammars.conf", .{home});
    defer gpa.free(registry_path);
    var registry = treesitter.Registry.load(gpa, io, registry_path) catch return 1;
    defer registry.deinit();

    const first = args.next() orelse return 1;

    if (std.mem.eql(u8, first, "--list-extensions")) {
        const exts = try registry.usableExtensions(gpa);
        defer gpa.free(exts);
        var buf: [8192]u8 = undefined;
        var out = Io.File.stdout().writer(io, &buf);
        for (exts) |e| try out.interface.print("{s}\n", .{e});
        try out.interface.flush();
        return 0;
    }

    const grammars_dir = if (env.get("SYNAPSE_GRAMMARS_DIR")) |d|
        try gpa.dupe(u8, d)
    else
        try std.fmt.allocPrint(gpa, "{s}/.cache/synapse/grammars", .{home});
    defer gpa.free(grammars_dir);

    var ex: treesitter.extractor.TreeSitterExtractor = .init(gpa, registry, grammars_dir);
    defer ex.deinit();
    if (env.get("SYNAPSE_GRAMMAR_LOCK_TRIES")) |t|
        ex.lock_tries = std.fmt.parseInt(usize, t, 10) catch 300;

    if (std.mem.eql(u8, first, "--paths")) {
        const list_file = args.next() orelse return 1;
        return batch(gpa, io, &ex, list_file);
    }
    return single(gpa, io, &ex, registry, first);
}

fn single(
    gpa: Allocator,
    io: Io,
    ex: *treesitter.extractor.TreeSitterExtractor,
    registry: treesitter.Registry,
    path: []const u8,
) !u8 {
    Io.Dir.cwd().access(io, path, .{}) catch return 1;

    // The exit code has to distinguish "no registry entry" (2, run discovery
    // and retry) from "unusable" (1, nothing else to try), and the extractor's
    // `.unsupported` collapses both. So the readiness is asked here, before
    // extraction, purely to decide which number to return.
    const ext = (try treesitter.extensionOf(gpa, path)) orelse return 1;
    defer gpa.free(ext);
    const readiness: u8 = switch (registry.lookup(ext)) {
        .ready => 0,
        .unusable => 1,
        .no_entry => 2,
    };
    if (readiness != 0) return readiness;

    const results = try ex.tagWithSpans(gpa, io, ".", &.{path});
    defer gpa.free(results);
    switch (results[0]) {
        .unsupported => return 1,
        .tagged => |tagged| {
            defer treesitter.tagger.freeTagged(gpa, tagged);
            var buf: [64 * 1024]u8 = undefined;
            var out = Io.File.stdout().writer(io, &buf);
            for (tagged) |t| try render(&out.interface, t.tag, t.span);
            try out.interface.flush();
            return 0;
        },
    }
}

fn batch(
    gpa: Allocator,
    io: Io,
    ex: *treesitter.extractor.TreeSitterExtractor,
    list_file: []const u8,
) !u8 {
    const listing = Io.Dir.cwd().readFileAlloc(io, list_file, gpa, .limited(64 << 20)) catch return 1;
    defer gpa.free(listing);

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(gpa);
    var it = std.mem.splitScalar(u8, listing, '\n');
    while (it.next()) |line| {
        const p = std.mem.trim(u8, line, " \t\r");
        if (p.len != 0) try paths.append(gpa, p);
    }
    if (paths.items.len == 0) return 1;

    const results = try ex.tagWithSpans(gpa, io, ".", paths.items);
    defer {
        for (results) |r| if (r == .tagged) treesitter.tagger.freeTagged(gpa, r.tagged);
        gpa.free(results);
    }

    var usable: usize = 0;
    for (results) |r| if (r == .tagged) {
        usable += 1;
    };
    // Nothing in the list could be tagged at all. Saying so beats an empty
    // success that a caller would read as "this repo has no symbols".
    if (usable == 0) return 1;

    var buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    for (paths.items, results) |path, r| {
        // An unparseable file is absent from the output entirely, while one
        // that parsed to nothing still gets its path line. The whole
        // `unsupported` distinction rests on exactly that, in the cache and in
        // every caller that attributes this output back to paths.
        const tagged = switch (r) {
            .unsupported => continue,
            .tagged => |t| t,
        };
        try out.interface.print("{s}\n", .{path});
        for (tagged) |t| {
            try out.interface.writeAll("\t");
            try render(&out.interface, t.tag, t.span);
        }
    }
    try out.interface.flush();
    return 0;
}
