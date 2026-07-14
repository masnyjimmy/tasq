const std = @import("std");
const lib = @import("lib");
const conzole = @import("conzole");

const AppContext = @import("context.zig");

const Command = conzole.CommandWithContext(AppContext);

const Context = Command.Context;

const task_mod = @import("task.zig");

fn GlobalPreHandler(ctx: *const Context) !void {
    if (ctx.root != ctx.current or ctx.args.len == 0) {
        if (ctx.has("help")) {
            try ctx.current.writeHelp(ctx.app.printer);
            ctx.stop();
            return;
        }
    }
}

fn PrintVersion(ctx: *const Context) !void {
    try ctx.app.printer.printStyled(
        ctx.app.allocator,
        .{ .fg = .bright_white },
        "later bro",
        .{},
    );
}

fn RunTask(ctx: *const Context) !void {
    if (ctx.args.len == 0) {
        std.debug.panic("No task name provided", .{});
    }

    const task = ctx.args[0];
    const args = ctx.args[1..];

    try task_mod.runTask(&ctx.app, task, args);
}

fn ShowUsage(ctx: *const Context) !void {
    switch (ctx.args.len) {
        1 => {},
        else => std.debug.panic("Invalid number of arguments", .{}),
    }

    const taskName = ctx.args[0];

    try task_mod.printTaskUsage(&ctx.app, taskName);
}

fn RunList(ctx: *const Context) !void {
    try task_mod.printTasksList(&ctx.app);
}

fn RunLsp(ctx: *const Context) !void {
    const lsp = @import("lsp");

    try lsp.run(ctx.app.allocator, ctx.app.io);
}

fn Dump(ctx: *const Context) !void {
    const map = comptime lib.enums.generateEnumNameMap(enum { ast, ir });

    switch (ctx.args.len) {
        1 => {},
        else => return ctx.fail("Invalid arguments, required [ast, ir]", .{}),
    }

    const target = map.get(ctx.args[0]) orelse return ctx.fail("Invalid arguments, required [ast, ir]", .{});

    const cwd = std.Io.Dir.cwd();

    var arena = std.heap.ArenaAllocator.init(ctx.app.allocator);
    defer arena.deinit();

    const source = try cwd.readFileAlloc(ctx.app.io, ctx.app.source_file_path, arena.allocator(), .unlimited);

    const comp = @import("compiler");
    var span_registry = comp.Span.Registry.init(ctx.app.allocator);

    var lexer = comp.Lexer.init(source, &span_registry);
    var diagnostics: comp.Diagnostics = .init(arena.allocator());

    var parser = try comp.Parser.init(
        &arena,
        &lexer,
        &span_registry,
        &diagnostics,
    );

    const ast = try parser.parseFile();

    if (target == .ast) {
        lib.debug.dump(ast, 4);
        return;
    }

    var sema = comp.Sema.init(
        &arena,
        &span_registry,
        &diagnostics,
    );

    const ir = try sema.analyse(ast);

    lib.debug.dump(ir, 4);
}

pub fn buildCommand(allocator: std.mem.Allocator) !*Command {
    var rootCmd = try Command.create(allocator, .{
        .name = "tasq",
        .brief = "task language cli",
        .persistent_pre_run = .set(GlobalPreHandler),
        .run = .set(RunTask),
        .unknown_flag_behaviour = .as_positional,
    });

    try rootCmd.addFlag(.{
        .name = "help",
        .brief = "Shows this help message",
        .global = true,
    }, .flag);

    _ = try rootCmd.createSub(.{
        .name = "--version",
        .brief = "Display app version",
        .run = .set(PrintVersion),
    });

    _ = try rootCmd.createSub(.{
        .name = "--list",
        .brief = "Display list of tasks",
        .run = .set(RunList),
    });

    _ = try rootCmd.createSub(.{
        .name = "--usage",
        .brief = "Display usage of task",
        .run = .set(ShowUsage),
    });

    var lspCmd = try rootCmd.createSub(.{
        .name = "--lsp",
        .brief = "Starts lsp server protocol on stdio",
        .run = .set(RunLsp),
    });

    try lspCmd.addFlag(.{
        .name = "stdio",
        .brief = "choose stdio as transport layer",
        .short = null,
    }, .flag);

    _ = try rootCmd.createSub(.{
        .name = "--dump",
        .brief = "dumps either ast tree or ir into stdout",
        .run = .set(Dump),
    });

    return rootCmd;
}
