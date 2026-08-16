//! `synapse write-node` -- `claude/lib/synapse/synapse-write-node.sh`.
//!
//!   write-node --title <t> --summary <s> --paths <file> --body <file>
//!
//! Hashes every source, computes `sources_digest`, records the baseline
//! `commit`, expands the crux directive, records and strips the groundings,
//! builds the `## Sources` mirror, and PUTs the note through the Obsidian
//! Local REST API.
//!
//! Prints `<file>\t<n> files\t<digest>` on success. Exit 1 for anything
//! that made the write impossible, 2 for a usage error.
//!
//! Writes go through the API so Obsidian's own view stays consistent and
//! the vault's git hook sees the change; the three reads the script made
//! through the same API are disk reads now (see `context.zig`).
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
        try refreshTagsCache(Extractor, gpa, io, env, ctx, paths.items, contents);

    // --- crux and groundings -------------------------------------------------
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
            try emit.writeCruxBlock(&block.writer, span, cut);
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
                .path = span.path,
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
    var store = (try openStore(gpa, io, env, ctx)) orelse return 1;
    defer store.deinit();
    const put = store.put(io, node_file, note.written()) catch {
        std.debug.print("{s}: PUT failed (000): curl did not complete\n", .{prog});
        return 1;
    };
    defer gpa.free(put.body);
    if (!put.accepted()) {
        std.debug.print("{s}: PUT failed ({d:0>3}): {s}\n", .{ prog, put.status, put.body });
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
    tags_cache_cmd.backfill(Extractor, gpa, io, env, ctx.repo_root, &cache, pairs, null) catch
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

/// The plugin's port and API key, from the vault's own `data.json` -- read
/// here rather than passed in `argv`, which stays visible to `ps`.
fn openStore(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    ctx: *const Context,
) !?adapters.obsidian.ObsidianStore {
    const plugin_path = try std.fmt.allocPrint(
        gpa,
        "{s}/.obsidian/plugins/obsidian-local-rest-api/data.json",
        .{ctx.vault},
    );
    defer gpa.free(plugin_path);
    const text = Io.Dir.cwd().readFileAlloc(io, plugin_path, gpa, .limited(1 << 20)) catch {
        std.debug.print("{s}: REST API not configured\n", .{prog});
        return null;
    };
    defer gpa.free(text);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch {
        std.debug.print("{s}: no API key/port\n", .{prog});
        return null;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: no API key/port\n", .{prog});
            return null;
        },
    };
    const api_key = switch (obj.get("apiKey") orelse .null) {
        .string => |s| s,
        else => "",
    };
    const port: u16 = switch (obj.get("port") orelse .null) { // plugin writes a number; hand-edited may be a string
        .integer => |i| @intCast(i),
        .string => |s| std.fmt.parseInt(u16, s, 10) catch 0,
        else => 0,
    };
    if (api_key.len == 0 or port == 0) {
        std.debug.print("{s}: no API key/port\n", .{prog});
        return null;
    }

    const cert = try certPath(gpa, env);
    defer gpa.free(cert);
    return try adapters.obsidian.ObsidianStore.init(gpa, port, cert, api_key, ctx.dir);
}

/// `~/.claude/obsidian-local-rest-api-ca.pem`, the plugin's own CA.
fn certPath(gpa: Allocator, env: *std.process.Environ.Map) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/.claude/obsidian-local-rest-api-ca.pem", .{
        env.get("HOME") orelse "",
    });
}
