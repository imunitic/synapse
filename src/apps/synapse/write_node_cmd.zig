//! `synapse write-node` -- `claude/lib/synapse/synapse-write-node.sh`.
//!
//!   write-node --title <t> --summary <s> --paths <file> --body <file>
//!
//! Hashes every source, computes `sources_digest`, records the baseline
//! `commit`, expands the crux directive, records and strips the groundings,
//! builds the `## Sources` mirror, and writes the note through whichever
//! `Store` `SYNAPSE_VAULT_INTEGRATIONS`/`SYNAPSE_VAULT_DIR` resolve to
//! (`adapters.store_resolve.resolveStore`) -- a plain disk write either
//! way, `disk` (the default) or an extended store.
//!
//! Prints `<file>\t<n> files\t<digest>` on success. Exit 1 for anything
//! that made the write impossible, 2 for a usage error.
//!
//! The write goes through `Store` so an extended store's own live view
//! stays consistent and the vault's git hook sees the change; the three
//! reads this command makes are plain disk reads regardless of backend
//! (see `context.zig`) -- reading a node the compiled binary already has a
//! local checkout of never needed to go through a `Store` at all.
//!
//! Refuses (exit 1, not a degraded write) a crux path the node doesn't
//! claim, a range outside the file, and a range longer than its cap -- all
//! in `core/emit.zig`. Also refuses to destroy hand-written notes:
//! everything after `<!-- synapse:generated:end -->` in an existing node
//! is re-emitted verbatim.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const context = @import("context.zig");
const tags_cache_cmd = @import("tags_cache_cmd.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = context.Context;
const emit = core.emit;

const prog = "synapse-write-node";

const usage_text =
    \\usage: synapse write-node --title <t> --summary <s> --paths <file> --body <file>
    \\
    \\  --title    node title. Used verbatim as the H1, and sanitized for the filename.
    \\  --summary  one line for the index bullet, stored as the `summary` field.
    \\  --paths    file of repo-relative paths, one per line: every file the node covers.
    \\  --body     file holding the authored prose (## Summary / ## Crux / ## Links).
    \\
;

fn usage() u8 {
    std.debug.print("{s}", .{usage_text});
    return 2;
}

pub fn run(
    comptime Extractor: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var title: []const u8 = "";
    var summary: []const u8 = "";
    var paths_file: []const u8 = "";
    var body_file: []const u8 = "";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        }
        const dest: *[]const u8 =
            if (std.mem.eql(u8, arg, "--title")) &title
            else if (std.mem.eql(u8, arg, "--summary")) &summary
            else if (std.mem.eql(u8, arg, "--paths")) &paths_file
            else if (std.mem.eql(u8, arg, "--body")) &body_file
            else return usage();
        dest.* = args.next() orelse return usage();
    }
    if (title.len == 0 or summary.len == 0 or paths_file.len == 0 or body_file.len == 0)
        return usage();

    const cwd = Io.Dir.cwd();
    const paths_text = cwd.readFileAlloc(io, paths_file, gpa, .limited(256 << 20)) catch {
        std.debug.print("{s}: empty path list: {s}\n", .{ prog, paths_file });
        return 1;
    };
    defer gpa.free(paths_text);
    if (paths_text.len == 0) {
        std.debug.print("{s}: empty path list: {s}\n", .{ prog, paths_file });
        return 1;
    }
    const body_text = cwd.readFileAlloc(io, body_file, gpa, .limited(256 << 20)) catch {
        std.debug.print("{s}: no body file: {s}\n", .{ prog, body_file });
        return 1;
    };
    defer gpa.free(body_text);

    var ctx = (try context.resolve(gpa, io, env, prog)) orelse return 1;
    defer ctx.deinit();

    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try write(Extractor, gpa, io, env, &ctx, .{
        .title = title,
        .summary = summary,
        .paths_text = paths_text,
        .body_text = body_text,
    }, &out.interface);
    try out.interface.flush();
    return code;
}

pub const Input = struct {
    title: []const u8,
    summary: []const u8,
    paths_text: []const u8,
    body_text: []const u8,
    /// Test-only: `tags_cache_cmd.backfill`'s own per-path trace log, so a
    /// test can tell a cache-hit second run (nothing traced) from a real
    /// re-tag without a call counter on the fake extractor.
    trace: ?[]const u8 = null,
};

