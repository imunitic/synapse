//! `synapse doctor` -- every silent guard in the system, said out loud.
//! See `core/doctor.zig` for what `warn` means. Each check below mirrors a
//! specific silent guard elsewhere; the comment on each says which.
//!
//!   doctor [--repo <dir>]
//!
//! Ordered as an install is built: dependencies, config, vault + API,
//! identity, namespace, derived artefacts, hooks -- so a reader stopping at
//! the first `FAIL` has usually found the cause, not a symptom.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const treesitter = @import("treesitter"); // for the staleness-window constant only
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Check = core.doctor.Check;

const usage_text =
    \\usage: synapse doctor [--repo <dir>]
    \\
    \\  --repo  the checkout to examine. Default: the one containing $PWD.
    \\
;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var repo: []const u8 = ".";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        } else if (std.mem.eql(u8, arg, "--repo")) {
            repo = args.next() orelse {
                std.debug.print("{s}", .{usage_text});
                return 2;
            };
        } else {
            std.debug.print("{s}", .{usage_text});
            return 2;
        }
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try diagnose(gpa, io, env, repo, &out.interface);
    try out.interface.flush();
    return code;
}

/// The command itself, minus argument parsing -- separated so a test can
/// drive it against a real fixture directly.
pub fn diagnose(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    repo: []const u8,
    w: *Io.Writer,
) !u8 {
    var checks: std.ArrayListUnmanaged(Check) = .empty;
    defer checks.deinit(gpa);
    var owned: std.ArrayListUnmanaged([]u8) = .empty; // every detail string, freed at the end
    defer {
        for (owned.items) |o| gpa.free(o);
        owned.deinit(gpa);
    }
    var ctx: Ctx = .{ .gpa = gpa, .io = io, .env = env, .checks = &checks, .owned = &owned };

    try dependencies(&ctx);
    const vault = try vaultChecks(&ctx);
    const id = try identityChecks(&ctx, repo);
    defer if (id) |i| i.deinit(gpa);
    try namespaceChecks(&ctx, vault, id);
    try workDirChecks(&ctx, id);
    try grammarLockChecks(&ctx);
    try hookChecks(&ctx);

    try core.doctor.writeReport(w, checks.items);
    return core.doctor.exitCode(checks.items);
}

const Ctx = struct {
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    checks: *std.ArrayListUnmanaged(Check),
    owned: *std.ArrayListUnmanaged([]u8),

    fn add(self: *Ctx, name: []const u8, status: core.doctor.Status, detail: []const u8) !void {
        try self.checks.append(self.gpa, .{ .name = name, .status = status, .detail = detail });
    }

    /// An owned detail string, for free-form formatting.
    fn fmt(self: *Ctx, comptime f: []const u8, a: anytype) ![]const u8 {
        const s = try std.fmt.allocPrint(self.gpa, f, a);
        try self.owned.append(self.gpa, s);
        return s;
    }

    fn exists(self: *Ctx, path: []const u8) bool {
        _ = Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return true;
    }

    fn read(self: *Ctx, path: []const u8) ?[]u8 {
        const text = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(64 << 20)) catch |e| {
            // FileNotFound reads as an ordinary "not configured" to every
            // caller of read(), which is correct -- but any other error
            // (permissions, OOM) would silently read the same way without
            // this, so a genuine problem could be misreported as "missing".
            if (e != error.FileNotFound)
                std.debug.print("synapse-doctor: could not read {s} ({t})\n", .{ path, e });
            return null;
        };
        self.owned.append(self.gpa, text) catch |e| {
            std.debug.print("synapse-doctor: could not track {s} for cleanup ({t})\n", .{ path, e });
            self.gpa.free(text);
            return null;
        };
        return text;
    }
};

/// `git`. Mirrors: every subcommand that spawns it and treats a failure as
/// "nothing found" rather than "the tool is missing".
fn dependencies(ctx: *Ctx) !void {
    for ([_][]const u8{"git"}) |tool| {
        const res = adapters.process.run(ctx.io, ctx.gpa, &.{ tool, "--version" }, .{}) catch {
            try ctx.add(tool, .fail, "not on PATH");
            continue;
        };
        defer res.deinit(ctx.gpa);
        if (!res.ok()) {
            try ctx.add(tool, .fail, "not on PATH");
            continue;
        }
        const first = res.stdout[0 .. std.mem.indexOfScalar(u8, res.stdout, '\n') orelse res.stdout.len];
        try ctx.add(tool, .ok, try ctx.fmt("{s}", .{std.mem.trim(u8, first, " \t\r")}));
    }
}

