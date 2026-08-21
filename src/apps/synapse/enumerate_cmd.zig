//! `synapse enumerate` -- tracked files worth graphing, into the work dir.
//!
//!   enumerate [--reenumerate]   tracked files worth graphing, into the work dir
//!
//! Writes `$SYNAPSE_WORK_DIR/all.txt` (`git ls-files` order) and
//! `oversize.txt` (`size<TAB>path`). An existing non-empty `all.txt` is
//! reused unless `--reenumerate` forces a rebuild.
//!
//! Identity resolves in-process via `core.identity.resolve()`; the work
//! dir arrives via `SYNAPSE_WORK_DIR`, and its absence is an error, not a
//! guess.
//!
//! Measured on syrius3: bash spent 15.9s / 65 spawns (45 of them `sed`, one
//! per conf line) enumerating 124,817 of 125,351 tracked files; this is one
//! `git ls-files` plus one `statFile` per path. `git ls-files` stays a real
//! spawn (git owns that binary format); the extension/lockfile filters moved
//! into `core/enumerate.zig`, but the user's own EREs stay on real `grep -vE`
//! rather than a reimplemented dialect that would disagree at the edges.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var reenumerate = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = usage();
            return 0;
        }
        if (std.mem.eql(u8, arg, "--reenumerate")) {
            reenumerate = true;
        } else return usage();
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try runEnumerate(gpa, io, env, ".", reenumerate, &out.interface);
    try out.interface.flush();
    return code;
}

/// The command itself, minus argument parsing -- separated so a test can
/// drive it against a real fixture repo without depending on the test
/// process's own cwd. `identity_path` is `"."` for the real CLI (identity
/// resolves from wherever the process was invoked) or a fixture's real
/// repo root for a test.
pub fn runEnumerate(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    identity_path: []const u8,
    reenumerate: bool,
    result: *Io.Writer,
) !u8 {
    // Outside a repo, say so rather than letting `git ls-files` fail with its own wording.
    const id = core.identity.resolve(gpa, io, identity_path) catch {
        std.debug.print("synapse-enumerate: not inside a git repo\n", .{});
        return 1;
    };
    defer id.deinit(gpa);

    const work = (try context.workDir(gpa, io, env, "synapse-enumerate")) orelse return 1;
    defer work.deinit(gpa);
    const work_dir = work.path;
    if (work_dir.len == 0) {
        std.debug.print("synapse-enumerate: empty SYNAPSE_WORK_DIR\n", .{});
        return 1;
    }

    try ensure(gpa, io, env, id.layout.repo_root, work_dir, reenumerate, result);
    return 0;
}

/// Brings `all.txt`/`oversize.txt` up to date and reports: the rebuild
/// banner when a rebuild happens, the oversize report if anything was
/// skipped, `enumerated: N` always. Shared with `build-lists` (writes to
/// the caller's own writer) rather than spawned, since a native test below
/// asserts on where these lines land.
pub fn ensure(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    repo_root: []const u8,
    work_dir: []const u8,
    reenumerate: bool,
    out: *Io.Writer,
) !void {
    const all_path = try std.fmt.allocPrint(gpa, "{s}/all.txt", .{work_dir});
    defer gpa.free(all_path);
    const oversize_path = try std.fmt.allocPrint(gpa, "{s}/oversize.txt", .{work_dir});
    defer gpa.free(oversize_path);

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, work_dir) catch {};

    // Checked by size, not existence: a zero-byte all.txt from an
    // interrupted run is not a usable enumeration.
    const existing: u64 = if (cwd.statFile(io, all_path, .{})) |st| st.size else |_| 0;
    if (existing == 0 or reenumerate) {
        try out.writeAll("--- enumerating tracked files\n");
        try out.flush();
        try enumerateInto(gpa, io, env, repo_root, all_path, oversize_path);
    }

    try reportOversize(gpa, io, env, out, oversize_path);

    const kept = countLines(gpa, io, all_path) catch 0;
    try out.print("enumerated: {d}\n", .{kept});
}