/// `result` receives the one success line, `<file>\t<n> files\t<digest>`.
/// Passed in, not printed: `push-nodes` prefixes it with the node number
/// and doesn't want it on stdout twice.
pub fn write(
    comptime Extractor: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    ctx: *const Context,
    in: Input,
    result: *Io.Writer,
) !u8 {
    // --- refuse to write into another repo's namespace -----------------------
    // Checked only when Index.md exists -- absent means a first build, fine.
    if (try readVault(gpa, io, ctx, "Index.md")) |index_text| {
        defer gpa.free(index_text);
        const existing_remote = core.query.field(index_text, "remote") orelse "";
        if (existing_remote.len != 0 and !std.mem.eql(u8, existing_remote, ctx.remote)) {
            std.debug.print("{s}: {s}/ belongs to a different repo\n", .{ prog, ctx.dir });
            std.debug.print("  existing remote: {s}\n", .{existing_remote});
            std.debug.print("  this repo:       {s}\n", .{ctx.remote});
            std.debug.print("  refusing to overwrite -- rename one of the two repos first\n", .{});
            return 1;
        }
        const existing_branch = core.query.field(index_text, "branch") orelse "";
        if (existing_branch.len != 0 and !std.mem.eql(u8, existing_branch, ctx.branch)) {
            std.debug.print(
                "{s}: {s}/ records branch '{s}', not '{s}'\n",
                .{ prog, ctx.dir, existing_branch, ctx.branch },
            );
            std.debug.print("  the directory name and its branch field disagree -- refusing to write\n", .{});
            return 1;
        }
    }

    // A sanitised title silently breaks inbound wikilinks, hence the warning.
    const file_title = try emit.fileTitle(gpa, in.title);
    defer gpa.free(file_title);
    if (!std.mem.eql(u8, file_title, in.title)) {
        std.debug.print(
            "{s}: WARNING title needed sanitizing, so [[{s}]] will not resolve\n",
            .{ prog, in.title },
        );
        std.debug.print("  filename: {s}.md -- reword the title to avoid divergence\n", .{file_title});
    }
    const node_file = try std.fmt.allocPrint(gpa, "{s}.md", .{file_title});
    defer gpa.free(node_file);

    // --- preserve everything after the generated region ----------------------
    var tail: ?[]const u8 = null;
    const existing = try readVault(gpa, io, ctx, node_file);
    defer if (existing) |e| gpa.free(e);
    if (existing) |e| {
        const s = core.node.split(e);
        if (s.fenced) {
            const after_marker = s.tail[core.node.generated_end.len..];
            const cut = if (after_marker.len != 0 and after_marker[0] == '\n')
                after_marker[1..]
            else
                after_marker;
            tail = std.mem.trimEnd(u8, cut, "\n");
        }
    }

    // --- the source list, deduplicated and byte-sorted -----------------------
    var paths = try sortedUnique(gpa, in.paths_text);
    defer paths.deinit(gpa);

    // Every path checked before any is hashed, so a bad entry (deleted since
    // enumeration, a submodule gitlink) is named, not just an abort.
    var contents = try gpa.alloc([]u8, paths.items.len);
    var loaded: usize = 0;
    defer {
        for (contents[0..loaded]) |c| gpa.free(c);
        gpa.free(contents);
    }
    var bad: Io.Writer.Allocating = .init(gpa);
    defer bad.deinit();
    for (paths.items) |p| {
        const c = try readRepoFile(gpa, io, ctx, p);
        if (c) |content| {
            contents[loaded] = content;
            loaded += 1;
        } else try bad.writer.print("{s} ", .{p});
    }
    if (bad.written().len != 0) {
        std.debug.print(
            "{s}: not regular files in {s}: {s}\n",
            .{ prog, ctx.repo_root, std.mem.trimEnd(u8, bad.written(), " ") },
        );
        std.debug.print(
            "  (deleted since enumeration, or a submodule gitlink -- drop them from the list)\n",
            .{},
        );
        return 1;
    }

    var sources = try gpa.alloc(core.node.Source, paths.items.len);
    defer {
        for (sources) |s| gpa.free(s.hash);
        gpa.free(sources);
    }
    for (paths.items, contents, 0..) |p, c, i|
        sources[i] = .{ .path = p, .hash = try gpa.dupe(u8, &core.verify.blobHash(c)) };

    const digest = try core.node.sourcesDigest(gpa, sources);

    // --- baseline commit, for `query drift` -- full sha, never abbreviated ---
    const commit = try headCommit(gpa, io, ctx);
    defer if (commit) |c| gpa.free(c);
    if (commit != null) try warnDirtySources(gpa, io, ctx, paths.items, commit.?);

    // --- keep the tags cache current, as a byproduct -------------------------
    if (env.get("SYNAPSE_DISABLE_SYMBOL_CACHE") == null)
        try refreshTagsCache(Extractor, gpa, io, env, ctx, paths.items, contents, in.trace);

    // --- crux and groundings -------------------------------------------------
    const home = env.get("HOME") orelse return 1;
    const fence_langs_path = if (env.get("SYNAPSE_FENCE_LANGUAGES_CONF")) |p|
        try gpa.dupe(u8, p)
    else if (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-fence-languages.conf")) |p|
        p
    else
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-fence-languages.conf", .{home});
    defer gpa.free(fence_langs_path);
    var fence_langs = core.fence_languages.Registry.load(gpa, io, fence_langs_path) catch {
        std.debug.print("{s}: cannot read the fence-languages registry\n", .{prog});
        return 1;
    };
    defer fence_langs.deinit();

    var body: []const u8 = in.body_text;
    var owned_body: ?[]u8 = null;
    defer if (owned_body) |b| gpa.free(b);

    var crux_field: ?emit.CruxPointer = null;
    var crux_lines_buf: ?[]u8 = null;
    defer if (crux_lines_buf) |b| gpa.free(b);

    // Scoped to the `## Crux` section, not the whole body: prose describing
    // the directive syntax elsewhere (a node about Synapse's own node format,
    // say) is otherwise indistinguishable from the real directive and gets
    // matched instead of it. No `## Crux` heading at all means no crux was
    // authored -- not a fallback to a whole-body scan, which would just
    // resurrect the same bug in a smaller disguise.
    const crux_section = emit.section(body, "Crux");
    const crux_directive = if (crux_section) |cs| emit.findDirective(cs, emit.kind_crux) else null;
    if (crux_directive) |directive| {
        const arg = emit.directiveArg(directive[4 .. directive.len - 3], emit.kind_crux).?;
        var block: Io.Writer.Allocating = .init(gpa);
        defer block.deinit();

        if (std.mem.eql(u8, arg, "none")) {
            try block.writer.writeAll(emit.crux_none_text);
        } else {
            const span = emit.parseSpan(arg) orelse {
                std.debug.print("{s}: bad crux directive: {s}\n", .{ prog, directive });
                std.debug.print(
                    "  expected: <!-- crux: path/to/file.ext 412-419 -->  (or 'none')\n",
                    .{},
                );
                return 1;
            };
            const content = try readRepoFile(gpa, io, ctx, span.path);
            defer if (content) |c| gpa.free(c);
            if (try reportSpanProblem(gpa, span, .crux, paths.items, content)) return 1;
            const cut = core.verify.slice(content.?, span.start, span.end).?;
            try emit.writeCruxBlock(&block.writer, span, cut, fence_langs.languageFor(span.path));
            crux_lines_buf = try std.fmt.allocPrint(gpa, "{d}-{d}", .{ span.start, span.end });
            crux_field = .{ .path = span.path, .lines = crux_lines_buf.? };
        }
        const expanded = try emit.substituteLine(gpa, body, directive, block.written());
        owned_body = expanded;
        body = expanded;
    }

    var grounded: std.ArrayListUnmanaged(emit.Grounded) = .empty;
    defer {
        for (grounded.items) |g| {
            gpa.free(g.path);
            gpa.free(g.lines);
            gpa.free(g.digest);
        }
        grounded.deinit(gpa);
    }
    {
        var it = emit.directives(body, emit.kind_grounded);
        while (it.next()) |directive| {
            const arg = emit.directiveArg(directive[4 .. directive.len - 3], emit.kind_grounded).?;
            const span = emit.parseSpan(arg) orelse {
                std.debug.print("{s}: bad grounded_in directive: {s}\n", .{ prog, directive });
                std.debug.print("  expected: <!-- grounded_in: path/to/file.ext 10-14 -->\n", .{});
                return 1;
            };
            const content = try readRepoFile(gpa, io, ctx, span.path);
            defer if (content) |c| gpa.free(c);
            if (try reportSpanProblem(gpa, span, .grounded, paths.items, content)) return 1;
            const cut = core.verify.slice(content.?, span.start, span.end).?;
            try grounded.append(gpa, .{
                // Owned, not borrowed from `body` -- `body` gets replaced
                // (and the buffer `span.path` points into freed) by the
                // `stripGrounded` call just below, once every directive in
                // this loop has been read. A borrowed slice here survives
                // only until that free, then reads back as whatever the
                // allocator leaves behind (confirmed live: all-zero bytes),
                // silently corrupting every grounded_in path in the
                // written note while `lines`/`digest` -- already
                // independently allocated -- stay correct.
                .path = try gpa.dupe(u8, span.path),
                .lines = try std.fmt.allocPrint(gpa, "{d}-{d}", .{ span.start, span.end }),
                // Digest of the sliced text, never the text itself -- keeps
                // the field small and a change elsewhere leaves it intact.
                .digest = try gpa.dupe(u8, &core.verify.sha256Hex(cut)),
            });
        }
        if (grounded.items.len != 0) {
            const stripped = try emit.stripGrounded(gpa, body);
            if (owned_body) |b| gpa.free(b);
            owned_body = stripped;
            body = stripped;
        }
    }

    const modules = try core.query.moduleCounts(gpa, paths.items, ctx.chains);
    defer gpa.free(modules);

    const built_at = try nowStamp(gpa, io);
    defer gpa.free(built_at);

    var note: Io.Writer.Allocating = .init(gpa);
    defer note.deinit();
    try emit.writeNote(&note.writer, .{
        .title = in.title,
        .summary = in.summary,
        .project = ctx.namespace[0 .. std.mem.indexOfScalar(u8, ctx.namespace, '@') orelse ctx.namespace.len],
        .branch = ctx.branch,
        .sources = sources,
        .digest = &digest,
        .built_at = built_at,
        .commit = commit,
        .crux = crux_field,
        .grounded = grounded.items,
        .modules = modules,
        .body = body,
        .tail = tail,
    });

    // --- PUT into the vault --------------------------------------------------
    var resolved = (try adapters.store_resolve.resolveStore(gpa, io, env, ctx.vault, ctx.dir, prog, "")) orelse return 1;
    defer resolved.deinit();
    var store = resolved.store();
    const put_result = store.write(io, node_file, note.written()) catch |err| {
        std.debug.print("{s}: write failed: {s}\n", .{ prog, @errorName(err) });
        return 1;
    };
    defer gpa.free(put_result.body);
    if (!put_result.accepted) {
        std.debug.print("{s}: write rejected ({d:0>3}): {s}\n", .{ prog, put_result.status, put_result.body });
        return 1;
    }

    try result.print("{s}\t{d} files\t{s}\n", .{ node_file, paths.items.len, &digest });
    return 0;
}

/// True when the span is unusable, having said why.
fn reportSpanProblem(
    gpa: Allocator,
    span: emit.Span,
    kind: emit.Kind,
    paths: []const []const u8,
    content: ?[]const u8,
) !bool {
    _ = gpa;
    const label = kind.keyword();
    if (content == null) {
        std.debug.print("{s}: {s} path does not exist: {s}\n", .{ prog, label, span.path });
        return true;
    }
    const total = emit.wcLines(content.?);
    const problem = emit.checkSpan(span, kind, paths, total) orelse return false;
    switch (problem) {
        .not_claimed => std.debug.print(
            "{s}: {s} path is not in this node's sources: {s}\n",
            .{ prog, label, span.path },
        ),
        .out_of_range => |t| std.debug.print(
            "{s}: {s} range {d}-{d} outside {s} (1-{d})\n",
            .{ prog, label, span.start, span.end, span.path, t },
        ),
        .too_long => |n| {
            std.debug.print(
                "{s}: {s} range {d}-{d} is {d} lines; keep it under {d}\n",
                .{ prog, label, span.start, span.end, n, kind.cap() },
            );
            if (kind == .crux) std.debug.print(
                "  a crux is the few lines carrying the decision, not the whole function\n",
                .{},
            );
        },
    }
    return true;
}

fn readVault(gpa: Allocator, io: Io, ctx: *const Context, name: []const u8) !?[]u8 {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.abs_dir, name });
    defer gpa.free(path);
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)) catch null;
}

