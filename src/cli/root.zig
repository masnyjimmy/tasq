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

    var workspace: compiler.Workspace = .init(allocator);
    defer workspace.deinit();

    var diag: conzole.command.Diagnostic = undefined;

    const invokation_dir = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        ".",
        allocator,
    );
    defer allocator.free(invokation_dir);

    const cmd = try command.buildCommand(allocator);
    defer cmd.destroy();

    cmd.execute(allocator, args[1..], &diag, .{
        .allocator = allocator,
        .io = io,
        .invokation_dir = invokation_dir,
        .environ = environ,
        .printer = &printer,
        .workspace = &workspace,
    }) catch |err| return switch (err) {
        conzole.command.CommandError.InvalidArguments,
        conzole.command.CommandError.CommandFailed,
        => {
            try printer.printStyled(allocator, .{ .fg = .bright_red }, "{f}\n", .{diag});
        },
        else => err,
    };

    try stdout_writer.flush();
}
