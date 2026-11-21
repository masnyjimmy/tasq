const std = @import("std");

const Dispatcher = @import("Dispatcher.zig");
const lsp = @import("lsp_kit");

const lib = @import("lib");

const compiler = @import("compiler");
const Workspace = compiler.Workspace;

pub const semantic_token = @import("semantic_token.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    var read_buffer: [256]u8 = undefined;

    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    var regex_cache: lib.regex.Cache = .init(allocator);
    defer regex_cache.deinit();

    var workspace: Workspace = .init(allocator, &regex_cache);
    defer workspace.deinit();

    var dispatcher: Dispatcher = .init(allocator, &workspace);
    defer dispatcher.deinit();

    try lsp.basic_server.run(io, allocator, transport, &dispatcher, std.log.err);
}
