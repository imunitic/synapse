//! `synapse frontmatter-set` -- a byte-preserving, single-key frontmatter
//! write to one vault note. Replaces `vault_patch`'s `frontmatter` target,
//! which re-serializes the whole YAML block and can turn an array value
//! into a quoted string instead of a real list -- see `core/frontmatter.zig`
//! for the primitive this command is a thin CLI wrapper over.
//!
//!   frontmatter-set <path> <key> <value>
//!   frontmatter-set <path> --add-tag <tag>
//!   frontmatter-set <path> --remove-tag <tag>
//!
//! `<path>` is the note's full vault-relative path (e.g.
//! `tasks/synapse/sb-037 — Foo.md`), not scoped to any one repo's code-graph
//! namespace -- the store this command opens carries an empty namespace for
//! exactly that reason (see `ObsidianStore.namespace`'s doc comment).
//!
//! `<value>` with no comma sets a scalar field; a comma-separated value sets
//! an array (`tags: [a, b]`), never a quoted string. `--add-tag`/
//! `--remove-tag` are the `tags`-specific alternative, mutually exclusive
//! with `<key> <value>`.
//!
//! Prints `<path>\t<key>\n` on success. Exit 1 for anything that made the
//! write impossible (no such note, an unreachable vault, no frontmatter at
//! all), 2 for a usage error.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-frontmatter-set";

const usage_text =
    \\usage: synapse frontmatter-set <path> <key> <value>
    \\       synapse frontmatter-set <path> --add-tag <tag>
    \\       synapse frontmatter-set <path> --remove-tag <tag>
    \\
    \\  <path>   the note's full vault-relative path, e.g. tasks/proj/foo.md
    \\  <value>  bare sets a scalar field; comma-separated sets an array
    \\
;

fn usage() u8 {
    std.debug.print("{s}", .{usage_text});
    return 2;
}

const Op = union(enum) {
    set: struct { key: []const u8, value: []const u8 },
    add_tag: []const u8,
    remove_tag: []const u8,
};

const Parsed = struct {
    path: []const u8,
    op: Op,
};

/// Pure over an already-collected argv slice, so the mutual-exclusivity and
/// missing-argument cases are testable without a real `Args.Iterator`. Null
/// means "print usage and exit 2" -- every rejection reads the same way to
/// the caller, since none of them can be acted on differently.
fn parseArgs(argv: []const []const u8) ?Parsed {
    var positional: [3][]const u8 = undefined;
    var n_pos: usize = 0;
    var tag_flag: ?enum { add, remove } = null;
    var tag: []const u8 = "";

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--add-tag") or std.mem.eql(u8, arg, "--remove-tag")) {
            if (tag_flag != null) return null; // repeated flag
            tag_flag = if (std.mem.eql(u8, arg, "--add-tag")) .add else .remove;
            i += 1;
            if (i >= argv.len) return null;
            tag = argv[i];
            continue;
        }
        if (n_pos >= positional.len) return null; // too many positionals
        positional[n_pos] = arg;
        n_pos += 1;
    }

    if (n_pos == 0) return null;
    const path = positional[0];

    if (tag_flag) |f| {
        // A tag flag alongside <key> <value> is the mutual-exclusivity case:
        // only <path> may accompany it.
        if (n_pos != 1) return null;
        return .{ .path = path, .op = switch (f) {
            .add => .{ .add_tag = tag },
            .remove => .{ .remove_tag = tag },
        } };
    }
    if (n_pos != 3) return null;
    return .{ .path = path, .op = .{ .set = .{ .key = positional[1], .value = positional[2] } } };
}

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        }
        try argv.append(gpa, arg);
    }
    const parsed = parseArgs(argv.items) orelse return usage();

    const vault = (try core.conf.vaultDir(gpa, io, adapters.env.vars(env))) orelse {
        std.debug.print("{s}: no vault\n", .{prog});
        return 1;
    };
    defer gpa.free(vault);

    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try write(gpa, io, env, vault, parsed.path, parsed.op, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn write(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    path: []const u8,
    op: Op,
    result: *Io.Writer,
) !u8 {
    var os_store = (try openStore(gpa, io, env, vault)) orelse return 1;
    defer os_store.deinit();
    var store = os_store.store();

    const current = (store.read(gpa, io, path) catch {
        std.debug.print("{s}: GET failed: curl did not complete\n", .{prog});
        return 1;
    }) orelse {
        std.debug.print("{s}: no such note: {s}\n", .{ prog, path });
        return 1;
    };
    defer gpa.free(current);

    var owned_list: ?[]const []const u8 = null;
    defer if (owned_list) |l| gpa.free(l);

    const label: []const u8 = switch (op) {
        .set => |kv| kv.key,
        .add_tag, .remove_tag => "tags",
    };

    const updated = (switch (op) {
        .set => |kv| blk: {
            const value: core.frontmatter.Value = if (std.mem.indexOfScalar(u8, kv.value, ',') == null)
                .{ .scalar = kv.value }
            else v: {
                var items: std.ArrayListUnmanaged([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, kv.value, ',');
                while (it.next()) |part| try items.append(gpa, std.mem.trim(u8, part, " \t"));
                owned_list = try items.toOwnedSlice(gpa);
                break :v .{ .list = owned_list.? };
            };
            break :blk core.frontmatter.set(gpa, current, kv.key, value);
        },
        .add_tag => |t| core.frontmatter.addTag(gpa, current, t),
        .remove_tag => |t| core.frontmatter.removeTag(gpa, current, t),
    }) catch |e| {
        if (e == error.NoFrontmatter) {
            std.debug.print("{s}: no frontmatter in {s}\n", .{ prog, path });
            return 1;
        }
        return e;
    };
    defer gpa.free(updated);

    const put_result = store.write(io, path, updated) catch {
        std.debug.print("{s}: PUT failed (000): curl did not complete\n", .{prog});
        return 1;
    };
    defer gpa.free(put_result.body);
    if (!put_result.accepted) {
        std.debug.print("{s}: PUT failed ({d:0>3}): {s}\n", .{ prog, put_result.status, put_result.body });
        return 1;
    }

    try result.print("{s}\t{s}\n", .{ path, label });
    return 0;
}

/// The plugin's port and API key, from the vault's own `data.json` -- same
/// resolution `write_node_cmd`'s own `openStore` uses, but with an empty
/// namespace: this command addresses any note in the vault by its full
/// vault-relative path, not one repo's code-graph directory.
fn openStore(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
) !?adapters.obsidian.ObsidianStore {
    const plugin_path = try std.fmt.allocPrint(
        gpa,
        "{s}/.obsidian/plugins/obsidian-local-rest-api/data.json",
        .{vault},
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
    return try adapters.obsidian.ObsidianStore.init(gpa, port, cert, api_key, "");
}

/// `~/.claude/obsidian-local-rest-api-ca.pem`, the plugin's own CA.
fn certPath(gpa: Allocator, env: *std.process.Environ.Map) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/.claude/obsidian-local-rest-api-ca.pem", .{
        env.get("HOME") orelse "",
    });
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

test "parseArgs: a bare key/value sets a scalar" {
    const got = parseArgs(&.{ "tasks/x.md", "status", "DONE" }).?;
    try testing.expectEqualStrings("tasks/x.md", got.path);
    try testing.expectEqualStrings("status", got.op.set.key);
    try testing.expectEqualStrings("DONE", got.op.set.value);
}

test "parseArgs: --add-tag and --remove-tag parse to their own op" {
    const add = parseArgs(&.{ "tasks/x.md", "--add-tag", "zig" }).?;
    try testing.expectEqualStrings("zig", add.op.add_tag);

    const remove = parseArgs(&.{ "tasks/x.md", "--remove-tag", "zig" }).?;
    try testing.expectEqualStrings("zig", remove.op.remove_tag);
}

test "parseArgs: <key> <value> together with --add-tag is a usage error" {
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{ "tasks/x.md", "status", "DONE", "--add-tag", "zig" }));
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{ "tasks/x.md", "--add-tag", "zig", "status", "DONE" }));
}

