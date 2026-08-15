//! The Obsidian Local REST API as a `ports.Store`.
//!
//! `read`/`write` are `GET`/`PUT` on `/vault/{path}`; `list` reads the
//! namespace directory from disk (cheaper than the API); `search` is the
//! JsonLogic endpoint, unused today but named for a future caller.
//!
//! **`curl`, not `std.http`**: the plugin's certificate carries an IP SAN
//! and no DNS name, which `std.crypto.tls` has no path for (verified
//! 2026-08-11). One spawn per call is affordable here specifically because
//! this runs per *node* (tens per namespace), not per *file* like `vocab`/`rank`.
//!
//! **Absence is ordinary, and needs the HTTP status, not the body**: a
//! missing path 404s with a body that's itself valid JSON
//! (`{"message":"Not Found",...}`), which silently misread as a real node
//! in two repos in the wild. `curl -f` (exit 22 on HTTP error) is used for
//! reads for exactly this reason.

const std = @import("std");
const ports = @import("ports");
const process = @import("../process.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;

/// `curl -f`'s exit code for "the server answered, and said no" -- distinct
/// from every other non-zero exit, which means the call didn't happen.
const curl_http_error = 22;

pub const ObsidianStore = struct {
    gpa: Allocator,
    /// `https://127.0.0.1:{port}`, built once.
    base: []const u8,
    /// The plugin's own CA, from `~/.claude/obsidian-local-rest-api-ca.pem`.
    cert_path: []const u8,
    api_key: []const u8,
    /// `synapse/{repo}@{branch}`, prefixed onto every node name so callers
    /// pass a title, never a vault path. Resolved once by the constructor,
    /// so two resolutions can't disagree.
    namespace: []const u8,

    /// Copies all three strings; `deinit` frees them. Borrowing made every
    /// caller responsible for outliving the store and all three got it
    /// wrong the same way -- caught only by the Linux container's
    /// `DebugAllocator`, silent on macOS.
    pub fn init(
        gpa: Allocator,
        port_number: u16,
        cert_path: []const u8,
        api_key: []const u8,
        namespace: []const u8,
    ) !ObsidianStore {
        const base = try std.fmt.allocPrint(gpa, "https://127.0.0.1:{d}", .{port_number});
        errdefer gpa.free(base);
        const cert = try gpa.dupe(u8, cert_path);
        errdefer gpa.free(cert);
        const key = try gpa.dupe(u8, api_key);
        errdefer gpa.free(key);
        const ns = try gpa.dupe(u8, namespace);
        return .{
            .gpa = gpa,
            .base = base,
            .cert_path = cert,
            .api_key = key,
            .namespace = ns,
        };
    }

    pub fn deinit(self: *ObsidianStore) void {
        self.gpa.free(self.base);
        self.gpa.free(self.cert_path);
        self.gpa.free(self.api_key);
        self.gpa.free(self.namespace);
    }

    pub fn store(self: *ObsidianStore) Store {
        return .{ .ptr = self, .vtable = &.{
            .read = read,
            .write = write,
            .list = list,
            .search = search,
        } };
    }

    /// `Authorization: Bearer …`, built per call.
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
        // 22: server said no, an absent node. Anything else (refused
        // connection, bad cert, no curl) must not read as "missing" -- a
        // caller acting on that would treat an unreachable vault as empty.
        if (res.exitCode() == curl_http_error) return null;
        return error.VaultUnreachable;
    }

    fn write(ptr: *anyopaque, io: Io, node: []const u8, body: []const u8) anyerror!void {
        const self: *ObsidianStore = @ptrCast(@alignCast(ptr));
        const res = try self.put(io, node, body);
        defer self.gpa.free(res.body);
        if (!res.accepted()) return error.VaultWriteRejected;
    }

    /// What the server said about a PUT.
    pub const PutResult = struct {
        /// The HTTP status, or 0 when `curl` didn't complete.
        status: u16,
        /// The response body, owned by the caller.
        body: []u8,

        pub fn accepted(self: PutResult) bool {
            return self.status >= 200 and self.status < 300;
        }
    };

    /// A PUT, reporting the status rather than collapsing it to an error --
    /// the port can't carry an HTTP status, but `write-node`'s failure line
    /// (`PUT failed (500): <body>`) needs one, so it calls this directly.
    pub fn put(self: *ObsidianStore, io: Io, node: []const u8, body: []const u8) !PutResult {
        const gpa = self.gpa;
        const url = try self.nodeUrl(gpa, node);
        defer gpa.free(url);
        const auth = try self.authHeader(gpa);
        defer gpa.free(auth);

        // `--data-binary @-` on stdin, not inline: an argument list is
        // bounded and a node can run to megabytes. `-w '\n%{http_code}'`
        // with no `-o` puts the body, a newline, and the status all on stdout.
        const res = try process.run(io, gpa, &.{
            "curl",          "-s",
            "-w",            "\n%{http_code}",
            "-X",            "PUT",
            "--cacert",      self.cert_path,
            "-H",            auth,
            "-H",            "Content-Type: text/markdown",
            "--data-binary", "@-",
            url,
        }, .{ .stdin = body });
        defer gpa.free(res.stderr);
        defer gpa.free(res.stdout);
        if (!res.ok()) return .{ .status = 0, .body = try gpa.dupe(u8, "") };

        const trimmed = std.mem.trimEnd(u8, res.stdout, " \t\r\n");
        const nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n');
        const status_text = if (nl) |at| trimmed[at + 1 ..] else trimmed;
        const payload = if (nl) |at| trimmed[0..at] else "";
        return .{
            .status = std.fmt.parseInt(u16, status_text, 10) catch 0,
            .body = try gpa.dupe(u8, payload),
        };
    }

    /// Every node in the namespace, from the directory rather than the API.
    /// A node is any `*.md` directly under the namespace except `Index.md`;
    /// `_manifest.tsv`/`_profile.txt` are machine-only, matching
    /// `synapse-graph-wipe.sh`'s own distinction.
    fn list(ptr: *anyopaque, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        const self: *ObsidianStore = @ptrCast(@alignCast(ptr));
        // Vault root isn't this adapter's to know -- deliberately not
        // guessed, since a listing against the wrong directory would be
        // silently empty.
        _ = gpa;
        _ = io;
        _ = self;
        return error.ListNeedsVaultDir;
    }

    /// The JsonLogic search endpoint. Unimplemented: the prompt hook that
    /// used to search stopped, since on a real 52-node namespace it
    /// returned 50 of 52 for ~1057 tokens every turn.
    fn search(ptr: *anyopaque, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
        _ = ptr;
        _ = gpa;
        _ = io;
        _ = query;
        return error.SearchNotImplemented;
    }
};

/// Percent-encode each path segment, leaving `/` alone. Node titles
/// routinely contain spaces and em dashes, which must survive as separators.
///
/// Unreserved set from RFC 3986: `A-Z a-z 0-9 - . _ ~`. Everything else is
/// escaped byte by byte, including UTF-8 bytes above 0x7F (an em dash
/// becomes `%E2%80%94`).
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
