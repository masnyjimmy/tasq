const std = @import("std");

const lib = @import("lib");
const platform = lib.platform;
const program = lib.program;

const compiler = @import("compiler");
const functions = compiler.functions;
const Type = compiler.Type;
const ir = compiler.ir;
const Value = compiler.Value;
const Scope = @import("Scope.zig");

const Runtime = @import("Runtime.zig");
const globs = @import("glob.zig");

const functions_count = functions.definitions.items.len;

pub const Error = Runtime.Error;

pub fn callFunction(
    runtime: *Runtime,
    cwd: std.Io.Dir,
    scope: *Scope,
    id: functions.definitions.Id,
    args: []const Value,
) Error!Value {
    switch (id) {
        inline else => |tag| {
            const name = @tagName(tag);

            const handler: *const handlers.Signature = &@field(handlers, name);

            return handler(runtime, cwd, scope, args);
        },
    }
}

pub fn makeResult(scope: *Scope, result_type: *const Type, value: ?Value) Error!Value {
    std.debug.assert(result_type.* != .result);

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

fn callLambda(
    self: *Runtime,
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
        _ = try self.destructure(
            ir.Capture,
            cwd,
            lambda_scope,
            param.target,
            arg,
            null,
        );
    }

    return try self.evaluateExpr(
        cwd,
        lambda_scope,
        &lambda.body,
    );
}

