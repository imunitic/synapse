//! Grammar preparation: from a registry entry to a loaded `TSLanguage`.
//! Clones the grammar repo on first use (locked), then compiles it --
//! `zig cc` first, falling back to `cc`/`gcc`/`clang`, each actually
//! invoked rather than just version-probed.

const std = @import("std");
const root = @import("root.zig");
const process = @import("adapters").process;
const dir_lock = @import("adapters").dir_lock;

const c = root.c;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Shared default for every grammar-lock retry count in this codebase
/// (`Extractor.lock_tries`, the `SYNAPSE_GRAMMAR_LOCK_TRIES` fallback,
/// `build`'s own `max_tries`) so they can't drift apart.
pub const default_lock_tries: usize = 300;

pub const Error = error{
    NoCompiler,
    CloneFailed,
    CompileFailed,
    ParserSourceMissing,
    SymbolNotFound,
    /// Grammar ABI newer than the pinned libtree-sitter supports.
    AbiUnsupported,
};

/// `tree-sitter-java` -> `tree_sitter_java`, matching the CLI's own derivation.
/// A repo shipping two grammars (tree-sitter-typescript) needs the registry
/// entry to name the symbol explicitly.
pub fn symbolFor(gpa: Allocator, repo_name: []const u8) ![]u8 {
    const stem = if (std.mem.startsWith(u8, repo_name, "tree-sitter-"))
        repo_name["tree-sitter-".len..]
    else
        repo_name;
    const out = try gpa.alloc(u8, "tree_sitter_".len + stem.len);
    @memcpy(out[0.."tree_sitter_".len], "tree_sitter_");
    for (stem, 0..) |ch, i| out["tree_sitter_".len + i] = if (ch == '-') '_' else ch;
    return out;
}

/// Shared-library extension for `std.DynLib` (`dlopen`/`LoadLibrary`).
pub fn sharedLibExt() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "dll",
        .macos, .ios, .watchos, .tvos => "dylib",
        else => "so",
    };
}

/// `basename` of a git URL with any `.git` suffix removed.
pub fn repoNameOf(url: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    const base = std.fs.path.basename(trimmed);
    return if (std.mem.endsWith(u8, base, ".git")) base[0 .. base.len - ".git".len] else base;
}

pub const Compiler = struct {
    argv0: []const u8,
    /// `cc` for zig, nothing for a compiler that is one already.
    sub: ?[]const u8,

    /// What to call it in a message: `zig cc`, or just `clang`.
    pub fn label(self: Compiler, gpa: Allocator) ![]u8 {
        return if (self.sub) |s|
            std.fmt.allocPrint(gpa, "{s} {s}", .{ self.argv0, s })
        else
            gpa.dupe(u8, self.argv0);
    }
};

/// Preference order. `zig cc` first (same toolchain, cross-compiles); the
/// rest match what `synapse-tags.sh` accepted.
pub const compilers = [_]Compiler{
    .{ .argv0 = "zig", .sub = "cc" },
    .{ .argv0 = "cc", .sub = null },
    .{ .argv0 = "gcc", .sub = null },
    .{ .argv0 = "clang", .sub = null },
};

/// First candidate on PATH -- a precondition check, not a promise it works.
pub fn findCompiler(io: Io, gpa: Allocator) !Compiler {
    for (compilers) |candidate| {
        const version_arg = if (candidate.sub != null) "version" else "--version";
        if (probe(io, gpa, &.{ candidate.argv0, version_arg })) return candidate;
    }
    return Error.NoCompiler;
}

/// Whether the command exists and exits 0 -- not proof it can compile: `cc
/// --version` can succeed while `cc` itself fails with "cannot execute
/// 'cc1'" (missing backend). Decides try order only, never which one wins.
fn probe(io: Io, gpa: Allocator, argv: []const []const u8) bool {
    const res = process.run(io, gpa, argv, .{}) catch return false;
    defer res.deinit(gpa);
    return res.ok();
}