fn readRepoFile(gpa: Allocator, io: Io, ctx: *const Context, rel: []const u8) !?[]u8 {
    const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.repo_root, rel });
    defer gpa.free(full);
    const st = Io.Dir.cwd().statFile(io, full, .{}) catch return null;
    if (st.kind != .file) return null;
    return Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(256 << 20)) catch null;
}

/// `LC_ALL=C sort -u` over the path list.
fn sortedUnique(gpa: Allocator, text: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        try out.append(gpa, line);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var n: usize = 0;
    for (out.items) |p| {
        if (n != 0 and std.mem.eql(u8, out.items[n - 1], p)) continue;
        out.items[n] = p;
        n += 1;
    }
    out.shrinkRetainingCapacity(n);
    return out;
}

/// `git rev-parse --verify --quiet HEAD`. `--verify`, not bare `rev-parse
/// HEAD`: without it, a failure still echoes the literal string "HEAD".
fn headCommit(gpa: Allocator, io: Io, ctx: *const Context) !?[]u8 {
    const res = try adapters.process.run(io, gpa, &.{
        "git", "rev-parse", "--verify", "--quiet", "HEAD",
    }, .{ .cwd = .{ .path = ctx.repo_root } });
    defer res.deinit(gpa);
    if (!res.ok()) return null;
    const sha = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (sha.len == 0) return null;
    return try gpa.dupe(u8, sha);
}

/// Hashes come from the worktree, so a dirty source makes the recorded
/// commit approximate. Scoped to this node's own paths.
fn warnDirtySources(
    gpa: Allocator,
    io: Io,
    ctx: *const Context,
    paths: []const []const u8,
    commit: []const u8,
) !void {
    const res = try adapters.process.run(io, gpa, &.{ "git", "diff", "--name-only", "HEAD" }, .{
        .cwd = .{ .path = ctx.repo_root },
    });
    defer res.deinit(gpa);
    if (!res.ok()) return;

    var named: usize = 0;
    var msg: Io.Writer.Allocating = .init(gpa);
    defer msg.deinit();
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (named == 3) break; // `head -3`
        for (paths) |p| if (std.mem.eql(u8, p, line)) {
            try msg.writer.print("{s} ", .{line});
            named += 1;
            break;
        };
    }
    if (named == 0) return;
    std.debug.print(
        "{s}: NOTE uncommitted changes in this node's sources: {s}\n",
        .{ prog, std.mem.trimEnd(u8, msg.written(), " ") },
    );
    std.debug.print(
        "  commit: {s} records what was checked out, not a faithful drift baseline\n",
        .{commit},
    );
}

