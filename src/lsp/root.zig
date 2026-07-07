const std = @import("std");

const Dispatcher = @import("Dispatcher.zig");
const lsp = @import("lsp_kit");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    var read_buffer: [256]u8 = undefined;

    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    var dispatcher: Dispatcher = .init(allocator);
    defer dispatcher.deinit();

    try lsp.basic_server.run(io, allocator, transport, &dispatcher, std.log.err);
}
