const std = @import("std");

const inter = @import("interpreter");
const Scope = inter.symbol.Scope;

const compiler = @import("compiler");
const ir = compiler.ir;
const typing = compiler.typing;
const Value = compiler.Value;

const conzole = @import("conzole");
const ArgsReader = conzole.Reader;
const ArgsCollector = conzole.args.Collector;

const Printer = conzole.terminal.Printer;
const Style = conzole.terminal.Style;

const lib = @import("lib");

io: std.Io,
gpa: std.mem.Allocator,

filepath: []const u8,
printer: *conzole.terminal.Printer,
max_file_size: usize = 5000,
diagnostics: *lib.Diagnostic.List,
source_store: *lib.source_file.SourceStore,

const Context = @This();

const TaskError = error{
    TaskNotFound,
};

const DESCRIPTION_TEXT_OFFSET = 10;

pub fn compileRunfile(ctx: *Context) !compiler.Result {
    const source_id = try ctx.source_store.loadFile(ctx.gpa, ctx.io, ctx.filepath);

    const source_view = try ctx.source_store.view(source_id);

    return try compiler.compile(ctx.gpa, source_view, ctx.diagnostics);
}

pub fn printTasksList(ctx: *Context) !void {
    const cr = try ctx.compileRunfile();
    defer cr.deinit();

    const file = &cr.result;

    const p = ctx.printer;

    // consider moving task reading into ir.File
    const tasks = try file.scope.readTasks(ctx.gpa);
    defer ctx.gpa.free(tasks);

    const groups = try file.scope.readGroups(ctx.gpa);
    defer ctx.gpa.free(groups);

    if (tasks.len == 0 and groups.len == 0) {
        try p.printStyled(ctx.gpa, .{ .fg = .bright_yellow }, "no tasks available\n", .{});
        return;
    }

    try p.printStyled(ctx.gpa, .{ .fg = .white, .bold = true }, "Tasks:", .{});

    for (file.tasks) |task| {
        p.indent();
        defer p.detend();

        try p.printStyled(ctx.gpa, .{ .fg = .green }, "\n{s}", .{task.name});

        if (task.desc) |desc| {
            try p.printStyled(ctx.gpa, .{ .fg = .white }, " " ** 4 ++ "{s}", .{desc});
        }
    }

    for (file.groups) |group| {
        p.indent();
        defer p.detend();

        //TODO: handle properly anonymous groups
        try p.printStyled(
            ctx.gpa,
            .{ .fg = .yellow, .bold = true },
            "\n[{s}]",
            .{group.name.?},
        );

        for (group.tasks) |task| {
            try p.printStyled(ctx.gpa, .{ .fg = .green }, "\n{s}", .{task.name});
            if (task.desc) |desc| {
                try p.printStyled(ctx.gpa, .{ .fg = .white }, " " ** 4 ++ "{s}", .{desc});
            }
        }
    }
}

