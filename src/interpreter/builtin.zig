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

fn handleEnv(self: *Interpreter, scope: *Scope, args: []const Value) Error!Value {
    const key = args[0].string;

    return if (self.environ.get(key)) |value| makeResult(
        scope,
        &.string,
        .{ .string = value },
    ) else makeResult(scope, &.string, null);
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

fn handleAll(self: *Interpreter, scope: *Scope, args: []const Value) Error!Value {
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

        if (result.eql(.{ .bool = false }))
            return .{ .bool = false };
    }

    return .{ .bool = true };
}

fn handleReduce(self: *Interpreter, scope: *Scope, args: []const Value) Error!Value {
    const list = args[0].list;
    var value = args[1];
    const func = args[2].lambda;

    for (list.items) |item| {
        var lambda_scope = try Scope.create(scope, self.allocator, func.scope);
        defer lambda_scope.destroy();

        try lambda_scope.define(.{
            .name = func.captures[0].name,
            .value = value,
        }, false);

        try lambda_scope.define(.{
            .name = func.captures[1].name,
            .value = item,
        }, false);

        value = try self.evaluateExpr(lambda_scope, &func.body);
    }

    return value;
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

fn handleSplit(_: *Interpreter, scope: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;
    const sep = args[1].string;

    const list_size = std.mem.count(u8, str, sep);

    const items = try scope.arena.allocator().alloc(Value, list_size);

    var it = std.mem.splitSequence(u8, str, sep);

    for (items) |*item| {
        item.* = .{ .string = it.next().? };
    }

    return .{
        .list = .{
            .items_type = &.string,
            .items = items,
        },
    };
}

fn handleJoin(_: *Interpreter, scope: *Scope, args: []const Value) Error!Value {
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

fn handleLower(_: *Interpreter, scope: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;

    const out = try std.ascii.allocLowerString(scope.arena.allocator(), str);

    return .{
        .string = out,
    };
}

fn handleUpper(_: *Interpreter, scope: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;

    const out = try std.ascii.allocUpperString(scope.arena.allocator(), str);

    return .{
        .string = out,
    };
}

fn handleContains(_: *Interpreter, _: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;
    const sub = args[1].string;

    const contains = std.mem.containsAtLeast(u8, str, 1, sub);

    return .{
        .bool = contains,
    };
}

fn handleStartsWith(_: *Interpreter, _: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;
    const sub = args[1].string;

    const starts_with = std.mem.startsWith(u8, str, sub);

    return .{
        .bool = starts_with,
    };
}

fn handleEndsWith(_: *Interpreter, _: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;
    const sub = args[1].string;

    const ends_with = std.mem.endsWith(u8, str, sub);

    return .{
        .bool = ends_with,
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

fn handleParseNumber(_: *Interpreter, scope: *Scope, args: []const Value) Error!Value {
    const str = args[0].string;

    const number: ?f64 = std.fmt.parseFloat(f64, str) catch null;

    return if (number) |n|
        makeResult(scope, &.number, .{ .number = n })
    else
        makeResult(scope, &.number, null);
}