/// The conf file and the vault directory. Mirrors: `core.conf.vaultDir`
/// returning null, which every hook/command treats as silent "no vault".
fn vaultChecks(ctx: *Ctx) !?[]const u8 {
    // Tiered, like vaultDir() just below it -- this used to hardcode
    // ~/.claude/{name} directly, predating resolveConfPath, so it
    // reported a false FAIL for anyone whose synapse.conf resolves at tier
    // 1 (XDG) or tier 3 (a plugin-bundled template) instead of tier 2.
    var found: ?[]const u8 = null;
    for (core.conf.file_names) |name| {
        const path = core.conf.resolveConfPath(ctx.gpa, ctx.io, adapters.env.vars(ctx.env), name) catch null;
        if (path) |p| {
            try ctx.owned.append(ctx.gpa, p);
            found = p;
            break;
        }
    }
    if (found) |path| {
        try ctx.add("config", .ok, path);
    } else if (ctx.env.get("SYNAPSE_VAULT_DIR") != null) {
        try ctx.add("config", .warn, "no synapse.conf; using $SYNAPSE_VAULT_DIR");
    } else {
        try ctx.add("config", .fail, "no synapse.conf found -- create one at $XDG_CONFIG_HOME/synapse/synapse.conf (or ~/.config/synapse/synapse.conf), or ~/.claude/synapse.conf");
    }

    const vault = core.conf.vaultDir(ctx.gpa, ctx.io, adapters.env.vars(ctx.env)) catch null;
    if (vault) |v| {
        try ctx.owned.append(ctx.gpa, v);
        const st = Io.Dir.cwd().statFile(ctx.io, v, .{}) catch {
            try ctx.add("vault", .fail, try ctx.fmt("{s} does not exist", .{v}));
            return null;
        };
        if (st.kind != .directory) {
            try ctx.add("vault", .fail, try ctx.fmt("{s} is not a directory", .{v}));
            return null;
        }
        try ctx.add("vault", .ok, v);
        return v;
    }
    try ctx.add("vault", .fail, "SYNAPSE_VAULT_DIR is not set anywhere");
    return null;
}

/// The namespace this checkout resolves to. Mirrors: every component's silent exit on a
/// detached HEAD or a non-repo, and `core.identity`'s own fallback chain.
fn identityChecks(ctx: *Ctx, repo: []const u8) !?core.identity.Resolved {
    const id = core.identity.resolve(ctx.gpa, ctx.io, repo) catch |e| {
        switch (e) {
            error.NotAGitRepo => try ctx.add("repository", .warn, "not inside a git repo -- nothing to graph here"),
            error.DetachedHead => try ctx.add("repository", .warn, "detached HEAD -- a namespace is keyed by branch, so there is none"),
            else => try ctx.add("repository", .fail, "could not resolve"),
        }
        return null;
    };
    try ctx.add("repository", .ok, id.layout.repo_root);
    // Named separately because a worktree is where the two-hop lookup can go wrong, and
    // seeing the git dir is how someone would notice it had.
    if (!std.mem.eql(u8, id.layout.git_dir, id.layout.common_dir))
        try ctx.add("worktree", .ok, try ctx.fmt("{s} (shared: {s})", .{ id.layout.git_dir, id.layout.common_dir }));
    try ctx.add("remote", .ok, id.remote);
    try ctx.add("namespace", .ok, id.key);
    return id;
}

