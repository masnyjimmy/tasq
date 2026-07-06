const std = @import("std");
const lib = @import("lib");
const conzole = @import("conzole");

const AppContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    printer: *conzole.terminal.Printer,
    diagnostics: *lib.Diagnostic.List,
    source_store: *lib.source_file.SourceStore,

    const TaskContext = @import("task.zig");

    fn getTaskContext(self: *const AppContext) TaskContext {
        return TaskContext{
            .diagnostics = self.diagnostics,
            .filepath = "tasq",
            .gpa = self.gpa,
            .io = self.io,
            .printer = self.printer,
            .source_store = self.source_store,
        };
    }
};

const Command = conzole.CommandWithContext(AppContext);

const Context = Command.Context;

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
        ctx.app.gpa,
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

    var task_ctx = ctx.app.getTaskContext();
    task_ctx.runTask(task, args) catch |err| return switch (err) {
        error.TaskNotFound => {
            std.debug.panic("Task not found", .{});
        },
        else => err,
    };
}

fn ShowUsage(ctx: *const Context) !void {
    switch (ctx.args.len) {
        1 => {},
        else => std.debug.panic("Invalid number of arguments", .{}),
    }

    const taskName = ctx.args[0];

    var task_ctx = ctx.app.getTaskContext();
    try task_ctx.printTaskUsage(taskName);
}

fn RunList(ctx: *const Context) !void {
    var task_ctx = ctx.app.getTaskContext();
    try task_ctx.printTasksList();
}

fn RunLsp(_: *const Context) !void {}

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

    return rootCmd;
}