/// Compiles `repo_dir/src/parser.c` (+ `scanner.c` if present) into
/// `out_path`. No-op if the artefact is already newer than every source.
/// `max_tries` bounds the compile lock's wait, same as `ensureCloned`'s.
pub fn build(io: Io, gpa: Allocator, repo_dir: []const u8, out_path: []const u8, max_tries: usize) !void {
    const cwd = Io.Dir.cwd();

    const parser_c = try std.fs.path.join(gpa, &.{ repo_dir, "src", "parser.c" });
    defer gpa.free(parser_c);
    cwd.access(io, parser_c, .{}) catch return Error.ParserSourceMissing;

    var sources: std.ArrayListUnmanaged([]const u8) = .empty;
    defer sources.deinit(gpa);
    try sources.append(gpa, parser_c);

    // C++ scanners need `zig c++` and libc++, not supported yet.
    const scanner_c = try std.fs.path.join(gpa, &.{ repo_dir, "src", "scanner.c" });
    defer gpa.free(scanner_c);
    const scanner_cc = try std.fs.path.join(gpa, &.{ repo_dir, "src", "scanner.cc" });
    defer gpa.free(scanner_cc);
    if (cwd.access(io, scanner_c, .{})) |_| {
        try sources.append(gpa, scanner_c);
    } else |_| if (cwd.access(io, scanner_cc, .{})) |_| {
        std.debug.print(
            "synapse: {s} has a C++ scanner, which is not supported yet -- skipping that grammar\n",
            .{repo_dir},
        );
        return Error.CompileFailed;
    } else |_| {}

    if (try upToDate(io, out_path, sources.items)) return;

    // Must exist before the lock dir is created under it -- `createDir` is
    // single-level and fails on a missing parent, which a fresh
    // `grammars_dir` always is on its first-ever compile.
    if (std.fs.path.dirname(out_path)) |dir| cwd.createDirPath(io, dir) catch {};

    // Same locking discipline as `ensureCloned`'s clone lock, kept separate:
    // compiling and cloning are different resources, and serializing a fast
    // compile behind a network-clone-sized wait would be its own bug.
    const compile_lock_dir = try std.fmt.allocPrint(gpa, "{s}.lock", .{out_path});
    defer gpa.free(compile_lock_dir);

    var got_compile_lock = false;
    var compile_tries: usize = 0;
    while (compile_tries < max_tries) : (compile_tries += 1) {
        if (try dir_lock.tryAcquire(gpa, io, compile_lock_dir, lock_stale_after_ns)) |acquired| {
            gpa.free(acquired);
            got_compile_lock = true;
            break;
        }
        // Re-checked every wait cycle, not just before/after the loop: another
        // process may finish compiling while this one is still waiting, and
        // that should end the wait immediately rather than contending for a
        // lock this call no longer needs.
        if (try upToDate(io, out_path, sources.items)) return;
        std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    }

    if (!got_compile_lock) {
        std.debug.print(
            "synapse: timed out waiting for the compile lock {s} -- another synapse is compiling " ++
                "this grammar, or one was killed within the last {d} minutes; a lock left by a " ++
                "crash is taken over automatically once it is older than that\n",
            .{ compile_lock_dir, @divTrunc(lock_stale_after_ns, std.time.ns_per_min) },
        );
        return Error.CompileFailed;
    }
    defer cwd.deleteDir(io, compile_lock_dir) catch {};

    if (try upToDate(io, out_path, sources.items)) return; // re-check under the lock

    const src_dir = try std.fs.path.join(gpa, &.{ repo_dir, "src" });
    defer gpa.free(src_dir);
    const include = try std.fmt.allocPrint(gpa, "-I{s}", .{src_dir});
    defer gpa.free(include);

    // -fPIC/-shared for loadability, -O2 since a parser is hot and paid once.
    // No -march=native: the artefact may outlive the machine that built it.
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "-shared", "-fPIC", "-O2", include, "-o", out_path });
    try argv.appendSlice(gpa, sources.items);

    // Every present candidate gets a real attempt; failures are collected
    // rather than reported from the first one (see `probe`).
    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    var tried: usize = 0;

    for (compilers) |candidate| {
        const version_arg = if (candidate.sub != null) "version" else "--version";
        if (!probe(io, gpa, &.{ candidate.argv0, version_arg })) continue;
        tried += 1;

        var full: std.ArrayListUnmanaged([]const u8) = .empty;
        defer full.deinit(gpa);
        try full.append(gpa, candidate.argv0);
        if (candidate.sub) |s| try full.append(gpa, s);
        try full.appendSlice(gpa, argv.items);

        const res = try process.run(io, gpa, full.items, .{});
        defer res.deinit(gpa);
        if (res.ok()) return;

        const name = try candidate.label(gpa);
        defer gpa.free(name);
        try report.writer.print("  {s}: {s}\n", .{ name, std.mem.trimEnd(u8, res.stderr, "\n") });
    }

    if (tried == 0) return Error.NoCompiler;
    std.debug.print("synapse: compiling {s} failed with every compiler found:\n{s}", .{
        repo_dir, report.written(),
    });
    return Error.CompileFailed;
}

