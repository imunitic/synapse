//! `synapse tags` -- the port of `claude/lib/synapse/synapse-tags.sh`.
//!
//! Same three forms, same output bytes, same exit codes, because
//! `tests/integration/tags_lock_test.zig` is the specification and four bash
//! scripts still parse this output during the transition:
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
const adapters = @import("adapters");
const treesitter = @import("treesitter");
const trace_file = @import("trace.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const render = treesitter.tagger.renderCliLine;

/// Where to append a record of what was tagged, or null for none. Exists
/// for `synapse-fake`: a test asserting N files cost ONE invocation has no
/// process to count otherwise, since nothing is spawned in-process. The
/// real binary always passes null.
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

    const home = env.get("HOME") orelse {
        std.debug.print("synapse-tags: $HOME is not set\n", .{});
        return 1;
    };

    const registry_path = (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-grammars.conf")) orelse
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-grammars.conf", .{home});
    defer gpa.free(registry_path);
    var registry = treesitter.Registry.load(gpa, io, registry_path) catch {
        std.debug.print("synapse-tags: unreadable grammar registry: {s}\n", .{registry_path});
        return 1;
    };
    defer registry.deinit();


    if (std.mem.eql(u8, first, "--list-extensions")) {
        var buf: [8192]u8 = undefined;
        var out = Io.File.stdout().writer(io, &buf);
        const code = try listExtensions(gpa, registry, &out.interface);
        try out.interface.flush();
        return code;
    }

    const grammars_dir = if (try core.conf.resolve(gpa, io, adapters.env.vars(env), "SYNAPSE_GRAMMARS_DIR")) |d|
        d
    else
        try std.fmt.allocPrint(gpa, "{s}/.cache/synapse/grammars", .{home});
    defer gpa.free(grammars_dir);

    const kind_rules_path = if (env.get("SYNAPSE_KIND_SYNONYMS_CONF")) |p|
        try gpa.dupe(u8, p)
    else if (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-kind-synonyms.conf")) |p|
        p
    else
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-kind-synonyms.conf", .{home});
    defer gpa.free(kind_rules_path);
    var kind_rules = core.kind_synonyms.RuleList.load(gpa, io, kind_rules_path) catch {
        std.debug.print("synapse-tags: unreadable kind-synonyms conf: {s}\n", .{kind_rules_path});
        return 1;
    };
    defer kind_rules.deinit();

    var ex: Ex = .init(gpa, registry, grammars_dir, kind_rules);
    defer ex.deinit();
    // Both resolve through `core.conf.resolve` like `SYNAPSE_GRAMMARS_DIR`
    // above -- a real environment variable wins, then the first conf file
    // defining the key. They used to be bare `env.get`, which made a
    // `synapse.conf` line for either one silently inert.
    const lock_tries_raw = try core.conf.resolve(gpa, io, adapters.env.vars(env), "SYNAPSE_GRAMMAR_LOCK_TRIES");
    defer if (lock_tries_raw) |t| gpa.free(t);
    if (lock_tries_raw) |t|
        ex.lock_tries = std.fmt.parseInt(usize, t, 10) catch treesitter.grammar.default_lock_tries;
    // Owned now, where `env.get` returned a borrow into the environment:
    // `ex` holds this slice rather than copying it, so the free has to
    // outlive every `ex` call below. `Extractor.deinit` never reads it, so
    // the LIFO order against `defer ex.deinit()` is not a use-after-free.
    const query_override_dir = try core.conf.resolve(gpa, io, adapters.env.vars(env), "SYNAPSE_GRAMMARS_QUERY_PATH");
    defer if (query_override_dir) |d| gpa.free(d);
    ex.query_override_dir = query_override_dir;

    var buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    const code = if (std.mem.eql(u8, first, "--paths")) code: {
        const list_file = args.next() orelse break :code 1;
        break :code try batch(Ex, gpa, io, &ex, list_file, trace, &out.interface);
    } else try single(Ex, gpa, io, &ex, registry, first, trace, &out.interface);
    try out.interface.flush();
    return code;
}

/// The registry's usable extensions, one per line, sorted -- the allowlist
/// `vocab`/`rank` pre-filter tagging with.
pub fn listExtensions(gpa: Allocator, registry: treesitter.Registry, result: *Io.Writer) !u8 {
    const exts = try registry.usableExtensions(gpa);
    defer gpa.free(exts);
    for (exts) |e| try result.print("{s}\n", .{e});
    return 0;
}

pub fn single(
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    ex: *Ex,
    registry: treesitter.Registry,
    path: []const u8,
    trace: Trace,
    result: *Io.Writer,
) !u8 {
    Io.Dir.cwd().access(io, path, .{}) catch {
        std.debug.print("synapse-tags: no such file: {s}\n", .{path});
        return 1;
    };

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

    try trace_file.write(io, trace, &.{path});

    const results = try ex.tagWithSpans(gpa, io, ".", &.{path});
    defer gpa.free(results);
    switch (results[0]) {
        .unsupported => return 1,
        .tagged => |tagged| {
            defer treesitter.tagger.freeTagged(gpa, tagged);
            for (tagged) |t| try render(result, t.tag, t.span);
            return 0;
        },
    }
}

pub fn batch(
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    ex: *Ex,
    list_file: []const u8,
    trace: Trace,
    result: *Io.Writer,
) !u8 {
    const listing = Io.Dir.cwd().readFileAlloc(io, list_file, gpa, .limited(64 << 20)) catch {
        std.debug.print("synapse-tags: unreadable paths file: {s}\n", .{list_file});
        return 1;
    };
    defer gpa.free(listing);

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(gpa);
    var it = std.mem.splitScalar(u8, listing, '\n');
    while (it.next()) |line| {
        const p = std.mem.trim(u8, line, " \t\r");
        if (p.len != 0) try paths.append(gpa, p);
    }
    if (paths.items.len == 0) return 1;

    try trace_file.write(io, trace, paths.items);

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

    for (paths.items, results) |path, r| {
        // Unparseable: absent entirely. Parsed to nothing: still gets its
        // path line. The `unsupported` distinction rests on that.
        const tagged = switch (r) {
            .unsupported => continue,
            .tagged => |t| t,
        };
        try result.print("{s}\n", .{path});
        for (tagged) |t| {
            try result.writeAll("\t");
            try render(result, t.tag, t.span);
        }
    }
    return 0;
}


const testing = std.testing;
const fixture = @import("cmd_test_support.zig");
const fake_grammar = @import("fake_grammar.zig");

/// A real registry plus extractor, built the same way `run()` builds them
/// after its own arg-parsing -- for calling `single`/`batch`/`listExtensions`
/// directly. `git clone` (real, for any never-before-cloned extension) is
/// intercepted by `tests/fixtures/fake-bin/git`'s own `clone`-only stub,
/// already on the fixture's `PATH`; `FakeBackend` stubs only compile-and-load.
const TagsFixture = struct {
    fx: fixture.Fixture,

    fn init(gpa: Allocator) !TagsFixture {
        var fx = try fixture.Fixture.init(gpa);
        errdefer fx.deinit();
        try fx.tmp.dir.createDirPath(testing.io, "home/.claude");
        return .{ .fx = fx };
    }

    fn deinit(self: *TagsFixture) void {
        self.fx.deinit();
    }

    fn writeRegistry(self: *TagsFixture, json: []const u8) !void {
        try self.fx.tmp.dir.writeFile(testing.io, .{
            .sub_path = "home/.claude/synapse-grammars.conf",
            .data = json,
        });
    }

    /// A real file at an absolute path -- `single`/`batch` resolve the paths
    /// they're given against the real process cwd, not the fixture's tmp
    /// dir, so every path used with them has to be absolute.
    fn writeSample(self: *TagsFixture, sub_path: []const u8, content: []const u8) ![]const u8 {
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = content });
        return std.fmt.allocPrint(self.fx.gpa, "{s}/{s}", .{ self.fx.root, sub_path });
    }

    fn listPath(self: *TagsFixture, sub_path: []const u8, entries: []const []const u8) ![]const u8 {
        var body: Io.Writer.Allocating = .init(self.fx.gpa);
        defer body.deinit();
        for (entries) |e| try body.writer.print("{s}\n", .{e});
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = body.written() });
        return std.fmt.allocPrint(self.fx.gpa, "{s}/{s}", .{ self.fx.root, sub_path });
    }

    fn runSingle(self: *TagsFixture, path: []const u8, trace: Trace) !struct { code: u8, out: []u8 } {
        const gpa = self.fx.gpa;
        const registry_path = try self.registryPath();
        defer gpa.free(registry_path);
        var registry = try treesitter.Registry.load(gpa, self.fx.io(), registry_path);
        defer registry.deinit();
        var kind_rules = try core.kind_synonyms.RuleList.load(gpa, self.fx.io(), "/nonexistent");
        defer kind_rules.deinit();
        var ex: fake_grammar.FakeExtractor = .init(gpa, registry, self.fx.work, kind_rules);
        defer ex.deinit();

        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try single(fake_grammar.FakeExtractor, gpa, self.fx.io(), &ex, registry, path, trace, &out.writer);
        return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
    }

    fn runBatch(self: *TagsFixture, list_file: []const u8, trace: Trace) !struct { code: u8, out: []u8 } {
        const gpa = self.fx.gpa;
        const registry_path = try self.registryPath();
        defer gpa.free(registry_path);
        var registry = try treesitter.Registry.load(gpa, self.fx.io(), registry_path);
        defer registry.deinit();
        var kind_rules = try core.kind_synonyms.RuleList.load(gpa, self.fx.io(), "/nonexistent");
        defer kind_rules.deinit();
        var ex: fake_grammar.FakeExtractor = .init(gpa, registry, self.fx.work, kind_rules);
        defer ex.deinit();

        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try batch(fake_grammar.FakeExtractor, gpa, self.fx.io(), &ex, list_file, trace, &out.writer);
        return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
    }

    fn runListExtensions(self: *TagsFixture) !struct { code: u8, out: []u8 } {
        const gpa = self.fx.gpa;
        const registry_path = try self.registryPath();
        defer gpa.free(registry_path);
        var registry = try treesitter.Registry.load(gpa, self.fx.io(), registry_path);
        defer registry.deinit();
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try listExtensions(gpa, registry, &out.writer);
        return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
    }

    fn registryPath(self: *TagsFixture) ![]const u8 {
        return std.fmt.allocPrint(self.fx.gpa, "{s}/.claude/synapse-grammars.conf", .{self.fx.home});
    }
};

