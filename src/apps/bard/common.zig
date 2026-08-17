//! What `synapse-bard`'s subcommands share: resolving the repo root and
//! `_bard/graph/`/`_bard/vault/`'s roots from the current working
//! directory, and the small def/ref cleanup none of them should each
//! reimplement.

const std = @import("std");
const core = @import("core");
const model = @import("model");
const ports = @import("ports");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Every root a subcommand might need: `graph_root` to list/read/write
/// `_bard/graph/`'s own cluster nodes, `repo_root` to resolve a cluster's
/// `sources:` path entries (repo-root-relative) to real files, `vault_root`
/// for `_bard/vault/`'s design/task notes. Before `synapse-bard-005`'s
/// clustering refactor, only `sync` ever needed `repo_root` -- `query`/
/// `field`/`search` read `_bard/graph/{slug}.md` directly and never touched
/// a real source file. Now all four resolve through a cluster's `sources:`
/// first, so all four need both graph-side roots. `vault_root` is unused by
/// any of the graph-side commands; it exists for `vault-search`.
pub const Roots = struct {
    repo_root: []const u8,
    graph_root: []const u8,
    vault_root: []const u8,

    /// All three found via one `core.identity.resolve` call so a command
    /// run from a subdirectory still finds the repo's top -- same
    /// resolution `bard_hook`'s own `session_start.zig` uses for
    /// `_bard/vault/Index.md`.
    pub fn resolve(gpa: Allocator, io: Io) !Roots {
        const id = try core.identity.resolve(gpa, io, ".");
        defer id.deinit(gpa);
        const repo_root = try gpa.dupe(u8, id.layout.repo_root);
        errdefer gpa.free(repo_root);
        const graph_root = try std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{id.layout.repo_root});
        errdefer gpa.free(graph_root);
        const vault_root = try std.fmt.allocPrint(gpa, "{s}/_bard/vault", .{id.layout.repo_root});
        return .{ .repo_root = repo_root, .graph_root = graph_root, .vault_root = vault_root };
    }

    pub fn deinit(self: Roots, gpa: Allocator) void {
        gpa.free(self.repo_root);
        gpa.free(self.graph_root);
        gpa.free(self.vault_root);
    }
};

/// A wikilink target with a literal `.md` suffix resolves the same as one
/// without -- the same rule `BardVaultStore.backlinkCounts` already proved
/// out for the vault side (`synapse-bard-001` step 5), applied here fresh
/// rather than exported and shared: three lines isn't worth a cross-module
/// dependency for.
pub fn stripMdSuffix(text: []const u8) []const u8 {
    if (std.mem.endsWith(u8, text, ".md")) return text[0 .. text.len - 3];
    return text;
}

/// Frees one `ports.Extractor.Outcome` slice -- the same cleanup
/// `frontmatter.zig`'s own tests do, duplicated here since that helper
/// isn't exported (it's test-only there).
pub fn freeOutcomes(gpa: Allocator, out: []ports.Extractor.Outcome) void {
    for (out) |o| switch (o) {
        .unsupported => {},
        .tags => |ts| {
            for (ts) |t| {
                gpa.free(t.name);
                gpa.free(t.kind);
                gpa.free(t.expression);
            }
            gpa.free(ts);
        },
    };
    gpa.free(out);
}

pub fn freeNames(gpa: Allocator, names: []const []const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}
