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
//!
//! Generic over the extractor so the test binary is this same dispatch with
//! a different innermost step -- see `extractor.zig`'s header.

const std = @import("std");
const model = @import("model");
const core = @import("core");
const treesitter = @import("treesitter");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const render = treesitter.tagger.renderCliLine;

/// Where to append a record of what was tagged, or null for none. Exists
/// for `synapse-fake`: bats tests assert N files cost ONE invocation, and
/// with nothing spawned there's no process to count. The real binary always
/// passes null.
pub const Trace = ?[]const u8;

const usage_text =
    \\usage: synapse tags <file>
    \\       synapse tags --paths <list-file>   every listed file, in one batch
    \\       synapse tags --list-extensions     every extension with a usable grammar
    \\
;

fn usage() u8 {
    std.debug.print("{s}", .{usage_text});
    return 2;
}

/// A `core.conf.Vars` over this process's environment. Indirection exists
/// because `core` may not name `std.process` (`ci/check-layering.sh`).
fn envVars(env: *std.process.Environ.Map) core.conf.Vars {
    return .{ .ctx = @ptrCast(env), .getFn = envLookup };
}

fn envLookup(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const env: *std.process.Environ.Map = @ptrCast(@alignCast(ctx));
    return env.get(name);
}

pub fn run(
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
    trace: Trace,
) !u8 {
    // Before the registry: help needs neither $HOME nor a grammar.
    const first = args.next() orelse return usage();
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        _ = usage();
        return 0;
    }

    const home = env.get("HOME") orelse return 1;

    const registry_path = (try core.conf.resolveConfPath(gpa, io, envVars(env), "synapse-grammars.conf")) orelse
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-grammars.conf", .{home});
    defer gpa.free(registry_path);
    var registry = treesitter.Registry.load(gpa, io, registry_path) catch return 1;
    defer registry.deinit();


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

    const kind_rules_path = if (env.get("SYNAPSE_KIND_SYNONYMS_CONF")) |p|
        try gpa.dupe(u8, p)
    else if (try core.conf.resolveConfPath(gpa, io, envVars(env), "synapse-kind-synonyms.conf")) |p|
        p
    else
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-kind-synonyms.conf", .{home});
    defer gpa.free(kind_rules_path);
    var kind_rules = core.kind_synonyms.RuleList.load(gpa, io, kind_rules_path) catch return 1;
    defer kind_rules.deinit();

    var ex: Ex = .init(gpa, registry, grammars_dir, kind_rules);
    defer ex.deinit();
    if (env.get("SYNAPSE_GRAMMAR_LOCK_TRIES")) |t|
        ex.lock_tries = std.fmt.parseInt(usize, t, 10) catch treesitter.grammar.default_lock_tries;
    ex.query_override_dir = env.get("SYNAPSE_GRAMMARS_QUERY_PATH");

    if (std.mem.eql(u8, first, "--paths")) {
        const list_file = args.next() orelse return 1;
        return batch(Ex, gpa, io, &ex, list_file, trace);
    }
    return single(Ex, gpa, io, &ex, registry, first, trace);
}

fn single(
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    ex: *Ex,
    registry: treesitter.Registry,
    path: []const u8,
    trace: Trace,
) !u8 {
    Io.Dir.cwd().access(io, path, .{}) catch return 1;

    // Readiness asked before extraction, purely to pick 1 vs 2: the
    // extractor's `.unsupported` collapses "no entry" and "unusable" alike.
    const ext = (try treesitter.extensionOf(gpa, path)) orelse return 1;
    defer gpa.free(ext);
    const readiness: u8 = switch (registry.lookup(ext)) {
        .ready => 0,
        .unusable => 1,
        .no_entry => 2,
    };
    if (readiness != 0) return readiness;

    try writeTrace(io, trace, &.{path});

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
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    ex: *Ex,
    list_file: []const u8,
    trace: Trace,
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

    try writeTrace(io, trace, paths.items);

    const results = try ex.tagWithSpans(gpa, io, ".", paths.items);
    defer {
        for (results) |r| if (r == .tagged) treesitter.tagger.freeTagged(gpa, r.tagged);
        gpa.free(results);
    }

    var usable: usize = 0;
    for (results) |r| if (r == .tagged) {
        usable += 1;
    };
    if (usable == 0) return 1; // beats an empty success reading as "no symbols"

    var buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    for (paths.items, results) |path, r| {
        // Unparseable: absent entirely. Parsed to nothing: still gets its
        // path line. The `unsupported` distinction rests on that.
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

/// One `tags <paths...>` line, then one `path <p>` line per path -- the
/// format the old fake tree-sitter binary wrote, kept byte-compatible.
/// Appended, not truncated: a test may run the binary more than once.
fn writeTrace(io: Io, trace: Trace, paths: []const []const u8) !void {
    const path = trace orelse return;

    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer f.close(io);

    var buf: [16 * 1024]u8 = undefined;
    var w = f.writer(io, &buf);
    w.pos = (try f.stat(io)).size;

    try w.interface.writeAll("tags");
    for (paths) |p| try w.interface.print(" {s}", .{p});
    try w.interface.writeAll("\n");
    for (paths) |p| try w.interface.print("path {s}\n", .{p});
    try w.interface.flush();
}
