const std = @import("std");
const cli = @import("cli");
const lib = @import("lib");
const compiler = @import("compiler");
const lsp = @import("lsp");

pub fn lsp_test(init: std.process.Init) !void {
    var workspace = compiler.Workspace.init;
    defer workspace.deinit(init.gpa);

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, "tasq", init.gpa, .unlimited);
    defer init.gpa.free(source);

    const file_id = try workspace.openFile(init.gpa, "tasq", source, 0);

    const ast_view = workspace.view(file_id.id, .tree);
    const ir_view = workspace.view(file_id.id, .ir);
    const span_view = workspace.view(file_id.id, .span);

    _ = try lsp.semantic_token.Collector.collect(init.arena.allocator(), ast_view.source, ir_view.source.scope, span_view.source);
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
