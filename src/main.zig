const std = @import("std");
const cli = @import("cli");
const compiler = @import("compiler");
const lsp = @import("lsp");

pub fn lsp_test(init: std.process.Init) !void {
    var workspace = compiler.Workspace.init(init.gpa);
    defer workspace.deinit();

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, "tasq", init.gpa, .unlimited);
    defer init.gpa.free(source);

    const result = try workspace.openFile("tasq", source, 0);

    const file = workspace.getFileState(result.id);

    _ = try lsp.semantic_token.Collector.collect(init.arena.allocator(), file.tree.?, file.ir.?.scope);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (std.mem.eql(u8, args[1], "::LSP_TEST")) {
        try lsp_test(init);
        return;
    }

    try cli.run(
        init.gpa,
        init.io,
        init.environ_map,
        args,
    );
}

// const std = @import("std");
// const lib = @import("lib");
// const compiler = @import("compiler");

// const conzole = @import("conzole");

// pub fn dump_diagnostics(
//     allocator: std.mem.Allocator,
//     source: []const u8,
//     uri: []const u8,
//     diagnostics: *const compiler.Diagnostics,
//     printer: *conzole.terminal.Printer,
// ) !void {
//     const records = diagnostics.records.items;

//     for (records) |record| {
//         const lc = try lib.debug.lineColFromIndex(source, record.span.start);

//         try printer.printStyled(
//             allocator,
//             .{ .fg = .white },
//             "{[file]s}:{[line]}:{[col]}",
//             .{ .file = uri, .line = lc.line, .col = lc.column },
//         );

//         const severity_color: conzole.terminal.Color = switch (record.severity) {
//             .err => .bright_red,
//             .hint => .bright_green,
//             .warn => .yellow,
//         };

//         try printer.printStyled(
//             allocator,
//             .{ .bold = true, .fg = severity_color },
//             "{f}: ",
//             .{record.severity},
//         );

//         try printer.printStyled(
//             allocator,
//             .{ .fg = .bright_white },
//             "{s}\n",
//             .{record.message},
//         );
//     }

//     try printer.flush();
// }

// pub fn main(init: std.process.Init) !void {
//     const cwd = std.Io.Dir.cwd();

//     const source = try cwd.readFileAlloc(init.io, "tasq", init.gpa, .unlimited);
//     defer init.gpa.free(source);

//     var workspace: compiler.Workspace = .init;
//     defer workspace.deinit(init.gpa);

//     const result = try workspace.openFile(init.gpa, "tasq", source, 0);

//     const file = workspace.getFileState(result.id);

//     var buffer: [1024]u8 = undefined;
//     var writer = std.Io.File.stdout().writer(init.io, &buffer);

//     try compiler.cst.debug.printTree(&writer.interface, file.tree.?);
//     try writer.flush();

//     lib.debug.dump(file.ir.?, 4);

//     var printer = conzole.terminal.Printer.init(&writer.interface);

//     try dump_diagnostics(
//         init.gpa,
//         source,
//         file.uri,
//         &file.diagnostics,
//         &printer,
//     );
// }