const ml_registry =
    \\{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}
;

test "single: file with no extension exits 1" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry("{}");
    const path = try tf.writeSample("noext", "no extension here\n");
    defer gpa.free(path);

    const r = try tf.runSingle(path, null);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
}

test "single: extension has no registry entry at all exits 2, no clone attempted" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry("{}");
    const path = try tf.writeSample("sample.ml", "let x = 1\n");
    defer gpa.free(path);

    const r = try tf.runSingle(path, null);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 2), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "single: extension marked unsupported exits 1, no clone attempted" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry("{\"rs\": {\"unsupported\": true}}");
    const path = try tf.writeSample("sample.rs", "fn main() {}\n");
    defer gpa.free(path);

    const r = try tf.runSingle(path, null);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
}

test "single: a known, never-cloned extension clones the grammar and prints tags" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry(ml_registry);
    const path = try tf.writeSample("sample.ml", "let x = 1\n");
    defer gpa.free(path);

    const r = try tf.runSingle(path, null);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "FAKE_NAME") != null);
    try tf.fx.tmp.dir.access(testing.io, "work/repos/tree-sitter-ocaml", .{});
}

test "single: the clone lands in a staging directory, never at the destination" {
    // Why an interrupted clone cannot leave a zombie: `git clone <dst>` builds
    // its destination in place, so a process killed mid-clone used to leave a
    // directory that existed and was not a repository, and the readiness
    // check is existence -- the next run adopted it and failed forever.
    // Publication is one rename, atomic, so there is no window where a
    // partial clone sits at the destination.
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry(ml_registry);
    const path = try tf.writeSample("sample.ml", "let x = 1\n");
    defer gpa.free(path);
    const git_log = try std.fmt.allocPrint(gpa, "{s}/git.log", .{tf.fx.root});
    defer gpa.free(git_log);
    try tf.fx.env.put("FAKE_GIT_LOG", git_log);
    try tf.fx.refreshEnv();

    const r = try tf.runSingle(path, null);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);

    const log = try tf.fx.tmp.dir.readFileAlloc(testing.io, "git.log", gpa, .limited(1 << 20));
    defer gpa.free(log);
    const line = std.mem.trimEnd(u8, log, "\n");
    const dest = line[std.mem.lastIndexOfScalar(u8, line, ' ').? + 1 ..];
    try testing.expect(std.mem.indexOf(u8, dest, ".partial.") != null);
    const final = try std.fmt.allocPrint(gpa, "{s}/work/repos/tree-sitter-ocaml", .{tf.fx.root});
    defer gpa.free(final);
    try testing.expect(!std.mem.eql(u8, dest, final));
    _ = try tf.fx.tmp.dir.access(testing.io, "work/repos/tree-sitter-ocaml", .{});
    try testing.expectEqual(error.FileNotFound, tf.fx.tmp.dir.access(testing.io, dest, .{}));
}

