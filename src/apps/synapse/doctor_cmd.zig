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
    try apiChecks(&ctx, vault);
    const id = try identityChecks(&ctx, repo);
    defer if (id) |i| i.deinit(gpa);
    try namespaceChecks(&ctx, vault, id);
    try workDirChecks(&ctx, id);
    try grammarLockChecks(&ctx);
    try hookChecks(&ctx);

    var buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    try core.doctor.writeReport(&out.interface, checks.items);
    try out.interface.flush();
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
        const text = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(64 << 20)) catch
            return null;
        self.owned.append(self.gpa, text) catch return null;
        return text;
    }
};

/// `git`/`curl`. Mirrors: every subcommand that spawns one and treats a
/// failure as "nothing found" rather than "the tool is missing".
fn dependencies(ctx: *Ctx) !void {
    for ([_][]const u8{ "git", "curl" }) |tool| {
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
    // jq is unused by either binary itself -- it's a shell-out dependency of
    // the obsidian-mcp-refresh.sh SessionStart hook (cert/key extraction,
    // settings.json merge), so absence breaks that hook silently, not either
    // binary's own behaviour.
    const res = adapters.process.run(ctx.io, ctx.gpa, &.{ "jq", "--version" }, .{}) catch null;
    if (res) |r| {
        defer r.deinit(ctx.gpa);
        if (r.ok()) {
            try ctx.add("jq", .ok, "used by the obsidian-mcp-refresh.sh hook only");
            return;
        }
    }
    try ctx.add("jq", .warn, "absent: the obsidian-mcp-refresh.sh hook needs it and will skip silently");
}

/// The conf file and the vault directory. Mirrors: `core.conf.vaultDir`
/// returning null, which every hook/command treats as silent "no vault".
fn vaultChecks(ctx: *Ctx) !?[]const u8 {
    // Tiered, like vaultDir() just below it -- this used to hardcode
    // ~/.claude/{name} directly, predating resolveConfPath (sb-017), so it
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
    } else if (ctx.env.get("OBSIDIAN_VAULT_DIR") != null) {
        try ctx.add("config", .warn, "no synapse.conf; using $OBSIDIAN_VAULT_DIR");
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
    try ctx.add("vault", .fail, "OBSIDIAN_VAULT_DIR is not set anywhere");
    return null;
}

/// Plugin port/key, the certificate, whether anything answers. Mirrors:
/// every `curl` failure a hook turns into silence, and `write-node`'s "REST
/// API not configured".
fn apiChecks(ctx: *Ctx, vault: ?[]const u8) !void {
    const v = vault orelse {
        try ctx.add("REST API", .fail, "skipped: no vault");
        return;
    };
    const plugin = try ctx.fmt("{s}/.obsidian/plugins/obsidian-local-rest-api/data.json", .{v});
    const text = ctx.read(plugin) orelse {
        try ctx.add("REST API", .fail, "no plugin data.json -- install \"Local REST API\" in Obsidian");
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, text, .{}) catch {
        try ctx.add("REST API", .fail, "plugin data.json is not readable JSON");
        return;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try ctx.add("REST API", .fail, "plugin data.json is not an object");
            return;
        },
    };
    const key = switch (obj.get("apiKey") orelse .null) {
        .string => |s| s,
        else => "",
    };
    const port: u16 = switch (obj.get("port") orelse .null) {
        .integer => |i| @intCast(i),
        .string => |s| std.fmt.parseInt(u16, s, 10) catch 0,
        else => 0,
    };
    if (key.len == 0 or port == 0) {
        try ctx.add("REST API", .fail, "plugin has no apiKey/port yet -- open Obsidian once");
        return;
    }
    try ctx.add("REST API", .ok, try ctx.fmt("127.0.0.1:{d}", .{port}));

    const home = ctx.env.get("HOME") orelse "";
    const cert = try ctx.fmt("{s}/.claude/obsidian-local-rest-api-ca.pem", .{home});
    if (ctx.exists(cert)) {
        try ctx.add("certificate", .ok, cert);
    } else {
        try ctx.add("certificate", .fail, "absent -- created automatically by the obsidian-mcp-refresh.sh SessionStart hook; start a new session");
        return;
    }

    // The one round-trip check, not a file test: most real API failures are
    // reachability failures (Obsidian not running, sandbox blocking loopback).
    const url = try ctx.fmt("https://127.0.0.1:{d}/vault/", .{port});
    const auth = try ctx.fmt("Authorization: Bearer {s}", .{key});
    const res = adapters.process.run(ctx.io, ctx.gpa, &.{
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
        "--max-time", "5", "--cacert", cert, "-H", auth, url,
    }, .{}) catch {
        try ctx.add("Obsidian", .fail, "curl did not run");
        return;
    };
    defer res.deinit(ctx.gpa);
    const status = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (res.ok() and status.len != 0 and status[0] == '2') {
        try ctx.add("Obsidian", .ok, "answering on loopback");
    } else if (res.ok() and std.mem.eql(u8, status, "401")) {
        try ctx.add("Obsidian", .fail, "answered 401 -- the stored apiKey is stale");
    } else {
        try ctx.add("Obsidian", .fail, "not answering -- is it running with the plugin enabled?");
    }
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
    const repos = if (ctx.env.get("SYNAPSE_GRAMMARS_DIR")) |d|
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

/// The installed version directory under the plugin cache, if `claude plugin
/// install synapse@synapse` has actually succeeded -- keyed by the
/// marketplace/plugin names this repo's own `marketplace.json` declares
/// (verified directly against a real install, sb-019), not guessed. A plugin
/// install never populates `~/.claude/bin/synapse-hook` or merges hooks into
/// `settings.json` -- `hooks.json` is loaded straight from this cache
/// instead -- so `hookChecks` below must tell the two install shapes apart
/// rather than judge a healthy plugin install by the legacy shape's absence.
fn pluginVersionDir(ctx: *Ctx) !?[]const u8 {
    const home = ctx.env.get("HOME") orelse return null;
    const cache = try ctx.fmt("{s}/.claude/plugins/cache/synapse/synapse", .{home});
    var dir = Io.Dir.cwd().openDir(ctx.io, cache, .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    const entry = (try it.next(ctx.io)) orelse return null;
    return try ctx.fmt("{s}/{s}", .{ cache, entry.name });
}

/// Whether the five hooks are registered, once each, at the current command. Mirrors
/// nothing silent -- it mirrors something *loud in the wrong direction*: a hook wired
/// twice fires twice, and the only symptom is duplicated context nobody attributes to
/// settings.json. Two entirely different install shapes to check, not one: a plugin
/// install (hooks.json in the plugin cache) or the legacy setup.sh shape (hooks merged
/// into settings.json, binary at a fixed path) -- whichever one is actually present.
fn hookChecks(ctx: *Ctx) !void {
    if (try pluginVersionDir(ctx)) |version_dir| {
        const hooks_json = try ctx.fmt("{s}/hooks/hooks.json", .{version_dir});
        try ctx.add("hooks", if (ctx.exists(hooks_json)) .ok else .fail, if (ctx.exists(hooks_json))
            try ctx.fmt("plugin install -- {s}", .{hooks_json})
        else
            try ctx.fmt("plugin install detected at {s} but hooks/hooks.json is missing -- reinstall the plugin", .{version_dir}));
        return;
    }

    const home = ctx.env.get("HOME") orelse return;
    const hook_bin = try ctx.fmt("{s}/.claude/bin/synapse-hook", .{home});
    try ctx.add("hook binary", if (ctx.exists(hook_bin)) .ok else .fail, if (ctx.exists(hook_bin))
        hook_bin
    else
        "no plugin install and no legacy hook binary -- install the Synapse Claude Code plugin");

    const settings_path = try ctx.fmt("{s}/.claude/settings.json", .{home});
    const text = ctx.read(settings_path) orelse {
        try ctx.add("hooks", .fail, "no settings.json -- this looks like neither a plugin nor a legacy install");
        return;
    };
    const names = [_][]const u8{ "session-start", "prompt-context", "staleness", "db-sync", "stop-nudge" };
    var missing: usize = 0;
    var duplicated: usize = 0;
    for (names) |name| {
        const needle = try ctx.fmt("synapse-hook {s}", .{name});
        const n = std.mem.count(u8, text, needle);
        if (n == 0) missing += 1;
        if (n > 1) duplicated += 1;
    }
    if (missing == 0 and duplicated == 0) {
        try ctx.add("hooks", .ok, "all five registered once (legacy install)");
    } else if (duplicated != 0) {
        try ctx.add("hooks", .fail, try ctx.fmt(
            "{d} registered more than once -- each fires that many times; fix ~/.claude/settings.json or reinstall the plugin",
            .{duplicated},
        ));
    } else {
        try ctx.add("hooks", .fail, try ctx.fmt("{d} of 5 not registered -- fix ~/.claude/settings.json or install the plugin", .{missing}));
    }

    // A wrapper still referenced would silently take precedence over the binary for
    // that hook, and it would keep working -- which is why this is a failure rather
    // than a note.
    if (std.mem.indexOf(u8, text, "hooks/synapse-") != null)
        try ctx.add("hook wiring", .fail, "settings.json still names a hooks/*.sh wrapper -- fix ~/.claude/settings.json or reinstall the plugin");
}
