const std = @import("std");
const cli = @import("cli");
const lib = @import("lib");
const compiler = @import("compiler");

pub fn test_main(init: std.process.Init) !void {
    var source_store = lib.source_file.SourceStore.init();

    const id = try source_store.loadFile(init.arena.allocator(), init.io, "tasq");

    const source = try source_store.view(id);
    var diag = lib.Diagnostic.List.init(init.arena.allocator());

    const result = compiler.compile(init.arena.allocator(), source, &diag) catch |err| {
        for (diag.items.items) |item| {
            const line_col = try lib.debug.lineColFromIndex(source.text, item.details.span.start);

            std.debug.print("./tasq:{}:{}: {s}\n", .{ line_col.line, line_col.column, item.message });
        }

        return err;
    };

    lib.debug.dump(result.result, 4);
}

pub fn run_main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    try cli.run(
        init.gpa,
        init.io,
        init.environ_map,
        args,
    );
}

pub fn main(init: std.process.Init) !void {
    try run_main(init);
}
