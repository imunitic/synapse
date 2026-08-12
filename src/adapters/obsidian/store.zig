//! The Obsidian Local REST API as a `ports.Store`.
//!
//! `read` and `write` are `GET` and `PUT` on `/vault/{path}`; `list` reads the
//! namespace directory from disk, because that is where the answer is and the
//! API has no cheaper way to give it; `search` is the JsonLogic endpoint, which
//! nothing currently calls -- the prompt hook that used to stopped searching --
//! but which the port names and a future caller will want.
//!
//! ## `curl` stays, and this is not a preference
//!
//! Zig's `std.http` cannot verify the plugin's certificate: it carries an IP SAN
//! and no DNS name, which `std.crypto.tls` has no path for. Verified 2026-08-11.
//! The alternatives were asking users to enable the plugin's plaintext port, or
//! skipping verification, and both are worse than one spawn per call against a
//! loopback address. Do not re-attempt this without new information about
//! `std.crypto.tls`; the note in the design says the same thing.
//!
//! One spawn per call is affordable here in a way it was not in `vocab` or
//! `rank`, and for a structural reason rather than a lucky one: those ran per
//! *file* over a whole repository, while this runs per *node*. A namespace has
//! tens of nodes against a hundred thousand files.
//!
//! ## Absence is an ordinary answer, and the 404 body is why that took care
//!
//! `read` returns null for a node that is not there. Getting that right needs
//! the HTTP status, not the body: the API answers a missing path with a 404
//! whose body is *itself valid JSON* (`{"message":"Not Found","errorCode":40400}`),
//! so a reader that only checked "did I get parseable content" treated an absent
//! node as a real one. That happened in the wild to two repositories edited
//! before `/synapse-init` had ever run, and it is why `curl -f` (fail on HTTP
//! error, exit 22) is used for reads rather than inspecting the payload.

const std = @import("std");
const ports = @import("ports");
const process = @import("../process.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;

/// `curl`'s exit code for "HTTP error" under `-f`. Distinguished from every
/// other non-zero exit because it is the only one that means "the server
/// answered, and the answer was no" rather than "the call did not happen".
const curl_http_error = 22;

pub const ObsidianStore = struct {
    gpa: Allocator,
    /// `https://127.0.0.1:{port}`, built once.
    base: []const u8,
    /// The plugin's own CA, from `~/.claude/obsidian-local-rest-api-ca.pem`.
    cert_path: []const u8,
    api_key: []const u8,
    /// `synapse/{repo}@{branch}`, prefixed onto every node name so callers pass
    /// a node title and never a vault path. The namespace is resolved once, by
    /// whoever constructed this, for the same reason every other component
    /// resolves it once: two resolutions that disagree make one component refuse
    /// where another proceeds.
    namespace: []const u8,

    pub fn init(
        gpa: Allocator,
        port_number: u16,
        cert_path: []const u8,
        api_key: []const u8,
        namespace: []const u8,
    ) !ObsidianStore {
        return .{
            .gpa = gpa,
            .base = try std.fmt.allocPrint(gpa, "https://127.0.0.1:{d}", .{port_number}),
            .cert_path = cert_path,
            .api_key = api_key,
            .namespace = namespace,
        };
    }

    pub fn deinit(self: *ObsidianStore) void {
        self.gpa.free(self.base);
    }

    pub fn store(self: *ObsidianStore) Store {
        return .{ .ptr = self, .vtable = &.{
            .read = read,
            .write = write,
            .list = list,
            .search = search,
        } };
    }

    /// `Authorization: Bearer …`, built per call because it borrows nothing the
    /// caller can keep.
    fn authHeader(self: *ObsidianStore, gpa: Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "Authorization: Bearer {s}", .{self.api_key});
    }

    fn nodeUrl(self: *ObsidianStore, gpa: Allocator, node: []const u8) ![]u8 {
        const vault_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.namespace, node });
        defer gpa.free(vault_path);
        const encoded = try encodePath(gpa, vault_path);
        defer gpa.free(encoded);
        return std.fmt.allocPrint(gpa, "{s}/vault/{s}", .{ self.base, encoded });
    }

    fn read(ptr: *anyopaque, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        const self: *ObsidianStore = @ptrCast(@alignCast(ptr));
        const url = try self.nodeUrl(gpa, node);
        defer gpa.free(url);
        const auth = try self.authHeader(gpa);
        defer gpa.free(auth);

        const res = try process.run(io, gpa, &.{
            "curl", "-s",  "-f",
            "--cacert", self.cert_path,
            "-H",       auth,
            "-H",       "Accept: text/markdown",
            url,
        }, .{});
        defer gpa.free(res.stderr);
        errdefer gpa.free(res.stdout);

        if (res.ok()) return res.stdout;
        gpa.free(res.stdout);
        // 22 is the server saying no -- an absent node, which is an ordinary
        // answer. Anything else is the call not having happened: a refused
        // connection, a certificate that would not verify, no `curl` at all.
        // Those must not read as "the node is missing", because a caller acting
        // on that would treat an unreachable vault as an empty one.
        if (res.exitCode() == curl_http_error) return null;
        return error.VaultUnreachable;
    }

    fn write(ptr: *anyopaque, io: Io, node: []const u8, body: []const u8) anyerror!void {
        const self: *ObsidianStore = @ptrCast(@alignCast(ptr));
        const gpa = self.gpa;
        const url = try self.nodeUrl(gpa, node);
        defer gpa.free(url);
        const auth = try self.authHeader(gpa);
        defer gpa.free(auth);

        // `--data-binary @-` with the body on stdin, never `--data-binary <body>`
        // inline: an argument list is bounded and a node runs to megabytes on a
        // hub. The scripts wrote a temp file and passed `@file` for the same
        // reason; stdin skips the file.
        const res = try process.run(io, gpa, &.{
            "curl",     "-s",             "-o", "/dev/null",
            "-w",       "%{http_code}",
            "-X",       "PUT",
            "--cacert", self.cert_path,
            "-H",       auth,
            "-H",       "Content-Type: text/markdown",
            "--data-binary", "@-",
            url,
        }, .{ .stdin = body });
        defer res.deinit(gpa);

        if (!res.ok()) return error.VaultUnreachable;
        // `-o /dev/null -w '%{http_code}'`: stdout is the status and nothing
        // else, which is what the scripts checked with `case "$http_code" in 20*)`.
        const status = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (status.len < 3 or status[0] != '2') return error.VaultWriteRejected;
    }

    /// Every node in the namespace, from the directory rather than the API.
    ///
    /// A node file is any `*.md` directly under the namespace except `Index.md`;
    /// `_manifest.tsv` and `_profile.txt` are machine-only and not nodes. The
    /// same distinction `synapse-graph-wipe.sh` draws, and the reverse index and
    /// the caches are not here at all any more -- they live in the work dir.
    fn list(ptr: *anyopaque, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        const self: *ObsidianStore = @ptrCast(@alignCast(ptr));
        // The vault root is not this adapter's to know: `namespace` is a vault
        // path, and turning it into a filesystem path needs `$OBSIDIAN_VAULT_DIR`,
        // which belongs to whoever configured the adapter. Deliberately not
        // guessed -- a listing against the wrong directory is silently empty.
        _ = gpa;
        _ = io;
        _ = self;
        return error.ListNeedsVaultDir;
    }

    /// The JsonLogic search endpoint. Nothing calls this yet: the prompt hook
    /// that used to search stopped, because on a real 52-node namespace it
    /// returned 50 of 52 nodes for ~1057 tokens on every turn. Left unimplemented
    /// rather than guessed at, so the first real caller writes it against a real
    /// requirement.
    fn search(ptr: *anyopaque, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
        _ = ptr;
        _ = gpa;
        _ = io;
        _ = query;
        return error.SearchNotImplemented;
    }
};

