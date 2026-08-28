//! LinkGraph: a vault's own wikilink graph -- backlinks, outgoing links, and
//! broken/orphaned/dead-end structure. A separate capability from `Store`,
//! not a fifth `Store` method: `BardGraphStore`/`BardVaultStore` have no use
//! for a link graph and shouldn't have to stub one -- no half-fake stubs.
//! `?LinkGraph` on a `ResolvedStore` means "not every
//! `Store` is a vault-store," not "nice-to-have" -- both real coding-vault
//! backends are expected to implement it for real over time.
//!
//! Attached to a concrete store via composition (a genuine field, e.g.
//! `ObsidianStore.link_graph: ObsidianLinkGraph`), never by a store growing
//! a second interface's worth of methods on itself, and reached from a
//! `ResolvedStore` through a comptime duck-typed dispatcher that asks only
//! "does whatever's active have a `linkGraph()` method" -- never a union tag
//! naming a specific backend.

const std = @import("std");

pub const LinkGraph = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Backlink = struct { node: []const u8, count: usize };
    pub const Unresolved = struct { target: []const u8, count: usize, sources: []const []const u8 };
    /// A wikilink target that resolved to more than one real file -- same
    /// shape as `Unresolved` plus the candidate list, since it's the same
    /// underlying question ("what does this link text mean") with a
    /// different answer (too many, not zero). A backend with no way to
    /// detect this (`ObsidianStore`'s CLI has no such concept) reports none,
    /// same as it would for anything else it can't see.
    pub const Ambiguous = struct { target: []const u8, candidates: []const []const u8, count: usize, sources: []const []const u8 };

    pub const VTable = struct {
        backlinks: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, node: []const u8) anyerror![]const Backlink,
        links: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, node: []const u8) anyerror![]const []const u8,
        unresolved: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror![]const Unresolved,
        orphans: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror![]const []const u8,
        deadends: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror![]const []const u8,
        ambiguous: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror![]const Ambiguous,
    };

    /// Caller-owned: free every `.node` and the outer slice.
    pub fn backlinks(self: LinkGraph, gpa: std.mem.Allocator, io: std.Io, node: []const u8) anyerror![]const Backlink {
        return self.vtable.backlinks(self.ptr, gpa, io, node);
    }

    /// Caller-owned: free every name and the outer slice.
    pub fn links(self: LinkGraph, gpa: std.mem.Allocator, io: std.Io, node: []const u8) anyerror![]const []const u8 {
        return self.vtable.links(self.ptr, gpa, io, node);
    }

    /// Caller-owned: free every `.target`, every entry of every `.sources`
    /// slice, every `.sources` slice itself, and the outer slice.
    pub fn unresolved(self: LinkGraph, gpa: std.mem.Allocator, io: std.Io) anyerror![]const Unresolved {
        return self.vtable.unresolved(self.ptr, gpa, io);
    }

    /// Caller-owned: free every name and the outer slice.
    pub fn orphans(self: LinkGraph, gpa: std.mem.Allocator, io: std.Io) anyerror![]const []const u8 {
        return self.vtable.orphans(self.ptr, gpa, io);
    }

    /// Caller-owned: free every name and the outer slice.
    pub fn deadends(self: LinkGraph, gpa: std.mem.Allocator, io: std.Io) anyerror![]const []const u8 {
        return self.vtable.deadends(self.ptr, gpa, io);
    }

    /// Caller-owned: free every `.target`, every entry of every `.candidates`
    /// and `.sources` slice, both slices themselves, and the outer slice.
    pub fn ambiguous(self: LinkGraph, gpa: std.mem.Allocator, io: std.Io) anyerror![]const Ambiguous {
        return self.vtable.ambiguous(self.ptr, gpa, io);
    }

    /// Builds a `LinkGraph` from any concrete `T` exposing all five methods
    /// with this same shape, self-first -- the wrapper idiom, identical to
    /// `Store.from`. Every real implementation gets its own `.linkGraph()`
    /// for free by calling this once with its own type.
    pub fn from(comptime T: type, self: *T) LinkGraph {
        const Impl = struct {
            fn backlinks(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, node: []const u8) anyerror![]const Backlink {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.backlinks(gpa, io, node);
            }
            fn links(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, node: []const u8) anyerror![]const []const u8 {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.links(gpa, io, node);
            }
            fn unresolved(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror![]const Unresolved {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.unresolved(gpa, io);
            }
            fn orphans(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror![]const []const u8 {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.orphans(gpa, io);
            }
            fn deadends(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror![]const []const u8 {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.deadends(gpa, io);
            }
            fn ambiguous(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror![]const Ambiguous {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.ambiguous(gpa, io);
            }
        };
        return .{ .ptr = self, .vtable = &.{
            .backlinks = Impl.backlinks,
            .links = Impl.links,
            .unresolved = Impl.unresolved,
            .orphans = Impl.orphans,
            .deadends = Impl.deadends,
            .ambiguous = Impl.ambiguous,
        } };
    }
};
