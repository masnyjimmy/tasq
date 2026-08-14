const std = @import("std");
const lib = @import("lib");
const conzole = @import("conzole");

const AppContext = @import("context.zig");

const Command = conzole.CommandWithContext(AppContext);

const Context = Command.Context;

const task_mod = @import("task.zig");

const DEFAULT_FILEPATH = "tasq";

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

    try task_mod.runTask(
        &ctx.app,
        ctx.getValueT("file", .string) orelse DEFAULT_FILEPATH,
        task,
        args,
    );
}

fn ShowUsage(ctx: *const Context) !void {
    switch (ctx.args.len) {
        1 => {},
        else => std.debug.panic("Invalid number of arguments", .{}),
    }

    const taskName = ctx.args[0];

    try task_mod.printTaskUsage(
        &ctx.app,
        ctx.getValueT("file", .string) orelse DEFAULT_FILEPATH,
        taskName,
    );
}

fn RunList(ctx: *const Context) !void {
    try task_mod.printTasksList(
        &ctx.app,
        ctx.getValueT("file", .string) orelse DEFAULT_FILEPATH,
    );
}

fn RunLsp(ctx: *const Context) !void {
    const lsp = @import("lsp");

    try lsp.run(ctx.app.allocator, ctx.app.io);
}

fn Dump(ctx: *const Context) !void {
    const compiler = @import("compiler");

    const Target = enum {
        source,
        tree,
        ir,
        spans,

        const string = blk: {
            var out: []const u8 = "";

            const ti = @typeInfo(@This()).@"enum";
            const last = ti.fields.len - 1;

            for (ti.fields, 0..) |f, idx| {
                out = out ++ f.name;

                if (idx != last)
                    out = out ++ ", ";
            }

            break :blk out;
        };

        const map = lib.enums.generateEnumNameMap(@This());
    };

    switch (ctx.args.len) {
        1 => {},
        else => return ctx.fail("Invalid arguments, required [{s}]", .{Target.string}),
    }

    const target = Target.map.get(ctx.args[0]) orelse return ctx.fail("Invalid arguments, required [{s}]", .{Target.string});

    const cwd = std.Io.Dir.cwd();
    const source = try cwd.readFileAlloc(
        ctx.app.io,
        ctx.getValueT("file", .string) orelse DEFAULT_FILEPATH,
        ctx.app.allocator,
        .unlimited,
    );
    defer ctx.app.allocator.free(source);

    var diagnostics: compiler.Diagnostics = .init(ctx.app.allocator);
    defer diagnostics.deinit();

    const Dumper = struct {
        fn dump(c: *const Context, d: *compiler.Diagnostics, t: Target, s: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(c.app.allocator);
            defer arena.deinit();

            if (t == .source) {
                try c.app.printer.print(arena.allocator(), "{s}", .{s});
                return;
            }

            var span_registry = compiler.Span.Registry.init(c.app.allocator);
            defer span_registry.deinit();

            var lexer = compiler.Lexer.init(s, &span_registry);

            var parser = try compiler.Parser.init(
                &arena,
                &lexer,
                &span_registry,
                d,
            );

            const ast = try parser.parseFile();

            if (t == .tree) {
                lib.debug.dump(ast, 4);
                return;
            }

            if (t == .spans) {
                lib.debug.dump(span_registry.nodes, 4);
                return;
            }

            var sema = compiler.Sema.init(
                &arena,
                &span_registry,
                d,
            );

            const ir = try sema.analyse(&ast);
            lib.debug.dump(ir, 4);
        }
    };

    try Dumper.dump(ctx, &diagnostics, target, source);

    const dd = @import("dump_diagnostics.zig");

    try dd.dump_diagnostics(
        ctx.app.allocator,
        source,
        ctx.getValueT("file", .string) orelse DEFAULT_FILEPATH,
        &diagnostics,
        ctx.app.printer,
    );
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
        .name = "file",
        .brief = "Target file, overrides tasq",
        .global = true,
    }, .string);

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
