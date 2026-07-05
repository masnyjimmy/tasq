const std = @import("std");
const ir = @import("ir.zig");

const sym = @import("symbol.zig");
const Symbol = sym.Symbol;

pub const Scope = struct {
    // pub const Kind = enum {
    //     file,
    //     group,
    //     task,
    // };

    const IndexesStorage = std.array_hash_map.String(usize);

    parent: ?*Scope,
    // kind: Kind,
    // symbols
    symbols: std.ArrayList(Symbol) = .empty,
    // indexes
    variables: IndexesStorage = .empty,
    tasks: IndexesStorage = .empty,
    groups: IndexesStorage = .empty,

    pub fn debugDump(_: *const Scope) []const u8 {
        return "<scope>";
    }
    pub fn init(parent: ?*Scope) Scope {
        return .{
            .parent = parent,
        };
    }

    pub fn deinit(self: *Scope, gpa: std.mem.Allocator) void {
        self.symbols.deinit(gpa);
    }

    pub fn define(self: *Scope, gpa: std.mem.Allocator, symbol: Symbol) !void {
        const index = self.symbols.items.len;

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

        try self.symbols.append(gpa, symbol);
    }

    var one = false;
    pub fn resolveLocal(self: *const Scope, name: []const u8, symbol_type: Symbol.Type) ?*Symbol {
        const index = switch (symbol_type) {
            .variable => self.variables.get(name),
            .task => self.tasks.get(name),
            .group => self.groups.get(name),
        };

        return if (index) |i|
            &self.symbols.items[i]
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
            o.* = self.symbols.items[task_idx].details.task.origin;
        }

        return out;
    }

    /// Read all groups, excluding anonymous as these are compiled out from file scope
    pub fn readGroups(self: *const Scope, allocator: std.mem.Allocator) ![]*ir.Group {
        std.debug.assert(self.isRoot());

        const out = try allocator.alloc(*ir.Group, self.groups.count());

        for (self.groups.values(), out) |group_idx, *o| {
            o.* = self.symbols.items[group_idx].details.group.origin;
        }

        return out;
    }
};
