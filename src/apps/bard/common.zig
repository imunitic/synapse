//! What `synapse-bard`'s subcommands share: resolving `_bard/graph/`'s root
//! from the current working directory, and the small def/ref cleanup none
//! of them should each reimplement.

const std = @import("std");
const core = @import("core");
const model = @import("model");
const ports = @import("ports");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// `{repo_root}/_bard/graph`, found via `core.identity.resolve` so a
/// command run from a subdirectory still finds the graph at the repo's
/// top -- same resolution `bard_hook`'s own `session_start.zig` uses for
/// `_bard/vault/Index.md`.
pub fn graphRoot(gpa: Allocator, io: Io) ![]u8 {
    const id = try core.identity.resolve(gpa, io, ".");
    defer id.deinit(gpa);
    return std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{id.layout.repo_root});
}

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
