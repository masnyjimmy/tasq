const std = @import("std");

const lib = @import("lib");
const Diagnostics = lib.Diagnostic.List;

const comp = @import("compiler");
const ir = comp.ir;
const Value = comp.Value;
const StaticScope = comp.scope.Scope;

const symbol_mod = @import("symbol.zig");
const Scope = symbol_mod.Scope;

const ScopeStack = @This();

const ScopeState = struct {
    group_scope: ?*Scope,
    own_group_scope: bool,
    current_scope: *Scope,
    arena: std.heap.ArenaAllocator,

    fn create(
        allocator: std.mem.Allocator,
        group_scope: ?*Scope,
        own_group_scope: bool,
        current_scope: *Scope,
    ) !*ScopeState {
        const ptr = try allocator.create(@This());
        errdefer allocator.destroy(ptr);

        ptr.* = .{
            .group_scope = group_scope,
            .own_group_scope = own_group_scope,
            .current_scope = current_scope,
            .arena = .init(allocator),
        };

        return ptr;
    }

    fn destroy(self: *ScopeState, allocator: std.mem.Allocator) void {
        if (self.group_scope) |gs| {
            if (self.own_group_scope) {
                gs.deinit(allocator);
                allocator.destroy(gs);
            }
        }
        self.current_scope.deinit(allocator);
        allocator.destroy(self.current_scope);

        allocator.destroy(self);
    }
};
diagnostics: *Diagnostics,

root: *Scope,
stack: std.ArrayList(*ScopeState),
current: ?*ScopeState,

pub fn init(allocator: std.mem.Allocator, diagnostics: *Diagnostics, task: *ir.Task, values_in: std.array_hash_map.String(Value)) !ScopeStack {
    var values = values_in;

    const root = try allocator.create(Scope);
    root.* = .init(null, task.body.scope.root());

    const group_scope: ?*Scope = blk: {
        if (task.group) |group| {
            const scope = try allocator.create(Scope);
            scope.* = .init(root, group.scope);

            try bindArgs(allocator, scope, group.args, group.name orelse "<anonymous>", &values);

            break :blk scope;
        } else {
            break :blk null;
        }
    };

    const task_scope = try allocator.create(Scope);
    task_scope.* = .init(group_scope orelse root, task.body.scope);

    try bindArgs(allocator, task_scope, task.args, task.name, &values);

    assertExhaustedAndFree(allocator, &values, task.name);

    return .{
        .diagnostics = diagnostics,
        .root = root,
        .stack = .empty,
        .current = try ScopeState.create(allocator, group_scope, true, task_scope),
    };
}

pub fn deinit(self: *ScopeStack, allocator: std.mem.Allocator) void {
    while (self.current) |_| {
        self.pop(allocator);
    }
    self.stack.deinit(allocator);

    self.root.deinit(allocator);
    allocator.destroy(self.root);
}

fn currentInnerScope(self: *ScopeStack) struct {
    scope: *Scope,
    is_group: bool,
} {
    if (self.current) |curr| {
        if (curr.group_scope) |group| {
            return .{
                .scope = group,
                .is_group = true,
            };
        }
    }

    return .{ .scope = self.root, .is_group = false };
}
pub fn pushTask(self: *ScopeStack, allocator: std.mem.Allocator, task: *ir.Task, values: std.array_hash_map.String(Value)) !void {
    defer values.deinit(allocator);

    const inner = self.currentInnerScope();

    const scope = try allocator.create(Scope);
    scope.* = .init(inner.scope, task.body.scope);

    try bindArgs(allocator, scope, task.args, task.name, &values);

    assertExhaustedAndFree(&values, task.name);

    try self.push(
        allocator,
        try ScopeState.create(allocator, if (inner.is_group) inner.scope else null, false, scope),
    );
}
pub fn pushTaskWithGroup(
    self: *ScopeStack,
    allocator: std.mem.Allocator,
    group: *ir.Group,
    task: *ir.Task,
    values: std.array_hash_map.String(Value),
) !void {
    const gs = try allocator.create(Scope);
    gs.* = .init(self.root, group.scope);

    try bindArgs(allocator, gs, group.args, group.name orelse "<anonymous>", &values);

    const ts = try allocator.create(Scope);
    ts.* = .init(gs, task.body.scope);

    try bindArgs(allocator, ts, task.args, task.name, &values);

    assertExhaustedAndFree(&values, task.name);

    try self.push(allocator, ScopeState.create(
        allocator,
        gs,
        true,
        ts,
    ));
}

pub fn pushBlock(self: *ScopeStack, allocator: std.mem.Allocator, block_scope: *StaticScope) !void {
    const curr = self.current orelse unreachable;

    const scope = try allocator.create(Scope);
    scope.* = .init(curr.current_scope, block_scope);

    try self.push(allocator, try ScopeState.create(
        allocator,
        curr.group_scope,
        false,
        scope,
    ));
}

fn push(self: *ScopeStack, allocator: std.mem.Allocator, state: *ScopeState) !void {
    if (self.current) |c| {
        try self.stack.append(allocator, c);
    }

    self.current = state;
}

pub fn pop(self: *ScopeStack, allocator: std.mem.Allocator) void {
    if (self.current) |current| {
        current.destroy(allocator);
    }

    self.current = self.stack.pop();
}

fn assertCurrentState(self: *ScopeStack) *ScopeState {
    return self.current.?;
}

pub fn assertCurrentScope(self: *ScopeStack) *Scope {
    return self.assertCurrentState().current_scope;
}

pub fn currentScopeAllocator(self: *ScopeStack) std.mem.Allocator {
    return self.assertCurrentState().arena.allocator();
}

fn bindArgs(allocator: std.mem.Allocator, scope: *Scope, args: []*ir.Argument, name: []const u8, values: *std.array_hash_map.String(Value)) !void {
    for (args) |arg| {
        const kv = values.fetchSwapRemove(arg.name) orelse {
            std.debug.panic(
                "internal error: missing argument '{s}' for '{s}' at runtime; " ++
                    "this should have been caught during IR validation",
                .{ arg.name, name },
            );
        };

        try scope.define(allocator, .{ .name = arg.name, .value = kv.value });
    }
}

fn assertExhaustedAndFree(allocator: std.mem.Allocator, values: *std.array_hash_map.String(Value), name: []const u8) void {
    if (values.count() != 0) {
        std.debug.panic(
            "internal error: {d} unexpected value(s) left over for '{s}' at runtime; " ++
                "this should have been caught during IR validation",
            .{ values.count(), name },
        );
    }
    values.clearAndFree(allocator);
}
