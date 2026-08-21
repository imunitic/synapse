//! `synapse-hook session-start` -- SessionStart.
//!
//! Injects the vault's `Index.md` so a session starts with the map already
//! in context, plus the Synapse pointer check. Everything here is a path
//! lookup, never a model call or HTTP round trip, which keeps it zero-cost
//! for a repo that never ran `/synapse-init`. Three pieces: the vault
//! index; this repo's namespace pointer (verified against the recorded
//! remote, or an explicit "no namespace" line); and a catalogue of the
//! *other* namespaces, so a session that later `cd`s elsewhere knows that
//! repo's graph exists too.
//!
//! The catalogue is built here and stored nowhere -- the directory listing
//! plus each index's `remote:` field is the source of truth, so nothing to
//! invalidate, and this hook stays read-only against the vault (only
//! `staleness` writes).
//!
//! A mismatched remote is reported, never repaired: it could mean a
//! different repo sharing this basename, or this repo's remote changed
//! deliberately (including via a `url.<base>.insteadOf` git config rule).
//! Nothing here tries to tell those apart or auto-migrate -- both remedies
//! belong to the person who made the change.

const std = @import("std");
const core = @import("core");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const label = "Synapse Vault index";

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv0: []const u8) !void {
    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();

    const text = try build(gpa, io, env, argv0, payload.str("cwd") orelse ".") orelse return;
    defer gpa.free(text);
    try common.emitContext(gpa, io, "SessionStart", text);
}