test "single: grammar already cloned does not clone again" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry(ml_registry);
    const path = try tf.writeSample("sample.ml", "let x = 1\n");
    defer gpa.free(path);
    try tf.fx.tmp.dir.createDirPath(testing.io, "work/repos/tree-sitter-ocaml");
    const git_log = try std.fmt.allocPrint(gpa, "{s}/git.log", .{tf.fx.root});
    defer gpa.free(git_log);
    try tf.fx.env.put("FAKE_GIT_LOG", git_log);
    try tf.fx.refreshEnv();

    const r = try tf.runSingle(path, null);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(error.FileNotFound, tf.fx.tmp.dir.access(testing.io, "git.log", .{}));
}

test "batch: a second file of the same extension resolves the grammar once, not twice" {
    // Per-extension work happens once per extension, however many files
    // carry it -- the property that survives the port from the deleted
    // shell script's own "forks nothing per file" check.
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry(ml_registry);
    const a = try tf.writeSample("a.ml", "let a = 1\n");
    defer gpa.free(a);
    const b = try tf.writeSample("b.ml", "let b = 2\n");
    defer gpa.free(b);
    const list = try tf.listPath("list.txt", &.{ a, b });
    defer gpa.free(list);
    const git_log = try std.fmt.allocPrint(gpa, "{s}/git.log", .{tf.fx.root});
    defer gpa.free(git_log);
    try tf.fx.env.put("FAKE_GIT_LOG", git_log);
    try tf.fx.refreshEnv();

    const r = try tf.runBatch(list, null);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    const log = try tf.fx.tmp.dir.readFileAlloc(testing.io, "git.log", gpa, .limited(1 << 20));
    defer gpa.free(log);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, log, "clone "));
}

