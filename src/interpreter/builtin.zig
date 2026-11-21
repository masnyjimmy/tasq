const std = @import("std");

const lib = @import("lib");
const platform = lib.platform;
const program = lib.program;

const compiler = @import("compiler");
const fns = compiler.functions;
const Type = compiler.Type;
const ir = compiler.ir;
const Value = compiler.Value;
const Scope = @import("Scope.zig");

const Runtime = @import("Runtime.zig");
const globs = @import("glob.zig");

pub const Error = Runtime.Error;

const Context = Runtime.Ctx;

/// `return_type` is the type the call was resolved to. Handlers of functions that can fail get
/// the whole result type (`E!T`) there and pass it on to `fail` / `ok`; the others ignore it.
pub fn callFunction(
    runtime: *Runtime,
    ctx: Context,
    id: fns.definitions.Id,
    args: []const Value,
    return_type: *const Type,
) Error!Value {
    switch (id) {
        inline else => |tag| {
            const name = @tagName(tag);

            const handler: *const handlers.Signature = &@field(handlers, name);

            return handler(runtime, ctx, args, return_type);
        },
    }
}

fn callLambda(
    self: *Runtime,
    ctx: Context,
    lambda: *const ir.LambdaInstance,
    args: []const Value,
) Error!Value {
    std.debug.assert(args.len == lambda.params.len);

    const parent_scope = ctx.scope.findByStatic(lambda.template.parent_scope) orelse unreachable;

    const lambda_scope = try Scope.create(
        parent_scope,
        self.allocator,
        lambda.scope,
    );
    defer lambda_scope.destroy();

    const lambda_ctx = ctx.withScope(lambda_scope);

    for (lambda.params, args) |*param, arg| {
        _ = try self.destructure(
            ir.Capture,
            lambda_ctx,
            param.target,
            arg,
            null,
        );
    }

    return try self.evaluateExpr(
        lambda_ctx,
        &lambda.body,
    );
}

/// The failure of `at` / `first` / `last`, for both strings and lists.
fn outOfBounds(
    ctx: Context,
    return_type: *const Type,
    comptime fmt: []const u8,
    args: anytype,
) Error!Value {
    return fns.PosResult.fail(ctx.arena(), return_type, .out_of_bounds, fmt, args);
}