/// The command itself, minus payload parsing -- separated so a test can
/// drive it against a real fixture directly, without a real stdin payload.
/// Returns the injected context text, or null when there's nothing to say.
/// Caller owns the result.
pub fn build(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv0: []const u8, cwd: []const u8) !?[]u8 {
    const vault = common.vault(gpa, io, env) orelse ""; // one guard below, not two paths
    defer if (vault.len != 0) gpa.free(vault);

    var synapse_line: ?[]u8 = null;
    defer if (synapse_line) |s| gpa.free(s);
    var absent: ?[]u8 = null;
    defer if (absent) |s| gpa.free(s);
    var catalogue: ?[]u8 = null;
    defer if (catalogue) |s| gpa.free(s);

    // Independent of vault configuration entirely -- this is Synapse's own
    // standing instructions, not vault content. `CLAUDE_PLUGIN_ROOT` is a
    // real exported environment variable on the spawned hook process
    // ("regardless of how it was launched", per Claude Code's own hooks
    // reference) -- checked first when running as a plugin. Falls back to
    // resolving relative to this binary's own invoked path (`argv0`), one
    // directory up, for the pre-plugin `setup.sh` install, which has no
    // `CLAUDE_PLUGIN_ROOT` at all: `~/.claude/bin/synapse-hook` next to
    // `~/.claude/synapse-claude.md` today. No frontmatter to strip --
    // unlike a skill file, this one has none.
    var claude_md: ?[]u8 = null;
    defer if (claude_md) |s| gpa.free(s);
    const claude_md_path: ?[]u8 = if (env.get("CLAUDE_PLUGIN_ROOT")) |root|
        try std.fmt.allocPrint(gpa, "{s}/synapse-claude.md", .{root})
    else if (std.fs.path.dirname(argv0)) |bin_dir|
        try std.fmt.allocPrint(gpa, "{s}/../synapse-claude.md", .{bin_dir})
    else
        null;
    if (claude_md_path) |path| {
        defer gpa.free(path);
        if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20))) |content| {
            claude_md = content;
        } else |_| {}
    }

    // The one precondition every other section here silently depends on.
    // Said, not implied by silence: there's no install-time prompt to catch
    // this instead (a plugin install just clones files, nothing prints
    // anything), so this hook is the only place it can ever get said.
    var vault_warning: ?[]u8 = null;
    defer if (vault_warning) |s| gpa.free(s);
    if (vault.len == 0) {
        vault_warning = try gpa.dupe(
            u8,
            "Synapse Vault isn't configured, or its directory isn't reachable -- code-graph and vault-note features are unavailable until synapse.conf's OBSIDIAN_VAULT_DIR points at a real directory. Create or edit synapse.conf at $XDG_CONFIG_HOME/synapse/synapse.conf (or ~/.config/synapse/synapse.conf if that variable isn't set), or ~/.claude/synapse.conf.",
        );
    }

    // The catalogue below needs the key to drop this repo's own namespace.
    const maybe_ns = if (vault.len != 0)
        common.Namespace.resolve(gpa, io, env, cwd)
    else
        null;
    defer if (maybe_ns) |ns| ns.deinit(gpa);

    if (vault.len != 0) {
        if (maybe_ns) |ns| {
            const ns_index = try std.fmt.allocPrint(gpa, "{s}/synapse/{s}/Index.md", .{ vault, ns.key });
            defer gpa.free(ns_index);
            if (Io.Dir.cwd().readFileAlloc(io, ns_index, gpa, .limited(64 << 20))) |text| {
                defer gpa.free(text);
                const existing = core.query.field(text, "remote") orelse "";
                if (std.mem.eql(u8, existing, ns.remote)) {
                    synapse_line = try std.fmt.allocPrint(
                        gpa,
                        "Synapse namespace for this repo and branch: synapse/{s}/Index.md -- consult it for existing code-graph nodes before re-exploring from scratch.",
                        .{ns.key},
                    );
                } else {
                    synapse_line = try std.fmt.allocPrint(
                        gpa,
                        "Synapse namespace synapse/{s}/ exists but its remote (\"{s}\") doesn't match this repo's (\"{s}\") -- either a different repo sharing this name, or this repo's remote changed. Skipping the pointer rather than risk cross-project contamination. If the remote changed deliberately, rebuild the namespace with /synapse-rebuild-full.",
                        .{ ns.key, existing, ns.remote },
                    );
                }
            } else |_| {
                // Said, not implied by silence -- a branch with no namespace
                // is ordinary, but must stay distinguishable from "a
                // namespace that found nothing".
                absent = try std.fmt.allocPrint(gpa, "synapse/{s}/", .{ns.key});
            }
        }
        catalogue = try buildCatalogue(gpa, io, vault, if (maybe_ns) |ns| ns.key else null);
    }

    var base: ?[]u8 = null;
    defer if (base) |b| gpa.free(b);
    if (vault.len != 0) {
        const index_path = try std.fmt.allocPrint(gpa, "{s}/Index.md", .{vault});
        defer gpa.free(index_path);
        if (Io.Dir.cwd().readFileAlloc(io, index_path, gpa, .limited(64 << 20))) |content| {
            defer gpa.free(content);
            base = try std.fmt.allocPrint(
                gpa,
                "{s} ({s}) — read before creating or linking any note; prefer linking to an existing note over duplicating content, and fall back to linking this index if nothing more specific applies:\n\n{s}",
                .{ label, index_path, content },
            );
        } else |_| {
            // `vault` is already confirmed to exist and be a real directory
            // by common.vault() above, so a read failure here can only mean
            // Index.md itself is missing -- not an unreachable vault. Offer,
            // don't seed: this is the agent's call to make, not this hook's.
            //
            // The seed template's own path is resolved the same way
            // `claude_md_path` above resolves `synapse-claude.md` -- a
            // repo-relative string (`plugins/synapse/Index.md.template`)
            // means nothing to a model inside an ordinary installed
            // session, which has no copy of this repo checked out at all.
            // `CLAUDE_PLUGIN_ROOT` (or, pre-plugin, argv0's own directory)
            // is the only path that resolves in every install shape.
            const template_path: ?[]u8 = if (env.get("CLAUDE_PLUGIN_ROOT")) |root|
                try std.fmt.allocPrint(gpa, "{s}/Index.md.template", .{root})
            else if (std.fs.path.dirname(argv0)) |bin_dir|
                try std.fmt.allocPrint(gpa, "{s}/../Index.md.template", .{bin_dir})
            else
                null;
            defer if (template_path) |p| gpa.free(p);

            base = try std.fmt.allocPrint(
                gpa,
                "No Index.md found at {s} -- the configured Synapse Vault has no index yet. Offer to seed it from the shipped default ({s}) before creating or linking any note.",
                .{ index_path, template_path orelse "this plugin's own Index.md.template" },
            );
        }
    }

    // Only worth saying alongside something else -- alone it's a hook
    // announcing it has nothing to announce.
    if (absent) |a| {
        if (base != null or catalogue != null) {
            synapse_line = try std.fmt.allocPrint(
                gpa,
                "No Synapse namespace covers {s} -- this branch has no code graph. That is normal; /synapse-init builds one if it is worth it. Nothing here is stale, there is simply nothing to consult.",
                .{a},
            );
        }
    }

    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    var wrote = false;
    for ([_]?[]u8{ claude_md, vault_warning, base, synapse_line, catalogue }) |part| {
        const p = part orelse continue;
        if (p.len == 0) continue;
        if (wrote) try text.writer.writeAll("\n\n");
        try text.writer.writeAll(p);
        wrote = true;
    }
    if (!wrote) return null;
    return try gpa.dupe(u8, text.written());
}