fn usage() u8 {
    std.debug.print(
        \\usage: synapse enumerate [--reenumerate]
        \\
    , .{});
    return 2;
}

/// Default cap (`SYNAPSE_MAX_FILE_BYTES`). Skips are reported, not silent --
/// a silent skip would make `enumerated` disagree with the repo.
const default_max_file_bytes: u64 = 1048576;

fn maxFileBytes(env: *std.process.Environ.Map) u64 {
    const raw = env.get("SYNAPSE_MAX_FILE_BYTES") orelse return default_max_file_bytes;
    return std.fmt.parseInt(u64, raw, 10) catch default_max_file_bytes;
}

fn enumerateInto(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    repo_root: []const u8,
    all_path: []const u8,
    oversize_path: []const u8,
) !void {
    const cwd = Io.Dir.cwd();
    // Truncated up front so a clean rebuild doesn't keep the previous run's findings.
    try cwd.writeFile(io, .{ .sub_path = oversize_path, .data = "" });

    // Explicit cwd, not inherited: every real caller invokes from the repo
    // root anyway, but a test needs to point this at a fixture repo without
    // touching the test process's own cwd.
    const listed = try adapters.process.run(io, gpa, &.{ "git", "ls-files" }, .{
        .cwd = .{ .path = repo_root },
    });
    defer listed.deinit(gpa);
    if (!listed.ok()) return error.GitLsFilesFailed;

    const candidates = try applyUserPatterns(gpa, io, env, listed.stdout);
    defer if (candidates.ptr != listed.stdout.ptr) gpa.free(candidates);

    var all: std.Io.Writer.Allocating = .init(gpa);
    defer all.deinit();
    var oversize: std.Io.Writer.Allocating = .init(gpa);
    defer oversize.deinit();

    const cap = maxFileBytes(env);
    var it = std.mem.splitScalar(u8, candidates, '\n');
    while (it.next()) |path| {
        if (path.len == 0) continue;
        if (core.enumerate.isExcluded(path)) continue;

        // One statFile answers both is-it-a-regular-file (a submodule gitlink
        // is an ls-files entry but a directory on disk) and how big. Symlinks
        // followed: measures the target, not the link, unlike the script.
        const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ repo_root, path });
        defer gpa.free(full);
        const st = cwd.statFile(io, full, .{}) catch continue;
        if (st.kind != .file) continue;
        if (st.size > cap) {
            try oversize.writer.print("{d}\t{s}\n", .{ st.size, path });
        } else {
            try all.writer.print("{s}\n", .{path});
        }
    }

    try cwd.writeFile(io, .{ .sub_path = all_path, .data = all.written() });
    try cwd.writeFile(io, .{ .sub_path = oversize_path, .data = oversize.written() });
}