/// Whether the namespace exists and agrees about which repo and branch it describes.
/// Mirrors: `context.verifyNamespace` and the staleness hook's `indexAgrees`, both of
/// which refuse silently -- the mismatch case being the one that looks like nothing
/// happening.
fn namespaceChecks(ctx: *Ctx, vault: ?[]const u8, id: ?core.identity.Resolved) !void {
    const v = vault orelse return;
    const i = id orelse return;
    const index = try ctx.fmt("{s}/synapse/{s}/Index.md", .{ v, i.key });
    const text = ctx.read(index) orelse {
        try ctx.add("graph", .warn, try ctx.fmt("no namespace at synapse/{s}/ -- /synapse-init builds one", .{i.key}));
        return;
    };
    const recorded_remote = core.query.field(text, "remote") orelse "";
    const recorded_branch = core.query.field(text, "branch") orelse "";
    if (recorded_remote.len == 0) {
        try ctx.add("graph", .fail, "Index.md has no remote field -- every component reads that as a mismatch");
        return;
    }
    if (!std.mem.eql(u8, recorded_remote, i.remote)) {
        try ctx.add("graph", .fail, try ctx.fmt(
            "remote mismatch: Index.md says {s} -- rebuild with /synapse-rebuild-full if the remote changed",
            .{recorded_remote},
        ));
        return;
    }
    if (!std.mem.eql(u8, recorded_branch, i.branch_key)) {
        try ctx.add("graph", .fail, try ctx.fmt(
            "branch mismatch: Index.md says {s}, this is {s} -- the directory was renamed by hand",
            .{ recorded_branch, i.branch_key },
        ));
        return;
    }

    var nodes: usize = 0;
    const dir_path = try ctx.fmt("{s}/synapse/{s}", .{ v, i.key });
    if (Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true })) |dir| {
        var d = dir;
        defer d.close(ctx.io);
        var it = d.iterate();
        while (it.next(ctx.io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
            if (std.mem.eql(u8, entry.name, "Index.md")) continue;
            nodes += 1;
        }
    } else |_| {}
    try ctx.add("graph", .ok, try ctx.fmt("synapse/{s}/ ({d} nodes)", .{ i.key, nodes }));
}

/// The derived artefacts. Mirrors: the staleness hook's `[ -f _index.bin ]`, `symbol`'s
/// "no tags cache yet", and `callers`' "no reference index" -- the first of which is
/// silence and the other two of which only speak when asked.
fn workDirChecks(ctx: *Ctx, id: ?core.identity.Resolved) !void {
    const i = id orelse return;
    const resolved = (try context.workDirFor(ctx.gpa, ctx.io, ctx.env, i.layout.repo_root, "synapse-doctor")) orelse
        return;
    defer resolved.deinit(ctx.gpa);
    // Copied into the report's own storage before that `defer` runs: a `Check` holds a
    // slice, not a string, and the first version of this printed a *later* check's
    // detail here because the freed bytes had been reused by the next `fmt`.
    const work = try ctx.fmt("{s}", .{resolved.path});
    try ctx.add("work dir", if (ctx.exists(work)) .ok else .warn, work);

    const index_path = try ctx.fmt("{s}/_index.bin", .{work});
    if (ctx.exists(index_path)) {
        var map = core.index_map.Map.open(ctx.io, index_path) catch {
            try ctx.add("reverse index", .fail, "unreadable -- rebuild with /synapse-init step 3");
            return;
        };
        defer map.close(ctx.io);
        if (map.discarded) |e| {
            try ctx.add("reverse index", .fail, try ctx.fmt("discarded ({t}) -- rebuild it", .{e}));
        } else {
            try ctx.add("reverse index", .ok, try ctx.fmt(
                "{d} paths, {d} nodes, {d} unassigned",
                .{ map.count(), map.nodeCount(), map.unassignedCount() },
            ));
        }
    } else {
        // The staleness hook's own precondition: without this file it does nothing at
        // all, which is exactly the silence this command exists to break.
        try ctx.add("reverse index", .warn, "absent -- the staleness hook does nothing without it");
    }

    const cache = try ctx.fmt("{s}/_tags_cache.bin", .{work});
    try ctx.add("tags cache", if (ctx.exists(cache)) .ok else .warn, if (ctx.exists(cache))
        cache
    else
        "absent -- `query symbol` will tag on demand, slowly");
    const refs = try ctx.fmt("{s}/_refs.tsv", .{work});
    try ctx.add("code cache", if (ctx.exists(refs)) .ok else .warn, if (ctx.exists(refs))
        refs
    else
        "absent -- `callers` exits 1 until `build-refs` runs");
}

