const std = @import("std");

const compiler = @import("compiler");
const static_symbol = compiler.symbol;
const static_scope = compiler.scope;

const Value = compiler.Value;

const Scope = @This();

pub const Symbol = struct {
    name: []const u8,
    value: Value,
};

const Identity = static_symbol.Origin.Identity;

const SymbolMap = std.hash_map.AutoHashMapUnmanaged(Identity, Symbol);

parent: ?*Scope,
static: *static_scope.Scope,
symbols: SymbolMap = .empty,
arena: std.heap.ArenaAllocator,
environ: std.process.Environ.Map,

pub fn create(parent: ?*Scope, allocator: std.mem.Allocator, ss: *static_scope.Scope) !*Scope {
    const ptr = try allocator.create(Scope);
    ptr.* = .{
        .parent = parent,
        .arena = .init(allocator),
        .static = ss,
        .environ = if (parent) |p|
            try p.environ.clone(allocator)
        else
            .init(allocator),
    };
    return ptr;
}

pub fn destroy(self: *Scope) void {
    var allocator = self.arena.child_allocator;
    self.arena.deinit();
    self.environ.deinit();
    allocator.destroy(self);
}

pub fn define(self: *Scope, identity: Identity, symbol: Symbol, can_replace: bool) !void {
    std.debug.assert(self.static.resolve(symbol.name, .variable) != null);
    std.debug.assert(can_replace or self.symbols.contains(identity) == false);

    try self.symbols.put(self.arena.allocator(), identity, symbol);
}

pub fn resolve(self: *Scope, identity: Identity) ?*Symbol {
    return self.symbols.getPtr(identity) orelse if (self.parent) |p|
        p.resolve(identity)
    else
        null;
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
