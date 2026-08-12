//! Store: where nodes and indexes are read, written, listed and searched.
//!
//! The Obsidian REST API for code; plain files under `_bard/synapse/` for a
//! bible. Search belongs to this port rather than to core, so "full-text over
//! prose" and "exact symbol lookup" stay adapter concerns — they are the same
//! question asked of very different corpora, and core has no business
//! preferring one implementation's answer.

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
        /// Null when the node does not exist. Absence is an ordinary answer
        /// here, not an error: a first build asks for nodes that are not there
        /// yet, and a namespace with no `Index.md` is a repo nobody has run
        /// `/synapse-init` in rather than a fault.
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