/// Persists the tagging this node's sources need anyway, so `query symbol`
/// is a cache read. Never fatal.
fn refreshTagsCache(
    comptime Extractor: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    ctx: *const Context,
    paths: []const []const u8,
    contents: []const []u8,
    trace: ?[]const u8,
) !void {
    const cache_path = try std.fmt.allocPrint(gpa, "{s}/_tags_cache.bin", .{ctx.work_dir});
    defer gpa.free(cache_path);
    var pairs = try gpa.alloc(core.tags_cache.PathHash, paths.len);
    defer gpa.free(pairs);
    for (paths, contents, 0..) |p, c, i|
        pairs[i] = .{ .path = p, .hash = core.verify.blobHashRaw(c) };

    var cache = core.tags_cache.Cache.open(io, cache_path) catch {
        std.debug.print("{s}: tags cache refresh failed (non-fatal)\n", .{prog});
        return;
    };
    defer cache.close(io);
    tags_cache_cmd.backfill(Extractor, gpa, io, env, ctx.repo_root, &cache, pairs, trace) catch
        std.debug.print("{s}: tags cache refresh failed (non-fatal)\n", .{prog});
}

/// `date '+%Y-%m-%d %H:%M'`, spawned for local time -- the timezone
/// database `date` reads has no Zig stdlib equivalent.
fn nowStamp(gpa: Allocator, io: Io) ![]u8 {
    const res = try adapters.process.run(io, gpa, &.{ "date", "+%Y-%m-%d %H:%M" }, .{});
    defer res.deinit(gpa);
    if (!res.ok()) return error.NoDate;
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");
const fake_grammar = @import("fake_grammar.zig");

test "writes frontmatter, a fenced body, and an empty ## Notes section" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Widget core",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nA node.\n\n## Links\n- part_of [[Other]]\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readNode(gpa, "Widget core")).?;
    defer gpa.free(written);

    try testing.expect(std.mem.indexOf(u8, written, "title: \"Widget core\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "node_type: synapse-node\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "project: repo\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "branch: main\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "stale: false\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, core.node.generated_start) != null);
    try testing.expect(std.mem.indexOf(u8, written, core.node.generated_end) != null);

    // ## Notes sits outside the generated region -- what makes "preserved
    // verbatim" enforceable rather than just a promise.
    const end_at = std.mem.indexOf(u8, written, core.node.generated_end).?;
    const notes_at = std.mem.indexOf(u8, written, "## Notes\n").?;
    try testing.expect(notes_at > end_at);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "## Notes\n"));
}

test "a summary containing quotes and backslashes stays valid YAML" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Widget core",
        .summary = "a \"quoted\" path C:\\x",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nA node.\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readNode(gpa, "Widget core")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(
        u8,
        written,
        "summary: \"a \\\"quoted\\\" path C:\\\\x\"\n",
    ) != null);
}

test "body is reproduced verbatim between the fences" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const body = "## Summary\nExact words, unmodified.\n\n## Links\n- uses [[Thing]]\n";
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Verbatim",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = body,
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readNode(gpa, "Verbatim")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, body) != null);
}

test "sources_digest is independent of input order and of duplicate lines" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("a/A.ml", "a\n");
    try fx.writeRepoFile("b/B.ml", "b\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out_a: Io.Writer.Allocating = .init(gpa);
    defer out_a.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Order A",
        .summary = "one line",
        .paths_text = "a/A.ml\nb/B.ml\n",
        .body_text = "## Summary\nx\n",
    }, &out_a.writer);
    const a = (try fx.readNode(gpa, "Order A")).?;
    defer gpa.free(a);

    var out_b: Io.Writer.Allocating = .init(gpa);
    defer out_b.deinit();
    // Reordered, plus a duplicate of one path -- `sortedUnique` must erase
    // both before hashing, so this and the run above agree.
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Order B",
        .summary = "one line",
        .paths_text = "b/B.ml\na/A.ml\nb/B.ml\n",
        .body_text = "## Summary\nx\n",
    }, &out_b.writer);
    const b = (try fx.readNode(gpa, "Order B")).?;
    defer gpa.free(b);

    const digest_a = core.query.field(a, "sources_digest").?;
    const digest_b = core.query.field(b, "sources_digest").?;
    try testing.expectEqualStrings(digest_a, digest_b);
    // The duplicate must not survive into `sources:` either.
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, b, "  - path: b/B.ml\n"),
    );
}

test "a rebuild preserves human-authored ## Notes instead of resetting them" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Kept",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nOriginal.\n",
    }, &out.writer);

    // A human writes under the ## Notes heading the first build created --
    // that text sits outside the generated fence, which the design
    // guarantees is preserved verbatim forever after.
    const first = (try fx.readNode(gpa, "Kept")).?;
    defer gpa.free(first);
    const hand_written = "Hand-written: the timer id is nullable on legacy rows.\n";
    const appended = try std.fmt.allocPrint(gpa, "{s}{s}", .{ first, hand_written });
    defer gpa.free(appended);
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "vault/synapse/repo@main/Kept.md",
        .data = appended,
    });

    out.clearRetainingCapacity();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Kept",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nRewritten body.\n",
    }, &out.writer);

    const second = (try fx.readNode(gpa, "Kept")).?;
    defer gpa.free(second);
    // The generated region is replaced...
    try testing.expect(std.mem.indexOf(u8, second, "Rewritten body.") != null);
    try testing.expect(std.mem.indexOf(u8, second, "Original.") == null);
    // ...and everything after the closing fence survives. A blind PUT here
    // would silently destroy the human's notes, which is the one failure
    // the fencing scheme exists to prevent.
    try testing.expect(std.mem.indexOf(u8, second, hand_written) != null);
    // Exactly one ## Notes heading -- the tail is re-emitted, not appended
    // to a fresh one.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, second, "## Notes\n"));
}

test "writing a node from its own recovered body is idempotent" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    const body = "## Summary\nThe prose.\n\n## Crux\n```ocaml\nlet x = 1\n```\n";
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Roundtrip",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = body,
    }, &out.writer);

    // A reseat recovers the body from the node, drops the regenerated
    // ## Sources block, and writes it back. Doing that repeatedly must not
    // accrete padding, since the fenced region is emitted with blank lines
    // around the body.
    var pass1: ?[]u8 = null;
    defer if (pass1) |p| gpa.free(p);
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const written = (try fx.readNode(gpa, "Roundtrip")).?;
        defer gpa.free(written);
        const start_at = std.mem.indexOf(u8, written, core.node.generated_start).? + core.node.generated_start.len;
        const end_at = std.mem.indexOf(u8, written, core.node.generated_end).?;
        const between = written[start_at..end_at];
        const sources_at = std.mem.indexOf(u8, between, "\n## Sources\n").?;
        const recovered = between[0..sources_at];

        out.clearRetainingCapacity();
        _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
            .title = "Roundtrip",
            .summary = "one line",
            .paths_text = "src/foo.ml\n",
            .body_text = recovered,
        }, &out.writer);

        if (i == 0) {
            const snapshot = (try fx.readNode(gpa, "Roundtrip")).?;
            defer gpa.free(snapshot);
            pass1 = try gpa.dupe(u8, snapshot);
        }
    }
    const pass2 = (try fx.readNode(gpa, "Roundtrip")).?;
    defer gpa.free(pass2);

    // Identical but for `built_at:`, which moves by design.
    const strip = struct {
        fn call(a: Allocator, text: []const u8) ![]u8 {
            var out2: std.ArrayListUnmanaged(u8) = .empty;
            defer out2.deinit(a);
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "built_at:")) continue;
                try out2.appendSlice(a, line);
                try out2.append(a, '\n');
            }
            return out2.toOwnedSlice(a);
        }
    }.call;
    const s1 = try strip(gpa, pass1.?);
    defer gpa.free(s1);
    const s2 = try strip(gpa, pass2);
    defer gpa.free(s2);
    try testing.expectEqualStrings(s1, s2);
}

