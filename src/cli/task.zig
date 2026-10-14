const std = @import("std");

const inter = @import("interpreter");
const Scope = inter.symbol.Scope;

const compiler = @import("compiler");
const ir = compiler.ir;
const Type = compiler.Type;
const ArgType = compiler.ArgType;
const Value = compiler.Value;

const conzole = @import("conzole");
const ArgsReader = conzole.Reader;
const ArgsCollector = conzole.args.Collector;

const Printer = conzole.terminal.Printer;
const Style = conzole.terminal.Style;

const lib = @import("lib");

const Context = @import("context.zig");

pub const TaskError = error{
    TaskNotFound,
    CompilationFailed,
};

/// All colors / text styles used by the list and usage output live here,
/// so the look can be changed in one place.
const style = struct {
    // generic
    const err: Style = .{ .fg = .bright_red };
    const head: Style = .{
        .fg = .bright_yellow,
        .bold = true,
    };
    const body: Style = .{ .fg = .bright_cyan };
    const option_name: Style = .{ .fg = .bright_green };
    const desc: Style = .{
        .fg = .bright_blue,
    };
    const notice: Style = .{ .fg = .bright_yellow };

    // tasks list
    const list_title: Style = .{ .fg = .white, .bold = true };
    const task_name: Style = .{ .fg = .green };
    const task_positional: Style = .{ .fg = .bright_cyan };
    const task_desc: Style = .{ .fg = .white };
    const group_name: Style = .{ .fg = .yellow, .bold = true };
    const group_desc: Style = .{ .fg = .white };

    // requirements (list + usage)
    const requires_label: Style = .{ .fg = .bright_yellow };
    const requires: Style = .{ .fg = .yellow };

    // usage
    const positional_name: Style = .{ .fg = .bright_cyan };
    const type_name: Style = .{ .fg = .bright_cyan };
    const meta: Style = .{ .fg = .yellow };
};

/// spaces between the longest "name positional.." signature and its description in `list`
const LIST_DESC_GAP = 4;

/// spaces between columns (name | type | description) in `usage`
const PARAM_COL_GAP = 2;

pub fn compileRunfile(ctx: *const Context, source_filepath: []const u8) !*const compiler.ir.File {
    const cwd = std.Io.Dir.cwd();

    const content = try cwd.readFileAlloc(
        ctx.io,
        source_filepath,
        ctx.allocator,
        .unlimited,
    );
    defer ctx.allocator.free(content);

    const result = try ctx.workspace.openFile(
        ctx.allocator,
        source_filepath,
        content,
        0,
    );

    // print compilation diagnostics

    const dd = @import("dump_diagnostics.zig");

    var iter = ctx.workspace.files.iterator();

    while (iter.next()) |kv| {
        const file = kv.value_ptr;
        const source = file.source;

        try dd.dump_diagnostics(
            ctx.allocator,
            source,
            file.uri,
            &file.diagnostics,
            ctx.printer,
        );
    }

    if (result.valid == false) {
        return TaskError.CompilationFailed;
    }

    return &ctx.workspace.getFileState(result.id).ir.?;
}

// ---------------------------------------------------------------------------
// shared helpers
// ---------------------------------------------------------------------------

/// Leading positional arguments of a task (positionals always come first).
fn positionalArgs(task: *const ir.Task) []const *ir.Argument {
    var count: usize = 0;

    for (task.args) |arg| {
        if (arg.is_positional == false)
            break;

        count += 1;
    }

    return task.args[0..count];
}

/// Printed width of "name pos1 pos2 ..." (without any styling).
fn signatureWidth(task: *const ir.Task) usize {
    var w: usize = task.name.len;

    for (positionalArgs(task)) |arg| {
        w += 1 + arg.name.len;
    }

    return w;
}

fn maxSignatureWidth(tasks: anytype) usize {
    var max: usize = 0;

    for (tasks) |task| {
        max = @max(max, signatureWidth(task));
    }

    return max;
}