/// Grammar clone locks left behind. Mirrors `grammar.ensureCloned`'s wait, which is
/// silent in the way this command exists for: a lock nobody holds costs every later
/// run its full ~60s ceiling and then skips that extension, and the only visible
/// symptom is tagging that quietly stopped covering one language.
///
/// The interesting state is a lock *younger* than the staleness window, because that
/// one is not yet self-healing. An older one is reported too, as `ok` with a note,
/// since seeing it explains a slow run that has already fixed itself.
fn grammarLockChecks(ctx: *Ctx) !void {
    const resolved_dir = try core.conf.resolve(ctx.gpa, ctx.io, adapters.env.vars(ctx.env), "SYNAPSE_GRAMMARS_DIR");
    defer if (resolved_dir) |d| ctx.gpa.free(d);
    const repos = if (resolved_dir) |d|
        try ctx.fmt("{s}/repos", .{d})
    else if (ctx.env.get("HOME")) |home|
        try ctx.fmt("{s}/.cache/synapse/grammars/repos", .{home})
    else
        return;

    var dir = Io.Dir.cwd().openDir(ctx.io, repos, .{ .iterate = true }) catch {
        // No grammars cloned yet is the normal state on a fresh machine, and it is
        // already implied by every other tags-related check.
        return;
    };
    defer dir.close(ctx.io);

    const now = Io.Timestamp.now(ctx.io, .real).nanoseconds;
    var held: usize = 0;
    var abandoned: usize = 0;
    // One example per category, not one overall: naming a lock from the other half
    // would illustrate the sentence with a counter-example to it.
    var first_held: []const u8 = "";
    var first_abandoned: []const u8 = "";

    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".lock")) continue;
        const path = try ctx.fmt("{s}/{s}", .{ repos, entry.name });
        const st = Io.Dir.cwd().statFile(ctx.io, path, .{}) catch continue;
        if (now - st.mtime.nanoseconds > treesitter.grammar.lock_stale_after_ns) {
            abandoned += 1;
            if (first_abandoned.len == 0) first_abandoned = path;
        } else {
            held += 1;
            if (first_held.len == 0) first_held = path;
        }
    }

    if (held == 0 and abandoned == 0) return;
    if (held > 0) {
        try ctx.add("grammar locks", .warn, try ctx.fmt(
            "{d} held ({s}){s} -- another synapse is cloning, or one was killed just now; " ++
                "delete it if nothing is running",
            .{ held, first_held, if (abandoned > 0) ", plus abandoned ones" else "" },
        ));
    } else {
        try ctx.add("grammar locks", .ok, try ctx.fmt(
            "{d} abandoned ({s}) -- older than the staleness window, so the next run takes it over",
            .{ abandoned, first_abandoned },
        ));
    }
}

