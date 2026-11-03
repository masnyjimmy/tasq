const std = @import("std");

const conzole = @import("conzole");
const Printer = conzole.terminal.Printer;

const compiler = @import("compiler");
const Workspace = compiler.Workspace;

const Interpreter = @import("interpreter.zig");

const features_source = @embedFile("features.tasq");

test "features" {
    var workspace: Workspace = .init(std.testing.allocator);
    defer workspace.deinit();

    const result = try workspace.openFile("embed", features_source, 0);

    const file = workspace.getFileState(result.id);

    var aw = std.Io.Writer.Discarding.init(&.{});

    var printer: Printer = .init(&aw.writer);
    defer printer.deinit();

    var interpreter: Interpreter = try .init(
        std.testing.allocator,
        std.testing.io,
        &printer,
        &compiler.platform.default_options,
    );
    defer interpreter.deinit();

    const program = file.ir.?;

    const symbol = program.scope.resolve("test", .task) orelse {
        std.testing.failPrintLine("failed resolve task");
        return error.FailedTaskResolve;
    };

    const task = symbol.origin.task;

    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();

    try interpreter.run(
        task,
        &environ,
        .empty,
    );
}
