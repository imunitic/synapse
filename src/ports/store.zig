//! Store: where nodes and indexes are read, written, listed and searched.
//!
//! The Obsidian REST API for code; plain files under `_bard/graph/` for a
//! bible. Search belongs here rather than in core, since "full-text over
//! prose" vs. "exact symbol lookup" is an adapter-specific question.

const std = @import("std");

pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Hit = struct {
        node: []const u8,
        score: f32,
        context: []const u8,
    };

    pub const VTable = struct {
        /// Null when the node doesn't exist -- an ordinary answer, not an
        /// error (a first build asks for nodes that aren't there yet).
        read: *const fn (
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            io: std.Io,
            node: []const u8,
        ) anyerror!?[]u8,

        write: *const fn (
            ptr: *anyopaque,
            io: std.Io,
            node: []const u8,
            body: []const u8,
        ) anyerror!void,

        /// Caller-owned: free the outer slice and every name in it. A
        /// directory-backed implementation can only hand back names that
        /// outlive its own iterator by copying them -- the contract has to
        /// hold for every implementation, not just the ones for which it'd
        /// be free.
        list: *const fn (
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            io: std.Io,
        ) anyerror![]const []const u8,

        search: *const fn (
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            io: std.Io,
            query: []const u8,
        ) anyerror![]const Hit,
    };

    pub fn read(self: Store, gpa: std.mem.Allocator, io: std.Io, node: []const u8) anyerror!?[]u8 {
        return self.vtable.read(self.ptr, gpa, io, node);
    }

    pub fn write(self: Store, io: std.Io, node: []const u8, body: []const u8) anyerror!void {
        return self.vtable.write(self.ptr, io, node, body);
    }

    pub fn list(self: Store, gpa: std.mem.Allocator, io: std.Io) anyerror![]const []const u8 {
        return self.vtable.list(self.ptr, gpa, io);
    }

    pub fn search(self: Store, gpa: std.mem.Allocator, io: std.Io, query: []const u8) anyerror![]const Hit {
        return self.vtable.search(self.ptr, gpa, io, query);
    }
};