/// Whether the four hooks are registered, once each, in `settings.json` --
/// what `synapse-setup configure claude` writes there, npm's own commands
/// merged in directly (no plugin cache, no fixed-path legacy binary to
/// check for instead: an npm install's binary lives inside
/// node_modules/@imunitic/synapse-{platform}-{arch}/, a path this check has
/// no fixed location to look for, but doesn't need to -- the full resolved
/// command each hook was merged with is already sitting in settings.json,
/// which is what the count below actually reads). Mirrors nothing silent --
/// it mirrors something *loud in the wrong direction*: a hook wired twice
/// fires twice, and the only symptom is duplicated context nobody
/// attributes to settings.json.
fn hookChecks(ctx: *Ctx) !void {
    const home = ctx.env.get("HOME") orelse return;
    const settings_path = try ctx.fmt("{s}/.claude/settings.json", .{home});
    const text = ctx.read(settings_path) orelse {
        try ctx.add("hooks", .fail, "no settings.json -- run `synapse-setup configure claude`");
        return;
    };
    const names = [_][]const u8{ "session-start", "prompt-context", "staleness", "stop-nudge" };
    var missing: usize = 0;
    var duplicated: usize = 0;
    for (names) |name| {
        const needle = try ctx.fmt("synapse-hook {s}", .{name});
        const n = std.mem.count(u8, text, needle);
        if (n == 0) missing += 1;
        if (n > 1) duplicated += 1;
    }
    if (missing == 0 and duplicated == 0) {
        try ctx.add("hooks", .ok, "all four registered once");
    } else if (duplicated != 0) {
        try ctx.add("hooks", .fail, try ctx.fmt(
            "{d} registered more than once -- each fires that many times; fix ~/.claude/settings.json or re-run `synapse-setup configure claude`",
            .{duplicated},
        ));
    } else {
        try ctx.add("hooks", .fail, try ctx.fmt("{d} of 5 not registered -- run `synapse-setup configure claude`", .{missing}));
    }

    // A wrapper still referenced would silently take precedence over the binary for
    // that hook, and it would keep working -- which is why this is a failure rather
    // than a note.
    if (std.mem.indexOf(u8, text, "hooks/synapse-") != null)
        try ctx.add("hook wiring", .fail, "settings.json still names a hooks/*.sh wrapper -- fix ~/.claude/settings.json or re-run `synapse-setup configure claude`");
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

const DoctorFixture = struct {
    fx: fixture.Fixture,

    fn init(gpa: Allocator) !DoctorFixture {
        const fx = try fixture.Fixture.init(gpa);
        return .{ .fx = fx };
    }

    fn deinit(self: *DoctorFixture) void {
        self.fx.deinit();
    }

    fn commit(self: *DoctorFixture) !void {
        try self.fx.writeRepoFile("README.md", "seed\n");
        try self.fx.gitCommit("init");
    }

    /// Matches bats' own `common_setup()` default: a real `synapse.conf` at
    /// `$HOME/.claude/synapse.conf` pointing `SYNAPSE_VAULT_DIR` at the
    /// fixture vault -- the "configured machine" baseline every doctor test
    /// in bats started from. `Fixture.init()` sets the env var directly
    /// instead, which is a *different* state (`vaultChecks`' own `.warn`
    /// "no synapse.conf; using $SYNAPSE_VAULT_DIR" branch), so tests that
    /// want the `ok` config state need this written explicitly.
    fn writeConf(self: *DoctorFixture) !void {
        const data = try std.fmt.allocPrint(self.fx.gpa, "SYNAPSE_VAULT_DIR=\"{s}\"\n", .{self.fx.vault});
        defer self.fx.gpa.free(data);
        try self.fx.tmp.dir.createDirPath(testing.io, "home/.claude");
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.claude/synapse.conf", .data = data });
    }

    /// `commit()` + `writeConf()` -- the "configured machine" most tests
    /// start from.
    fn baseline(self: *DoctorFixture) !void {
        try self.commit();
        try self.writeConf();
    }

    fn check(self: *DoctorFixture, repo: []const u8, w: *Io.Writer) !u8 {
        return diagnose(self.fx.gpa, self.fx.io(), &self.fx.env, repo, w);
    }
};

test "config resolves at tier 1 (XDG), not just tier 2 -- the config check used to hardcode ~/.claude" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.commit();
    const data = try std.fmt.allocPrint(gpa, "SYNAPSE_VAULT_DIR=\"{s}\"\n", .{df.fx.vault});
    defer gpa.free(data);
    try df.fx.tmp.dir.createDirPath(testing.io, "home/.config/synapse");
    try df.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.config/synapse/synapse.conf", .data = data });
    _ = df.fx.env.swapRemove("XDG_CONFIG_HOME");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try df.check(df.fx.repo, &out.writer);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "config") != null and std.mem.indexOf(u8, text, ".config/synapse/synapse.conf") != null);
    try testing.expect(std.mem.indexOf(u8, text, "FAIL") == null or std.mem.indexOf(u8, text, "FAIL  config") == null);
}

test "no vault configured is a failure, and says where to set it" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.commit();
    // No conf file, and no SYNAPSE_VAULT_DIR -- the state every hook treats
    // as silence and every command as a bare "no vault".
    _ = df.fx.env.swapRemove("SYNAPSE_VAULT_DIR");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try df.check(df.fx.repo, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "FAIL") != null and std.mem.indexOf(u8, text, "config") != null);
    try testing.expect(std.mem.indexOf(u8, text, "synapse.conf") != null);
}

test "a vault path that does not exist is named as such, not reported as absent" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.commit();
    // The env var wins over the conf file (core.conf.vaultDir's own tier
    // order), so it has to be cleared for the conf-file value to matter at all.
    _ = df.fx.env.swapRemove("SYNAPSE_VAULT_DIR");
    const nope = try std.fmt.allocPrint(gpa, "{s}/nope", .{df.fx.root});
    defer gpa.free(nope);
    const data = try std.fmt.allocPrint(gpa, "SYNAPSE_VAULT_DIR=\"{s}\"\n", .{nope});
    defer gpa.free(data);
    try df.fx.tmp.dir.createDirPath(testing.io, "home/.claude");
    try df.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.claude/synapse.conf", .data = data });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try df.check(df.fx.repo, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "does not exist") != null);
}