/// `$SYNAPSE_EXTRA_EXCLUDE_RE` OR'd with every pattern line of
/// `~/.claude/synapse-ignore-files.conf`, applied by one `grep -vE`. Returns
/// the input untouched when there are no patterns (the common case) --
/// an empty ERE matches every line, so a missing guard would enumerate zero files.
pub fn applyUserPatterns(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    listing: []u8,
) ![]u8 {
    var pattern: std.Io.Writer.Allocating = .init(gpa);
    defer pattern.deinit();

    if (env.get("SYNAPSE_EXTRA_EXCLUDE_RE")) |re| {
        if (re.len != 0) try pattern.writer.writeAll(re);
    }

    if (env.get("HOME")) |home| {
        const conf = (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-ignore-files.conf")) orelse
            try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-ignore-files.conf", .{home});
        defer gpa.free(conf);
        if (Io.Dir.cwd().readFileAlloc(io, conf, gpa, .limited(1 << 20))) |text| {
            defer gpa.free(text);
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |raw| {
                const uncommented = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
                const pat = std.mem.trim(u8, uncommented, " \t\r");
                if (pat.len == 0) continue;
                if (pattern.written().len != 0) try pattern.writer.writeAll("|");
                try pattern.writer.writeAll(pat);
            }
        } else |_| {}
    }

    if (pattern.written().len == 0) return listing;

    const res = try adapters.process.run(io, gpa, &.{ "grep", "-vE", pattern.written() }, .{
        .stdin = listing,
    });
    defer gpa.free(res.stderr);
    // grep exits 1 when every line matched (everything excluded) -- a
    // legitimate empty result, not a failure.
    if (res.exitCode()) |code| {
        if (code > 1) {
            gpa.free(res.stdout);
            return error.GrepFailed;
        }
    } else {
        gpa.free(res.stdout);
        return error.GrepFailed;
    }
    return res.stdout;
}

/// `skipped N file(s) over CAP bytes (largest first):` and the five biggest.
fn reportOversize(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
    oversize_path: []const u8,
) !void {
    const text = Io.Dir.cwd().readFileAlloc(io, oversize_path, gpa, .limited(64 << 20)) catch return;
    defer gpa.free(text);
    if (text.len == 0) return;

    const Row = struct { size: u64, path: []const u8 };
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer rows.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const size = std.fmt.parseInt(u64, line[0..tab], 10) catch continue;
        try rows.append(gpa, .{ .size = size, .path = line[tab + 1 ..] });
    }
    if (rows.items.len == 0) return;

    try out.print("skipped {d} file(s) over {d} bytes (largest first):\n", .{
        rows.items.len,
        maxFileBytes(env),
    });
    std.mem.sort(Row, rows.items, {}, struct {
        fn desc(_: void, a: Row, b: Row) bool {
            return a.size > b.size;
        }
    }.desc);
    for (rows.items[0..@min(5, rows.items.len)]) |r|
        try out.print("  {d: >10}  {s}\n", .{ r.size, r.path });
}

fn countLines(gpa: Allocator, io: Io, path: []const u8) !usize {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20));
    defer gpa.free(text);
    return std.mem.count(u8, text, "\n");
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

fn makeMixedRepo(fx: *fixture.Fixture) !void {
    try fx.writeRepoFile("mod-a/src/main/java/A.java", "class A {}\n");
    try fx.writeRepoFile("docs/guide.md", "# guide\n");
    try fx.writeRepoFile("stray.txt", "stray\n");
    try fx.writeRepoFile("assets/logo.png", "PNGDATA\n");
    try fx.gitCommit("mixed");
}

fn runEnum(gpa: Allocator, fx: *fixture.Fixture, reenumerate: bool) !struct { out: []u8 } {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try runEnumerate(gpa, fx.io(), &fx.env, fx.repo, reenumerate, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    return .{ .out = try gpa.dupe(u8, out.written()) };
}

test "enumerates tracked files with no manifest.tsv anywhere -- the whole point of the split" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeMixedRepo(&fx);

    const r = try runEnum(gpa, &fx, false);
    defer gpa.free(r.out);

    const all = try fx.tmp.dir.readFileAlloc(testing.io, "work/all.txt", gpa, .limited(1 << 20));
    defer gpa.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "mod-a/src/main/java/A.java\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "docs/guide.md\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "logo.png") == null);
}

test "prints the enumerated count" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeMixedRepo(&fx);

    const r = try runEnum(gpa, &fx, false);
    defer gpa.free(r.out);

    const all = try fx.tmp.dir.readFileAlloc(testing.io, "work/all.txt", gpa, .limited(1 << 20));
    defer gpa.free(all);
    const enumerated = std.mem.count(u8, all, "\n");
    const want = try std.fmt.allocPrint(gpa, "enumerated: {d}", .{enumerated});
    defer gpa.free(want);
    try testing.expect(std.mem.indexOf(u8, r.out, want) != null);
}