pub fn printTaskUsage(ctx: *Context, task_id: []const u8) !void {
    const style = struct {
        const head: Style = .{
            .fg = .bright_yellow,
            .bold = true,
        };
        const body: Style = .{ .fg = .bright_cyan };
        const option_name: Style = .{ .fg = .bright_green };
        const desc: Style = .{
            .fg = .bright_blue,
        };
    };

    const cr = try ctx.compileRunfile();
    defer cr.deinit();

    const file = cr.result;

    const task = file.findTask(.parse(task_id)) orelse return TaskError.TaskNotFound;

    // Usage: tasq {task name} [{positional argument names..}] "[OPTIONS]"

    // collect positionals
    const positional = blk: {
        var count: usize = 0;

        for (task.args) |arg| {
            if (arg.is_positional == false)
                break;

            count += 1;
        }

        break :blk task.args[0..count];
    };

    try ctx.printer.printStyled(ctx.gpa, style.head, "Usage: ", .{});

    try ctx.printer.printStyled(ctx.gpa, style.body, "tasq {s} ", .{task.name});

    for (positional) |arg|
        try ctx.printer.printStyled(ctx.gpa, style.body, "{s} ", .{arg.name});

    try ctx.printer.printStyled(ctx.gpa, style.body, "[OPTIONS]\n", .{});

    //Arguments:
    //  {argument name} [<{argument value type}>]   [{description}]

    if (positional.len != 0) {
        const names_col_width = blk: {
            var max: usize = 0;

            for (positional) |arg| {
                max = @max(max, arg.name.len);
            }

            break :blk @max(10, max);
        };

        try ctx.printer.printStyled(ctx.gpa, style.head, "\nArguments:", .{});

        for (positional) |arg| {
            ctx.printer.indent();
            defer ctx.printer.detend();

            try ctx.printer.printStyled(ctx.gpa, style.body, "\n{[name]s: <[width]}", .{
                .name = arg.name,
                .width = names_col_width,
            });

            if (arg.desc) |desc| {
                try ctx.printer.printStyled(ctx.gpa, style.desc, "{s}", .{desc});
            }
        }
    }

    // Options:
    //   -s, -long name  desc
    //       -long name  desc

    const OptionNameBuilder = struct {
        fn build(allocator: std.mem.Allocator, opt: *ir.Argument) ![]const u8 {
            var aw = std.Io.Writer.Allocating.init(allocator);

            var writer = &aw.writer;

            if (opt.short) |short| {
                try writer.writeAll(&.{ '-', short });
            }

            if (opt.long) |long| {
                if (opt.short) |_|
                    try writer.writeAll(", ");

                try writer.writeAll("--");
                try writer.writeAll(long);
            }

            return try aw.toOwnedSlice();
        }
    };

    const options = blk: {
        var options = try std.ArrayList(*ir.Argument).initCapacity(ctx.gpa, task.args.len - positional.len);
        // append non positional task args
        try options.appendSlice(ctx.gpa, task.args[positional.len..]);

        // append group args
        if (task.group) |group| {
            try options.appendSlice(ctx.gpa, group.args);
        }

        break :blk try options.toOwnedSlice(ctx.gpa);
    };
    defer ctx.gpa.free(options);

    if (options.len != 0) {

        // build and compute max length of names (i.e "-s, --long")
        const precomputed_names = try ctx.gpa.alloc([]const u8, options.len);
        defer {
            for (precomputed_names) |pn| {
                ctx.gpa.free(pn);
            }
            ctx.gpa.free(precomputed_names);
        }

        const name_col_width = blk: {
            var max: usize = 0;

            for (options, precomputed_names) |opt, *out| {
                const names = try OptionNameBuilder.build(ctx.gpa, opt);
                max = @max(max, names.len);
                out.* = names;
            }

            break :blk @max(10, max);
        };

        // build and compute max length of type names (excluding flag) (i.e "<string>")
        const precomputed_type_names = try ctx.gpa.alloc(?[]const u8, options.len);
        defer {
            for (precomputed_type_names) |precomputed_types_name| {
                if (precomputed_types_name) |ptn| {
                    ctx.gpa.free(ptn);
                }
            }
            ctx.gpa.free(precomputed_type_names);
        }

        const type_col_width = blk: {
            var max: usize = 0;

            for (options, 0..) |opt, idx| {
                if (opt.type == .flag) {
                    precomputed_type_names[idx] = null;
                    continue;
                }

                const type_name = try std.fmt.allocPrint(ctx.gpa, "<{f}>", .{opt.type});
                const w = type_name.len;

                precomputed_type_names[idx] = type_name;
                max = @max(max, w);
            }

            break :blk max;
        };

        // left col (names + type i.e "-s, --long <string>")
        const left_col_width = blk: {
            var max: usize = 0;

            for (precomputed_type_names) |type_name| {
                var w: usize = name_col_width;

                if (type_name) |_| {
                    w += 1 + type_col_width;
                }

                max = @max(max, w);
            }
            break :blk @max(10, max + DESCRIPTION_TEXT_OFFSET);
        };

        try ctx.printer.printStyled(ctx.gpa, style.head, "\nOptions:", .{});

        // left = name + type + offset
        // type + offset = left - name
        const type_with_offset_width = left_col_width - name_col_width;

        for (options, precomputed_names, precomputed_type_names) |opt, name, type_name| {
            ctx.printer.indent();
            defer ctx.printer.detend();

            // print name
            try ctx.printer.printStyled(ctx.gpa, style.option_name, "\n{[name]s: >[width]}", .{
                .name = name,
                .width = name_col_width,
            });

            // print type optionally
            try ctx.printer.printStyled(ctx.gpa, style.body, "{[type]s: <[width]}", .{
                .type = type_name orelse "",
                .width = type_with_offset_width,
            });

            //print desc

            if (opt.desc) |desc| {
                try ctx.printer.printStyled(ctx.gpa, style.desc, "{s}", .{desc});
            }
        }
    }
}