test "sources lists every path with its real blob hash, not a sample" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("mod-a/src/main/java/com/example/A.java", "class A {}\n");
    try fx.writeRepoFile("mod-a/src/main/java/com/example/B.java", "class B {}\n");
    try fx.writeRepoFile("mod-b/src/main/java/C.java", "class C {}\n");
    try fx.writeRepoFile("docs/guide.md", "# doc\n");
    try fx.writeRepoFile("rootfile.txt", "root\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Wide",
        .summary = "one line",
        .paths_text = "mod-a/src/main/java/com/example/A.java\nmod-a/src/main/java/com/example/B.java\n" ++
            "mod-b/src/main/java/C.java\ndocs/guide.md\nrootfile.txt\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);

    const written = (try fx.readNode(gpa, "Wide")).?;
    defer gpa.free(written);
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, written, "  - path: "));

    for ([_]struct { path: []const u8, data: []const u8 }{
        .{ .path = "mod-a/src/main/java/com/example/A.java", .data = "class A {}\n" },
        .{ .path = "mod-a/src/main/java/com/example/B.java", .data = "class B {}\n" },
        .{ .path = "mod-b/src/main/java/C.java", .data = "class C {}\n" },
        .{ .path = "docs/guide.md", .data = "# doc\n" },
        .{ .path = "rootfile.txt", .data = "root\n" },
    }) |p| {
        const want = core.verify.blobHash(p.data);
        const line = try std.fmt.allocPrint(gpa, "  - path: {s}\n    hash: {s}\n", .{ p.path, want });
        defer gpa.free(line);
        try testing.expect(std.mem.indexOf(u8, written, line) != null);
    }
}

test "sources_digest is wired from the same real sources" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("a.java", "a\n");
    try fx.writeRepoFile("b.java", "b\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Digest",
        .summary = "one line",
        .paths_text = "a.java\nb.java\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);
    // Also echoed on stdout, so a caller can log it without re-reading.
    try testing.expect(std.mem.indexOf(u8, out.written(), "Digest.md\t2 files\t") != null);

    const written = (try fx.readNode(gpa, "Digest")).?;
    defer gpa.free(written);
    const want = try core.node.sourcesDigest(gpa, &.{
        .{ .path = "a.java", .hash = &core.verify.blobHash("a\n") },
        .{ .path = "b.java", .hash = &core.verify.blobHash("b\n") },
    });
    const line = try std.fmt.allocPrint(gpa, "sources_digest: {s}\n", .{&want});
    defer gpa.free(line);
    try testing.expect(std.mem.indexOf(u8, written, line) != null);
}

test "## Sources mirror groups exactly like core.query.moduleCounts" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("mod-a/src/main/java/com/example/A.java", "class A {}\n");
    try fx.writeRepoFile("mod-a/src/main/java/com/example/B.java", "class B {}\n");
    try fx.writeRepoFile("mod-b/src/main/java/C.java", "class C {}\n");
    try fx.writeRepoFile("docs/guide.md", "# doc\n");
    try fx.writeRepoFile("rootfile.txt", "root\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    const paths_text = "mod-a/src/main/java/com/example/A.java\nmod-a/src/main/java/com/example/B.java\n" ++
        "mod-b/src/main/java/C.java\ndocs/guide.md\nrootfile.txt\n";
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Mirror",
        .summary = "one line",
        .paths_text = paths_text,
        .body_text = "## Summary\nx\n",
    }, &out.writer);

    const written = (try fx.readNode(gpa, "Mirror")).?;
    defer gpa.free(written);
    // module = everything before /src/, plus one segment past it (no
    // boilerplate chains configured); else the first path component; else
    // "(repo root)".
    try testing.expect(std.mem.indexOf(u8, written, "- `mod-a/src/main` (2)\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "- `mod-b/src/main` (1)\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "- `docs` (1)\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "- `(repo root)` (1)\n") != null);
}

test "a sanitised title keeps the original in frontmatter, only the filename changes" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Bad — import/export",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);

    try testing.expect(try fx.nodeExists("Bad — import_export"));
    const written = (try fx.readNode(gpa, "Bad — import_export")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "title: \"Bad — import/export\"\n") != null);
}

test "refuses to write when the namespace records a different remote" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("rootfile.txt", "root\n");
    try fx.writeIndex("ssh://git@example.com/y/theirs.git", "main");
    try fx.env.put("SYNAPSE_REMOTE", "ssh://git@example.com/x/mine.git");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Contaminant",
        .summary = "one line",
        .paths_text = "rootfile.txt\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(!try fx.nodeExists("Contaminant"));
}

test "writes when the namespace remote matches" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("rootfile.txt", "root\n");
    try fx.writeIndex("ssh://git@example.com/x/mine.git", "main");
    try fx.env.put("SYNAPSE_REMOTE", "ssh://git@example.com/x/mine.git");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Allowed",
        .summary = "one line",
        .paths_text = "rootfile.txt\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(try fx.nodeExists("Allowed"));
}

test "writes when no Index.md exists yet, since that is a first-time build" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "First",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(try fx.nodeExists("First"));
}

test "a listed path that no longer exists fails loudly instead of writing a short node" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    // src/deleted.ml deliberately not written.

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Missing",
        .summary = "one line",
        .paths_text = "src/foo.ml\nsrc/deleted.ml\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(!try fx.nodeExists("Missing"));
}

test "a directory in the path list fails, the way a submodule gitlink would" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("rootfile.txt", "root\n");
    try fx.writeRepoFile("docs/guide.md", "# doc\n"); // makes "docs" a real directory

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Gitlink",
        .summary = "one line",
        .paths_text = "rootfile.txt\ndocs\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(!try fx.nodeExists("Gitlink"));
}

