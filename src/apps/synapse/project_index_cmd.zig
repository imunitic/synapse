//! `synapse build-project-index` -- `claude/lib/synapse/synapse-build-project-index.sh`.
//!
//! Builds and uploads `synapse/{repo}@{branch}/Index.md`, the per-namespace node map
//! carrying the `remote` field the SessionStart hook verifies before injecting a
//! pointer. Step 4, and last, of a scripted `/synapse-init`.
//!
//! Built *from* the nodes on disk, not from anything the build kept: a
//! missing node or a missing `summary` field is a hard error with different
//! advice for each. Reading from disk also removes the last `curl` read
//! outside the hooks; the PUT stays on the API like every other write.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = context.Context;

const prog = "synapse-build-project-index";

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: synapse build-project-index\n", .{});
            return 0;
        }
        std.debug.print("usage: synapse build-project-index\n", .{});
        return 2;
    }

    var ctx = (try context.resolve(gpa, io, env, prog)) orelse return 1;
    defer ctx.deinit();

    const lists = try std.fmt.allocPrint(gpa, "{s}/lists", .{ctx.work_dir});
    defer gpa.free(lists);

    var names = try listTitles(gpa, io, lists);
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    if (names.items.len == 0) {
        std.debug.print("{s}: no lists/NN.title in {s}\n", .{ prog, ctx.work_dir });
        return 1;
    }

    var bullets: std.ArrayListUnmanaged(core.project_index.Bullet) = .empty;
    defer bullets.deinit(gpa);
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |b| gpa.free(b);
        owned.deinit(gpa);
    }

    const cwd = Io.Dir.cwd();
    for (names.items) |nn| {
        const title_path = try std.fmt.allocPrint(gpa, "{s}/{s}.title", .{ lists, nn });
        defer gpa.free(title_path);
        const raw_title = cwd.readFileAlloc(io, title_path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(raw_title);
        const link = try core.emit.fileTitle(gpa, std.mem.trimEnd(u8, raw_title, "\n"));
        try owned.append(gpa, link);

        const list_path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ lists, nn });
        defer gpa.free(list_path);
        const list = cwd.readFileAlloc(io, list_path, gpa, .limited(256 << 20)) catch "";
        defer if (list.len != 0) gpa.free(list);
        const files = std.mem.count(u8, list, "\n"); // `wc -l`: one path per line

        const node_text = try context.readNode(&ctx, io, link);
        defer if (node_text) |t| gpa.free(t);
        if (node_text == null) {
            std.debug.print("{s}: node not in the vault: {s}.md\n", .{ prog, link });
            std.debug.print("  the index is built from the nodes, so write them first\n", .{});
            return 1;
        }
        // `scalar`, not `field`: unescaped, since the summary goes into prose.
        const clean = (try core.query.scalar(gpa, node_text.?, "summary")) orelse
            try gpa.dupe(u8, "");
        if (clean.len == 0) {
            gpa.free(clean);
            std.debug.print("{s}: no summary field on {s}.md\n", .{ prog, link });
            return 1;
        }
        for (clean) |*c| if (c.* == '\t') { // tabs squashed to spaces
            c.* = ' ';
        };
        try owned.append(gpa, clean);

        try bullets.append(gpa, .{ .link = link, .files = files, .summary = clean });
    }

    std.mem.sort(core.project_index.Bullet, bullets.items, {}, struct {
        fn less(_: void, a: core.project_index.Bullet, b: core.project_index.Bullet) bool {
            return std.mem.order(u8, a.link, b.link) == .lt;
        }
    }.less);

    const total_files = try totalFiles(gpa, io, &ctx, lists);

    const built_at = try nowStamp(gpa, io);
    defer gpa.free(built_at);

    var index: Io.Writer.Allocating = .init(gpa);
    defer index.deinit();
    try core.project_index.write(&index.writer, .{
        .namespace = ctx.namespace,
        .project = ctx.namespace[0 .. std.mem.indexOfScalar(u8, ctx.namespace, '@') orelse ctx.namespace.len],
        .branch = ctx.branch,
        .remote = ctx.remote,
        .built_at = built_at,
        .total_files = total_files,
        .bullets = bullets.items,
    });

    var store = (try openStore(gpa, io, env, &ctx)) orelse return 1;
    defer store.deinit();
    const put = store.put(io, "Index.md", index.written()) catch {
        std.debug.print("{s}: PUT failed (000): curl did not complete\n", .{prog});
        return 1;
    };
    defer gpa.free(put.body);
    if (!put.accepted()) {
        std.debug.print("{s}: PUT failed ({d:0>3}): {s}\n", .{ prog, put.status, put.body });
        return 1;
    }

    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    try out.interface.print("Index.md written: {d} nodes, {d} tracked files, remote={s}\n", .{
        bullets.items.len,
        total_files,
        ctx.remote,
    });
    try out.interface.flush();
    return 0;
}

/// `find "$LISTS" -name '*.title' | LC_ALL=C sort`, yielding the `NN`.
fn listTitles(gpa: Allocator, io: Io, lists: []const u8) !std.ArrayListUnmanaged([]u8) {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    var dir = Io.Dir.cwd().openDir(io, lists, .{ .iterate = true }) catch return out;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".title")) continue;
        try out.append(gpa, try gpa.dupe(u8, entry.name[0 .. entry.name.len - ".title".len]));
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return out;
}

/// `all.txt`'s line count, or the distinct union of the lists when absent --
/// the lists only cover what a node claimed, so the union is the honest
/// fallback rather than zero.
fn totalFiles(gpa: Allocator, io: Io, ctx: *const Context, lists: []const u8) !usize {
    const all_path = try std.fmt.allocPrint(gpa, "{s}/all.txt", .{ctx.work_dir});
    defer gpa.free(all_path);
    if (Io.Dir.cwd().readFileAlloc(io, all_path, gpa, .limited(256 << 20))) |all| {
        defer gpa.free(all);
        if (all.len != 0) return std.mem.count(u8, all, "\n");
    } else |_| {}

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var texts: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }
    var dir = Io.Dir.cwd().openDir(io, lists, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ lists, entry.name });
        defer gpa.free(p);
        const text = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(256 << 20)) catch continue;
        try texts.append(gpa, text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try seen.put(gpa, line, {});
        }
    }
    return seen.count();
}

/// `date '+%Y-%m-%d %H:%M'`, spawned -- see `write_node_cmd.nowStamp`.
fn nowStamp(gpa: Allocator, io: Io) ![]u8 {
    const res = try adapters.process.run(io, gpa, &.{ "date", "+%Y-%m-%d %H:%M" }, .{});
    defer res.deinit(gpa);
    if (!res.ok()) return error.NoDate;
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

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
        else => return null,
    };
    const api_key = switch (obj.get("apiKey") orelse .null) {
        .string => |s| s,
        else => "",
    };
    const port: u16 = switch (obj.get("port") orelse .null) {
        .integer => |i| @intCast(i),
        .string => |s| std.fmt.parseInt(u16, s, 10) catch 0,
        else => 0,
    };
    if (api_key.len == 0 or port == 0) {
        std.debug.print("{s}: no API key/port\n", .{prog});
        return null;
    }
    const cert = try std.fmt.allocPrint(gpa, "{s}/.claude/obsidian-local-rest-api-ca.pem", .{
        env.get("HOME") orelse "",
    });
    defer gpa.free(cert);
    return try adapters.obsidian.ObsidianStore.init(gpa, port, cert, api_key, ctx.dir);
}
