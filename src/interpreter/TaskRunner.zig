const std = @import("std");

const lib = @import("lib");

const compiler = @import("compiler");
const ir = compiler.ir;
const Value = compiler.Value;

const Scope = @import("Scope.zig");
const Runtime = @import("Runtime.zig");

const TaskRunner = @This();

const Key = struct {
    task: *const ir.Task,
    args: []const Value,
};

const State = enum {
    running,
    done,
};

const MapContext = struct {
    pub fn hash(_: @This(), key: Key) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        updateHasher(.from(&hasher), key);
        return hasher.final();
    }

    pub fn eql(_: @This(), a: Key, b: Key) bool {
        if (a.task != b.task)
            return false;

        if (a.args.len != b.args.len)
            return false;

        for (a.args, b.args) |l, r| {
            if (Value.eql(l, r) == false)
                return false;
        }
        return true;
    }

    pub fn updateHasher(hasher: lib.hash.Hasher, value: Key) void {
        hasher.update(std.mem.asBytes(&value.task));

        for (value.args) |arg| {
            Value.MapContext.updateHasher(hasher, arg);
        }
    }
};

run_set: std.HashMapUnmanaged(Key, State, MapContext, 80),
interpreter: *Runtime,
key_arena: std.heap.ArenaAllocator,

pub fn init(interpreter: *Runtime) TaskRunner {
    return .{
        .run_set = .empty,
        .interpreter = interpreter,
        .key_arena = .init(interpreter.allocator),
    };
}

pub fn deinit(self: *TaskRunner) void {
    self.key_arena.deinit();
    self.run_set.deinit(self.interpreter.allocator);
}

pub fn run(
    self: *TaskRunner,
    scope: *Scope,
    task: *const ir.Task,
    values: std.array_hash_map.String(Value),
    same_group: bool,
    is_dependency: bool,
) Runtime.Error!void {
    const allocator = self.interpreter.allocator;

    var key_args: std.ArrayList(Value) = .empty;
    errdefer key_args.deinit(allocator);

    const group_scope = if (task.group) |group|
        try self.createGroupScope(
            scope,
            group,
            values,
            same_group,
            &key_args,
        )
    else
        null;
    defer if (group_scope) |gs|
        gs.destroy();

    const task_scope = try self.createTaskScope(
        group_scope orelse scope,
        task,
        values,
        &key_args,
    );
    defer task_scope.destroy();

    const target_working_dir = try self.openTaskTargetDir(task);
    defer target_working_dir.close(self.interpreter.io);

    //===== update current call graph ======//

    const key: Key = .{
        .task = task,
        .args = key_args.items,
    };

    if (self.run_set.get(key)) |state| switch (state) {
        .running => std.debug.panic(
            \\internal error: task '{s}' re-entered while still running;
            \\dependency cycles should have been rejected at compile time.
        ,
            .{task.name},
        ),
        .done => if (is_dependency) {
            return;
        },
    };
    try self.run_set.put(allocator, key, .running);

    for (task.dependecies) |*dep| {
        try self.handleDependency(target_working_dir, task_scope, dep);
    }

    const task_body_scope = try Scope.create(
        task_scope,
        self.interpreter.allocator,
        task.body.scope,
    );
    defer task_body_scope.destroy();

    try self.interpreter.runBlock(target_working_dir, task_body_scope, task.body.statements);

    try self.run_set.put(allocator, key, .done);
}

fn handleDependency(
    self: *TaskRunner,
    cwd: std.Io.Dir,
    scope: *Scope,
    call: *const ir.TaskCall,
) Runtime.Error!void {
    const allocator = self.interpreter.allocator;
    var it = call.args.iterator();

    var values: std.array_hash_map.String(Value) = .empty;
    defer values.deinit(allocator);

    while (it.next()) |arg| {
        const value = switch (arg.value_ptr.*) {
            .default => |def| def,
            .value => |*expr| try self.interpreter.evaluateExpr(cwd, scope, expr),
        };

        try values.put(
            allocator,
            arg.key_ptr.*,
            value,
        );
    }

    try self.run(
        scope,
        call.task,
        values,
        call.same_group,
        true,
    );
}

fn openTaskTargetDir(self: *TaskRunner, task: *const ir.Task) !std.Io.Dir {
    const allocator = self.interpreter.allocator;

    const group_working_dir: ?[]const u8 = blk: {
        const group = task.group orelse break :blk null;
        break :blk group.cwd;
    };

    if (group_working_dir == null and task.cwd == null)
        return try self.interpreter.cwd.openDir(
            self.interpreter.io,
            ".",
            .{},
        );

    const path = try std.fs.path.join(
        allocator,
        &.{
            group_working_dir orelse "",
            task.cwd orelse "",
        },
    );
    defer allocator.free(path);

    return try self.interpreter.cwd.openDir(
        self.interpreter.io,
        path,
        .{},
    );
}

fn createTaskScope(
    self: *TaskRunner,
    scope: *Scope,
    task: *const ir.Task,
    values: std.array_hash_map.String(Value),
    key_args: *std.ArrayList(Value),
) !*Scope {
    const allocator = self.interpreter.allocator;

    const task_scope = try Scope.create(
        scope,
        allocator,
        task.scope,
    );
    errdefer task_scope.destroy();

    for (task.args) |arg| {
        const value = values.get(arg.name) orelse arg.default orelse {
            std.debug.panic(
                \\internal error: missing argument '{s}';
                \\this should have been caught during IR validation.
            ,
                .{arg.name},
            );
        };
        try self.addKeyArg(key_args, value);
        try task_scope.define(arg, .{
            .name = arg.name,
            .value = try value.clone(task_scope.arena.allocator()),
        }, false);
    }

    for (task.envs) |env| {
        try task_scope.environ.put(
            env.key,
            env.value,
        );
    }

    return task_scope;
}

fn createGroupScope(
    self: *TaskRunner,
    scope: *Scope,
    group: *const ir.Group,
    values: std.array_hash_map.String(Value),
    same_group: bool,
    key_args: *std.ArrayList(Value),
) !*Scope {
    const allocator = self.interpreter.allocator;

    const parent_scope = blk: {
        if (same_group) break :blk scope.findByStatic(group.scope);
        break :blk if (group.scope.parent) |p| scope.findByStatic(p) else scope.root();
    };
    const group_scope = try Scope.create(parent_scope, allocator, group.scope);
    errdefer group_scope.destroy();

    for (group.args) |arg| {
        const value = blk: {
            if (values.get(arg.name)) |v|
                break :blk v;

            if (same_group == false) {
                if (arg.default) |v|
                    break :blk v;

                std.debug.panic(
                    \\internal error: missing argument '{s}';
                    \\this should have been caught during IR validation.
                ,
                    .{arg.name},
                );
            }

            if (group_scope.resolve(arg)) |symbol|
                break :blk symbol.value;

            if (arg.default) |v|
                break :blk v;

            std.debug.panic(
                \\internal error: missing argument '{s}';
                \\this should have been caught during IR validation.
            ,
                .{arg.name},
            );
        };
        try self.addKeyArg(key_args, value);
        try group_scope.define(arg, .{
            .name = arg.name,
            .value = try value.clone(group_scope.arena.allocator()),
        }, same_group);
    }

    return group_scope;
}

fn addKeyArg(self: *TaskRunner, key_args: *std.ArrayList(Value), value: Value) Runtime.Error!void {
    const allocator = self.key_arena.allocator();

    try key_args.append(
        allocator,
        try value.clone(allocator),
    );
}