/// `name|remote` for every *other* namespace in the vault, byte-sorted (this
/// repo's own is dropped -- it already got the stronger verified pointer
/// above). Byte-sorted, not locale-collated, so the text is identical
/// across machines.
fn buildCatalogue(gpa: Allocator, io: Io, vault: []const u8, own: ?[]const u8) !?[]u8 {
    const root = try std.fmt.allocPrint(gpa, "{s}/synapse", .{vault});
    defer gpa.free(root);
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var entries: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (entries.items) |e| gpa.free(e);
        entries.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (own) |o| if (std.mem.eql(u8, entry.name, o)) continue;
        const index_path = try std.fmt.allocPrint(gpa, "{s}/{s}/Index.md", .{ root, entry.name });
        defer gpa.free(index_path);
        const text = Io.Dir.cwd().readFileAlloc(io, index_path, gpa, .limited(64 << 20)) catch continue;
        defer gpa.free(text);
        const remote = core.query.field(text, "remote") orelse continue;
        try entries.append(gpa, try std.fmt.allocPrint(gpa, "{s}|{s}", .{ entry.name, remote }));
    }
    if (entries.items.len == 0) return null;
    std.mem.sort([]u8, entries.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(
        "Other Synapse namespaces in this vault (name | remote). A session that moves into one of these repos can consult synapse/{name}/Index.md for its code graph -- but verify the listed remote against that repo's own `git remote get-url origin` first, since a namespace is keyed by repo and branch and names only the branch it was built from:\n",
    );
    for (entries.items, 0..) |e, i| {
        if (i > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(e);
    }
    return try out.toOwnedSlice();
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

const SessionStartFixture = struct {
    fx: fixture.Fixture,

    fn init(gpa: Allocator) !SessionStartFixture {
        const fx = try fixture.Fixture.init(gpa);
        return .{ .fx = fx };
    }

    fn deinit(self: *SessionStartFixture) void {
        self.fx.deinit();
    }

    /// A separate step from `init()`, called by every test right after
    /// construction -- see `graph_cmd.zig`'s `CleanFixture.commit()` for
    /// why a real file has to exist before `gitCommit()`, and
    /// `brief_cmd.zig`'s `BriefFixture` for why this can't happen inside
    /// `init()` itself.
    fn commit(self: *SessionStartFixture) !void {
        try self.fx.writeRepoFile("README.md", "seed\n");
        try self.fx.gitCommit("init");
    }

    fn addRemote(self: *SessionStartFixture, remote_url: []const u8) !void {
        const res = try self.fx.git(&.{ "remote", "add", "origin", remote_url });
        res.deinit(self.fx.gpa);
    }

    fn writeVaultIndex(self: *SessionStartFixture) !void {
        try self.fx.tmp.dir.writeFile(testing.io, .{
            .sub_path = "vault/Index.md",
            .data = "---\ntitle: \"Index\"\n---\n# Index\nTest index content.\n",
        });
    }

    /// `synapse/{key}/Index.md`, real enough for `build()` to read (only
    /// `remote:` matters to it) -- `key` need not correspond to a real repo
    /// on disk, for the catalogue's "foreign" namespaces.
    fn writeNamespace(self: *SessionStartFixture, key: []const u8, remote: []const u8) !void {
        try self.fx.writeIndex(key, remote, "main");
    }

    /// `dir` is an absolute path, potentially outside the fixture's own tmp
    /// root (the argv0-fallback test needs a `plugin/hooks/../` shape) --
    /// written through `Io.Dir.cwd()` directly rather than the fixture's
    /// own relative-rooted `tmp.dir`, the same pattern `staleness.zig`'s own
    /// tests already use for paths outside the tmp tree.
    fn writeClaudeMd(self: *SessionStartFixture, dir: []const u8, content: []const u8) !void {
        try Io.Dir.cwd().createDirPath(self.fx.io(), dir);
        const path = try std.fmt.allocPrint(self.fx.gpa, "{s}/synapse-claude.md", .{dir});
        defer self.fx.gpa.free(path);
        try Io.Dir.cwd().writeFile(self.fx.io(), .{ .sub_path = path, .data = content });
    }

    fn inject(self: *SessionStartFixture, argv0: []const u8, cwd: []const u8) !?[]u8 {
        return build(self.fx.gpa, self.fx.io(), &self.fx.env, argv0, cwd);
    }
};

test "no vault index and no synapse namespace: offers to seed Index.md, states the namespace absence" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.commit();

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "No Index.md found at") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Offer to seed it") != null);
    try testing.expect(std.mem.indexOf(u8, text, "No Synapse namespace covers synapse/repo@main/") != null);
}

