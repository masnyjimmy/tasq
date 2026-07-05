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

pub const BuiltinHandler = struct {
    const FunctionType = fn (*Interpreter, []const Value) Error!Value;

    const handlers: [functions_count]FunctionType = .{
        handleEnv,
        handleEnvWithDefault,
        handleExists,
        handleOs,
        handleStatusCode,
    };

    interpreter: *const Interpreter,

    pub fn init(
        interpreter: *const Interpreter,
    ) BuiltinHandler {
        return .{
            .interpreter = interpreter,
        };
    }

    pub fn callFunction(
        self: *BuiltinHandler,
        id: functions.FunctionId,
        args: []const Value,
    ) !Value {
        const index = functions.getFunctionDefById(id, args.len) catch unreachable;
        const handler = handlers[index];

        return try handler(self.interpreter, args);
    }

    fn handleEnv(self: *const Interpreter, args: []const Value) !Value {
        const key = args[0].string;

        const value = if (self.environ.get(key)) |value|
            value
        else {
            self.diagnostics.Err(.runtime, "'{s}' environment variable not found", .{key}) catch unreachable;
            return Error.FunctionFailed;
        };

        return .{
            .string = .{
                .data = value,
                .owned = false,
            },
        };
    }

    fn handleEnvWithDefault(self: *const Interpreter, args: []const Value) !Value {
        const key = args[0].string;
        const default = args[1].string;

        return if (self.environ.get(key)) |value| .{
            .string = .{
                .data = value,
                .owned = false,
            },
        } else .{ .string = .{
            .data = self.allocator.dupe(u8, default) catch unreachable,
            .owned = true,
        } };
    }

    fn handleExists(self: *const Interpreter, args: []const Value) !Value {
        const path = args[0].string;

        const cwd = std.Io.Dir.cwd();

        const access_result = cwd.access(self.io, path, .{ .read = true });

        const result: bool = if (access_result) |_|
            true
        else |_|
            false;

        return .{ .bool = result };
    }

    fn handleOs(_: *const Interpreter, _: []const Value) !Value {
        return .{
            .string = .{
                .data = @tagName(platform.tag),
                .owned = false,
            },
        };
    }

    fn handleStatusCode(self: *const Interpreter, _: []const Value) !Value {
        return .{ .number = @floatFromInt(self.status_code) };
    }
};