test "an absent namespace is a warning, not a failure" {
    // The distinction the whole three-level scheme exists for: a branch
    // nobody has clustered is an ordinary state, so this must not fail a
    // scripted check.
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try df.check(df.fx.repo, &out.writer);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "warn") != null and std.mem.indexOf(u8, text, "graph") != null);
    try testing.expect(std.mem.indexOf(u8, text, "/synapse-init") != null);
}

test "a namespace whose remote disagrees is a failure that names the remedy" {
    // The exact case the SessionStart hook skips a pointer for and the
    // staleness hook refuses to write on -- both without a word.
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();
    try df.fx.writeIndex("ssh://git@elsewhere.invalid/other.git", "main");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try df.check(df.fx.repo, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "remote mismatch") != null);
    try testing.expect(std.mem.indexOf(u8, text, "/synapse-rebuild-full") != null);
}

test "a namespace whose branch field disagrees is a failure" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();
    // A real (matching) remote, so this test isolates the branch mismatch
    // rather than tripping the "no remote field" check first -- an empty
    // remote short-circuits before the branch is ever compared.
    const id = try core.identity.resolve(gpa, df.fx.io(), df.fx.repo);
    defer id.deinit(gpa);
    try df.fx.writeIndex(id.remote, "some-other-branch");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try df.check(df.fx.repo, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "branch mismatch") != null);
}

test "an absent reverse index says what stops working without it" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();
    try df.fx.writeIndex("", "main");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try df.check(df.fx.repo, &out.writer);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "warn") != null and std.mem.indexOf(u8, text, "reverse index") != null);
    try testing.expect(std.mem.indexOf(u8, text, "staleness hook does nothing") != null);
}

test "a staged reverse index is reported with its counts" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();
    try df.fx.writeIndex("", "main");
    try df.fx.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo.md" }});

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try df.check(df.fx.repo, &out.writer);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "ok") != null and std.mem.indexOf(u8, text, "reverse index") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1 paths") != null);
}

test "a recent grammar lock warns and names the directory to delete" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();
    const grammars = try std.fmt.allocPrint(gpa, "{s}/grammars", .{df.fx.root});
    defer gpa.free(grammars);
    const lock = try std.fmt.allocPrint(gpa, "{s}/repos/tree-sitter-ocaml.lock", .{grammars});
    defer gpa.free(lock);
    try Io.Dir.cwd().createDirPath(df.fx.io(), lock);
    try df.fx.env.put("SYNAPSE_GRAMMARS_DIR", grammars);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try df.check(df.fx.repo, &out.writer);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "warn") != null and std.mem.indexOf(u8, text, "grammar locks") != null);
    try testing.expect(std.mem.indexOf(u8, text, "tree-sitter-ocaml.lock") != null);
    // Naming the path is the whole point: the condition is a directory to
    // remove, and the failure it causes elsewhere reads as a network problem.
    try testing.expect(std.mem.indexOf(u8, text, "delete it if nothing is running") != null);
}

test "a grammar lock past the staleness window is reported as self-healing" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();
    const grammars = try std.fmt.allocPrint(gpa, "{s}/grammars", .{df.fx.root});
    defer gpa.free(grammars);
    const lock = try std.fmt.allocPrint(gpa, "{s}/repos/tree-sitter-ocaml.lock", .{grammars});
    defer gpa.free(lock);
    try Io.Dir.cwd().createDirPath(df.fx.io(), lock);
    const touch_res = try adapters.process.run(df.fx.io(), gpa, &.{ "touch", "-t", "202601010000", lock }, .{});
    touch_res.deinit(gpa);
    try df.fx.env.put("SYNAPSE_GRAMMARS_DIR", grammars);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try df.check(df.fx.repo, &out.writer);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "ok") != null and std.mem.indexOf(u8, text, "grammar locks") != null);
    try testing.expect(std.mem.indexOf(u8, text, "takes it over") != null);
}