const handlers = struct {
    const Signature = fn (*Runtime, cwd: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value;

    fn env(_: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const key = args[0].string;

        return if (scope.environ.get(key)) |value| makeResult(
            scope,
            &.string,
            .{ .string = value },
        ) else makeResult(scope, &.string, null);
    }

    fn exists(self: *Runtime, dir: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const path = args[0].string;

        const access_result = dir.access(self.io, path, .{ .read = true });

        const result: bool = if (access_result) |_|
            true
        else |_|
            false;

        return .{ .bool = result };
    }

    fn read(self: *Runtime, dir: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const RESULT_TYPE = &@unionInit(Type, "string", {});

        const path = args[0].string;

        const content = dir.readFileAlloc(
            self.io,
            path,
            scope.arena.allocator(),
            .limited(1024),
        ) catch return makeResult(scope, RESULT_TYPE, null);

        return makeResult(scope, RESULT_TYPE, .{ .string = content });
    }

    fn glob(self: *Runtime, dir: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const pattern = args[0].string;

        var it = globs.iterate(
            self.allocator,
            dir,
            self.io,
            pattern,
        ) catch |err| return switch (err) {
            globs.Error.InvalidGlob => .{
                .list = .{
                    .items_type = &.string,
                    .items = &.{},
                },
            },
            else => @errorCast(err),
        };
        defer it.deinit();

        var result: std.ArrayList(Value) = .empty;

        while (try it.next()) |match| {
            try result.append(scope.arena.allocator(), .{
                .string = try scope.arena.allocator().dupe(u8, match),
            });
        }

        return .{
            .list = .{
                .items_type = &.string,
                .items = try result.toOwnedSlice(scope.arena.allocator()),
            },
        };
    }

    fn basename(_: *Runtime, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const path = args[0].string;
        return .{ .string = std.fs.path.basename(path) };
    }

    fn join_path(self: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const paths = args[0].list;

        const temp_buffer: [][]const u8 = try self.allocator.alloc([]const u8, paths.items.len);
        defer self.allocator.free(temp_buffer);

        for (paths.items, temp_buffer) |in, *out| {
            out.* = in.string;
        }

        return .{
            .string = try std.fs.path.join(scope.arena.allocator(), temp_buffer),
        };
    }

    fn is_file(self: *Runtime, dir: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const path = args[0].string;

        const stat = dir.statFile(
            self.io,
            path,
            .{},
        ) catch return .{ .bool = false };

        return .{ .bool = stat.kind == .file };
    }

    fn is_dir(self: *Runtime, dir: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const path = args[0].string;

        const stat = dir.statFile(
            self.io,
            path,
            .{},
        ) catch return .{ .bool = false };

        return .{ .bool = stat.kind == .directory };
    }

    fn os(_: *Runtime, _: std.Io.Dir, _: *Scope, _: []const Value) Error!Value {
        return .{
            .string = @tagName(platform.tag),
        };
    }

    fn cwd(self: *Runtime, dir: std.Io.Dir, scope: *Scope, _: []const Value) Error!Value {
        var buffer: [1024]u8 = undefined;

        const size = try dir.realPath(self.io, &buffer);

        return .{
            .string = try scope.arena.allocator().dupe(u8, buffer[0..size]),
        };
    }

    fn arch(_: *Runtime, _: std.Io.Dir, _: *Scope, _: []const Value) Error!Value {
        const builtin = @import("builtin");

        const arch_family = builtin.target.cpu.arch.family();

        return .{
            .string = @tagName(arch_family),
        };
    }

    fn invokation_dir(self: *Runtime, _: std.Io.Dir, _: *Scope, _: []const Value) Error!Value {
        return .{
            .string = self.invokation_dir,
        };
    }

    fn status_code(_: *Runtime, _: std.Io.Dir, s: *Scope, _: []const Value) Error!Value {
        return .{ .number = @floatFromInt(s.statusCode()) };
    }

    fn which(self: *Runtime, dir: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const name = args[0].string;

        const result = try program.which(
            self.allocator,
            dir,
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

    fn @"error"(self: *Runtime, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const message = args[0].string;

        try self.printer.printStyled(
            self.allocator,
            .{ .fg = .bright_red },
            "{s}\n",
            .{message},
        );

        return Error.Abort;
    }

    fn print(self: *Runtime, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const message = args[0].string;

        try self.printer.print(
            self.allocator,
            "{s}\n",
            .{message},
        );

        return .void;
    }

    fn any(self: *Runtime, dir: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const list = args[0].list;

        const test_fn = args[1].lambda.instance;

        for (list.items) |item| {
            const result = try callLambda(
                self,
                dir,
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

    fn all(self: *Runtime, dir: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const list = args[0].list;

        const test_fn = args[1].lambda.instance;

        for (list.items) |item| {
            const result = try callLambda(
                self,
                dir,
                scope,
                test_fn,
                &.{item},
            );

            if (result.eql(.{ .bool = false }))
                return .{ .bool = false };
        }

        return .{ .bool = true };
    }

    fn reduce(self: *Runtime, dir: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const list = args[0].list;
        var value = args[1];
        const func = args[2].lambda.instance;

        for (list.items) |item| {
            value = try callLambda(
                self,
                dir,
                scope,
                func,
                &.{ value, item },
            );
        }

        return value;
    }

    fn @"collections/at"(_: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const list = args[0].list;

        const pos: i64 = blk: {
            const number = args[1].number;
            break :blk Runtime.integerize(number);
        };

        if (pos < 0 or list.items.len <= pos) {
            return makeResult(scope, list.items_type, null);
        }

        return makeResult(scope, list.items_type, list.items[@intCast(pos)]);
    }

    fn unique(_: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const list = args[0].list;

        var set: std.HashMapUnmanaged(Value, bool, Value.MapContext, 80) = .empty;

        var result: std.ArrayList(Value) = .empty;

        for (list.items) |item| {
            const gop = try set.getOrPut(scope.arena.allocator(), item);

            if (gop.found_existing)
                continue;

            try result.append(scope.arena.allocator(), item);
        }

        return .{
            .list = .{
                .items_type = list.items_type,
                .items = result.items,
            },
        };
    }

    fn sort(self: *Runtime, dir: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const list = args[0].list;
        const cmp_fn = args[1].lambda.instance;

        const result: []Value = try scope.arena.allocator().alloc(Value, list.items.len);

        for (list.items, result) |in, *out| {
            out.* = try in.clone(scope.arena.allocator());
        }

        const Context = struct {
            i: *Runtime,
            c: std.Io.Dir,
            s: *Scope,
            f: *const ir.LambdaInstance,
            err: ?Error = null,

            fn lessThan(s: *@This(), a: Value, b: Value) bool {
                if (s.err == null) {
                    const out = callLambda(
                        s.i,
                        s.c,
                        s.s,
                        s.f,
                        &.{
                            a, b,
                        },
                    ) catch |err| {
                        s.err = err;
                        unreachable;
                        // return false;
                    };
                    return out.bool;
                }

                return false;
            }
        };

        var ctx: Context = .{
            .i = self,
            .c = dir,
            .s = scope,
            .f = cmp_fn,
        };
        //TODO: just replace it which custom sort implementation instead of this wire thing
        std.mem.sort(Value, result, &ctx, Context.lessThan);

        if (ctx.err) |err|
            return err;

        return .{
            .list = .{
                .items_type = list.items_type,
                .items = result,
            },
        };
    }

    fn @"strings/len"(_: *Runtime, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const string = args[0].string;

        return .{
            .number = @floatFromInt(string.len),
        };
    }

    fn @"collections/len"(_: *Runtime, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const list = args[0].list;

        return .{
            .number = @floatFromInt(list.items.len),
        };
    }

    // when sep is "" split on chars
    fn split(_: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const str = args[0].string;
        const sep = args[1].string;

        if (sep.len == 0) {
            const result: []Value = try scope.arena.allocator().alloc(Value, str.len);

            for (result, 0..) |*out, idx| {
                out.* = .{
                    .string = str[idx .. idx + 1],
                };
            }

            return .{
                .list = .{
                    .items_type = &.string,
                    .items = result,
                },
            };
        }

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

    fn join(_: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const strings = args[0].list;
        const sep = args[1].string;

        const string_size = blk: {
            var total: usize = 0;

            for (strings.items) |item| {
                total += item.string.len;
            }

            if (strings.items.len > 1) {
                total += (strings.items.len - 1) * sep.len;
            }

            break :blk total;
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

    fn lower(_: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const str = args[0].string;

        const out = try std.ascii.allocLowerString(scope.arena.allocator(), str);

        return .{
            .string = out,
        };
    }

    fn upper(_: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const str = args[0].string;

        const out = try std.ascii.allocUpperString(scope.arena.allocator(), str);

        return .{
            .string = out,
        };
    }

    fn contains(_: *Runtime, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const str = args[0].string;
        const sub = args[1].string;

        const result = std.mem.containsAtLeast(u8, str, 1, sub);

        return .{
            .bool = result,
        };
    }

    fn starts_with(_: *Runtime, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const str = args[0].string;
        const sub = args[1].string;

        const result = std.mem.startsWith(u8, str, sub);

        return .{
            .bool = result,
        };
    }

    fn ends_with(_: *Runtime, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const str = args[0].string;
        const sub = args[1].string;

        const result = std.mem.endsWith(u8, str, sub);

        return .{
            .bool = result,
        };
    }

    fn @"strings/replace"(_: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
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

    fn @"strings/at"(_: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const str = args[0].string;

        const pos: i64 = blk: {
            const number = args[1].number;
            break :blk Runtime.integerize(number);
        };

        if (pos < 0 or str.len <= pos) {
            return makeResult(scope, &.string, null);
        }

        const idx: usize = @intCast(pos);

        return makeResult(scope, &.string, .{ .string = str[idx .. idx + 1] });
    }

    fn lines(_: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const str = args[0].string;

        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(scope.arena.allocator());

        var rest = str;
        while (rest.len > 0) {
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;

            var line = rest[0..end];
            if (line.len > 0 and line[line.len - 1] == '\r')
                line = line[0 .. line.len - 1];

            try items.append(scope.arena.allocator(), .{ .string = line });

            rest = if (end < rest.len) rest[end + 1 ..] else rest[end..];
        }

        return .{
            .list = .{
                .items_type = &.string,
                .items = try items.toOwnedSlice(scope.arena.allocator()),
            },
        };
    }

    fn trim(_: *Runtime, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const str = args[0].string;
        const set = args[1].string;

        const result = std.mem.trim(u8, str, set);

        return .{
            .string = result,
        };
    }

    fn trim_end(_: *Runtime, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const str = args[0].string;
        const set = args[1].string;

        const result = std.mem.trimStart(u8, str, set);

        return .{
            .string = result,
        };
    }

    fn trim_start(_: *Runtime, _: std.Io.Dir, _: *Scope, args: []const Value) Error!Value {
        const str = args[0].string;
        const set = args[1].string;

        const result = std.mem.trimEnd(u8, str, set);

        return .{
            .string = result,
        };
    }

    fn @"collections/replace"(_: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
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

    fn parse_number(_: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const str = args[0].string;

        const number: ?f64 = std.fmt.parseFloat(f64, str) catch null;

        return if (number) |n|
            makeResult(scope, &.number, .{ .number = n })
        else
            makeResult(scope, &.number, null);
    }

    fn input(self: *Runtime, _: std.Io.Dir, scope: *Scope, args: []const Value) Error!Value {
        const text = args[0].string;
        try self.printer.printStyled(
            self.allocator,
            .{ .fg = .bright_white },
            "{s}",
            .{text},
        );
        var buffer: [512]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(self.io, &buffer);
        const reader = &stdin.interface;

        var aw: std.Io.Writer.Allocating = .init(scope.arena.allocator());
        const writer = &aw.writer;
        _ = reader.streamDelimiter(writer, '\n') catch {
            aw.deinit();
            return try makeResult(scope, &.string, null);
        };

        return try makeResult(
            scope,
            &.string,
            .{ .string = try aw.toOwnedSlice() },
        );
    }

    fn select(_: *Runtime, _: std.Io.Dir, _: *Scope, _: []const Value) Error!Value {
        lib.debug.todo("select not implemented yet");
    }
};