/// Newer than every source, not just `parser.c` -- an external scanner
/// changes on its own (e.g. a `git pull` touching only `scanner.c`), and
/// checking the parser alone would silently reuse a stale scanner.
fn upToDate(io: Io, out_path: []const u8, sources: []const []const u8) !bool {
    const cwd = Io.Dir.cwd();
    const out = cwd.statFile(io, out_path, .{}) catch return false;
    for (sources) |source| {
        const src = cwd.statFile(io, source, .{}) catch return false;
        if (out.mtime.nanoseconds < src.mtime.nanoseconds) return false;
    }
    return true;
}

/// Clones into `repos_parent/<name>` if not already there, under a lock so
/// parallel workers don't race a `git clone` into the same destination. A
/// lock is honoured while it could belong to a live holder, and taken over
/// once it's older than `lock_stale_after_ns`.
pub fn ensureCloned(
    io: Io,
    gpa: Allocator,
    repo_url: []const u8,
    repos_parent: []const u8,
    max_tries: usize,
) ![]u8 {
    const cwd = Io.Dir.cwd();
    const repo_dir = try std.fs.path.join(gpa, &.{ repos_parent, repoNameOf(repo_url) });
    errdefer gpa.free(repo_dir);

    if (cwd.access(io, repo_dir, .{})) |_| return repo_dir else |_| {}

    try cwd.createDirPath(io, repos_parent);

    const lock_dir = try std.fmt.allocPrint(gpa, "{s}.lock", .{repo_dir});
    defer gpa.free(lock_dir);

    var got_lock = false;
    var tries: usize = 0;
    while (tries < max_tries) : (tries += 1) {
        if (try dir_lock.tryAcquire(gpa, io, lock_dir, lock_stale_after_ns)) |acquired| {
            gpa.free(acquired);
            got_lock = true;
            break;
        }
        if (cwd.access(io, repo_dir, .{})) |_| break else |_| {} // holder may have finished
        std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    }

    if (got_lock) {
        defer cwd.deleteDir(io, lock_dir) catch {};
        if (cwd.access(io, repo_dir, .{})) |_| return repo_dir else |_| {} // re-check under the lock

        try cloneInto(io, gpa, repo_url, repo_dir);
        return repo_dir;
    }

    // Not old enough to take over, and still nothing there: a live clone
    // slower than the ceiling, or a too-recent crash. The path is named in
    // the message because `CloneFailed` alone reads as a network error.
    cwd.access(io, repo_dir, .{}) catch {
        std.debug.print(
            "synapse: timed out waiting for the grammar lock {s} -- another synapse is cloning, " ++
                "or one was killed within the last {d} minutes; a lock left by a crash is taken " ++
                "over automatically once it is older than that\n",
            .{ lock_dir, @divTrunc(lock_stale_after_ns, std.time.ns_per_min) },
        );
        return Error.CloneFailed;
    };
    return repo_dir;
}