test "no grammar lock says nothing at all" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();
    const grammars = try std.fmt.allocPrint(gpa, "{s}/grammars", .{df.fx.root});
    defer gpa.free(grammars);
    const repo_dir = try std.fmt.allocPrint(gpa, "{s}/repos/tree-sitter-ocaml", .{grammars});
    defer gpa.free(repo_dir);
    try Io.Dir.cwd().createDirPath(df.fx.io(), repo_dir);
    try df.fx.env.put("SYNAPSE_GRAMMARS_DIR", grammars);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try df.check(df.fx.repo, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "grammar locks") == null);
}

test "hooks wired to a wrapper are a failure, because the wrapper would still run" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();
    try df.fx.tmp.dir.createDirPath(testing.io, "home/.claude");
    try df.fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "home/.claude/settings.json",
        .data = "{\"hooks\":{\"PostToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"bash ~/.claude/hooks/synapse-staleness.sh\"}]}]}}",
    });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try df.check(df.fx.repo, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "still names a hooks/") != null);
}

test "a hook registered twice is a failure that says it fires twice" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();
    try df.fx.tmp.dir.createDirPath(testing.io, "home/.claude");
    try df.fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "home/.claude/settings.json",
        .data =
        \\{"hooks":{"PostToolUse":[
        \\  {"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook staleness"}]},
        \\  {"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook staleness"}]}],
        \\ "SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook session-start"}]}],
        \\ "UserPromptSubmit":[{"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook prompt-context"}]}],
        \\ "Stop":[{"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook stop-nudge"}]}]}}
        ,
    });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try df.check(df.fx.repo, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "more than once") != null);
}

test "all four hooks registered once reports ok, whatever absolute path they were merged with" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();
    try df.fx.tmp.dir.createDirPath(testing.io, "home/.claude");
    // The command prefix is an npm-resolved node_modules path here -- an
    // arbitrary absolute path, on purpose: this check counts occurrences of
    // "synapse-hook {name}" as a substring, so it never needs to know or
    // care what precedes it.
    try df.fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "home/.claude/settings.json",
        .data =
        \\{"hooks":{
        \\ "SessionStart":[{"hooks":[{"type":"command","command":"/x/node_modules/@imunitic/synapse-darwin-arm64/bin/synapse-hook session-start"}]}],
        \\ "UserPromptSubmit":[{"hooks":[{"type":"command","command":"/x/node_modules/@imunitic/synapse-darwin-arm64/bin/synapse-hook prompt-context"}]}],
        \\ "PostToolUse":[
        \\  {"hooks":[{"type":"command","command":"/x/node_modules/@imunitic/synapse-darwin-arm64/bin/synapse-hook staleness"}]}],
        \\ "Stop":[{"hooks":[{"type":"command","command":"/x/node_modules/@imunitic/synapse-darwin-arm64/bin/synapse-hook stop-nudge"}]}]}}
        ,
    });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try df.check(df.fx.repo, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "all four registered once") != null);
}

test "outside a git repo it warns rather than failing" {
    // `doctor` is the one command someone runs when they do not know what
    // is wrong, so it has to answer everywhere -- including from a
    // directory that is not a checkout.
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try df.check("/tmp", &out.writer);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "warn") != null and std.mem.indexOf(u8, text, "repository") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not inside a git repo") != null);
}

test "every line carries a status, and the tally matches the lines" {
    const gpa = testing.allocator;
    var df = try DoctorFixture.init(gpa);
    defer df.deinit();
    try df.baseline();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try df.check(df.fx.repo, &out.writer);

    var lines: usize = 0;
    var ok: usize = 0;
    var warn: usize = 0;
    var fail: usize = 0;
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "ok ")) {
            lines += 1;
            ok += 1;
        } else if (std.mem.startsWith(u8, line, "warn ")) {
            lines += 1;
            warn += 1;
        } else if (std.mem.startsWith(u8, line, "FAIL ")) {
            lines += 1;
            fail += 1;
        }
    }
    const summary = try std.fmt.allocPrint(gpa, "{d} ok, {d} warning(s), {d} failure(s)", .{ ok, warn, fail });
    defer gpa.free(summary);
    try testing.expect(std.mem.indexOf(u8, out.written(), summary) != null);
    try testing.expectEqual(ok + warn + fail, lines);
}