test "batch: one tagging pass for the whole list, output attributable" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry(ml_registry);
    const a = try tf.writeSample("a.ml", "let a = 1\n");
    defer gpa.free(a);
    const b = try tf.writeSample("b.ml", "let b = 2\n");
    defer gpa.free(b);
    const c = try tf.writeSample("c.ml", "let c = 3\n");
    defer gpa.free(c);
    const list = try tf.listPath("list.txt", &.{ a, b, c });
    defer gpa.free(list);
    const trace_path = try std.fmt.allocPrint(gpa, "{s}/trace.log", .{tf.fx.root});
    defer gpa.free(trace_path);

    const r = try tf.runBatch(list, trace_path);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    const trace = try tf.fx.tmp.dir.readFileAlloc(testing.io, "trace.log", gpa, .limited(1 << 20));
    defer gpa.free(trace);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "tags "));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, trace, "path "));
    // Attributable: a path line, then that path's tab-indented tags.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, r.out, "\n\t"));
}

test "batch: an extension with no grammar still lets the rest tag" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry(ml_registry);
    const a = try tf.writeSample("a.ml", "let a = 1\n");
    defer gpa.free(a);
    const one = try tf.writeSample("one.zzz", "x\n");
    defer gpa.free(one);
    const two = try tf.writeSample("two.zzz", "y\n");
    defer gpa.free(two);
    const list = try tf.listPath("list.txt", &.{ a, one, two });
    defer gpa.free(list);

    const r = try tf.runBatch(list, null);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "a.ml") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, ".zzz") == null);
}

