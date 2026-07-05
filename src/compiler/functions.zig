const std = @import("std");
const ir = @import("ir.zig");

const lib = @import("lib");

const typing = @import("typing.zig");
const Type = typing.Type;

pub const FunctionId = enum {
    status_code,
    env,
    exists,
    os,
};

fn getFunctionId(name: []const u8) ?FunctionId {
    const map = std.StaticStringMap(FunctionId).initComptime(.{
        .{ "statusCode", .status_code },
        .{ "env", .env },
        .{ "exists", .exists },
        .{ "os", .os },
    });

    return map.get(name);
}

const FunctionDefinition = struct {
    const Arg = struct { []const u8, Type };

    id: FunctionId,
    args: []const Arg,
    return_type: Type,
};

fn define(comptime id: FunctionId, comptime args: []const FunctionDefinition.Arg, comptime return_type: Type) FunctionDefinition {
    return .{
        .id = id,
        .args = args,
        .return_type = return_type,
    };
}

pub const function_defs = [_]FunctionDefinition{
    define(.env, &.{
        .{ "key", Type.string },
    }, .string),
    define(.env, &.{
        .{ "key", Type.string },
        .{ "default", Type.string },
    }, .string),
    define(.exists, &.{
        .{ "path", Type.string },
    }, .bool),
    define(.os, &.{}, .string),
    define(.status_code, &.{}, .number),
};

fn validateFunctionDefinitions() void {
    inline for (function_defs, 0..) |a, i| {
        inline for (function_defs[i + 1 ..], i + 1..) |b, j| {
            if (a.id == b.id and a.args.len == b.args.len) {
                @compileError(std.fmt.comptimePrint(
                    "Duplicate overload for function {any} with {} arguments (indexes {} and {})",
                    .{ a.id, a.args.len, i, j },
                ));
            }
        }
    }
}

comptime {
    validateFunctionDefinitions();
}

pub const Error = error{
    UnknownFunction,
    InvalidArguments,
};

pub fn getFunctionDef(name: []const u8, args_num: usize) Error!FunctionDefinition {
    const id = getFunctionId(name) orelse return Error.UnknownFunction;

    return try getFunctionDefById(id, args_num);
}

pub fn getFunctionIndex(id: FunctionId, args_num: usize) Error!usize {
    inline for (function_defs, 0..) |def, idx| {
        if (def.id == id and def.args.len == args_num) {
            return idx;
        }
    }

    return Error.InvalidArguments;
}

pub fn getFunctionDefById(id: FunctionId, args_num: usize) Error!FunctionDefinition {
    const index = try getFunctionIndex(id, args_num);
    return function_defs[index];
}
