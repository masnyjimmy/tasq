const std = @import("std");

const lib = @import("lib");

const compiler = @import("compiler");
const platform = compiler.platform;
const functions = compiler.functions;
const typing = compiler.typing;
const Value = typing.Value;

const Interpreter = @import("interpreter.zig");

const functions_count = functions.function_defs.len;

pub const Error = error{
    FunctionFailed,
};

const FunctionType = *const fn (*const Interpreter, []const Value) Error!Value;

const handlers: [functions_count]FunctionType = .{
    handleEnv,
    handleEnvWithDefault,
    handleExists,
    handleOs,
    handleStatusCode,
};

pub fn callFunction(
    interpreter: *const Interpreter,
    id: functions.FunctionId,
    args: []const Value,
) Error!Value {
    const index = functions.getFunctionIndex(id, args.len) catch unreachable;
    const handler = handlers[index];

    return try handler(interpreter, args);
}

fn handleEnv(self: *const Interpreter, args: []const Value) Error!Value {
    const key = args[0].string;

    const value = if (self.environ.get(key)) |value|
        value
    else {
        self.printer.printStyled(
            self.allocator,
            .{ .fg = .red },
            "'{s}' environment variable not found",
            .{key},
        ) catch unreachable;
        return Error.FunctionFailed;
    };

    return .{ .string = value };
}

fn handleEnvWithDefault(self: *const Interpreter, args: []const Value) Error!Value {
    const key = args[0].string;
    const default = args[1].string;

    return if (self.environ.get(key)) |value| .{
        .string = value,
    } else .{ .string = default };
}

fn handleExists(self: *const Interpreter, args: []const Value) Error!Value {
    const path = args[0].string;

    const cwd = std.Io.Dir.cwd();

    const access_result = cwd.access(self.io, path, .{ .read = true });

    const result: bool = if (access_result) |_|
        true
    else |_|
        false;

    return .{ .bool = result };
}

fn handleOs(_: *const Interpreter, _: []const Value) Error!Value {
    return .{
        .string = @tagName(platform.tag),
    };
}

fn handleStatusCode(self: *const Interpreter, _: []const Value) Error!Value {
    return .{ .number = @floatFromInt(self.status_code) };
}