test "a disk write failure is reported and stores nothing" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.forceWriteFailure("synapse/repo@main/Rejected.md");
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Rejected",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    // Not `nodeExists`: the forced failure left a *directory* at this path,
    // which `access` alone can't tell apart from a real node -- `readNode`
    // actually reads it as a file, `catch null`-ing any error IsDir included.
    try testing.expectEqual(@as(?[]u8, null), try fx.readNode(gpa, "Rejected"));
}

test "records HEAD as the baseline commit, in full" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try fx.gitCommit("init");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Baselined",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readNode(gpa, "Baselined")).?;
    defer gpa.free(written);
    const head = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try testing.expectEqual(@as(usize, 40), head.len);

    const line = try std.fmt.allocPrint(gpa, "commit: {s}\n", .{head});
    defer gpa.free(line);
    try testing.expect(std.mem.indexOf(u8, written, line) != null);
}

test "the commit field is omitted when HEAD does not resolve yet" {
    // Staged, nothing committed: `git rev-parse --verify --quiet HEAD` fails,
    // and the field is left out rather than written empty -- so a later
    // drift check reads a missing baseline the same as an unusable one.
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    (try fx.git(&.{ "init", "-q" })).deinit(fx.gpa);
    (try fx.git(&.{ "add", "-A" })).deinit(fx.gpa);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Uncommitted",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readNode(gpa, "Uncommitted")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "commit:") == null);
    // The rest of the node must still be complete.
    try testing.expect(std.mem.indexOf(u8, written, "sources_digest: ") != null);
}

test "writing a node populates the tags cache for its sources, in the work dir alone" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    _ = fx.env.swapRemove("SYNAPSE_DISABLE_SYMBOL_CACHE");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Widget core",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const cache_path = try std.fmt.allocPrint(gpa, "{s}/_tags_cache.bin", .{ctx.work_dir});
    defer gpa.free(cache_path);
    var cache = try core.tags_cache.Cache.open(fx.io(), cache_path);
    defer cache.close(fx.io());
    try testing.expect(cache.get("src/foo.ml") != null);

    // Derived and disposable -- ~942 MB at scale against a 26 MB reverse
    // index, and the vault is version-controlled, so a copy per rebuild
    // would end up in its history.
    try testing.expectError(
        error.FileNotFound,
        fx.tmp.dir.access(testing.io, "vault/_tags_cache.bin", .{}),
    );
}

test "the tags cache honours SYNAPSE_WORK_DIR" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    _ = fx.env.swapRemove("SYNAPSE_DISABLE_SYMBOL_CACHE");
    const elsewhere = try std.fmt.allocPrint(gpa, "{s}/elsewhere", .{fx.root});
    defer gpa.free(elsewhere);
    try fx.tmp.dir.createDirPath(testing.io, "elsewhere");
    try fx.env.put("SYNAPSE_WORK_DIR", elsewhere);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();
    try testing.expectEqualStrings(elsewhere, ctx.work_dir);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Widget core",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const cache_path = try std.fmt.allocPrint(gpa, "{s}/_tags_cache.bin", .{elsewhere});
    defer gpa.free(cache_path);
    var cache = try core.tags_cache.Cache.open(fx.io(), cache_path);
    defer cache.close(fx.io());
    try testing.expect(cache.get("src/foo.ml") != null);
    try testing.expectError(
        error.FileNotFound,
        fx.tmp.dir.access(testing.io, "work/_tags_cache.bin", .{}),
    );
}

test "rewriting a node with an unchanged source re-tags nothing" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    _ = fx.env.swapRemove("SYNAPSE_DISABLE_SYMBOL_CACHE");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    const trace1 = try std.fmt.allocPrint(gpa, "{s}/trace1.log", .{fx.root});
    defer gpa.free(trace1);
    var out1: Io.Writer.Allocating = .init(gpa);
    defer out1.deinit();
    try testing.expectEqual(@as(u8, 0), try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Widget core",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nx\n",
        .trace = trace1,
    }, &out1.writer));
    const t1 = try fx.tmp.dir.readFileAlloc(testing.io, "trace1.log", gpa, .limited(1 << 20));
    defer gpa.free(t1);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, t1, "path "));

    const trace2 = try std.fmt.allocPrint(gpa, "{s}/trace2.log", .{fx.root});
    defer gpa.free(trace2);
    var out2: Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    try testing.expectEqual(@as(u8, 0), try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Widget core",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nx\n",
        .trace = trace2,
    }, &out2.writer));
    try testing.expectEqual(
        error.FileNotFound,
        fx.tmp.dir.access(testing.io, "trace2.log", .{}),
    );
}

test "disabled via env var: node write still succeeds, no cache file created" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    // `Fixture.init` already sets this by default; asserted explicitly here
    // so a future change to that default doesn't silently drop the case.
    try testing.expect(fx.env.get("SYNAPSE_DISABLE_SYMBOL_CACHE") != null);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Widget core",
        .summary = "one line",
        .paths_text = "src/foo.ml\n",
        .body_text = "## Summary\nx\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    try testing.expectError(
        error.FileNotFound,
        fx.tmp.dir.access(testing.io, "work/_tags_cache.bin", .{}),
    );
}

/// "let lineNN = N\n" for N in `from..=to` -- the crux/grounded_in fixture
/// file's own shape, real enough for a directive to slice.
fn calcMl(gpa: Allocator, from: u32, to: u32) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var n = from;
    while (n <= to) : (n += 1) try out.writer.print("let line{d:0>2} = {d}\n", .{ n, n });
    return gpa.dupe(u8, out.written());
}

fn cruxFixture(gpa: Allocator, fx: *fixture.Fixture) !void {
    const calc = try calcMl(gpa, 1, 30);
    defer gpa.free(calc);
    try fx.writeRepoFile("lib/calc.ml", calc);
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
}

const crux_paths_text = "src/foo.ml\nlib/calc.ml\n";

test "crux: the pointed-at lines are sliced from the file, verbatim" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try cruxFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Sliced",
        .summary = "one line",
        .paths_text = crux_paths_text,
        .body_text = "## Summary\nA node.\n\n## Crux\n<!-- crux: lib/calc.ml 5-7 -->\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readNode(gpa, "Sliced")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "let line05 = 5") != null);
    try testing.expect(std.mem.indexOf(u8, written, "let line07 = 7") != null);
    try testing.expect(std.mem.indexOf(u8, written, "let line04 = 4") == null);
    try testing.expect(std.mem.indexOf(u8, written, "let line08 = 8") == null);
    try testing.expect(std.mem.indexOf(u8, written, "```ocaml") != null);
    try testing.expect(std.mem.indexOf(u8, written, "lib/calc.ml`:5-7") != null);
    try testing.expect(std.mem.indexOf(u8, written, "<!-- crux:") == null);
}