/// Prints one indented line: "\n" + formatted text.
fn printLine(ctx: *const Context, st: Style, comptime fmt: []const u8, args: anytype) !void {
    ctx.printer.indent();
    defer ctx.printer.detend();

    try ctx.printer.printStyled(ctx.allocator, st, "\n" ++ fmt, args);
}

fn printSpaces(ctx: *const Context, count: usize) !void {
    try ctx.printer.print(ctx.allocator, "{[pad]s: <[width]}", .{
        .pad = "",
        .width = count,
    });
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

/// Prints:
///   name pos1 pos2    description
///                     requires: prog1, prog2
fn printListedTask(ctx: *const Context, task: *const ir.Task, signature_col_width: usize) !void {
    const p = ctx.printer;

    p.indent();
    defer p.detend();

    const desc_col = signature_col_width + LIST_DESC_GAP;

    // signature
    try p.printStyled(ctx.allocator, style.task_name, "\n{s}", .{task.name});

    for (positionalArgs(task)) |arg| {
        try p.printStyled(ctx.allocator, style.task_positional, " {s}", .{arg.name});
    }

    // description (aligned)
    if (task.desc) |desc| {
        try printSpaces(ctx, desc_col - signatureWidth(task));
        try p.printStyled(ctx.allocator, style.task_desc, "{s}", .{desc});
    }
}

pub fn printTasksList(ctx: *const Context, source_filepath: []const u8) !void {
    const file = try compileRunfile(ctx, source_filepath);

    const p = ctx.printer;

    // consider moving task reading into ir.File
    const tasks = try file.scope.readTasks(ctx.allocator);
    defer ctx.allocator.free(tasks);

    const groups = try file.scope.readGroups(ctx.allocator);
    defer ctx.allocator.free(groups);

    if (tasks.len == 0 and groups.len == 0) {
        try p.printStyled(ctx.allocator, style.notice, "no tasks available\n", .{});
        return;
    }

    try p.printStyled(ctx.allocator, style.list_title, "Tasks:", .{});

    const root_width = maxSignatureWidth(file.tasks);

    for (file.tasks) |task| {
        try printListedTask(ctx, task, root_width);
    }

    for (file.groups) |group| {
        p.indent();
        defer p.detend();

        //TODO: handle properly anonymous groups
        try p.printStyled(
            ctx.allocator,
            style.group_name,
            "\n[{s}]",
            .{group.name orelse "<anonymous>"},
        );

        if (group.desc) |desc| {
            try p.printStyled(ctx.allocator, style.group_desc, "  {s}", .{desc});
        }

        // each group is aligned on its own
        const group_width = maxSignatureWidth(group.tasks);

        for (group.tasks) |task| {
            try printListedTask(ctx, task, group_width);
        }
    }

    try p.print(ctx.allocator, "\n", .{});
}

// ---------------------------------------------------------------------------
// usage
// ---------------------------------------------------------------------------

/// Argument type as printed to the user (adds "(integer)" for integer numbers).
const PrintableArgType = struct {
    type: ArgType,
    int: bool,

    pub fn format(self: PrintableArgType, w: *std.Io.Writer) !void {
        const with_integer = switch (self.type) {
            .list_number, .number => self.int,
            else => false,
        };

        try self.type.format(w);

        if (with_integer)
            try w.writeAll(" (integer)");
    }

    fn make(arg: *ir.Argument) PrintableArgType {
        return .{
            .type = arg.type,
            .int = arg.int,
        };
    }
};

/// One line of the "Arguments:" / "Options:" tables, fully pre-rendered.
const ParamRow = struct {
    name: []const u8, // "target" or "-s, --long"
    type_name: []const u8, // "<string>" or "" for flags
    desc: ?[]const u8,
    meta: []const u8, // "(required)", "(default: 5, pattern: ..)" or ""
};

const ParamColumns = struct {
    name: usize = 0,
    type_name: usize = 0,

    fn grow(self: *ParamColumns, rows: []const ParamRow) void {
        for (rows) |row| {
            self.name = @max(self.name, row.name.len);
            self.type_name = @max(self.type_name, row.type_name.len);
        }
    }
};

fn optionLabel(a: std.mem.Allocator, arg: *ir.Argument) ![]const u8 {
    if (arg.short) |short| {
        if (arg.long) |long|
            return std.fmt.allocPrint(a, "-{c}, --{s}", .{ short, long });

        return std.fmt.allocPrint(a, "-{c}", .{short});
    }

    if (arg.long) |long| {
        // 4 spaces == width of "-s, " so long names line up
        return std.fmt.allocPrint(a, "    --{s}", .{long});
    }

    return a.dupe(u8, arg.name);
}

fn defaultText(a: std.mem.Allocator, arg: *ir.Argument) !?[]const u8 {
    const def = arg.default orelse return null;

    if (def == .number) {
        if (arg.int)
            return try std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(def.number))});

        return try std.fmt.allocPrint(a, "{d}", .{def.number});
    }

    if (def == .string)
        return try std.fmt.allocPrint(a, "\"{s}\"", .{def.string});

    // `false` is the implicit default of a flag, not worth showing
    if (def == .bool)
        return if (def.bool) "true" else null;

    return null;
}

