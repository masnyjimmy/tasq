const std = @import("std");

const compiler = @import("compiler");
const ir = compiler.ir;
const static_symbol = compiler.symbol;
const static_scope = compiler.scope;

const Value = compiler.Value;

const Scope = @This();

pub const Symbol = struct {
    name: []const u8,
    value: Value,
};

const Identity = static_symbol.Symbol.Origin.Identity;

const SymbolMap = std.hash_map.AutoHashMapUnmanaged(Identity, Symbol);
const PendingMap = std.hash_map.AutoHashMapUnmanaged(*const ir.Decl, *std.Io.Event);

parent: ?*Scope,
static: *static_scope.Scope,
/// Guards `symbols` and `pending`. Never held while evaluating anything.
mutex: std.Io.Mutex = .init,
symbols: SymbolMap = .empty,
/// Static declarations that are being evaluated right now, with the event their waiters sleep on.
pending: PendingMap = .empty,
arena: std.heap.ArenaAllocator,
environ: Environ,

status_code: std.atomic.Value(u8) = .init(0),

pub fn create(parent: ?*Scope, allocator: std.mem.Allocator, ss: *static_scope.Scope) !*Scope {
    const ptr = try allocator.create(Scope);
    errdefer allocator.destroy(ptr);

    ptr.* = .{
        .parent = parent,
        .arena = .init(allocator),
        .static = ss,
        .environ = if (parent) |p|
            .initRef(&p.environ)
        else
            .init(allocator),
    };
    return ptr;
}

pub fn setStatusCode(self: *Scope, code: u8) void {
    self.status_code.store(code, .release);
}

pub fn statusCode(self: *Scope) u8 {
    return self.status_code.load(.acquire);
}

/// Only call this after every thread that uses the scope has joined, so no locking is needed.
pub fn destroy(self: *Scope) void {
    const allocator = self.arena.child_allocator;
    if (self.parent) |p|
        p.setStatusCode(self.statusCode());

    self.arena.deinit();
    self.environ.deinit();
    allocator.destroy(self);
}

pub fn define(self: *Scope, io: std.Io, identity: Identity, symbol: Symbol, can_replace: bool) !void {
    const dest = self.resolveDestScope(symbol.name);

    dest.mutex.lockUncancelable(io);
    defer dest.mutex.unlock(io);

    std.debug.assert(can_replace or !dest.symbols.contains(identity));
    // the map belongs to `dest`, so it must grow in `dest`'s arena
    try dest.symbols.put(dest.arena.allocator(), identity, symbol);
}

fn resolveDestScope(self: *Scope, name: []const u8) *Scope {
    var current: ?*Scope = self;
    while (current) |c| : (current = c.parent) {
        if (c.static.resolveLocal(name, .variable) != null) return c;
    } else unreachable;
}

pub fn clearSymbols(self: *Scope, io: std.Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.symbols.clearRetainingCapacity();
}

/// Returns a copy: a pointer into the map would dangle as soon as another thread grows it.
pub fn resolve(self: *Scope, io: std.Io, identity: Identity) ?Symbol {
    var current: ?*Scope = self;
    while (current) |c| : (current = c.parent) {
        c.mutex.lockUncancelable(io);
        const found = c.symbols.get(identity);
        c.mutex.unlock(io);

        if (found) |symbol| return symbol;
    }
    return null;
}

pub const Begin = union(enum) {
    /// Already evaluated: read it with `resolve`.
    done,
    /// The caller must evaluate the declaration and then call `endStatic`.
    owner,
    /// Someone else is evaluating it: wait on the event, then try again.
    wait: *std.Io.Event,
};

/// Called on the scope that declares `decl`. The "already defined" check and the claim happen in
/// one critical section, so a thread that missed a moment ago cannot claim a finished declaration.
pub fn beginStatic(self: *Scope, io: std.Io, decl: *const ir.Decl, identity: Identity) !Begin {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.symbols.contains(identity)) return .done;

    const gop = try self.pending.getOrPut(self.arena.allocator(), decl);
    if (gop.found_existing) return .{ .wait = gop.value_ptr.* };

    const event = try self.arena.allocator().create(std.Io.Event);
    event.* = .unset;
    gop.value_ptr.* = event;
    return .owner;
}

/// Always call it after `beginStatic` returned `.owner`, on success and on failure.
pub fn endStatic(self: *Scope, io: std.Io, decl: *const ir.Decl) void {
    self.mutex.lockUncancelable(io);
    const event = if (self.pending.fetchRemove(decl)) |kv| kv.value else null;
    self.mutex.unlock(io);

    if (event) |e| e.set(io);
}

pub fn findByStatic(self: *Scope, static: *static_scope.Scope) ?*Scope {
    var curr: ?*Scope = self;
    while (curr) |c| : (curr = c.parent) {
        if (c.static == static) return c;
    }
    return null;
}

pub fn root(self: *Scope) *Scope {
    var cur: *Scope = self;
    while (cur.parent) |p| cur = p;
    return cur;
}

pub const Environ = struct {
    map: std.process.Environ.Map,
    owns: bool,

    fn init(allocator: std.mem.Allocator) Environ {
        return .{
            .map = .init(allocator),
            .owns = true,
        };
    }

    fn deinit(self: *Environ) void {
        if (self.owns) {
            self.map.deinit();
        }
    }

    fn initRef(parent: *const Environ) Environ {
        return .{
            .map = parent.map,
            .owns = false,
        };
    }

    pub fn putEnvs(self: *Environ, allocator: std.mem.Allocator, vars: []const ir.Env) !void {
        if (vars.len == 0) return;

        if (!self.owns) {
            self.map = try self.map.clone(allocator);
            self.owns = true;
        }

        for (vars) |kv| {
            try self.map.put(kv.key, kv.value);
        }
    }

    pub fn get(self: *Environ, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }
};
