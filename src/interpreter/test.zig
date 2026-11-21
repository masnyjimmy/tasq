const std = @import("std");

const lib = @import("lib");

const conzole = @import("conzole");
const Printer = conzole.terminal.Printer;

const compiler = @import("compiler");
const Workspace = compiler.Workspace;

const Runtime = @import("Runtime.zig");

const features_source = @embedFile("features.tasq");

test "features" {
    var regex_cache: lib.regex.Cache = .init(std.testing.allocator);
    defer regex_cache.deinit();

    var workspace: Workspace = .init(
        std.testing.allocator,
        &regex_cache,
    );
    defer workspace.deinit();

    const result = try workspace.openFile(
        "embed",
        features_source,
        0,
    );

    try std.testing.expect(result.valid);

    const file = workspace.getFileState(result.id);

    var aw = std.Io.Writer.Discarding.init(&.{});

    var printer: Printer = .init(&aw.writer);
    defer printer.deinit();

    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();

    const invokation_dir = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(invokation_dir);

    var runtime: Runtime = try .init(
        std.testing.allocator,
        invokation_dir,
        std.testing.io,
        &environ,
        &printer,
        &regex_cache,
        &file.ir.?,
    );
    defer runtime.deinit();

    const program = file.ir.?;

    const symbol = program.scope.resolve("test", .task) orelse {
        std.testing.failPrintLine("failed resolve task");
        return error.FailedTaskResolve;
    };

    const task = symbol.origin.task;

    try runtime.run(
        task,
        .empty,
    );
}