test "crux: the pointer is recorded in frontmatter, not just the sliced text" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try cruxFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Recorded",
        .summary = "one line",
        .paths_text = crux_paths_text,
        .body_text = "## Summary\nA node.\n\n## Crux\n<!-- crux: lib/calc.ml L11-L13 -->\n",
    }, &out.writer);

    const written = (try fx.readNode(gpa, "Recorded")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "crux_path: lib/calc.ml\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "crux_lines: \"11-13\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "let line11 = 11") != null);
}

test "crux: a directive quoted as a prose example elsewhere is not mistaken for the real one" {
    // The original bug report: a node describing directive syntax itself
    // quotes the literal <!-- crux: ... --> form as an example inside
    // ## Summary. Before this was scoped to ## Crux, that quoted example
    // was found first and its bogus path/range refused the whole write.
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try cruxFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "QuotedExample",
        .summary = "one line",
        .paths_text = crux_paths_text,
        .body_text = "## Summary\nA crux directive looks like `<!-- crux: path/to/file.ext 1-99999 -->` in prose.\n\n" ++
            "## Crux\n<!-- crux: lib/calc.ml 5-7 -->\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readNode(gpa, "QuotedExample")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "let line05 = 5") != null);
    try testing.expect(std.mem.indexOf(u8, written, "lib/calc.ml`:5-7") != null);
}

test "crux: 'none' is an honest answer, not a missing field" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try cruxFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "NoCrux",
        .summary = "one line",
        .paths_text = crux_paths_text,
        .body_text = "## Summary\nA node.\n\n## Crux\n<!-- crux: none -->\n",
    }, &out.writer);

    const written = (try fx.readNode(gpa, "NoCrux")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "No single span carries") != null);
    try testing.expect(std.mem.indexOf(u8, written, "crux_path:") == null);
    try testing.expect(std.mem.indexOf(u8, written, "<!-- crux:") == null);
}

test "crux: a path the node does not claim is refused" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try cruxFixture(gpa, &fx);
    try fx.writeRepoFile("lib/other.ml", "let z = 1\n"); // real, but not in paths_text

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Foreign",
        .summary = "one line",
        .paths_text = crux_paths_text,
        .body_text = "## Summary\nA node.\n\n## Crux\n<!-- crux: lib/other.ml 1-1 -->\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(!try fx.nodeExists("Foreign"));
}

test "crux: a range past the end of the file is refused, not clamped" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try cruxFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Overrun",
        .summary = "one line",
        .paths_text = crux_paths_text,
        .body_text = "## Summary\nA node.\n\n## Crux\n<!-- crux: lib/calc.ml 28-40 -->\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(!try fx.nodeExists("Overrun"));
}

test "crux: a range longer than ~20 lines is refused" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try cruxFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "TooBig",
        .summary = "one line",
        .paths_text = crux_paths_text,
        .body_text = "## Summary\nA node.\n\n## Crux\n<!-- crux: lib/calc.ml 1-25 -->\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(!try fx.nodeExists("TooBig"));
}

test "crux: a malformed directive is refused rather than silently ignored" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try cruxFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Malformed",
        .summary = "one line",
        .paths_text = crux_paths_text,
        .body_text = "## Summary\nA node.\n\n## Crux\n<!-- crux: lib/calc.ml -->\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(!try fx.nodeExists("Malformed"));
}

test "crux: a body with no directive is written unchanged" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try cruxFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Plain",
        .summary = "one line",
        .paths_text = crux_paths_text,
        .body_text = "## Summary\nA node.\n\n## Links\n- part_of [[Other]]\n",
    }, &out.writer);

    const written = (try fx.readNode(gpa, "Plain")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "crux_path:") == null);
    try testing.expect(std.mem.indexOf(u8, written, "part_of [[Other]]") != null);
}

test "crux: re-pointing after the file changed re-slices, rather than keeping the old quote" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try cruxFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    const body = "## Summary\nA node.\n\n## Crux\n<!-- crux: lib/calc.ml 5-6 -->\n";
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Repointed",
        .summary = "one line",
        .paths_text = crux_paths_text,
        .body_text = body,
    }, &out.writer);
    const first = (try fx.readNode(gpa, "Repointed")).?;
    defer gpa.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "let line05 = 5") != null);

    // The file changes under the node: line 5 now says something else,
    // everything else unchanged (a whole-file rewrite would also change
    // line 6, which the assertions below don't distinguish from a real
    // re-slice).
    const before_5 = try calcMl(gpa, 1, 4);
    defer gpa.free(before_5);
    const after_5 = try calcMl(gpa, 6, 30);
    defer gpa.free(after_5);
    const changed = try std.fmt.allocPrint(
        gpa,
        "{s}let line999 = 999 (* CHANGED *)\n{s}",
        .{ before_5, after_5 },
    );
    defer gpa.free(changed);
    try fx.writeRepoFile("lib/calc.ml", changed);

    // Writing the SAME directive back must reflect the new content, which is
    // the whole point of storing a pointer: a rebuild re-cuts instead of
    // carrying a stale quote.
    out.clearRetainingCapacity();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Repointed",
        .summary = "one line",
        .paths_text = crux_paths_text,
        .body_text = body,
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const second = (try fx.readNode(gpa, "Repointed")).?;
    defer gpa.free(second);
    try testing.expect(std.mem.indexOf(u8, second, "let line999 = 999 (* CHANGED *)") != null);
    try testing.expect(std.mem.indexOf(u8, second, "let line05 = 5\n") == null);
}

// --- grounded_in: the evidence a summary rests on ---------------------------

fn groundedFixture(gpa: Allocator, fx: *fixture.Fixture) !void {
    const header = "(* Computes the premium for a contract.\n   Rounds half-up at two decimals. *)\n";
    const body_lines = try calcMl(gpa, 3, 20);
    defer gpa.free(body_lines);
    const calc = try std.fmt.allocPrint(gpa, "{s}{s}", .{ header, body_lines });
    defer gpa.free(calc);
    try fx.writeRepoFile("lib/calc.ml", calc);
    try fx.writeRepoFile(
        "test/calc_test.ml",
        "let test_rounds_half_up () = assert (round 1.005 = 1.01)\n" ++
            "let test_rejects_negative () = assert_raises Invalid_argument\n",
    );
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
}

const grounded_paths_text = "src/foo.ml\nlib/calc.ml\ntest/calc_test.ml\n";