test "an existing all.txt is reused, and --reenumerate rebuilds it" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeMixedRepo(&fx);

    const first = try runEnum(gpa, &fx, false);
    gpa.free(first.out);

    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/all.txt", .data = "sentinel-only" });
    const reused = try runEnum(gpa, &fx, false);
    defer gpa.free(reused.out);
    try testing.expect(std.mem.indexOf(u8, reused.out, "enumerating") == null);
    const kept = try fx.tmp.dir.readFileAlloc(testing.io, "work/all.txt", gpa, .limited(1 << 20));
    defer gpa.free(kept);
    try testing.expectEqualStrings("sentinel-only", kept);

    const rebuilt = try runEnum(gpa, &fx, true);
    defer gpa.free(rebuilt.out);
    try testing.expect(std.mem.indexOf(u8, rebuilt.out, "enumerating") != null);
    const after = try fx.tmp.dir.readFileAlloc(testing.io, "work/all.txt", gpa, .limited(1 << 20));
    defer gpa.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "sentinel-only") == null);
}

test "files over the size cap are skipped AND reported, never dropped silently" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/small.java", "small\n");
    const huge = try gpa.alloc(u8, 3000);
    defer gpa.free(huge);
    @memset(huge, 'x');
    try fx.writeRepoFile("src/huge.java", huge);
    try fx.gitCommit("files");
    try fx.env.put("SYNAPSE_MAX_FILE_BYTES", "1000");

    const r = try runEnum(gpa, &fx, false);
    defer gpa.free(r.out);

    const all = try fx.tmp.dir.readFileAlloc(testing.io, "work/all.txt", gpa, .limited(1 << 20));
    defer gpa.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "src/small.java\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "src/huge.java") == null);
    try testing.expect(std.mem.indexOf(u8, r.out, "skipped 1 file(s) over 1000 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "src/huge.java") != null);
}

test "a non-repo directory exits 1" {
    // `fx.repo` itself won't do: it's never git-initialized, but it lives
    // under `.zig-cache/tmp/`, inside this very repo -- identity resolution
    // walks up looking for `.git` and finds this project's own, same as it
    // would for any other file in the tree. Needs a directory with no git
    // ancestor at all, which the real system temp dir (outside the repo)
    // provides.
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    // `/tmp` directly, not `$TMPDIR`: this machine's own `$TMPDIR` turned
    // out to be `~/.emacs.d/var/tmp` -- itself a real git repo, which
    // defeated the whole point. `/tmp` is the one POSIX system temp root
    // no real project lives inside.
    const notarepo = "/tmp/synapse-enumerate-notarepo-test";
    try Io.Dir.cwd().createDirPath(fx.io(), notarepo);
    defer Io.Dir.cwd().deleteTree(fx.io(), notarepo) catch {};

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try runEnumerate(gpa, fx.io(), &fx.env, notarepo, false, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}

test "$SYNAPSE_EXTRA_EXCLUDE_RE adds repo-specific noise without losing the built-in filters" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeMixedRepo(&fx);
    try fx.writeRepoFile("generated/client.java", "gen\n");
    try fx.gitCommit("gen");
    try fx.env.put("SYNAPSE_EXTRA_EXCLUDE_RE", "^generated/");

    const r = try runEnum(gpa, &fx, false);
    defer gpa.free(r.out);

    const all = try fx.tmp.dir.readFileAlloc(testing.io, "work/all.txt", gpa, .limited(1 << 20));
    defer gpa.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "generated/client.java") == null);
    try testing.expect(std.mem.indexOf(u8, all, "logo.png") == null); // built-in filter still applies
    try testing.expect(std.mem.indexOf(u8, all, "mod-a/src/main/java/A.java\n") != null);
}

