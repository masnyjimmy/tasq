const std = @import("std");

const lib = @import("lib");

const compiler = @import("compiler");
const ir = compiler.ir;

const CallStack = @This();

pub const State = struct {
    task: *const ir.Task,
    block: *const ir.StatementBlock,

    pos: usize,
};

stack: std.ArrayList(*State),
current: ?*State,

pub fn init(allocator: std.mem.Allocator, task: ?*ir.Task) CallStack {
    var out: CallStack = .{
        .stack = .empty,
        .current = null,
    };

    if (task) |t| {
        out.push(allocator, t, &t.body) catch unreachable;
    }

    return out;
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    for (self.stack.items) |item| {
        allocator.destroy(item);
    }
    self.stack.deinit(allocator);

    if (self.current) |state|
        allocator.destroy(state);
}

pub fn push(self: *CallStack, allocator: std.mem.Allocator, task: ?*ir.Task, block: *const ir.StatementBlock) !void {
    std.debug.assert(task != null or self.current != null);

    const next_task = task orelse self.current.?.task;

    const ptr = try allocator.create(State);
    errdefer allocator.destroy(ptr);

    ptr.* = .{
        .task = next_task,
        .block = block,
        .pos = 0,
    };

    if (self.current) |state|
        try self.stack.append(allocator, state);

    self.current = ptr;
}

pub fn pop(self: *CallStack, allocator: std.mem.Allocator) void {
    if (self.current) |state| {
        allocator.destroy(state);
    }

    self.current = self.stack.pop();
}

pub const AdvanceResult = union(enum) {
    statement: *const ir.Statement,
    frame_end,
};

pub fn advance(self: *CallStack, allocator: std.mem.Allocator) !?AdvanceResult {
    const state = self.current orelse return null;

    if (state.pos >= state.block.statements.len) {
        self.pop(allocator);
        return .frame_end;
    }

    defer state.pos += 1;

    return .{
        .statement = &state.block.statements[state.pos],
    };
}

pub fn currentTask(self: *CallStack) *ir.Task {
    const state = self.current orelse {
        std.debug.panic("unable to retrieve current task, no call state", .{});
    };

    return state.task;
}

pub fn currentGroup(self: *CallStack) !?*ir.Group {
    const task = self.currentTask() catch {
        std.debug.panic("unable to retrieve group", .{});
    };

    return task.group;
}