test "parseArgs: missing pieces are all usage errors" {
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{}));
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{"tasks/x.md"}));
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{ "tasks/x.md", "status" }));
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{ "tasks/x.md", "--add-tag" }));
}

test "sets a scalar field on a note addressed by its full vault path" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/x.md", "---\ntitle: \"X\"\nstatus: TODO\n---\nbody\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{
        .set = .{ .key = "status", .value = "IN-PROGRESS" },
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("tasks/synapse/x.md\tstatus\n", out.written());

    const written = (try fx.readVaultFile(gpa, "tasks/synapse/x.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "status: IN-PROGRESS\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "title: \"X\"\n") != null);
}

test "a comma-separated value sets a real array, never a quoted string" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/x.md", "---\ntitle: \"X\"\n---\nbody\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{
        .set = .{ .key = "tags", .value = "synapse, vault-infra, architecture" },
    }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readVaultFile(gpa, "tasks/synapse/x.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "tags: [synapse, vault-infra, architecture]\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "tags: '[") == null);
}

test "--add-tag appends without needing the caller to know the current list" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/x.md", "---\ntitle: \"X\"\ntags: [synapse]\n---\nbody\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{ .add_tag = "zig" }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readVaultFile(gpa, "tasks/synapse/x.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "tags: [synapse, zig]\n") != null);
}

test "--remove-tag drops one entry, leaving the rest untouched" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/x.md", "---\ntitle: \"X\"\ntags: [synapse, zig, vault-infra]\n---\nbody\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{ .remove_tag = "zig" }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readVaultFile(gpa, "tasks/synapse/x.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "tags: [synapse, vault-infra]\n") != null);
}

test "a missing note fails clearly instead of writing a fresh one" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/nope.md", .{
        .set = .{ .key = "status", .value = "DONE" },
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expectEqual(@as(?[]u8, null), try fx.readVaultFile(gpa, "tasks/synapse/nope.md"));
}

test "a note with no frontmatter at all fails clearly rather than guessing where to insert" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/x.md", "# Just prose\nno frontmatter here\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{
        .set = .{ .key = "status", .value = "DONE" },
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}

test "a non-2xx PUT is reported as a failure and the note is left as read" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/x.md", "---\ntitle: \"X\"\nstatus: TODO\n---\nbody\n");
    try fx.setPutStatus("500");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{
        .set = .{ .key = "status", .value = "DONE" },
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);

    const still = (try fx.readVaultFile(gpa, "tasks/synapse/x.md")).?;
    defer gpa.free(still);
    try testing.expect(std.mem.indexOf(u8, still, "status: TODO\n") != null);
}