/// How long a lock must go untouched before it counts as abandoned. A
/// `--depth 1` clone is a few MB, so nothing legitimate needs 15 minutes --
/// well past the ~60s a waiter gives up after.
pub const lock_stale_after_ns: i96 = 15 * std.time.ns_per_min;

/// Clones into a private staging directory and publishes with one atomic
/// rename, so a killed clone (SIGKILL, full disk) never gets adopted as a
/// finished repo -- existence alone used to mean "done."
fn cloneInto(io: Io, gpa: Allocator, repo_url: []const u8, repo_dir: []const u8) !void {
    const cwd = Io.Dir.cwd();

    const staged = try std.fmt.allocPrint(gpa, "{s}.partial.{d}", .{
        repo_dir, Io.Timestamp.now(io, .awake).nanoseconds,
    });
    defer gpa.free(staged);

    const res = try process.run(io, gpa, &.{ "git", "clone", "--depth", "1", "-q", repo_url, staged }, .{});
    defer res.deinit(gpa);
    if (!res.ok()) {
        cwd.deleteTree(io, staged) catch {};
        return Error.CloneFailed;
    }

    cwd.rename(staged, cwd, repo_dir, io) catch {
        // Losing the rename is the ordinary way two concurrent clones end --
        // the winner's copy is as good as ours.
        cwd.deleteTree(io, staged) catch {};
        cwd.access(io, repo_dir, .{}) catch return Error.CloneFailed;
    };
}

/// Loads a built grammar, refusing an ABI the pinned libtree-sitter can't
/// parse with rather than surfacing it later as an unexplained empty parse.
pub fn load(gpa: Allocator, lib_path: []const u8, symbol: []const u8) !*const c.TSLanguage {
    var lib = try std.DynLib.open(lib_path);
    // Not closed: the returned TSLanguage points into this image and every
    // caller keeps using it for the process's life.
    const sym = try gpa.dupeZ(u8, symbol);
    defer gpa.free(sym);

    const LangFn = *const fn () callconv(.c) ?*const c.TSLanguage;
    const fn_ptr = lib.lookup(LangFn, sym) orelse return Error.SymbolNotFound;
    const lang = fn_ptr() orelse return Error.SymbolNotFound;

    const abi = c.ts_language_abi_version(lang);
    if (abi < root.abi_min or abi > root.abi_max) return Error.AbiUnsupported;
    return lang;
}

const testing = std.testing;

test "symbol names are derived the way the CLI derives them" {
    const gpa = testing.allocator;
    const java = try symbolFor(gpa, "tree-sitter-java");
    defer gpa.free(java);
    try testing.expectEqualStrings("tree_sitter_java", java);

    const embedded = try symbolFor(gpa, "tree-sitter-embedded-template");
    defer gpa.free(embedded);
    try testing.expectEqualStrings("tree_sitter_embedded_template", embedded);
}

test "repo names come off a URL with or without .git" {
    try testing.expectEqualStrings("tree-sitter-java", repoNameOf("https://github.com/tree-sitter/tree-sitter-java"));
    try testing.expectEqualStrings("tree-sitter-java", repoNameOf("https://github.com/tree-sitter/tree-sitter-java.git"));
    try testing.expectEqualStrings("tree-sitter-java", repoNameOf("git@github.com:tree-sitter/tree-sitter-java.git"));
}

test "a compiler is found on this machine" {
    const found = try findCompiler(testing.io, testing.allocator);
    try testing.expect(found.argv0.len > 0);
}

test "compiling into a nested output dir that doesn't exist yet -- a fresh grammars_dir's first-ever compile" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/parser.c",
        .data = "void *tree_sitter_fake(void) { return 0; }\n",
    });

    // Mirrors extractor.zig's real lib_path shape: {grammars_dir}/lib/{symbol}.{ext} --
    // "lib" must not exist yet, or this doesn't reproduce the bug.
    const out = try std.fmt.allocPrint(gpa, "{s}/lib/fake.{s}", .{ dir, sharedLibExt() });
    defer gpa.free(out);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, std.fs.path.dirname(out).?, .{}));

    try build(io, gpa, dir, out, default_lock_tries);
    try Io.Dir.cwd().access(io, out, .{});
}