fn paramMeta(a: std.mem.Allocator, arg: *ir.Argument) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;

    if (arg.default == null) {
        try parts.append(a, "required");
    } else if (try defaultText(a, arg)) |text| {
        try parts.append(a, try std.fmt.allocPrint(a, "default: {s}", .{text}));
    }

    if (arg.pattern) |pattern| {
        try parts.append(a, try std.fmt.allocPrint(a, "pattern: {s}", .{pattern}));
    }

    if (parts.items.len == 0)
        return "";

    const joined = try std.mem.join(a, ", ", parts.items);

    return std.fmt.allocPrint(a, "({s})", .{joined});
}

fn buildParamRows(
    a: std.mem.Allocator,
    args: []const *ir.Argument,
    named: bool,
) ![]ParamRow {
    const rows = try a.alloc(ParamRow, args.len);

    for (args, rows) |arg, *row| {
        row.* = .{
            .name = if (named) try optionLabel(a, arg) else arg.name,
            .type_name = if (arg.type == .flag)
                ""
            else
                try std.fmt.allocPrint(a, "<{f}>", .{PrintableArgType.make(arg)}),
            .desc = arg.desc,
            .meta = try paramMeta(a, arg),
        };
    }

    return rows;
}

fn printParamRows(
    ctx: *const Context,
    rows: []const ParamRow,
    name_style: Style,
    cols: ParamColumns,
) !void {
    const p = ctx.printer;

    for (rows) |row| {
        p.indent();
        defer p.detend();

        // name
        try p.printStyled(ctx.allocator, name_style, "\n{[v]s: <[w]}", .{
            .v = row.name,
            .w = cols.name,
        });
        try printSpaces(ctx, PARAM_COL_GAP);

        // type (column exists only if at least one param has a type)
        if (cols.type_name != 0) {
            try p.printStyled(ctx.allocator, style.type_name, "{[v]s: <[w]}", .{
                .v = row.type_name,
                .w = cols.type_name,
            });
            try printSpaces(ctx, PARAM_COL_GAP);
        }

        // description + meta
        if (row.desc) |desc| {
            try p.printStyled(ctx.allocator, style.desc, "{s}", .{desc});
        }

        if (row.meta.len != 0) {
            if (row.desc != null)
                try printSpaces(ctx, 1);

            try p.printStyled(ctx.allocator, style.meta, "{s}", .{row.meta});
        }
    }
}

