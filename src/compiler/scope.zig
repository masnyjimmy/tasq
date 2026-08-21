const std = @import("std");
const ir = @import("ir.zig");

const sym = @import("symbol.zig");
const Symbol = sym.Symbol;
const NodeId = @import("span.zig").Registry.NodeId;

pub const Scope = struct {
    const IndexesStorage = std.array_hash_map.String(usize);

    parent: ?*Scope,
    // symbols
    symbols: std.ArrayList(*Symbol) = .empty,
    // indexes
    variables: IndexesStorage = .empty,
    tasks: IndexesStorage = .empty,
    groups: IndexesStorage = .empty,
    // child scopes
    children: std.hash_map.AutoHashMapUnmanaged(NodeId, *Scope) = .empty,

    pub fn debugDump(self: *const Scope) []const *const Symbol {
        return self.symbols.items;
    }

    pub fn init(parent: ?*Scope) Scope {
        return .{
            .parent = parent,
        };
    }

    pub fn deinit(self: *Scope, gpa: std.mem.Allocator) void {
        self.variables.deinit(gpa);
        self.tasks.deinit(gpa);
        self.groups.deinit(gpa);

        for (self.symbols.items) |item| {
            gpa.free(item);
        }

        self.symbols.deinit(gpa);
    }

    pub fn put_child(self: *Scope, allocator: std.mem.Allocator, node_id: NodeId, scope: *Scope) !void {
        try self.children.putNoClobber(allocator, node_id, scope);
    }

    pub fn child(self: *const Scope, node_id: NodeId) ?*Scope {
        return self.children.get(node_id);
    }

    pub fn define(self: *Scope, gpa: std.mem.Allocator, symbol: Symbol) !void {
        const index = self.symbols.items.len;

        const ptr = try gpa.create(Symbol);
        errdefer gpa.destroy(ptr);
        ptr.* = symbol;

        const symbol_type = symbol.typeOf();

        // symbol cannot ever be redefined
        std.debug.assert(self.resolveLocal(symbol.name, symbol_type) == null);

        switch (symbol_type) {
            .variable => {
                try self.variables.putNoClobber(gpa, symbol.name, index);
            },
            .task => {
                try self.tasks.putNoClobber(gpa, symbol.name, index);
            },
            .group => {
                try self.groups.putNoClobber(gpa, symbol.name, index);
            },
        }

        try self.symbols.append(gpa, ptr);
    }

    pub fn resolveLocal(self: *const Scope, name: []const u8, symbol_type: Symbol.Type) ?*Symbol {
        const index = switch (symbol_type) {
            .variable => self.variables.get(name),
            .task => self.tasks.get(name),
            .group => self.groups.get(name),
        };

        return if (index) |i|
            self.symbols.items[i]
        else
            null;
    }

    pub fn resolve(self: *const Scope, name: []const u8, symbol_type: Symbol.Type) ?*Symbol {
        return self.resolveLocal(name, symbol_type) orelse
            if (self.parent) |p| p.resolve(name, symbol_type) else null;
    }

    pub fn root(self: *Scope) *Scope {
        var cur: *Scope = self;
        while (cur.parent) |parent| {
            cur = parent;
        }
        return cur;
    }

    pub fn isRoot(self: *const Scope) bool {
        return @as(*Scope, @constCast(self)).root() == self;
    }

    /// Read all tasks, including those from anonymous groups
    pub fn readTasks(self: *const Scope, allocator: std.mem.Allocator) ![]*ir.Task {
        std.debug.assert(self.isRoot());

        const out = try allocator.alloc(*ir.Task, self.tasks.count());

        for (self.tasks.values(), out) |task_idx, *o| {
            o.* = self.symbols.items[task_idx].origin.task;
        }

        return out;
    }

    /// Read all groups, excluding anonymous as these are compiled out from file scope
    pub fn readGroups(self: *const Scope, allocator: std.mem.Allocator) ![]*ir.Group {
        std.debug.assert(self.isRoot());

        const out = try allocator.alloc(*ir.Group, self.groups.count());

        for (self.groups.values(), out) |group_idx, *o| {
            o.* = self.symbols.items[group_idx].origin.group;
        }

        return out;
    }
};