test "end to end: compile a source tree and load a symbol out of it" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/parser.c",
        .data = "void *tree_sitter_fake(void) { return 0; }\n",
    });

    const out = try std.fmt.allocPrint(gpa, "{s}/fake.{s}", .{ dir, sharedLibExt() });
    defer gpa.free(out);

    try build(io, gpa, dir, out, default_lock_tries);
    try Io.Dir.cwd().access(io, out, .{});

    try testing.expectError(Error.SymbolNotFound, load(gpa, out, "tree_sitter_fake"));
    try testing.expectError(Error.SymbolNotFound, load(gpa, out, "tree_sitter_absent"));

    try build(io, gpa, dir, out, default_lock_tries); // no-op: already up to date
}

test "a scanner newer than the artefact rebuilds it, the way a newer parser does" {
    const gpa = testing.allocator;
    const io = testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/parser.c",
        .data = "void *tree_sitter_fake(void) { return 0; }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/scanner.c",
        .data = "int fake_scan(void) { return 1; }\n",
    });

    const out = try std.fmt.allocPrint(gpa, "{s}/scan.{s}", .{ dir, sharedLibExt() });
    defer gpa.free(out);

    try build(io, gpa, dir, out, default_lock_tries);
    const built_at = (try cwd.statFile(io, out, .{})).mtime.nanoseconds;

    try build(io, gpa, dir, out, default_lock_tries); // control: still a no-op
    try testing.expectEqual(built_at, (try cwd.statFile(io, out, .{})).mtime.nanoseconds);

    // Only the scanner moves, to a second after the artefact (set, not
    // slept for). Isolates the scanner from the parser, which stays older.
    const scanner = try std.fs.path.join(gpa, &.{ dir, "src", "scanner.c" });
    defer gpa.free(scanner);
    {
        const f = try cwd.openFile(io, scanner, .{ .mode = .read_write });
        defer f.close(io);
        try f.setTimestamps(io, .{
            .modify_timestamp = .{ .new = .{ .nanoseconds = built_at + std.time.ns_per_s } },
        });
    }

    try build(io, gpa, dir, out, default_lock_tries);
    try testing.expect((try cwd.statFile(io, out, .{})).mtime.nanoseconds > built_at);
}

test "a source tree with no parser.c is refused, not compiled into nothing" {
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const out = try std.fmt.allocPrint(gpa, "{s}/none.{s}", .{ dir, sharedLibExt() });
    defer gpa.free(out);

    try testing.expectError(Error.ParserSourceMissing, build(testing.io, gpa, dir, out, default_lock_tries));
}

/// A local git repo to clone from, so the lock/staging/failure paths are
/// exercised without leaving the machine. Skips if no usable git.
fn stageSourceRepo(io: Io, gpa: Allocator, base: []const u8) ![]u8 {
    const cwd = Io.Dir.cwd();
    const src = try std.fmt.allocPrint(gpa, "{s}/tree-sitter-fake", .{base});
    errdefer gpa.free(src);
    try cwd.createDirPath(io, src);

    const readme = try std.fmt.allocPrint(gpa, "{s}/README", .{src});
    defer gpa.free(readme);
    try cwd.writeFile(io, .{ .sub_path = readme, .data = "x" });

    for ([_][]const []const u8{
        &.{ "git", "init", "-q", src },
        &.{ "git", "-C", src, "add", "-A" },
        &.{ "git", "-C", src, "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-qm", "x" },
    }) |argv| {
        const r = try process.run(io, gpa, argv, .{});
        defer r.deinit(gpa);
        if (!r.ok()) return error.SkipZigTest;
    }
    return src;
}

