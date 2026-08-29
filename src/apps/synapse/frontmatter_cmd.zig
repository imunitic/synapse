//! `synapse frontmatter` -- byte-preserving reads and single-key writes to a
//! vault note's frontmatter, without ever pulling the note's body into the
//! agent's context. `set` replaces `vault_patch`'s `frontmatter` target,
//! which re-serializes the whole YAML block and can turn an array value
//! into a quoted string instead of a real list -- see `core/frontmatter.zig`
//! for the primitive `set` is a thin CLI wrapper over. `get` streams the file
//! a line at a time (`core.query.fieldStreaming`) and stops the moment it
//! has the key it wants; `set` still needs the whole note, so it reads
//! through `Store.read` and writes back through `Store.write`.
//!
//!   frontmatter get <path> <key>
//!   frontmatter set <path> <key> <value>
//!   frontmatter set <path> --add-tag <tag>
//!   frontmatter set <path> --remove-tag <tag>
//!
//! `<path>` is the note's full vault-relative path (e.g.
//! `tasks/widget/wg-037 — Foo.md`), not scoped to any one repo's code-graph
//! namespace -- the store this command opens carries an empty namespace for
//! exactly that reason (see `DiskStore.namespace`'s doc comment). Both
//! subcommands share this same `<path>` meaning deliberately: it's `synapse
//! query field --file`'s own `<path>` (a plain local filesystem path, no
//! vault or REST involved) that stays a separate thing, not this one.
//!
//! `<value>` with no comma sets a scalar field; a comma-separated value sets
//! an array (`tags: [a, b]`), never a quoted string. `--add-tag`/
//! `--remove-tag` are the `tags`-specific alternative, mutually exclusive
//! with `<key> <value>`.
//!
//! `set` prints `<path>\t<key>\n` on success; `get` prints the value (or
//! nothing for an absent key, exit 0 either way -- `query field`'s own
//! convention). Exit 1 for anything that made the operation impossible (no
//! such note, an unreachable vault, no frontmatter at all for `set`), 2 for
//! a usage error.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-frontmatter";

const usage_text =
    \\usage: synapse frontmatter get <path> <key>
    \\       synapse frontmatter set <path> <key> <value>
    \\       synapse frontmatter set <path> --add-tag <tag>
    \\       synapse frontmatter set <path> --remove-tag <tag>
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

const SetArgs = struct { path: []const u8, op: Op };

const Parsed = union(enum) {
    get: struct { path: []const u8, key: []const u8 },
    set: SetArgs,
};

/// Pure over an already-collected argv slice, so the mutual-exclusivity and
/// missing-argument cases are testable without a real `Args.Iterator`. Null
/// means "print usage and exit 2" -- every rejection reads the same way to
/// the caller, since none of them can be acted on differently.
fn parseArgs(argv: []const []const u8) ?Parsed {
    if (argv.len == 0) return null;
    const sub = argv[0];
    const rest = argv[1..];

    if (std.mem.eql(u8, sub, "get")) {
        if (rest.len != 2 or rest[0].len == 0 or rest[1].len == 0) return null;
        return .{ .get = .{ .path = rest[0], .key = rest[1] } };
    }
    if (std.mem.eql(u8, sub, "set")) {
        const parsed = parseSetArgs(rest) orelse return null;
        return .{ .set = parsed };
    }
    return null;
}

fn parseSetArgs(argv: []const []const u8) ?SetArgs {
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
    const code = switch (parsed) {
        .get => |g| try get(gpa, io, env, vault, g.path, g.key, &out.interface),
        .set => |s| try set(gpa, io, env, vault, s.path, s.op, &out.interface),
    };
    try out.interface.flush();
    return code;
}

/// Prints one frontmatter field's value, or nothing for an absent key --
/// `query field`'s own "absent key prints nothing, exits 0" convention, not
/// an error.
///
/// Streams the file a line at a time (`core.query.fieldStreaming`) instead of
/// going through `Store.read` -- both backends' reads are plain disk I/O
/// against the same `{vault}/{path}` join (`DiskStore.namespace`'s doc
/// comment; `store_resolve.zig` confirms it for `.obsidian` too), so there's
/// no abstraction to lose by reading the file directly for a lookup that
/// wants to stop early. `env` stays in the signature for symmetry with `set`,
/// which still needs a real `Store.write` for an extended store's own
/// consistency -- see `write_node_cmd.zig`'s own doc comment for why writes
/// don't get the same shortcut.
pub fn get(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    path: []const u8,
    key: []const u8,
    result: *Io.Writer,
) !u8 {
    _ = env;
    if (!core.node_path.isSafe(path)) {
        std.debug.print("{s}: no such note: {s}\n", .{ prog, path });
        return 1;
    }
    const abs = try std.fs.path.join(gpa, &.{ vault, path });
    defer gpa.free(abs);

    var file = Io.Dir.cwd().openFile(io, abs, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("{s}: no such note: {s}\n", .{ prog, path });
        } else {
            std.debug.print("{s}: read failed: {s}\n", .{ prog, @errorName(err) });
        }
        return 1;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    const v = core.query.fieldStreaming(&file_reader.interface, key) catch |err| {
        std.debug.print("{s}: read failed: {s}\n", .{ prog, @errorName(err) });
        return 1;
    };
    if (v) |val| try result.print("{s}\n", .{val});
    return 0;
}