const TaskArgumentParser = struct {
    task: *ir.Task,
    diagnostics: *lib.Diagnostic.List,

    args: std.ArrayList(*ir.Argument) = .empty,
    long_alias: std.StringHashMapUnmanaged(usize) = .empty,
    short_alias: std.AutoHashMapUnmanaged(u8, usize) = .empty,

    pub const Error = error{
        ParsingFailed,
    } || std.mem.Allocator.Error;

    pub fn init(gpa: std.mem.Allocator, task: *ir.Task, diagnostics: *lib.Diagnostic.List) Error!TaskArgumentParser {
        var out: TaskArgumentParser = .{
            .task = task,
            .diagnostics = diagnostics,
        };

        for (task.args) |arg| {
            const idx = out.args.items.len;

            try out.args.append(gpa, arg);

            if (arg.long) |long| {
                try out.long_alias.put(gpa, long, idx);
            }
            if (arg.short) |short| {
                try out.short_alias.put(gpa, short, idx);
            }
        }
        if (task.group) |group| {
            for (group.args) |arg| {
                std.debug.assert(arg.short != null or arg.long != null);
                const idx = out.args.items.len;

                try out.args.append(gpa, arg);

                if (arg.long) |long| {
                    try out.long_alias.put(gpa, long, idx);
                }

                if (arg.short) |short| {
                    try out.short_alias.put(gpa, short, idx);
                }
            }
        }

        return out;
    }

    pub fn deinit(self: *TaskArgumentParser, gpa: std.mem.Allocator) void {
        self.long_alias.deinit(gpa);
        self.short_alias.deinit(gpa);
        self.args.deinit(gpa);
    }

    pub fn parseArguments(
        self: *TaskArgumentParser,
        gpa: std.mem.Allocator,
        arguments: []const []const u8,
    ) Error!std.array_hash_map.String(Value) {
        var reader = ArgsReader.init(arguments);
        var collector = ArgsCollector.empty;
        errdefer collector.deinit(gpa);

        var out: std.array_hash_map.String(Value) = .empty;
        errdefer out.deinit(gpa);

        const CollectorAdapter = struct {
            fn collect(allocator: std.mem.Allocator, c: *ArgsCollector, r: *ArgsReader, arg: *ir.Argument) ArgsCollector.Error!void {
                const @"type": conzole.args.Type = switch (arg.type) {
                    .flag => .flag,
                    .string => .string,
                    .list_string => .list_string,
                    .number => if (arg.int) .int else .number,
                    .list_number => if (arg.int) .list_int else .list_number,
                };

                try c.interceptNext(allocator, r, arg.name, @"type");
            }
        };

        var idx: usize = 0;
        var positional_end = true;

        while (reader.read()) |tok| : (idx += 1) {
            switch (tok.type) {
                .value => {
                    if (positional_end) {
                        try self.diagnostics.Err(.{ .argument = idx }, "positional arguments must be placed before named ones", .{});
                        return Error.ParsingFailed;
                    }

                    // get argument
                    const arg = self.args.items[idx];

                    //TODO: consider named-positional allowed
                    // removing this condition almost make it work
                    // problems may appear somewhere else,
                    // i.e flag nor list can never be positional
                    if (arg.is_positional == false) {
                        try self.diagnostics.Err(.{ .argument = idx }, "{s} is not positional", .{arg.name});
                        return Error.ParsingFailed;
                    }

                    const NumberHandler = struct {
                        fn handle(str: []const u8, int: bool) ArgsReader.Error!Value {
                            return if (int)
                                .{ .number = @floatFromInt(try ArgsReader.parseAs(str, i64)) }
                            else
                                .{ .number = try ArgsReader.parseAs(str, f64) };
                        }
                    };

                    const value: Value = switch (arg.type) {
                        .number => NumberHandler.handle(tok.payload, arg.int) catch |err| return switch (err) {
                            error.InvalidType => {
                                try self.diagnostics.Err(.{ .argument = idx }, "invalid argument type, got '{s}' expected '{f}'", .{ tok.lexeme, arg.type });
                                return Error.ParsingFailed;
                            },
                            else => unreachable,
                        },
                        .string => .{ .string = .{
                            .data = tok.payload,
                            .owned = false,
                        } },
                        else => unreachable,
                    };

                    try out.put(gpa, arg.name, value);
                },
                .long => {
                    positional_end = true;
                    defer idx += 1;

                    const arg = blk: {
                        if (self.long_alias.get(tok.payload)) |arg_idx| {
                            const arg = self.args.items[arg_idx];
                            break :blk arg;
                        } else {
                            try self.diagnostics.Err(.{ .argument = idx }, "unknown argument '--{s}'", .{tok.payload});
                            return Error.ParsingFailed;
                        }
                    };
                    //TODO: add way to receive actual token from collector,

                    CollectorAdapter.collect(gpa, &collector, &reader, arg) catch |err| return switch (err) {
                        error.InvalidType => {
                            try self.diagnostics.Err(.{ .argument = idx }, "invalid '{s}' value type, got '{s}' expected '{f}'", .{ arg.name, reader.args[reader.pos], arg.type });
                            return Error.ParsingFailed;
                        },
                        error.UnexpectedEnd => {
                            try self.diagnostics.Err(.{ .argument = null }, "unexpected end, '{s}' requires '{f}' value", .{ arg.name, arg.type });
                            return Error.ParsingFailed;
                        },
                        else => unreachable,
                    };
                },
                .short => {
                    positional_end = true;
                    defer idx += 1;

                    const flags = tok.payload[0 .. tok.payload.len - 1];
                    const last = tok.payload[tok.payload.len - 1];

                    for (flags) |flag| {
                        const arg = blk: {
                            if (self.short_alias.get(flag)) |arg_idx| {
                                const arg = self.args.items[arg_idx];
                                break :blk arg;
                            } else {
                                try self.diagnostics.Err(.{ .argument = idx }, "unknown argument '-{c}'", .{flag});
                                return Error.ParsingFailed;
                            }
                        };

                        if (arg.type != .flag) {
                            std.debug.panic("TODO: handle invalid short flag pos", .{});
                        }

                        CollectorAdapter.collect(gpa, &collector, &reader, arg) catch |err| return switch (err) {
                            error.InvalidType => {
                                try self.diagnostics.Err(.{ .argument = idx }, "invalid '{s}' value type, got '{s}' expected '{f}'", .{ arg.name, reader.args[reader.pos], arg.type });
                                return Error.ParsingFailed;
                            },
                            error.UnexpectedEnd => {
                                try self.diagnostics.Err(.{ .argument = null }, "unexpected end, '{s}' requires '{f}' value", .{ arg.name, arg.type });
                                return Error.ParsingFailed;
                            },
                            else => unreachable,
                        };
                    }

                    const arg = blk: {
                        if (self.short_alias.get(last)) |arg_idx| {
                            const arg = self.args.items[arg_idx];
                            break :blk arg;
                        } else {
                            try self.diagnostics.Err(.{ .argument = idx }, "unknown argument '-{c}'", .{last});
                            return Error.ParsingFailed;
                        }
                    };

                    CollectorAdapter.collect(gpa, &collector, &reader, arg) catch |err| return switch (err) {
                        error.InvalidType => {
                            try self.diagnostics.Err(.{ .argument = idx }, "invalid '{s}' value type, got '{s}' expected '{f}'", .{ arg.name, reader.args[reader.pos], arg.type });
                            return Error.ParsingFailed;
                        },
                        error.UnexpectedEnd => {
                            try self.diagnostics.Err(.{ .argument = null }, "unexpected end, '{s}' requires '{f}' value", .{ arg.name, arg.type });
                            return Error.ParsingFailed;
                        },
                        else => unreachable,
                    };
                },
            }
        }

        // translate to Value

        var values = try collector.collect(gpa);
        defer values.deinit(gpa);

        const ArgPayloadConverter = struct {
            fn convert(allocator: std.mem.Allocator, payload: conzole.args.Payload) !Value {
                return switch (payload) {
                    .flag => |v| .{ .bool = v },
                    .int => |v| .{ .number = @floatFromInt(v) },
                    .list_int => |v| {
                        const items = try allocator.alloc(Value, v.len);
                        for (v, items) |src, *desc| {
                            desc.* = .{ .number = @floatFromInt(src) };
                        }

                        return .{
                            .list = .{
                                .items = items,
                                .items_type = &.number,
                            },
                        };
                    },
                    .number => |v| .{ .number = v },
                    .list_number => |v| {
                        const items = try allocator.alloc(Value, v.len);

                        for (v, items) |src, *dest| {
                            dest.* = .{ .number = src };
                        }

                        return .{
                            .list = .{
                                .items = items,
                                .items_type = &.number,
                            },
                        };
                    },
                    .string => |v| .{ .string = .{
                        .data = v,
                        .owned = false,
                    } },
                    .list_string => |v| {
                        const items = try allocator.alloc(Value, v.len);

                        for (v, items) |src, *dest| {
                            dest.* = .{ .string = .{
                                .data = src,
                                .owned = false,
                            } };
                        }

                        return .{
                            .list = .{
                                .items = items,
                                .items_type = &.string,
                            },
                        };
                    },
                };
            }
        };

        for (self.args.items) |arg| {
            const value = if (values.get(arg.name)) |value|
                try ArgPayloadConverter.convert(gpa, value)
            else if (arg.default) |def|
                def
            else {
                try self.diagnostics.Err(.{ .argument = null }, "'{s}' argument not provided", .{arg.name});
                return Error.ParsingFailed;
            };
            try out.put(gpa, arg.name, value);
        }

        // validate if everything provided

        var missing_argument: bool = false;

        if (self.task.group) |group| {
            for (group.args) |arg| {
                if (out.contains(arg.name) == false) {
                    try self.diagnostics.Err(.{ .argument = null }, "missing '{s}' value for '{s}' group", .{ arg.name, group.name orelse "<anonymous>" });
                    missing_argument = true;
                }
            }
        }

        for (self.task.args) |arg| {
            if (out.contains(arg.name) == false) {
                try self.diagnostics.Err(.{ .argument = null }, "missing '{s}' value for '{s}' task", .{ arg.name, self.task.name });
            }
        }

        if (missing_argument)
            return Error.ParsingFailed;

        return out;
    }
};

pub fn runTask(ctx: *Context, task_id: []const u8, args: []const []const u8) !void {
    const cr = try ctx.compileRunfile();
    defer cr.deinit();

    const file = cr.result;

    const task = file.findTask(.parse(task_id)) orelse return TaskError.TaskNotFound;

    var values = blk: {
        var parser: TaskArgumentParser = try .init(ctx.gpa, task, ctx.diagnostics);
        defer parser.deinit(ctx.gpa);

        break :blk try parser.parseArguments(ctx.gpa, args);
    };

    var call_stack: inter.CallStack = .init(ctx.gpa, ctx.diagnostics, task);
    defer call_stack.deinit(ctx.gpa);

    var scope_stack: inter.ScopeStack = try .init(ctx.gpa, ctx.diagnostics, task, values.move());
    defer scope_stack.deinit(ctx.gpa);

    var interpreter = inter.Interpreter.init(
        ctx.gpa,
        ctx.io,
        ctx.printer,
        &file.options,
        &call_stack,
        &scope_stack,
    );

    try interpreter.run();
}
