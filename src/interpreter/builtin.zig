const std = @import("std");

const lib = @import("lib");

const compiler = @import("compiler");
const platform = compiler.platform;
const functions = compiler.functions;
const Type = compiler.Type;
const Value = compiler.Value;
const Scope = @import("symbol.zig").Scope;

const Interpreter = @import("interpreter.zig");

const functions_count = functions.definitions.items.len;

pub const Error = Interpreter.Error;

const FunctionType = *const fn (*Interpreter, []const Value) Error!Value;

const handlers: [functions_count]FunctionType = .{
    handleEnv,
    handleExists,
    handleOs,
    handleStatusCode,
    handleError,
    handlePrint,
    handleAny,
};

pub fn callFunction(
    interpreter: *Interpreter,
    id: functions.definitions.Id,
    args: []const Value,
) Error!Value {
    const index = @intFromEnum(id);

    const handler = handlers[index];

    return try handler(interpreter, args);
}

fn handleEnv(self: *Interpreter, args: []const Value) Error!Value {
    const key = args[0].string;
    const default = args[1].string;

    return if (self.environ.get(key)) |value| .{
        .string = value,
    } else .{
        .string = default,
    };
}

fn handleExists(self: *Interpreter, args: []const Value) Error!Value {
    const path = args[0].string;

    const cwd = std.Io.Dir.cwd();

    const access_result = cwd.access(self.io, path, .{ .read = true });

    const result: bool = if (access_result) |_|
        true
    else |_|
        false;

    return .{ .bool = result };
}

fn handleOs(_: *Interpreter, _: []const Value) Error!Value {
    return .{
        .string = @tagName(platform.tag),
    };
}

fn handleStatusCode(self: *Interpreter, _: []const Value) Error!Value {
    return .{ .number = @floatFromInt(self.status_code) };
}

fn handleError(self: *Interpreter, args: []const Value) Error!Value {
    const message = args[0].string;

    try self.printer.printStyled(
        self.allocator,
        .{ .fg = .bright_red },
        "{s}\n",
        .{message},
    );

    return Error.Abort;
}

fn handlePrint(self: *Interpreter, args: []const Value) Error!Value {
    const message = args[0].string;

    try self.printer.print(
        self.allocator,
        "{s}\n",
        .{message},
    );

    return .void;
}

fn handleAny(self: *Interpreter, args: []const Value) Error!Value {
    const list = args[0].list;

    const test_fn = args[1].lambda;

    for (list.items) |item| {
        var scope: Scope = .init(self.currentScope(), self.allocator, test_fn.scope);
        defer scope.deinit();

        lib.debug.dump(.{
            .symbol = item,
        }, 4);

        try scope.define(.{
            .name = test_fn.captures[0].name,
            .value = item,
        });

        const result = try self.evaluateExpr(&scope, &test_fn.body);

        if (result.eql(.{ .bool = true }))
            return .{ .bool = true };
    }

    return .{ .bool = false };
}
