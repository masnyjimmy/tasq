const std = @import("std");
const lib = @import("lib");

const command = @import("command.zig");
const conzole = @import("conzole");
const compiler = @import("compiler");

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
    lib.debug.dump(args, 4);
    cmd.execute(allocator, args[1..], &diag, .{
        .allocator = allocator,
        .io = io,
        .environ = environ,
        .printer = &printer,
        .workspace = &workspace,
    }) catch |err| {
        if (err == conzole.command.CommandError.InvalidArguments) {
            try printer.printStyled(allocator, .{ .fg = .bright_red }, "{f}\n", .{diag});
        } else {
            var iter = workspace.files.iterator();
            while (iter.next()) |kv| {
                const file = kv.value_ptr;
                for (file.diagnostics.records.items) |record| {
                    try printer.printStyled(allocator, .{ .fg = .white }, "{[file]s}:{[line]}:{[col]}: ", args: {
                        const line_col = try lib.debug.lineColFromIndex(file.source, record.span.start);
                        break :args .{
                            .file = file.uri,
                            .line = line_col.line,
                            .col = line_col.column,
                        };
                    });

                    const severity_color: conzole.terminal.Color = switch (record.severity) {
                        .err => .bright_red,
                        .hint => .bright_green,
                        .warn => .yellow,
                    };

                    try printer.printStyled(
                        allocator,
                        .{ .bold = true, .fg = severity_color },
                        "{f}: ",
                        .{record.severity},
                    );

                    try printer.printStyled(
                        allocator,
                        .{ .fg = .bright_white },
                        "{s}\n",
                        .{record.message},
                    );
                }
            }

            stdout_writer.flush() catch unreachable;
        }

        return err;
    };

    try stdout_writer.flush();
}
