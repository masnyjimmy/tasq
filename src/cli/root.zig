const std = @import("std");
const lib = @import("lib");

const command = @import("command.zig");
const conzole = @import("conzole");
const compiler = @import("compiler");

const TaskError = @import("task.zig").TaskError;

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8) !void {
    var buffer: [4096]u8 = undefined;

    var stdout = std.Io.File.stdout();
    var stdout_writer = stdout.writer(io, &buffer);

    var printer = conzole.terminal.Printer.initConfig(
        &stdout_writer.interface,
        .{
            .autoFlush = true,
        },
    );

    var workspace: compiler.Workspace = .init;
    defer workspace.deinit(allocator);

    //TODO: handle non-compiling error in different way
    var diag: conzole.command.Diagnostic = undefined;

    const cmd = try command.buildCommand(allocator);
    defer cmd.destroy();
    cmd.execute(allocator, args[1..], &diag, .{
        .allocator = allocator,
        .io = io,
        .environ = environ,
        .printer = &printer,
        .workspace = &workspace,
    }) catch |err| return switch (err) {
        conzole.command.CommandError.InvalidArguments => {
            try printer.printStyled(allocator, .{ .fg = .bright_red }, "{f}\n", .{diag});
        },
        else => err,
    };

    try stdout_writer.flush();
}
