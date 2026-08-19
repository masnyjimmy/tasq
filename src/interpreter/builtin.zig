const std = @import("std");

const lib = @import("lib");

const compiler = @import("compiler");
const platform = compiler.platform;
const functions = compiler.functions;
const Type = compiler.Type;
const Value = compiler.Value;
const Scope = @import("Scope.zig");

const Interpreter = @import("interpreter.zig");

const functions_count = functions.definitions.items.len;

pub const Error = Interpreter.Error;

const FunctionType = *const fn (*Interpreter, scope: *Scope, []const Value) Error!Value;

const handlers: [functions_count]FunctionType = .{
    handleEnv,
    handleExists,
    handleOs,
    handleStatusCode,
    handleError,
    handlePrint,
    handleAny,
    handleLen,
    handleLen,
    handleReplaceString,
    handleReplaceList,
};

pub fn callFunction(
    interpreter: *Interpreter,
    scope: *Scope,
    id: functions.definitions.Id,
    args: []const Value,
) Error!Value {
    const index = @intFromEnum(id);

    const handler = handlers[index];

    return try handler(interpreter, scope, args);
}

fn handleEnv(self: *Interpreter, _: *Scope, args: []const Value) Error!Value {
    const key = args[0].string;
    const default = args[1].string;

    return if (self.environ.get(key)) |value| .{
        .string = value,
    } else .{
        .string = default,
    };
}

fn handleExists(self: *Interpreter, _: *Scope, args: []const Value) Error!Value {
    const path = args[0].string;

    const cwd = std.Io.Dir.cwd();

    const access_result = cwd.access(self.io, path, .{ .read = true });

    const result: bool = if (access_result) |_|
        true
    else |_|
        false;

    return .{ .bool = result };
}

fn handleOs(_: *Interpreter, _: *Scope, _: []const Value) Error!Value {
    return .{
        .string = @tagName(platform.tag),
    };
}

fn handleStatusCode(self: *Interpreter, _: *Scope, _: []const Value) Error!Value {
    return .{ .number = @floatFromInt(self.status_code) };
}

fn handleError(self: *Interpreter, _: *Scope, args: []const Value) Error!Value {
    const message = args[0].string;

    try self.printer.printStyled(
        self.allocator,
        .{ .fg = .bright_red },
        "{s}\n",
        .{message},
    );

    return Error.Abort;
}

fn handlePrint(self: *Interpreter, _: *Scope, args: []const Value) Error!Value {
    const message = args[0].string;

    try self.printer.print(
        self.allocator,
        "{s}\n",
        .{message},
    );

    return .void;
}

fn handleAny(self: *Interpreter, scope: *Scope, args: []const Value) Error!Value {
    const list = args[0].list;

    const test_fn = args[1].lambda;

    for (list.items) |item| {
        var lambda_scope = try Scope.create(scope, self.allocator, test_fn.scope);
        defer lambda_scope.destroy();

        try lambda_scope.define(.{
            .name = test_fn.captures[0].name,
            .value = item,
        }, false);

        const result = try self.evaluateExpr(lambda_scope, &test_fn.body);

        if (result.eql(.{ .bool = true }))
            return .{ .bool = true };
    }

    return .{ .bool = false };
}

fn handleLen(_: *Interpreter, _: *Scope, args: []const Value) Error!Value {
    const length = switch (args[0]) {
        .string => |str| str.len,
        .list => |list| list.items.len,
        else => unreachable,
    };

    return .{
        .number = @floatFromInt(length),
    };
}

fn handleReplaceString(_: *Interpreter, scope: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;
    const old = args[1].string;
    const new = args[2].string;

    const replaced = try std.mem.replaceOwned(
        u8,
        scope.arena.allocator(),
        str,
        old,
        new,
    );

    return .{
        .string = replaced,
    };
}

fn handleReplaceList(_: *Interpreter, scope: *Scope, args: []const Value) Error!Value {
    const list = args[0].list;
    const old = args[1];
    const new = args[2];

    const replaced = try scope.arena.allocator().dupe(Value, list.items);

    for (replaced) |*item| {
        if (item.eql(old)) {
            item.* = try new.clone(scope.arena.allocator());
        }
    }

    return .{
        .list = .{
            .items = replaced,
            .items_type = list.items_type,
        },
    };
}