const handlers = struct {
    const Signature = fn (*Runtime, Context, []const Value, *const Type) Error!Value;

    // ---------------------------------------------------------------------------------------
    // debug
    // ---------------------------------------------------------------------------------------

    fn @"error"(self: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        const message = args[0].string;

        try self.printer.printStyled(
            self.allocator,
            .{ .fg = .bright_red },
            "{s}\n",
            .{message},
        );

        return Error.Abort;
    }

    fn print(self: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        const message = args[0].string;

        try self.printer.print(
            self.allocator,
            "{s}\n",
            .{message},
        );

        return .void;
    }

    // ---------------------------------------------------------------------------------------
    // type casts
    // ---------------------------------------------------------------------------------------

    fn parse_number(_: *Runtime, ctx: Context, args: []const Value, return_type: *const Type) Error!Value {
        const str = args[0].string;

        const number = std.fmt.parseFloat(f64, str) catch return fns.ParseNumberResult.fail(
            ctx.arena(),
            return_type,
            .invalid_format,
            "'{s}' is not a valid number",
            .{str},
        );

        return fns.ParseNumberResult.ok(
            ctx.arena(),
            return_type,
            .{ .number = number },
        );
    }

    // ---------------------------------------------------------------------------------------
    // fs
    // ---------------------------------------------------------------------------------------

    fn exists(self: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const path = args[0].string;

        const access_result = ctx.cwd.access(self.io, path, .{ .read = true });

        const result: bool = if (access_result) |_|
            true
        else |_|
            false;

        return .{ .bool = result };
    }

    fn read(self: *Runtime, ctx: Context, args: []const Value, return_type: *const Type) Error!Value {
        const path = args[0].string;

        const content = ctx.cwd.readFileAlloc(
            self.io,
            path,
            ctx.arena(),
            .limited(1024),
        ) catch |err| return fns.ReadResult.fail(
            ctx.arena(),
            return_type,
            .unable_to_read,
            "error while trying to read file: {t}",
            .{err},
        );

        return fns.ReadResult.ok(
            ctx.arena(),
            return_type,
            .{ .string = content },
        );
    }

    fn glob(self: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const pattern = args[0].string;

        var it = globs.iterate(
            self.allocator,
            ctx.cwd,
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
            try result.append(ctx.arena(), .{
                .string = try ctx.arena().dupe(u8, match),
            });
        }

        return .{
            .list = .{
                .items_type = &.string,
                .items = try result.toOwnedSlice(ctx.arena()),
            },
        };
    }

    fn basename(_: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        const path = args[0].string;
        return .{ .string = std.fs.path.basename(path) };
    }

    fn join_path(self: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const paths = args[0].list;

        const temp_buffer: [][]const u8 = try self.allocator.alloc([]const u8, paths.items.len);
        defer self.allocator.free(temp_buffer);

        for (paths.items, temp_buffer) |in, *out| {
            out.* = in.string;
        }

        return .{
            .string = try std.fs.path.join(ctx.arena(), temp_buffer),
        };
    }

    fn is_file(self: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const path = args[0].string;

        const stat = ctx.cwd.statFile(
            self.io,
            path,
            .{},
        ) catch return .{ .bool = false };

        return .{ .bool = stat.kind == .file };
    }

    fn is_dir(self: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const path = args[0].string;

        const stat = ctx.cwd.statFile(
            self.io,
            path,
            .{},
        ) catch return .{ .bool = false };

        return .{ .bool = stat.kind == .directory };
    }

    // ---------------------------------------------------------------------------------------
    // misc
    // ---------------------------------------------------------------------------------------

    fn env(_: *Runtime, ctx: Context, args: []const Value, return_type: *const Type) Error!Value {
        const key = args[0].string;

        const value = ctx.scope.environ.get(key) orelse return fns.EnvResult.fail(
            ctx.arena(),
            return_type,
            .not_found,
            "'{s}' key not found",
            .{key},
        );

        return fns.EnvResult.ok(
            ctx.arena(),
            return_type,
            .{ .string = value },
        );
    }

    fn os(_: *Runtime, _: Context, _: []const Value, _: *const Type) Error!Value {
        return .{
            .string = @tagName(platform.tag),
        };
    }

    fn cwd(self: *Runtime, ctx: Context, _: []const Value, _: *const Type) Error!Value {
        var buffer: [1024]u8 = undefined;

        const size = try ctx.cwd.realPath(self.io, &buffer);

        return .{
            .string = try ctx.arena().dupe(u8, buffer[0..size]),
        };
    }

    fn arch(_: *Runtime, _: Context, _: []const Value, _: *const Type) Error!Value {
        const builtin = @import("builtin");

        const arch_family = builtin.target.cpu.arch.family();

        return .{
            .string = @tagName(arch_family),
        };
    }

    fn invokation_dir(self: *Runtime, _: Context, _: []const Value, _: *const Type) Error!Value {
        return .{
            .string = self.invokation_dir,
        };
    }

    fn status_code(_: *Runtime, ctx: Context, _: []const Value, _: *const Type) Error!Value {
        return .{ .number = @floatFromInt(ctx.scope.statusCode()) };
    }

    fn which(self: *Runtime, ctx: Context, args: []const Value, return_type: *const Type) Error!Value {
        const name = args[0].string;

        const path = try program.which(
            self.allocator,
            ctx.cwd,
            self.io,
            &ctx.scope.environ.map,
            name,
        ) orelse return fns.EnvResult.fail(
            ctx.arena(),
            return_type,
            .not_found,
            "unable to find '{s}' in PATH",
            .{name},
        );
        defer self.allocator.free(path);

        // the path is owned by the runtime allocator, the value has to live in scope memory
        return fns.EnvResult.ok(
            ctx.arena(),
            return_type,
            .{ .string = try ctx.arena().dupe(u8, path) },
        );
    }

    fn input(self: *Runtime, ctx: Context, args: []const Value, return_type: *const Type) Error!Value {
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

        var aw: std.Io.Writer.Allocating = .init(ctx.arena());
        _ = reader.streamDelimiter(&aw.writer, '\n') catch |err| {
            aw.deinit();
            return fns.InputResult.fail(
                ctx.arena(),
                return_type,
                .unable_to_read_input,
                "error while reading input: {t}",
                .{err},
            );
        };

        return fns.InputResult.ok(
            ctx.arena(),
            return_type,
            .{ .string = try aw.toOwnedSlice() },
        );
    }

    fn select(_: *Runtime, _: Context, _: []const Value, _: *const Type) Error!Value {
        lib.debug.todo("select not implemented yet");
    }

    // ---------------------------------------------------------------------------------------
    // collections
    // ---------------------------------------------------------------------------------------

    fn any(self: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const list = args[0].list;

        const test_fn = args[1].lambda.instance;

        for (list.items) |item| {
            const result = try callLambda(
                self,
                ctx,
                test_fn,
                &.{item},
            );

            if (result.eql(.{ .bool = true }))
                return .{ .bool = true };
        }

        return .{ .bool = false };
    }

    fn all(self: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const list = args[0].list;

        const test_fn = args[1].lambda.instance;

        for (list.items) |item| {
            const result = try callLambda(
                self,
                ctx,
                test_fn,
                &.{item},
            );

            if (result.eql(.{ .bool = false }))
                return .{ .bool = false };
        }

        return .{ .bool = true };
    }

    fn reduce(self: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const list = args[0].list;
        var value = args[1];
        const func = args[2].lambda.instance;

        for (list.items) |item| {
            value = try callLambda(
                self,
                ctx,
                func,
                &.{ value, item },
            );
        }

        return value;
    }

    fn iterate(self: *Runtime, ctx: Context, args: []const Value, result_type: *const Type) Error!Value {
        const init = args[0];
        const count = Runtime.integerize(args[1].number);

        const lambda = args[2].lambda.instance;

        const result_list = try ctx.arena().alloc(Value, @intCast(count));

        for (result_list, 0..) |*item, idx| {
            const in_val = if (idx == 0)
                init
            else
                result_list[idx - 1];

            item.* = try callLambda(self, ctx, lambda, &.{
                in_val,
            });
        }

        return .{
            .list = .{
                .items = result_list,
                .items_type = result_type.list,
            },
        };
    }

    fn @"collections/at"(_: *Runtime, ctx: Context, args: []const Value, return_type: *const Type) Error!Value {
        const list = args[0].list;

        const pos: i64 = Runtime.integerize(args[1].number);

        if (pos < 0 or list.items.len <= pos) {
            return outOfBounds(
                ctx,
                return_type,
                "index {} is out of bounds for a list of {} item(s)",
                .{ pos, list.items.len },
            );
        }

        return fns.PosResult.ok(
            ctx.arena(),
            return_type,
            list.items[@intCast(pos)],
        );
    }

    fn @"collections/first"(_: *Runtime, ctx: Context, args: []const Value, return_type: *const Type) Error!Value {
        const list = args[0].list;

        if (list.items.len == 0)
            return outOfBounds(ctx, return_type, "the list is empty, it has no first item", .{});

        return fns.PosResult.ok(ctx.arena(), return_type, list.items[0]);
    }

    fn @"collections/last"(_: *Runtime, ctx: Context, args: []const Value, return_type: *const Type) Error!Value {
        const list = args[0].list;

        if (list.items.len == 0)
            return outOfBounds(ctx, return_type, "the list is empty, it has no last item", .{});

        return fns.PosResult.ok(ctx.arena(), return_type, list.items[list.items.len - 1]);
    }

    fn unique(_: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const list = args[0].list;

        var set: std.HashMapUnmanaged(Value, bool, Value.MapContext, 80) = .empty;

        var result: std.ArrayList(Value) = .empty;

        for (list.items) |item| {
            const gop = try set.getOrPut(ctx.arena(), item);

            if (gop.found_existing)
                continue;

            try result.append(ctx.arena(), item);
        }

        return .{
            .list = .{
                .items_type = list.items_type,
                .items = try result.toOwnedSlice(ctx.arena()),
            },
        };
    }

    fn sort(self: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const list = args[0].list;
        const cmp_fn = args[1].lambda.instance;

        const result: []Value = try ctx.arena().alloc(Value, list.items.len);

        for (list.items, result) |in, *out| {
            out.* = try in.clone(ctx.arena());
        }

        const SortCtx = struct {
            i: *Runtime,
            c: Context,
            f: *const ir.LambdaInstance,
            err: ?Error = null,

            fn lessThan(s: *@This(), a: Value, b: Value) bool {
                if (s.err == null) {
                    const out = callLambda(
                        s.i,
                        s.c,
                        s.f,
                        &.{ a, b },
                    ) catch |err| {
                        s.err = err;
                        return false;
                    };
                    return out.bool;
                }

                return false;
            }
        };

        var sort_context: SortCtx = .{
            .i = self,
            .c = ctx,
            .f = cmp_fn,
        };
        //TODO: just replace it which custom sort implementation instead of this wire thing
        std.mem.sort(Value, result, &sort_context, SortCtx.lessThan);

        if (sort_context.err) |err|
            return err;

        return .{
            .list = .{
                .items_type = list.items_type,
                .items = result,
            },
        };
    }

    fn @"collections/len"(_: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        const list = args[0].list;

        return .{
            .number = @floatFromInt(list.items.len),
        };
    }

    fn @"collections/replace"(_: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const list = args[0].list;
        const old = args[1];
        const new = args[2];

        const replaced = try ctx.arena().dupe(Value, list.items);

        for (replaced) |*item| {
            if (item.eql(old)) {
                item.* = try new.clone(ctx.arena());
            }
        }

        return .{
            .list = .{
                .items = replaced,
                .items_type = list.items_type,
            },
        };
    }

    // ---------------------------------------------------------------------------------------
    // strings
    // ---------------------------------------------------------------------------------------

    fn @"strings/len"(_: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        const string = args[0].string;

        return .{
            .number = @floatFromInt(string.len),
        };
    }

    // when sep is "" split on chars
    fn split(_: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const str = args[0].string;
        const sep = args[1].string;

        if (sep.len == 0) {
            const result: []Value = try ctx.arena().alloc(Value, str.len);

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
            ctx.arena(),
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

    fn join(_: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
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

        const string = try ctx.arena().alloc(u8, string_size);

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

    fn lower(_: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const str = args[0].string;

        const out = try std.ascii.allocLowerString(ctx.arena(), str);

        return .{
            .string = out,
        };
    }

    fn upper(_: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const str = args[0].string;

        const out = try std.ascii.allocUpperString(ctx.arena(), str);

        return .{
            .string = out,
        };
    }

    fn contains(_: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        const str = args[0].string;
        const sub = args[1].string;

        return .{
            .bool = std.mem.containsAtLeast(u8, str, 1, sub),
        };
    }

    fn starts_with(_: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        const str = args[0].string;
        const sub = args[1].string;

        return .{
            .bool = std.mem.startsWith(u8, str, sub),
        };
    }

    fn ends_with(_: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        const str = args[0].string;
        const sub = args[1].string;

        return .{
            .bool = std.mem.endsWith(u8, str, sub),
        };
    }

    fn @"strings/replace"(_: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const str = args[0].string;
        const old = args[1].string;
        const new = args[2].string;

        const replaced = try std.mem.replaceOwned(
            u8,
            ctx.arena(),
            str,
            old,
            new,
        );

        return .{
            .string = replaced,
        };
    }

    fn @"strings/at"(_: *Runtime, ctx: Context, args: []const Value, return_type: *const Type) Error!Value {
        const str = args[0].string;

        const pos: i64 = Runtime.integerize(args[1].number);

        if (pos < 0 or str.len <= pos) {
            return outOfBounds(
                ctx,
                return_type,
                "index {} is out of bounds for a string of length {}",
                .{ pos, str.len },
            );
        }

        const idx: usize = @intCast(pos);

        return fns.PosResult.ok(
            ctx.arena(),
            return_type,
            .{ .string = str[idx .. idx + 1] },
        );
    }

    fn @"strings/first"(_: *Runtime, ctx: Context, args: []const Value, return_type: *const Type) Error!Value {
        const string = args[0].string;

        if (string.len == 0)
            return outOfBounds(ctx, return_type, "the string is empty, it has no first character", .{});

        return fns.PosResult.ok(
            ctx.arena(),
            return_type,
            .{ .string = string[0..1] },
        );
    }

    fn @"strings/last"(_: *Runtime, ctx: Context, args: []const Value, return_type: *const Type) Error!Value {
        const string = args[0].string;

        if (string.len == 0)
            return outOfBounds(ctx, return_type, "the string is empty, it has no last character", .{});

        return fns.PosResult.ok(
            ctx.arena(),
            return_type,
            .{ .string = string[string.len - 1 .. string.len] },
        );
    }

    fn lines(_: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const str = args[0].string;

        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(ctx.arena());

        var rest = str;
        while (rest.len > 0) {
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;

            var line = rest[0..end];
            if (line.len > 0 and line[line.len - 1] == '\r')
                line = line[0 .. line.len - 1];

            try items.append(ctx.arena(), .{ .string = line });

            rest = if (end < rest.len) rest[end + 1 ..] else rest[end..];
        }

        return .{
            .list = .{
                .items_type = &.string,
                .items = try items.toOwnedSlice(ctx.arena()),
            },
        };
    }

    fn trim(_: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        return .{
            .string = std.mem.trim(u8, args[0].string, args[1].string),
        };
    }

    fn trim_start(_: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        return .{
            .string = std.mem.trimStart(u8, args[0].string, args[1].string),
        };
    }

    fn trim_end(_: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        return .{
            .string = std.mem.trimEnd(u8, args[0].string, args[1].string),
        };
    }

    fn error_message(_: *Runtime, ctx: Context, args: []const Value, _: *const Type) Error!Value {
        const err = args[0].@"error";

        return .{
            .string = try ctx.arena().print(
                "{s}: {s}",
                .{
                    err.type.names[err.id],
                    err.message.?,
                },
            ),
        };
    }

    //=========== regex ==========//

    fn regex(self: *Runtime, ctx: Context, args: []const Value, t: *const Type) Error!Value {
        const str = args[0].string;

        var diagnostic: lib.regex.Diagnostic = undefined;

        const result = try self.regex_cache.get(str, &diagnostic) orelse {
            return fns.RegexResult.fail(
                ctx.arena(),
                t,
                .bad_regex,
                "{s}",
                .{lib.regex.diagnosticMessage(diagnostic)},
            );
        };

        return .{
            .regex = result,
        };
    }

    fn @"regex/contains"(_: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        const str = args[0].string;
        const re = args[1].regex;

        const find = re.find(str) catch unreachable;

        return .{
            .bool = find != null,
        };
    }

    fn matches(_: *Runtime, _: Context, args: []const Value, _: *const Type) Error!Value {
        const str = args[0].string;
        const re = args[1].regex;

        return .{
            .bool = re.isMatch(str) catch unreachable,
        };
    }
};