test "batch: a one-path list still gets a path line and indented tags, matching a many-path list's shape" {
    // Asserted as an equivalence, not two separate expectations, so the
    // normalisation cannot drift in only one direction.
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry(ml_registry);
    const a = try tf.writeSample("a.ml", "let a = 1\n");
    defer gpa.free(a);
    const b = try tf.writeSample("b.ml", "let b = 2\n");
    defer gpa.free(b);

    const one_list = try tf.listPath("one.txt", &.{a});
    defer gpa.free(one_list);
    const alone = try tf.runBatch(one_list, null);
    defer gpa.free(alone.out);
    try testing.expectEqual(@as(u8, 0), alone.code);
    try testing.expect(std.mem.startsWith(u8, alone.out, a));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, alone.out, "\n\t"));

    const two_list = try tf.listPath("two.txt", &.{ a, b });
    defer gpa.free(two_list);
    const together = try tf.runBatch(two_list, null);
    defer gpa.free(together.out);
    try testing.expectEqual(@as(u8, 0), together.code);
    // a.ml's slice of the two-path output: its path line plus every
    // following indented line, up to the next unindented one.
    var lines = std.mem.splitScalar(u8, together.out, '\n');
    var slice: Io.Writer.Allocating = .init(gpa);
    defer slice.deinit();
    var on = false;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, a)) {
            on = true;
            try slice.writer.print("{s}\n", .{line});
            continue;
        }
        if (on and std.mem.startsWith(u8, line, "\t")) {
            try slice.writer.print("{s}\n", .{line});
            continue;
        }
        if (on) break;
    }
    try testing.expectEqualStrings(alone.out, slice.written());
}

test "batch: no usable grammar for anything in the list exits 1, and nothing but warnings prints" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry("{}");
    const one = try tf.writeSample("one.zzz", "x\n");
    defer gpa.free(one);
    const list = try tf.listPath("list.txt", &.{one});
    defer gpa.free(list);

    const r = try tf.runBatch(list, null);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "batch: a missing list file exits 1 rather than tagging nothing quietly" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry(ml_registry);
    const missing = try std.fmt.allocPrint(gpa, "{s}/nope.txt", .{tf.fx.root});
    defer gpa.free(missing);

    const r = try tf.runBatch(missing, null);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
}

test "--list-extensions: the registry's usable entries, one per line, sorted" {
    // An entry marked unsupported, or missing repo or scope, is not usable
    // and must not appear -- a caller that tags on the strength of this list
    // would get a warning per file for a language it was told was available.
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.writeRegistry(
        \\{"py": {"repo": "https://example.invalid/tree-sitter-python", "scope": "source.python"},
        \\ "java": {"repo": "https://example.invalid/tree-sitter-java", "scope": "source.java"},
        \\ "rs": {"unsupported": true},
        \\ "go": {"repo": "https://example.invalid/tree-sitter-go"}}
    );

    const r = try tf.runListExtensions();
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("java\npy\n", r.out);
}