test "vault index present, no synapse namespace: says so rather than staying silent" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.writeVaultIndex();
    try sf.commit();

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Test index content.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "No Synapse namespace covers synapse/repo@main/") != null);
    // Ordinary, not alarming: it must not read as something being broken.
    try testing.expect(std.mem.indexOf(u8, text, "That is normal") != null);
}

test "synapse namespace with matching remote: appends pointer line" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.writeVaultIndex();
    try sf.commit();
    try sf.addRemote("git@github.com:example/repo.git");
    try sf.writeNamespace("repo@main", "git@github.com:example/repo.git");

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Synapse namespace for this repo and branch: synapse/repo@main/Index.md") != null);
}

test "synapse namespace with mismatched remote: skips pointer and says so" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.writeVaultIndex();
    try sf.commit();
    try sf.addRemote("git@github.com:example/repo.git");
    try sf.writeNamespace("repo@main", "git@github.com:someone-else/unrelated.git");

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "doesn't match") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Skipping the pointer") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Synapse namespace for this repo:") == null);
    // Both causes named, and a remedy. A changed remote is the likelier of
    // the two and used to go unmentioned, so the message read as an
    // accusation of a name collision with nothing to do about it.
    try testing.expect(std.mem.indexOf(u8, text, "this repo's remote changed") != null);
    try testing.expect(std.mem.indexOf(u8, text, "/synapse-rebuild-full") != null);
}

test "synapse namespace keyed by path fallback when repo has no remote" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.writeVaultIndex();
    try sf.commit(); // no remote
    const remote = common.Namespace.resolve(gpa, sf.fx.io(), &sf.fx.env, sf.fx.repo) orelse return error.NoIdentity;
    defer remote.deinit(gpa);
    try sf.writeNamespace("repo@main", remote.remote);

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Synapse namespace for this repo and branch: synapse/repo@main/Index.md") != null);
}

test "cwd outside any git repo: base index still injected, no synapse logic invoked" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.writeVaultIndex();

    const text = (try sf.inject("", "/tmp")).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Test index content.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Synapse namespace") == null);
}

test "no OBSIDIAN_VAULT_DIR configured: warns instead of staying silent, synapse check skipped" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.commit();
    try sf.addRemote("git@github.com:example/repo.git");
    _ = sf.fx.env.swapRemove("OBSIDIAN_VAULT_DIR");

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Synapse Vault isn't configured") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Synapse namespace") == null);
}

test "synapse-claude.md is injected from $CLAUDE_PLUGIN_ROOT when that's set" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.commit();
    const plugin_dir = try std.fmt.allocPrint(gpa, "{s}/plugin", .{sf.fx.root});
    defer gpa.free(plugin_dir);
    try sf.writeClaudeMd(plugin_dir, "STANDING INSTRUCTIONS MARKER\n");
    try sf.fx.env.put("CLAUDE_PLUGIN_ROOT", plugin_dir);

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "STANDING INSTRUCTIONS MARKER") != null);
}