/// sha256 of a `from..=to` line range -- the same formula `write()` itself
/// uses (`emit.zig`'s grounded digest), reused here to check the *wiring*
/// (the right slice reaches it), not to re-derive the digest algorithm
/// itself, which `core.verify`'s own tests already cover independently.
fn sliceDigest(gpa: Allocator, content: []const u8, from: u32, to: u32) ![64]u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var n: u32 = 1;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    while (lines.next()) |line| : (n += 1) {
        if (n < from) continue;
        if (n > to) break;
        try out.writer.print("{s}\n", .{line});
    }
    return core.verify.sha256Hex(out.written());
}

test "grounded_in: records path, lines and a digest of the slice" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try groundedFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Grounded",
        .summary = "one line",
        .paths_text = grounded_paths_text,
        .body_text = "## Summary\nRounds half-up.\n<!-- grounded_in: lib/calc.ml 1-2 -->\n",
    }, &out.writer);

    const written = (try fx.readNode(gpa, "Grounded")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "grounded_in:\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "  - path: lib/calc.ml\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "    lines: \"1-2\"\n") != null);

    const header = "(* Computes the premium for a contract.\n   Rounds half-up at two decimals. *)\n";
    const digest = try sliceDigest(gpa, header, 1, 2);
    const line = try std.fmt.allocPrint(gpa, "    digest: {s}\n", .{&digest});
    defer gpa.free(line);
    try testing.expect(std.mem.indexOf(u8, written, line) != null);
}

test "grounded_in: multiple groundings are all recorded" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try groundedFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Multi",
        .summary = "one line",
        .paths_text = grounded_paths_text,
        .body_text = "## Summary\nRounds half-up, rejects negatives.\n" ++
            "<!-- grounded_in: lib/calc.ml 1-2 -->\n" ++
            "<!-- grounded_in: test/calc_test.ml 1-1 -->\n" ++
            "<!-- grounded_in: test/calc_test.ml 2-2 -->\n",
    }, &out.writer);

    const written = (try fx.readNode(gpa, "Multi")).?;
    defer gpa.free(written);
    // Count `lines:`, not `- path:` -- both `sources` and `grounded_in` are
    // lists of `- path:` entries, so counting those conflates the two
    // blocks; `lines:` is emitted only by grounded_in.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, written, "    lines: "));
    try testing.expect(std.mem.indexOf(u8, written, "    lines: \"2-2\"\n") != null);
}

test "grounded_in: directives are stripped from the body, not rendered" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try groundedFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Stripped",
        .summary = "one line",
        .paths_text = grounded_paths_text,
        .body_text = "## Summary\nRounds half-up.\n<!-- grounded_in: lib/calc.ml 1-2 -->\n",
    }, &out.writer);

    const written = (try fx.readNode(gpa, "Stripped")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "<!-- grounded_in:") == null);
    // The prose survives, and the grounding's own text is NOT pasted in.
    try testing.expect(std.mem.indexOf(u8, written, "Rounds half-up.") != null);
    try testing.expect(std.mem.indexOf(u8, written, "Computes the premium for a contract") == null);
}

test "grounded_in: a digest over the slice, not the whole file" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try groundedFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    const body = "## Summary\nRounds half-up.\n<!-- grounded_in: lib/calc.ml 1-2 -->\n";
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "SliceOnly",
        .summary = "one line",
        .paths_text = grounded_paths_text,
        .body_text = body,
    }, &out.writer);
    const before = (try fx.readNode(gpa, "SliceOnly")).?;
    defer gpa.free(before);
    const digest_at = std.mem.indexOf(u8, before, "    digest: ").?;
    const before_digest = try gpa.dupe(u8, before[digest_at .. digest_at + "    digest: ".len + 64]);
    defer gpa.free(before_digest);

    // Change the file well away from the grounded range.
    const header = "(* Computes the premium for a contract.\n   Rounds half-up at two decimals. *)\n";
    const body_lines = try calcMl(gpa, 3, 20);
    defer gpa.free(body_lines);
    const changed = try std.fmt.allocPrint(gpa, "{s}{s}let tail = 99\n", .{ header, body_lines });
    defer gpa.free(changed);
    try fx.writeRepoFile("lib/calc.ml", changed);

    out.clearRetainingCapacity();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "SliceOnly",
        .summary = "one line",
        .paths_text = grounded_paths_text,
        .body_text = body,
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const after = (try fx.readNode(gpa, "SliceOnly")).?;
    defer gpa.free(after);
    const after_at = std.mem.indexOf(u8, after, "    digest: ").?;
    const after_digest = after[after_at .. after_at + "    digest: ".len + 64];
    // The whole-file hash in `sources` moved; the grounding digest must not.
    try testing.expectEqualStrings(before_digest, after_digest);
}

test "grounded_in: a path outside the node's sources is refused" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try groundedFixture(gpa, &fx);
    try fx.writeRepoFile("lib/other.ml", "let z = 1\n");

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Foreign2",
        .summary = "one line",
        .paths_text = grounded_paths_text,
        .body_text = "## Summary\nX.\n<!-- grounded_in: lib/other.ml 1-1 -->\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(!try fx.nodeExists("Foreign2"));
}

test "grounded_in: a bad range or malformed directive is refused" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try groundedFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const bad_range = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "BadRange",
        .summary = "one line",
        .paths_text = grounded_paths_text,
        .body_text = "## Summary\nX.\n<!-- grounded_in: lib/calc.ml 900-901 -->\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), bad_range);

    out.clearRetainingCapacity();
    const bad_form = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "BadForm",
        .summary = "one line",
        .paths_text = grounded_paths_text,
        .body_text = "## Summary\nX.\n<!-- grounded_in: lib/calc.ml -->\n",
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), bad_form);
}

test "grounded_in: absent means no field, not an empty one" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try groundedFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Ungrounded",
        .summary = "one line",
        .paths_text = grounded_paths_text,
        .body_text = "## Summary\nUngrounded prose.\n",
    }, &out.writer);

    const written = (try fx.readNode(gpa, "Ungrounded")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "grounded_in:") == null);
}

test "grounded_in: coexists with a crux directive" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try groundedFixture(gpa, &fx);

    var ctx = try fx.resolveContext();
    defer ctx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try write(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, .{
        .title = "Both",
        .summary = "one line",
        .paths_text = grounded_paths_text,
        .body_text = "## Summary\nRounds half-up.\n<!-- grounded_in: lib/calc.ml 1-2 -->\n\n" ++
            "## Crux\n<!-- crux: lib/calc.ml 5-6 -->\n",
    }, &out.writer);

    const written = (try fx.readNode(gpa, "Both")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "crux_path: lib/calc.ml\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "  - path: lib/calc.ml\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "let line05 = 5") != null); // crux sliced and rendered
    try testing.expect(std.mem.indexOf(u8, written, "Computes the premium") == null); // grounding not rendered
}