test "synapse-ignore-files.conf patterns are honoured, and OR'd with the env var" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("vendor/lib.java", "x\n");
    try fx.writeRepoFile("gen/Made.java", "x\n");
    try fx.writeRepoFile("src/keep.java", "x\n");
    try fx.gitCommit("mix");
    // Comments and blank lines must survive parsing; an empty pattern would
    // match every path and enumerate nothing.
    try fx.tmp.dir.createDirPath(testing.io, "home/.claude");
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "home/.claude/synapse-ignore-files.conf",
        .data = "# a comment\n\n(^|/)vendor/\n",
    });
    try fx.env.put("SYNAPSE_EXTRA_EXCLUDE_RE", "(^|/)gen/");

    const r = try runEnum(gpa, &fx, false);
    defer gpa.free(r.out);

    const all = try fx.tmp.dir.readFileAlloc(testing.io, "work/all.txt", gpa, .limited(1 << 20));
    defer gpa.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "src/keep.java\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "vendor/") == null); // from the conf file
    try testing.expect(std.mem.indexOf(u8, all, "gen/") == null); // from the env var
}

test "a blank or comment line after a pattern in synapse-ignore-files.conf does not swallow the whole listing" {
    // The hazard: appending an empty string to the alternation leaves a
    // trailing `|`, i.e. an empty alternative, which matches every path --
    // so the listing silently comes back empty.
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("vendor/lib.java", "x\n");
    try fx.writeRepoFile("src/keep.java", "x\n");
    try fx.gitCommit("mix");
    try fx.tmp.dir.createDirPath(testing.io, "home/.claude");
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "home/.claude/synapse-ignore-files.conf",
        .data = "(^|/)vendor/\n\n# a trailing comment\n\n",
    });

    const r = try runEnum(gpa, &fx, false);
    defer gpa.free(r.out);

    const all = try fx.tmp.dir.readFileAlloc(testing.io, "work/all.txt", gpa, .limited(1 << 20));
    defer gpa.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "src/keep.java\n") != null); // survives
    try testing.expect(std.mem.indexOf(u8, all, "vendor/") == null); // still excluded
    try testing.expect(all.len > 0);
}

test "skips a submodule gitlink, which git ls-files reports but git hash-object cannot hash" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeMixedRepo(&fx);

    const sub = try std.fmt.allocPrint(gpa, "{s}/sub", .{fx.root});
    defer gpa.free(sub);
    try Io.Dir.cwd().createDirPath(fx.io(), sub);
    const init_res = try adapters.process.run(fx.io(), gpa, &.{ "git", "init", "-q" }, .{ .cwd = .{ .path = sub } });
    init_res.deinit(gpa);
    const thing_path = try std.fmt.allocPrint(gpa, "{s}/thing.txt", .{sub});
    defer gpa.free(thing_path);
    try Io.Dir.cwd().writeFile(fx.io(), .{ .sub_path = thing_path, .data = "sub content\n" });
    const add_res = try adapters.process.run(fx.io(), gpa, &.{ "git", "add", "-A" }, .{ .cwd = .{ .path = sub } });
    add_res.deinit(gpa);
    const commit_res = try adapters.process.run(fx.io(), gpa, &.{
        "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init",
    }, .{ .cwd = .{ .path = sub } });
    commit_res.deinit(gpa);

    const submodule_res = try adapters.process.run(fx.io(), gpa, &.{
        "git", "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "vendor/sub",
    }, .{ .cwd = .{ .path = fx.repo } });
    submodule_res.deinit(gpa);
    try fx.gitCommit("addsub");

    const r = try runEnum(gpa, &fx, false);
    defer gpa.free(r.out);

    const all = try fx.tmp.dir.readFileAlloc(testing.io, "work/all.txt", gpa, .limited(1 << 20));
    defer gpa.free(all);
    // `git ls-files` lists vendor/sub as a single entry, but it is a
    // directory on disk -- leaving it in takes down the whole
    // `git hash-object --stdin-paths` batch this command doesn't even run
    // (a plain `statFile` skips it instead). `.gitmodules` itself is real
    // text and must survive.
    try testing.expect(std.mem.indexOf(u8, all, "vendor/sub") == null);
    try testing.expect(std.mem.indexOf(u8, all, ".gitmodules\n") != null);
}
