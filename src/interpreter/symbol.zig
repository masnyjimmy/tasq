const std = @import("std");
const static_scope = @import("compiler").scope;

const compiler = @import("compiler");

const Value = compiler.Value;

pub const Symbol = struct {
    name: []const u8,
    value: Value,
};

pub const Scope = struct {
    parent: ?*Scope,
    static: *static_scope.Scope,
    symbols: std.StringHashMapUnmanaged(Symbol) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn init(parent: ?*Scope, allocator: std.mem.Allocator, ss: *static_scope.Scope) Scope {
        return .{
            .parent = parent,
            .arena = .init(allocator),
            .static = ss,
        };
    }

    pub fn deinit(self: *Scope) void {
        self.arena.deinit();
    }

    pub fn define(self: *Scope, symbol: Symbol) !void {
        std.debug.assert(self.symbols.contains(symbol.name) == false);
        std.debug.assert(self.static.resolveLocal(symbol.name, .variable) != null);

        try self.symbols.put(self.arena.allocator(), symbol.name, symbol);
    }

    pub fn resolve(self: *Scope, name: []const u8) ?*Symbol {
        return self.symbols.getPtr(name) orelse if (self.parent) |p| p.resolve(name) else null;
    }

    pub fn findByStatic(self: *Scope, static: *static_scope.Scope) ?*Scope {
        var curr: ?*Scope = self;

        while (curr) |c| {
            if (c.static == static)
                return c;

            curr = c.parent;
        }

        return null;
    }

    pub fn root(self: *Scope) *Scope {
        var cur: *Scope = self;
        while (cur.parent) |p| {
            cur = p;
        }
        return cur;
    }
};