test "synapse-claude.md, when CLAUDE_PLUGIN_ROOT is unset, falls back to one directory above this binary" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.commit();
    const plugin_dir = try std.fmt.allocPrint(gpa, "{s}/plugin", .{sf.fx.root});
    defer gpa.free(plugin_dir);
    try sf.writeClaudeMd(plugin_dir, "STANDING INSTRUCTIONS MARKER\n");
    // `hooks/` has to exist as a real directory even though argv0 itself
    // doesn't need to be a real executable (build() only ever takes its
    // dirname to resolve a sibling file, never executes it) -- the
    // resolved path traverses through it via `..`, and path resolution
    // fails if an intermediate component doesn't exist on disk.
    const hooks_dir = try std.fmt.allocPrint(gpa, "{s}/plugin/hooks", .{sf.fx.root});
    defer gpa.free(hooks_dir);
    try Io.Dir.cwd().createDirPath(sf.fx.io(), hooks_dir);
    const argv0 = try std.fmt.allocPrint(gpa, "{s}/synapse-hook", .{hooks_dir});
    defer gpa.free(argv0);

    const text = (try sf.inject(argv0, sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "STANDING INSTRUCTIONS MARKER") != null);
}

test "no synapse-claude.md anywhere resolvable: injection is silently skipped" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.commit();

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "STANDING INSTRUCTIONS MARKER") == null);
}

test "catalogue: other namespaces are listed, the cwd repo's own is not" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.writeVaultIndex();
    try sf.commit();
    try sf.addRemote("git@github.com:example/repo.git");
    try sf.writeNamespace("repo@main", "git@github.com:example/repo.git");
    try sf.writeNamespace("mono-repo", "ssh://git@example.com/mono-repo.git");
    try sf.writeNamespace("shared-lib", "ssh://git@example.com/shared-lib.git");

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Other Synapse namespaces in this vault") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mono-repo|ssh://git@example.com/mono-repo.git") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shared-lib|ssh://git@example.com/shared-lib.git") != null);
    // own namespace excluded -- it already got the verified pointer above
    try testing.expect(std.mem.indexOf(u8, text, "repo@main|") == null);
}

test "catalogue: only the cwd repo has a namespace, so no catalogue is emitted" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.writeVaultIndex();
    try sf.commit();
    try sf.addRemote("git@github.com:example/repo.git");
    try sf.writeNamespace("repo@main", "git@github.com:example/repo.git");

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Other Synapse namespaces") == null);
    // the pointer itself is unaffected
    try testing.expect(std.mem.indexOf(u8, text, "Synapse namespace for this repo") != null);
}

test "catalogue: no synapse/ directory at all means nothing extra is emitted" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.writeVaultIndex();
    try sf.commit();

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Other Synapse namespaces") == null);
}

test "catalogue: ordering is byte sorted, not directory creation order" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.writeVaultIndex();
    try sf.commit();
    // created in deliberately non-alphabetical order
    try sf.writeNamespace("zzz-last", "ssh://git@example.com/z.git");
    try sf.writeNamespace("mmm-middle", "ssh://git@example.com/m.git");
    try sf.writeNamespace("aaa-first", "ssh://git@example.com/a.git");

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    const first = std.mem.indexOf(u8, text, "aaa-first|").?;
    const middle = std.mem.indexOf(u8, text, "mmm-middle|").?;
    const last = std.mem.indexOf(u8, text, "zzz-last|").?;
    try testing.expect(first < middle);
    try testing.expect(middle < last);
}

test "catalogue: outside any git repo, every namespace is listed and no pointer is emitted" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.writeVaultIndex();
    try sf.writeNamespace("core-lib", "ssh://git@example.com/core-lib.git");
    try sf.writeNamespace("mono-repo", "ssh://git@example.com/mono-repo.git");

    const text = (try sf.inject("", "/tmp")).?;
    defer gpa.free(text);
    // nothing to exclude, so both appear
    try testing.expect(std.mem.indexOf(u8, text, "core-lib|") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mono-repo|") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Synapse namespace for this repo") == null);
}

test "catalogue: emitted even when the vault has no Index.md to inject" {
    const gpa = testing.allocator;
    var sf = try SessionStartFixture.init(gpa);
    defer sf.deinit();
    try sf.commit();
    try sf.writeNamespace("mono-repo", "ssh://git@example.com/mono-repo.git");

    const text = (try sf.inject("", sf.fx.repo)).?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "mono-repo|") != null);
}
