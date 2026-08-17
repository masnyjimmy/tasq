const std = @import("std");

const lib = @import("lib");

const compiler = @import("compiler");
const platform = compiler.platform;
const functions = compiler.functions;
const Type = compiler.Type;
const Value = compiler.Value;

const Interpreter = @import("interpreter.zig");

const functions_count = functions.definitions.items.len;

pub const Error = error{
    FunctionFailed,
    Abort,
} || std.mem.Allocator.Error;

const FunctionType = *const fn (*Interpreter, []const Value) Error!Value;

const handlers: [functions_count]FunctionType = .{
    handleEnv,
    handleExists,
    handleOs,
    handleStatusCode,
    handleError,
    handlePrint,
    handleToArray,
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

    self.printer.printStyled(
        self.allocator,
        .{ .fg = .bright_red },
        "{s}\n",
        .{message},
    ) catch return Error.FunctionFailed;

    return Error.Abort;
}

fn handlePrint(self: *Interpreter, args: []const Value) Error!Value {
    const message = args[0].string;

    self.printer.print(
        self.allocator,
        "{s}\n",
        .{message},
    ) catch unreachable;

    return .void;
}

fn handleToArray(self: *Interpreter, args: []const Value) Error!Value {
    const value = args[0];

    var allocator = self.currentScope().arena.allocator();

    const out_array = try allocator.dupe(Value, &.{value});

    const type_ptr = try allocator.create(Type);
    type_ptr.* = value.typeOf();

    return .{
        .list = .{
            .items_type = type_ptr,
            .items = out_array,
        },
    };
}