pub fn printTaskUsage(ctx: *const Context, source_filepath: []const u8, task_id: []const u8) !void {
    const file = try compileRunfile(ctx, source_filepath);

    const task = file.findTask(.parse(task_id)) orelse {
        try ctx.printer.printStyled(ctx.allocator, style.err, "Task '{s}' not found\n", .{task_id});
        return TaskError.TaskNotFound;
    };

    const p = ctx.printer;

    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const positional = positionalArgs(task);

    // non positional task args + group args
    var options: std.ArrayList(*ir.Argument) = .empty;
    try options.appendSlice(a, task.args[positional.len..]);
    if (task.group) |group| {
        try options.appendSlice(a, group.args);
    }

    // Usage: tasq {task name} {positional names..} [OPTIONS]

    try p.printStyled(ctx.allocator, style.head, "Usage: ", .{});
    try p.printStyled(ctx.allocator, style.body, "tasq {s}", .{task.name});

    for (positional) |arg| {
        try p.printStyled(ctx.allocator, style.positional_name, " {s}", .{arg.name});
    }

    if (options.items.len != 0) {
        try p.printStyled(ctx.allocator, style.body, " [OPTIONS]", .{});
    }

    // Description:

    if (task.desc) |desc| {
        try p.printStyled(ctx.allocator, style.head, "\n\nDescription:", .{});
        try printLine(ctx, style.desc, "{s}", .{desc});
    }

    // Group:

    if (task.group) |group| {
        try p.printStyled(ctx.allocator, style.head, "\n\nGroup:", .{});

        p.indent();
        defer p.detend();

        try p.printStyled(ctx.allocator, style.group_name, "\n{s}", .{group.name orelse "<anonymous>"});

        if (group.desc) |desc| {
            try p.printStyled(ctx.allocator, style.group_desc, "  {s}", .{desc});
        }
    }

    // Arguments / Options share column widths, so both tables line up

    const positional_rows = try buildParamRows(a, positional, false);
    const option_rows = try buildParamRows(a, options.items, true);

    var cols: ParamColumns = .{};
    cols.grow(positional_rows);
    cols.grow(option_rows);

    // Arguments:
    //   {name}  <{type}>  {description} ({meta})

    if (positional_rows.len != 0) {
        try p.printStyled(ctx.allocator, style.head, "\n\nArguments:", .{});
        try printParamRows(ctx, positional_rows, style.positional_name, cols);
    }

    // Options:
    //   -s, --long  <{type}>  {description} ({meta})
    //       --long  <{type}>  {description} ({meta})

    if (option_rows.len != 0) {
        try p.printStyled(ctx.allocator, style.head, "\n\nOptions:", .{});
        try printParamRows(ctx, option_rows, style.option_name, cols);
    }

    try p.print(ctx.allocator, "\n", .{});
}

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