test "cloning is hermetic, idempotent, and leaves no lock behind" {
    const gpa = testing.allocator;
    const io = testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];

    const src = try stageSourceRepo(io, gpa, base);
    defer gpa.free(src);

    const parent = try std.fmt.allocPrint(gpa, "{s}/repos", .{base});
    defer gpa.free(parent);

    const first = try ensureCloned(io, gpa, src, parent, 5);
    defer gpa.free(first);
    try cwd.access(io, first, .{});
    try testing.expect(std.mem.endsWith(u8, first, "tree-sitter-fake"));

    const lock = try std.fmt.allocPrint(gpa, "{s}.lock", .{first});
    defer gpa.free(lock);
    try testing.expectError(error.FileNotFound, cwd.access(io, lock, .{})); // lock released

    const second = try ensureCloned(io, gpa, src, parent, 5);
    defer gpa.free(second);
    try testing.expectEqualStrings(first, second); // no-op on repeat

    var dir = try Io.Dir.cwd().openDir(io, parent, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.name, ".partial") == null); // no staging leftovers
    }
}

test "a lock older than the staleness window is taken over, a fresh one is not" {
    const gpa = testing.allocator;
    const io = testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];

    const src = try stageSourceRepo(io, gpa, base);
    defer gpa.free(src);

    const parent = try std.fmt.allocPrint(gpa, "{s}/repos", .{base});
    defer gpa.free(parent);
    try cwd.createDirPath(io, parent);
    const lock = try std.fmt.allocPrint(gpa, "{s}/tree-sitter-fake.lock", .{parent});
    defer gpa.free(lock);

    try cwd.createDirPath(io, lock);
    try testing.expectError(Error.CloneFailed, ensureCloned(io, gpa, src, parent, 2));
    try cwd.access(io, lock, .{}); // timed-out waiter did not delete it

    const long_ago = Io.Timestamp.now(io, .real).nanoseconds - lock_stale_after_ns - std.time.ns_per_min;
    try cwd.setTimestamps(io, lock, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = long_ago } } });

    const dir = try ensureCloned(io, gpa, src, parent, 2);
    defer gpa.free(dir);

    const readme = try std.fmt.allocPrint(gpa, "{s}/README", .{dir});
    defer gpa.free(readme);
    try cwd.access(io, readme, .{}); // a real clone, not just an empty directory

    try testing.expectError(error.FileNotFound, cwd.access(io, lock, .{}));
}

test "compiling is locked the same way cloning is: a fresh lock refuses, a stale one is taken over" {
    const gpa = testing.allocator;
    const io = testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/parser.c",
        .data = "void *tree_sitter_fake(void) { return 0; }\n",
    });

    const out = try std.fmt.allocPrint(gpa, "{s}/locked.{s}", .{ dir, sharedLibExt() });
    defer gpa.free(out);
    const lock = try std.fmt.allocPrint(gpa, "{s}.lock", .{out});
    defer gpa.free(lock);

    try cwd.createDirPath(io, lock);
    try testing.expectError(Error.CompileFailed, build(io, gpa, dir, out, 2));
    try cwd.access(io, lock, .{}); // timed-out waiter did not delete it
    try testing.expectError(error.FileNotFound, cwd.access(io, out, .{}));

    const long_ago = Io.Timestamp.now(io, .real).nanoseconds - lock_stale_after_ns - std.time.ns_per_min;
    try cwd.setTimestamps(io, lock, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = long_ago } } });

    try build(io, gpa, dir, out, 2);
    try cwd.access(io, out, .{});

    try testing.expectError(error.FileNotFound, cwd.access(io, lock, .{}));
}

test "a clone that fails reports it rather than leaving a half-built directory" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const parent = try std.fmt.allocPrint(gpa, "{s}/repos", .{base});
    defer gpa.free(parent);

    const missing = try std.fmt.allocPrint(gpa, "{s}/tree-sitter-absent", .{base});
    defer gpa.free(missing);

    try testing.expectError(Error.CloneFailed, ensureCloned(io, gpa, missing, parent, 5));
    const left = try std.fmt.allocPrint(gpa, "{s}/tree-sitter-absent", .{parent});
    defer gpa.free(left);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, left, .{}));
}
