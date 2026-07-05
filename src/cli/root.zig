const std = @import("std");
const lib = @import("lib");

const command = @import("command.zig");
const conzole = @import("conzole");

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8) !void {
    var diagnostics: lib.Diagnostic.List = .init(allocator);
    defer diagnostics.deinit();
    var buffer: [4096]u8 = undefined;

    var stdout = std.Io.File.stdout();
    var stdout_writer = stdout.writer(io, &buffer);

    var printer = conzole.terminal.Printer.initConfig(
        &stdout_writer.interface,
        .{
            .autoFlush = true,
        },
    );

    var source_store = lib.source_file.SourceStore.init();
    defer source_store.deinit(allocator);

    var diag: conzole.command.Diagnostic = undefined;

    const cmd = try command.buildCommand(allocator);
    defer cmd.destroy();
    lib.debug.dump(args, 4);
    cmd.execute(allocator, args, &diag, .{
        .diagnostics = &diagnostics,
        .gpa = allocator,
        .io = io,
        .environ = environ,
        .printer = &printer,
        .source_store = &source_store,
    }) catch |err| {
        if (err == conzole.command.CommandError.InvalidArguments) {
            try printer.printStyled(allocator, .{ .fg = .bright_red }, "{f}\n", .{diag});
        } else {
            for (diagnostics.items.items) |d| {
                switch (d.details) {
                    .span => |span| {
                        if (span == lib.Span.Unknown) {
                            try printer.printStyled(allocator, .{ .fg = .white }, "unknown span: ", .{});
                        } else {
                            try printer.printStyled(allocator, .{ .fg = .white }, "{[file]s}:{[line]}:{[col]}: ", args: {
                                const file = try source_store.getFile(span.sourceId);
                                const lineCol = try lib.debug.lineColFromIndex(file.text, span.start);
                                break :args .{
                                    .file = file.path,
                                    .line = lineCol.line,
                                    .col = lineCol.column,
                                };
                            });
                        }
                    },
                    .argument => |argIdx| try printer.printStyled(allocator, .{ .fg = .white }, "at argument [{?}]: ", .{argIdx}),
                    .runtime => try printer.printStyled(allocator, .{ .bold = true, .fg = .bright_yellow }, "runtime: ", .{}),
                }

                const severity_color: conzole.terminal.Color = switch (d.severity) {
                    .err => .bright_red,
                    .hint => .bright_green,
                    .warning => .yellow,
                };

                try printer.printStyled(
                    allocator,
                    .{ .bold = true, .fg = severity_color },
                    "{f}: ",
                    .{d.severity},
                );

                try printer.printStyled(
                    allocator,
                    .{ .fg = .bright_white },
                    "{s}\n",
                    .{d.message},
                );
            }
        }

        return err;
    };

    try stdout_writer.flush();
}