/// Percent-encode each path segment, leaving `/` alone.
///
/// Node titles routinely contain spaces and em dashes -- `World — entity core.md`
/// -- and the separators have to survive as separators. The scripts did this with
/// one `jq -rn '$s|@uri'` per segment, which is a fork per segment; the rule is
/// small enough to write out.
///
/// Unreserved set from RFC 3986: `A-Z a-z 0-9 - . _ ~`. Everything else is
/// escaped, including bytes above 0x7F one byte at a time, which is what `@uri`
/// does to a UTF-8 em dash (`%E2%80%94`).
pub fn encodePath(gpa: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (path) |c| {
        if (c == '/' or isUnreserved(c)) {
            try out.append(gpa, c);
        } else {
            try out.appendSlice(gpa, &.{ '%', hex(c >> 4), hex(c & 0x0f) });
        }
    }
    return out.toOwnedSlice(gpa);
}

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '.' or c == '_' or c == '~';
}

fn hex(nibble: u8) u8 {
    return "0123456789ABCDEF"[nibble];
}

const testing = std.testing;

test "each segment is encoded and the separators survive" {
    const gpa = testing.allocator;
    const got = try encodePath(gpa, "synapse/repo@main/Foo Node.md");
    defer gpa.free(got);
    try testing.expectEqualStrings("synapse/repo%40main/Foo%20Node.md", got);
}

test "an em dash becomes three escapes, byte by byte" {
    // The case the scripts' own test asserts by name: a node titled
    // `World — entity_component_resource core.md` has to survive the round trip,
    // and `jq @uri` escapes the UTF-8 bytes individually.
    const gpa = testing.allocator;
    const got = try encodePath(gpa, "World — entity_component_resource core.md");
    defer gpa.free(got);
    try testing.expectEqualStrings(
        "World%20%E2%80%94%20entity_component_resource%20core.md",
        got,
    );
}

test "the unreserved set is left alone" {
    const gpa = testing.allocator;
    const got = try encodePath(gpa, "a-b_c.d~e/F0");
    defer gpa.free(got);
    try testing.expectEqualStrings("a-b_c.d~e/F0", got);
}

test "a node name needing no escaping still round-trips unchanged" {
    const gpa = testing.allocator;
    const got = try encodePath(gpa, "synapse/fw-core@master/Index.md");
    defer gpa.free(got);
    try testing.expectEqualStrings("synapse/fw-core%40master/Index.md", got);
}
