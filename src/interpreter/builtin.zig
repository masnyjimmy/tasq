const std = @import("std");

const lib = @import("lib");
const program = lib.program;

const compiler = @import("compiler");
const platform = compiler.platform;
const functions = compiler.functions;
const Type = compiler.Type;
const ir = compiler.ir;
const Value = compiler.Value;
const Scope = @import("Scope.zig");

const Interpreter = @import("interpreter.zig");

const functions_count = functions.definitions.items.len;

pub const Error = Interpreter.Error;

const Handler = *const fn (*Interpreter, cwd: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value;

const handlers: [functions_count]Handler = .{
    handleError,
    handlePrint,
    handleParseNumber,
    handleExists,
    handleLen,
    handleSplit,
    handleJoin,
    handleLower,
    handleUpper,
    handleContains,
    handleStartsWith,
    handleEndsWith,
    handleReplaceString,
    handleLen,
    handleReplaceList,
    handleAny,
    handleAll,
    handleReduce,
    handleEnv,
    handleOs,
    handleStatusCode,
    handleWhich,
};

pub fn callFunction(
    interpreter: *Interpreter,
    cwd: std.Io.Dir,
    scope: *Scope,
    id: functions.definitions.Id,
    args: []const Value,
) Error!Value {
    const index = @intFromEnum(id);

    const handler = handlers[index];

    return try handler(interpreter, cwd, scope, args);
}

pub fn makeResult(scope: *Scope, result_type: *const Type, value: ?Value) Error!Value {
    if (value) |v| {
        const ptr = try scope.arena.allocator().create(Value);
        ptr.* = try v.clone(scope.arena.allocator());

        return .{
            .result = .{
                .type = result_type,
                .value = ptr,
            },
        };
    }

    return .{
        .result = .{
            .type = result_type,
            .value = null,
        },
    };
}

fn handleEnv(_: *Interpreter, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
    const key = args[0].string;

    return if (scope.environ.get(key)) |value| makeResult(
        scope,
        &.string,
        .{ .string = value },
    ) else makeResult(scope, &.string, null);
}

fn handleExists(self: *Interpreter, cwd: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
    const path = args[0].string;

    const access_result = cwd.access(self.io, path, .{ .read = true });

    const result: bool = if (access_result) |_|
        true
    else |_|
        false;

    return .{ .bool = result };
}

fn handleOs(_: *Interpreter, _: std.Io.Dir, _: *Scope, _: []const Value) Error!Value {
    return .{
        .string = @tagName(platform.tag),
    };
}

fn handleStatusCode(self: *Interpreter, _: std.Io.Dir, _: *Scope, _: []const Value) Error!Value {
    return .{ .number = @floatFromInt(self.status_code) };
}

fn handleWhich(self: *Interpreter, cwd: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
    const name = args[0].string;

    const result = try program.which(
        self.allocator,
        cwd,
        self.io,
        &scope.environ,
        name,
    );

    // move path to scope memory,
    const value: ?Value = blk: {
        if (result) |path| {
            defer self.allocator.free(path);
            break :blk .{
                .string = try scope.arena.allocator().dupe(u8, path),
            };
        }
        break :blk null;
    };

    return makeResult(
        scope,
        &.string,
        value,
    );
}

fn handleError(self: *Interpreter, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
    const message = args[0].string;

    try self.printer.printStyled(
        self.allocator,
        .{ .fg = .bright_red },
        "{s}\n",
        .{message},
    );

    return Error.Abort;
}

fn handlePrint(self: *Interpreter, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
    const message = args[0].string;

    try self.printer.print(
        self.allocator,
        "{s}\n",
        .{message},
    );

    return .void;
}

fn callLambda(
    self: *Interpreter,
    cwd: std.Io.Dir,
    scope: *Scope,
    lambda: *const ir.LambdaInstance,
    args: []const Value,
) Error!Value {
    std.debug.assert(args.len == lambda.params.len);

    const parent_scope = scope.findByStatic(lambda.template.parent_scope) orelse unreachable;

    const lambda_scope = try Scope.create(
        parent_scope,
        self.allocator,
        lambda.scope,
    );
    defer lambda_scope.destroy();

    for (lambda.params, args) |*param, arg| {
        try lambda_scope.define(
            param,
            .{
                .name = param.name,
                .value = arg,
            },
            false,
        );
    }

    return try self.evaluateExpr(
        cwd,
        lambda_scope,
        &lambda.body,
    );
}

fn handleAny(self: *Interpreter, cwd: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
    const list = args[0].list;

    const test_fn = args[1].lambda.instance;

    for (list.items) |item| {
        const result = try callLambda(
            self,
            cwd,
            scope,
            test_fn,
            &.{
                item,
            },
        );

        if (result.eql(.{ .bool = true }))
            return .{ .bool = true };
    }

    return .{ .bool = false };
}

fn handleAll(self: *Interpreter, cwd: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
    const list = args[0].list;

    const test_fn = args[1].lambda.instance;

    for (list.items) |item| {
        const result = try callLambda(
            self,
            cwd,
            scope,
            test_fn,
            &.{item},
        );

        if (result.eql(.{ .bool = false }))
            return .{ .bool = false };
    }

    return .{ .bool = true };
}

fn handleReduce(self: *Interpreter, cwd: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
    const list = args[0].list;
    var value = args[1];
    const func = args[2].lambda.instance;

    for (list.items) |item| {
        value = try callLambda(
            self,
            cwd,
            scope,
            func,
            &.{ value, item },
        );
    }

    return value;
}

fn handleLen(_: *Interpreter, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
    const length = switch (args[0]) {
        .string => |str| str.len,
        .list => |list| list.items.len,
        else => unreachable,
    };

    return .{
        .number = @floatFromInt(length),
    };
}

fn handleSplit(_: *Interpreter, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;
    const sep = args[1].string;

    const list_size = std.mem.count(u8, str, sep) + 1;

    var items: std.ArrayList(Value) = try .initCapacity(
        scope.arena.allocator(),
        list_size,
    );

    var it = std.mem.splitSequence(u8, str, sep);

    while (it.next()) |item| {
        items.appendAssumeCapacity(.{
            .string = item,
        });
    }

    return .{
        .list = .{
            .items_type = &.string,
            .items = items.toOwnedSliceAssert(),
        },
    };
}

fn handleJoin(_: *Interpreter, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
    const strings = args[0].list;
    const sep = args[1].string;

    const string_size = blk: {
        var total: usize = 0;

        for (strings.items) |item| {
            total = item.string.len;
        }

        break :blk total + ((strings.items.len - 1) * sep.len);
    };

    const string = try scope.arena.allocator().alloc(u8, string_size);

    var fw = std.Io.Writer.fixed(string);

    for (strings.items, 0..) |item, idx| {
        try fw.writeAll(item.string);

        if (idx != strings.items.len - 1) {
            try fw.writeAll(sep);
        }
    }

    std.debug.assert(fw.buffered().len == string.len);

    return .{
        .string = string,
    };
}

fn handleLower(_: *Interpreter, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;

    const out = try std.ascii.allocLowerString(scope.arena.allocator(), str);

    return .{
        .string = out,
    };
}

fn handleUpper(_: *Interpreter, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;

    const out = try std.ascii.allocUpperString(scope.arena.allocator(), str);

    return .{
        .string = out,
    };
}

fn handleContains(_: *Interpreter, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;
    const sub = args[1].string;

    const contains = std.mem.containsAtLeast(u8, str, 1, sub);

    return .{
        .bool = contains,
    };
}

fn handleStartsWith(_: *Interpreter, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;
    const sub = args[1].string;

    const starts_with = std.mem.startsWith(u8, str, sub);

    return .{
        .bool = starts_with,
    };
}

fn handleEndsWith(_: *Interpreter, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;
    const sub = args[1].string;

    const ends_with = std.mem.endsWith(u8, str, sub);

    return .{
        .bool = ends_with,
    };
}
fn handleReplaceString(_: *Interpreter, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
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

fn handleReplaceList(_: *Interpreter, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
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

fn handleParseNumber(_: *Interpreter, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;

    const number: ?f64 = std.fmt.parseFloat(f64, str) catch null;

    return if (number) |n|
        makeResult(scope, &.number, .{ .number = n })
    else
        makeResult(scope, &.number, null);
}