pub fn set(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    path: []const u8,
    op: Op,
    result: *Io.Writer,
) !u8 {
    var resolved = (try adapters.store_resolve.resolveStore(gpa, io, env, vault, "", prog, "")) orelse return 1;
    defer resolved.deinit();
    var store = resolved.store();

    const current = (store.read(gpa, io, path) catch |err| {
        std.debug.print("{s}: read failed: {s}\n", .{ prog, @errorName(err) });
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

    const put_result = store.write(io, path, updated) catch |err| {
        std.debug.print("{s}: write failed: {s}\n", .{ prog, @errorName(err) });
        return 1;
    };
    defer gpa.free(put_result.body);
    if (!put_result.accepted) {
        std.debug.print("{s}: write rejected ({d:0>3}): {s}\n", .{ prog, put_result.status, put_result.body });
        return 1;
    }

    try result.print("{s}\t{s}\n", .{ path, label });
    return 0;
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

test "parseArgs: get takes a path and a key" {
    const got = parseArgs(&.{ "get", "tasks/x.md", "status" }).?;
    try testing.expectEqualStrings("tasks/x.md", got.get.path);
    try testing.expectEqualStrings("status", got.get.key);
}

test "parseArgs: set with a bare key/value sets a scalar" {
    const got = parseArgs(&.{ "set", "tasks/x.md", "status", "DONE" }).?;
    try testing.expectEqualStrings("tasks/x.md", got.set.path);
    try testing.expectEqualStrings("status", got.set.op.set.key);
    try testing.expectEqualStrings("DONE", got.set.op.set.value);
}

test "parseArgs: set --add-tag and --remove-tag parse to their own op" {
    const add = parseArgs(&.{ "set", "tasks/x.md", "--add-tag", "zig" }).?;
    try testing.expectEqualStrings("zig", add.set.op.add_tag);

    const remove = parseArgs(&.{ "set", "tasks/x.md", "--remove-tag", "zig" }).?;
    try testing.expectEqualStrings("zig", remove.set.op.remove_tag);
}

test "parseArgs: set <key> <value> together with --add-tag is a usage error" {
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{ "set", "tasks/x.md", "status", "DONE", "--add-tag", "zig" }));
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{ "set", "tasks/x.md", "--add-tag", "zig", "status", "DONE" }));
}

test "parseArgs: missing pieces, an unknown subcommand, and no subcommand at all are all usage errors" {
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{}));
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{"get"}));
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{ "get", "tasks/x.md" }));
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{"set"}));
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{ "set", "tasks/x.md" }));
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{ "set", "tasks/x.md", "status" }));
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{ "set", "tasks/x.md", "--add-tag" }));
    try testing.expectEqual(@as(?Parsed, null), parseArgs(&.{ "delete", "tasks/x.md", "status" }));
}

test "get reads a real field back after set writes it" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/x.md", "---\ntitle: \"X\"\nstatus: TODO\n---\nbody\n");

    var set_out: Io.Writer.Allocating = .init(gpa);
    defer set_out.deinit();
    const set_code = try set(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{
        .set = .{ .key = "status", .value = "IN-PROGRESS" },
    }, &set_out.writer);
    try testing.expectEqual(@as(u8, 0), set_code);

    var get_out: Io.Writer.Allocating = .init(gpa);
    defer get_out.deinit();
    const get_code = try get(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", "status", &get_out.writer);
    try testing.expectEqual(@as(u8, 0), get_code);
    try testing.expectEqualStrings("IN-PROGRESS\n", get_out.written());
}

test "get on an absent key prints nothing and still exits 0" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/x.md", "---\ntitle: \"X\"\n---\nbody\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try get(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", "nonexistent", &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("", out.written());
}

test "get on a missing note fails clearly, same message shape as set" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try get(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/nope.md", "status", &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}

test "sets a scalar field on a note addressed by its full vault path" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/x.md", "---\ntitle: \"X\"\nstatus: TODO\n---\nbody\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try set(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{
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
    const code = try set(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{
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
    const code = try set(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{ .add_tag = "zig" }, &out.writer);
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
    const code = try set(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{ .remove_tag = "zig" }, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readVaultFile(gpa, "tasks/synapse/x.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "tags: [synapse, vault-infra]\n") != null);
}

test "set on a missing note fails clearly instead of writing a fresh one" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try set(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/nope.md", .{
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
    const code = try set(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{
        .set = .{ .key = "status", .value = "DONE" },
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}