const TaskArgumentParser = struct {
    task: *ir.Task,
    printer: *Printer,

    args: std.ArrayList(*ir.Argument) = .empty,
    long_alias: std.StringHashMapUnmanaged(usize) = .empty,
    short_alias: std.AutoHashMapUnmanaged(u8, usize) = .empty,

    pub const Error = error{
        ParsingFailed,
    } || std.mem.Allocator.Error || std.Io.Writer.Error;

    pub fn init(gpa: std.mem.Allocator, task: *ir.Task, printer: *Printer) Error!TaskArgumentParser {
        var out: TaskArgumentParser = .{
            .task = task,
            .printer = printer,
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
        arena: *std.heap.ArenaAllocator,
        arguments: []const []const u8,
    ) Error!std.array_hash_map.String(Value) {
        var reader = ArgsReader.init(arguments);
        var collector = ArgsCollector.empty;

        var out: std.array_hash_map.String(Value) = .empty;

        const NumberHandler = struct {
            fn handle(str: []const u8, int: bool) ArgsReader.Error!Value {
                return if (int)
                    .{ .number = @floatFromInt(try ArgsReader.parseAs(str, i64)) }
                else
                    .{ .number = try ArgsReader.parseAs(str, f64) };
            }
        };

        // Collects a named (--long / -short) argument's value into `collector`,
        // with unified error reporting for both failure modes.
        const NamedCollector = struct {
            fn collect(
                parser: *TaskArgumentParser,
                a: *std.heap.ArenaAllocator,
                c: *ArgsCollector,
                r: *ArgsReader,
                arg: *ir.Argument,
            ) Error!void {
                const @"type": conzole.args.Type = switch (arg.type) {
                    .flag => .flag,
                    .string => .string,
                    .list_string => .list_string,
                    .number => if (arg.int) .int else .number,
                    .list_number => if (arg.int) .list_int else .list_number,
                };

                c.interceptNext(a.allocator(), r, arg.name, @"type") catch |err| return switch (err) {
                    error.InvalidType => {
                        try parser.printer.printStyled(
                            a.allocator(),
                            style.err,
                            "invalid '{s}' value type, got '{s}' expected '{f}'\n",
                            .{ arg.name, r.args[r.pos - 1], PrintableArgType.make(arg) },
                        );
                        return Error.ParsingFailed;
                    },
                    error.UnexpectedEnd => {
                        try parser.printer.printStyled(
                            a.allocator(),
                            style.err,
                            "unexpected end, '{s}' requires '{f}' value\n",
                            .{ arg.name, PrintableArgType.make(arg) },
                        );
                        return Error.ParsingFailed;
                    },
                    else => unreachable,
                };
            }
        };

        // Looks up a named argument by its long/short alias, reporting
        // "unknown argument" consistently.
        const AliasLookup = struct {
            fn long(parser: *TaskArgumentParser, a: *std.heap.ArenaAllocator, name: []const u8) Error!*ir.Argument {
                if (parser.long_alias.get(name)) |arg_idx| {
                    return parser.args.items[arg_idx];
                }
                try parser.printer.printStyled(
                    a.allocator(),
                    style.err,
                    "unknown argument '--{s}'\n",
                    .{name},
                );
                return Error.ParsingFailed;
            }

            fn short(parser: *TaskArgumentParser, a: *std.heap.ArenaAllocator, name: u8) Error!*ir.Argument {
                if (parser.short_alias.get(name)) |arg_idx| {
                    return parser.args.items[arg_idx];
                }
                try parser.printer.printStyled(
                    a.allocator(),
                    style.err,
                    "unknown argument '-{c}'\n",
                    .{name},
                );
                return Error.ParsingFailed;
            }
        };

        var positional_idx: usize = 0;
        var positional_end = false;

        while (reader.read()) |tok| {
            switch (tok.type) {
                .value => {
                    if (positional_end) {
                        try self.printer.printStyled(
                            arena.allocator(),
                            style.err,
                            "positional arguments must be placed before named ones\n",
                            .{},
                        );
                        return Error.ParsingFailed;
                    }

                    if (self.args.items.len <= positional_idx) {
                        try self.printer.printStyled(
                            arena.allocator(),
                            style.err,
                            "invalid positional argument on {} position: '{s}'\n",
                            .{ positional_idx, tok.lexeme },
                        );
                        return Error.ParsingFailed;
                    }

                    const arg = self.args.items[positional_idx];
                    positional_idx += 1;

                    //TODO: consider named-positional allowed
                    // removing this condition almost make it work
                    // problems may appear somewhere else,
                    // i.e flag nor list can never be positional
                    if (arg.is_positional == false) {
                        try self.printer.printStyled(
                            arena.allocator(),
                            style.err,
                            "'{s}' is not positional\n",
                            .{arg.name},
                        );
                        return Error.ParsingFailed;
                    }

                    const value: Value = switch (arg.type) {
                        .number => NumberHandler.handle(tok.payload, arg.int) catch |err| return switch (err) {
                            error.InvalidType => {
                                try self.printer.printStyled(
                                    arena.allocator(),
                                    style.err,
                                    "invalid argument type, got '{s}' expected '{f}'\n",
                                    .{ tok.lexeme, PrintableArgType.make(arg) },
                                );
                                return Error.ParsingFailed;
                            },
                            else => unreachable,
                        },
                        .string => .{ .string = tok.payload },
                        else => unreachable,
                    };

                    try out.put(arena.allocator(), arg.name, value);
                },
                .long => {
                    positional_end = true;

                    const arg = try AliasLookup.long(self, arena, tok.payload);
                    try NamedCollector.collect(self, arena, &collector, &reader, arg);
                },
                .short => {
                    positional_end = true;

                    const flags = tok.payload[0 .. tok.payload.len - 1];
                    const last = tok.payload[tok.payload.len - 1];

                    for (flags) |flag| {
                        const arg = try AliasLookup.short(self, arena, flag);

                        if (arg.type != .flag) {
                            std.debug.panic("TODO: handle invalid short flag pos", .{});
                        }

                        try NamedCollector.collect(self, arena, &collector, &reader, arg);
                    }

                    const arg = try AliasLookup.short(self, arena, last);
                    try NamedCollector.collect(self, arena, &collector, &reader, arg);
                },
            }
        }

        // translate collected named-argument payloads into Values
        var values = try collector.collect(arena.allocator());

        const ArgPayloadConverter = struct {
            fn convert(a: std.mem.Allocator, p: conzole.args.Payload) !Value {
                return switch (p) {
                    .flag => |v| .{ .bool = v },
                    .int => |v| .{ .number = @floatFromInt(v) },
                    .list_int => |v| {
                        const items = try a.alloc(Value, v.len);
                        for (v, items) |src, *desc| {
                            desc.* = .{ .number = @floatFromInt(src) };
                        }
                        return .{ .list = .{ .items = items, .items_type = &.number } };
                    },
                    .number => |v| .{ .number = v },
                    .list_number => |v| {
                        const items = try a.alloc(Value, v.len);
                        for (v, items) |src, *dest| {
                            dest.* = .{ .number = src };
                        }
                        return .{ .list = .{ .items = items, .items_type = &.number } };
                    },
                    .string => |v| .{ .string = v },
                    .list_string => |v| {
                        const items = try a.alloc(Value, v.len);
                        for (v, items) |src, *dest| {
                            dest.* = .{ .string = src };
                        }
                        return .{ .list = .{ .items = items, .items_type = &.string } };
                    },
                };
            }
        };

        for (self.args.items) |arg| {
            // already resolved directly while parsing (positional argument)
            if (out.contains(arg.name)) continue;

            const value = if (values.get(arg.name)) |value|
                try ArgPayloadConverter.convert(arena.allocator(), value)
            else if (arg.default) |def|
                def
            else {
                try self.printer.printStyled(
                    arena.allocator(),
                    style.err,
                    "'{s}' argument not provided\n",
                    .{arg.name},
                );
                return Error.ParsingFailed;
            };
            try out.put(arena.allocator(), arg.name, value);
        }

        // validate if everything provided
        var missing_argument: bool = false;

        if (self.task.group) |group| {
            for (group.args) |arg| {
                if (out.contains(arg.name) == false) {
                    try self.printer.printStyled(
                        arena.allocator(),
                        style.err,
                        "missing '{s}' value for '{s}' group\n",
                        .{ arg.name, group.name orelse "<anonymous>" },
                    );
                    missing_argument = true;
                }
            }
        }

        for (self.task.args) |arg| {
            if (out.contains(arg.name) == false) {
                try self.printer.printStyled(
                    arena.allocator(),
                    style.err,
                    "missing '{s}' value for '{s}' task\n",
                    .{ arg.name, self.task.name },
                );
                missing_argument = true;
            }
        }

        if (missing_argument)
            return Error.ParsingFailed;

        return out.move();
    }
};

pub fn runTask(ctx: *const Context, source_filepath: []const u8, task_id: []const u8, args: []const []const u8) !void {
    const file = try compileRunfile(ctx, source_filepath);

    const task = file.findTask(.parse(task_id)) orelse {
        try ctx.printer.printStyled(ctx.allocator, style.err, "Task '{s}' not found\n", .{task_id});
        return TaskError.TaskNotFound;
    };

    var interpreter: inter.Interpreter = try .init(
        ctx.allocator,
        ctx.io,
        ctx.printer,
        &file.options,
    );
    defer interpreter.deinit();

    var parser: TaskArgumentParser = try .init(
        ctx.allocator,
        task,
        ctx.printer,
    );
    defer parser.deinit(ctx.allocator);

    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();

    const values = try parser.parseArguments(&arena, args);

    try interpreter.run(
        task,
        ctx.environ,
        values,
    );
}
