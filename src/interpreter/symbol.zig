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

    pub fn init(parent: ?*Scope, ss: *static_scope.Scope) Scope {
        return .{ .parent = parent, .static = ss };
    }

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        var iter = self.symbols.valueIterator();

        while (iter.next()) |sym| {
            sym.value.deinit(allocator);
        }

        self.symbols.deinit(allocator);
    }

    pub fn define(self: *Scope, allocator: std.mem.Allocator, symbol: Symbol) !void {
        std.debug.assert(self.symbols.contains(symbol.name) == false);

        if (self.static.resolveLocal(symbol.name, .variable)) |_| {
            try self.symbols.put(allocator, symbol.name, symbol);
        } else if (self.parent) |p| {
            try p.define(allocator, symbol);
        } else {
            std.debug.panic("No variable named '{s}' available in this scope", .{symbol.name});
        }
    }

    pub fn resolve(self: *Scope, name: []const u8) ?*Symbol {
        return self.symbols.getPtr(name) orelse if (self.parent) |p| p.resolve(name) else null;
    }

    pub fn findByStatic(self: *Scope, static: *static_scope.Scope) ?*Scope {
        var curr: ?*Scope = self;

        while (curr) |c| {
            if (c.static == static)
                return curr;

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
