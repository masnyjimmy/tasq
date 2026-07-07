const std = @import("std");

const lsp = @import("lsp_kit");

const compiler = @import("compiler");
const ir = compiler.ir;

const Dispatcher = @This();

allocator: std.mem.Allocator,
files: std.hash_map.StringHashMapUnmanaged([]u8) = .empty,

offset_encodings: lsp.offsets.Encoding = .@"utf-16",

pub fn init(allocator: std.mem.Allocator) Dispatcher {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Dispatcher) void {
    self.files.deinit(self.allocator);
}

pub fn initialize(self: *Dispatcher, _: std.mem.Allocator, request: lsp.types.InitializeParams) lsp.types.InitializeResult {
    if (request.clientInfo) |info| {
        std.log.info("The client is '{s}' ({s})", .{ info.name, info.version orelse "unknown version" });
    }

    if (request.capabilities.general) |general| {
        for (general.positionEncodings orelse &.{}) |enc| {
            self.offset_encodings = switch (enc) {
                .custom_value => continue,
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
            };
            break;
        }
    }

    return .{
        .serverInfo = .{ .name = "tasq-lsp", .version = "0.0.1" },
        .capabilities = .{
            .positionEncoding = switch (self.offset_encodings) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
            },
            .textDocumentSync = .{
                .text_document_sync_options = .{
                    .openClose = true,
                    .change = .Full, //TODO: change to incremental if possible
                },
            },
            .hoverProvider = .{ .bool = true },
            .completionProvider = .{ .triggerCharacters = &.{"."} },
        },
    };
}

pub fn initialized(_: *Dispatcher, _: std.mem.Allocator, _: lsp.types.InitializedParams) void {
    std.log.debug("Received 'initialized' notification", .{});
}

pub fn shutdown(_: *Dispatcher, _: std.mem.Allocator, _: void) ?void {
    std.log.debug("Received 'shutdown' notification", .{});
    return null;
}

pub fn exit(_: *Dispatcher, _: std.mem.Allocator, _: void) void {
    std.log.debug("Received 'exit' notification", .{});
}

pub fn @"textDocument/didOpen"(
    self: *Dispatcher,
    _: std.mem.Allocator,
    notification: lsp.types.TextDocument.DidOpenParams,
) !void {
    std.log.debug("Received 'textDocument/didOpen' notification", .{});

    const new_text = try self.allocator.dupe(u8, notification.textDocument.text);
    errdefer self.allocator.free(new_text);

    const gop = try self.files.getOrPut(self.allocator, notification.textDocument.uri);

    if (gop.found_existing) {
        std.log.warn("Document opened twice: '{s}'", .{notification.textDocument.uri});
        self.allocator.free(gop.value_ptr.*);
    } else {
        errdefer std.debug.assert(self.files.remove(notification.textDocument.uri));
        // FIX 1: dupe(u8, slice) not dupe(allocator, []u8, slice)
        gop.key_ptr.* = try self.allocator.dupe(u8, notification.textDocument.uri);
    }

    gop.value_ptr.* = new_text;
}

pub fn @"textDocument/didClose"(
    self: *Dispatcher,
    _: std.mem.Allocator,
    notification: lsp.types.TextDocument.DidCloseParams,
) !void {
    std.log.debug("Received 'textDocument/didClose' notification", .{});

    const entry = self.files.fetchRemove(notification.textDocument.uri) orelse {
        std.log.warn("Closing non existent Document: '{s}'", .{notification.textDocument.uri});
        return;
    };
    self.allocator.free(entry.key);
    self.allocator.free(entry.value);
}
