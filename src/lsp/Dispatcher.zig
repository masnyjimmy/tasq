const std = @import("std");

const lsp = @import("lsp_kit");

const compiler = @import("compiler");
const ir = compiler.ir;
const Workspace = compiler.Workspace;

const Dispatcher = @This();

const sem = @import("semantic_token.zig");

allocator: std.mem.Allocator,
workspace: *Workspace,

offset_encodings: lsp.offsets.Encoding = .@"utf-16",

pub fn init(allocator: std.mem.Allocator, workspace: *Workspace) Dispatcher {
    return .{
        .allocator = allocator,
        .workspace = workspace,
    };
}

pub fn deinit(_: *Dispatcher) void {}

pub fn initialize(
    self: *Dispatcher,
    _: std.mem.Allocator,
    request: lsp.types.InitializeParams,
) lsp.types.InitializeResult {
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
                    .change = .Incremental,
                },
            },
            .hoverProvider = .{ .bool = true },
            .completionProvider = .{ .triggerCharacters = &.{"."} },
            .semanticTokensProvider = .{
                .semantic_tokens_options = .{
                    .legend = .{
                        .tokenTypes = sem.TokenType.getNames(),
                        .tokenModifiers = sem.TokenModifier.getNames(),
                    },
                    .full = .{ .bool = true },
                },
            },
            .diagnosticProvider = .{
                .diagnostic_options = .{
                    .interFileDependencies = false,
                    .workspaceDiagnostics = false,
                },
            },
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

    if (self.workspace.getId(notification.textDocument.uri)) |file_id| {
        std.log.warn("Document opened twice: '{s}'", .{notification.textDocument.uri});

        _ = try self.workspace.changeFile(self.allocator, file_id, notification.textDocument.text, notification.textDocument.version);
        return;
    }

    _ = try self.workspace.openFile(
        self.allocator,
        notification.textDocument.uri,
        notification.textDocument.text,
        notification.textDocument.version,
    );
}

pub fn @"textDocument/didChange"(
    self: *Dispatcher,
    _: std.mem.Allocator,
    notification: lsp.types.TextDocument.DidChangeParams,
) !void {
    std.log.debug("Received 'textDocument/didChange' notification", .{});

    const file_id = blk: {
        if (self.workspace.getId(notification.textDocument.uri)) |id|
            break :blk id;

        std.log.warn("Modifying non existent document: '{s}'", .{notification.textDocument.uri});
        return;
    };

    const view = self.workspace.view(file_id, .source);

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(self.allocator);

    try buffer.appendSlice(self.allocator, view.source);

    for (notification.contentChanges) |cc| {
        switch (cc) {
            .text_document_content_change_whole_document => |change| {
                buffer.clearRetainingCapacity();
                try buffer.appendSlice(self.allocator, change.text);
            },
            .text_document_content_change_partial => |change| {
                const loc = lsp.offsets.rangeToLoc(buffer.items, change.range, self.offset_encodings);
                try buffer.replaceRange(self.allocator, loc.start, loc.end - loc.start, change.text);
            },
        }
    }
    const new_text = try buffer.toOwnedSlice(self.allocator);
    _ = try self.workspace.changeFile(self.allocator, file_id, new_text, notification.textDocument.version);
}

pub fn @"textDocument/didClose"(
    self: *Dispatcher,
    _: std.mem.Allocator,
    notification: lsp.types.TextDocument.DidCloseParams,
) !void {
    std.log.debug("Received 'textDocument/didClose' notification", .{});

    const file_id = blk: {
        if (self.workspace.getId(notification.textDocument.uri)) |id|
            break :blk id;

        std.log.warn("Closing non existent Document: '{s}'", .{notification.textDocument.uri});
        return;
    };

    try self.workspace.closeFile(self.allocator, file_id);
}

pub fn @"textDocument/hover"(
    self: *Dispatcher,
    _: std.mem.Allocator,
    params: lsp.types.Hover.Params,
) ?lsp.types.Hover {
    std.log.debug("Received 'textDocument/hover' request", .{});

    const file_id = blk: {
        if (self.workspace.getId(params.textDocument.uri)) |file_id|
            break :blk file_id;

        std.log.warn("Hover on non existent document: '{s}'", .{params.textDocument.uri});
        return null;
    };

    const view = self.workspace.view(file_id, .source);

    const source_index = lsp.offsets.positionToIndex(view.source, params.position, self.offset_encodings);
    std.log.debug("Hover position: line={d}, character={d}, index={d}", .{
        params.position.line, params.position.character, source_index,
    });

    return .{
        .contents = .{
            .markup_content = .{
                .kind = .plaintext,
                .value = "hello",
            },
        },
    };
}

pub fn @"textDocument/completion"(
    _: *Dispatcher,
    arena: std.mem.Allocator,
    params: lsp.types.completion.Params,
) !?lsp.types.completion.Result {
    std.log.debug("Received 'textDocument/completion' notification", .{});

    if (params.context) |ctx| {
        std.log.info("completion triggered by {?s} {t}", .{ ctx.triggerCharacter, ctx.triggerKind });
    }

    const completions = try arena.dupe(lsp.types.completion.Item, &.{
        .{ .label = "get", .detail = "get the value" },
        .{ .label = "set", .detail = "set the value" },
    });

    return .{ .completion_items = completions };
}

pub fn @"textDocument/semanticTokens/full"(
    self: *Dispatcher,
    arena: std.mem.Allocator,
    params: lsp.types.semantic_tokens.Params,
) !?lsp.types.semantic_tokens.Result {
    std.log.debug("Received 'textDocument/semanticTokens/full'", .{});

    const file_id = self.workspace.getId(params.textDocument.uri) orelse return null;

    const source_view = self.workspace.view(file_id, .source);
    const ast_view = self.workspace.view(file_id, .tree);
    const span_registry = self.workspace.view(file_id, .span);

    const raw_tokens = try sem.Collector.collect(arena, ast_view.source, span_registry.source);

    var data: std.ArrayList(u32) = .empty;
    var prev_line: u32 = 0;
    var prev_char: u32 = 0;

    for (raw_tokens) |raw| {
        const start_pos = lsp.offsets.indexToPosition(source_view.source, raw.start, self.offset_encodings);
        const len = lsp.offsets.locLength(source_view.source, .{ .start = raw.start, .end = raw.end }, self.offset_encodings);

        const line: u32 = @intCast(start_pos.line);
        const char: u32 = @intCast(start_pos.character);

        const delta_line = line - prev_line;
        const delta_char = if (delta_line == 0) char - prev_char else char;

        try data.appendSlice(arena, &.{ delta_line, delta_char, @intCast(len), raw.ttype, raw.mods });

        prev_line = line;
        prev_char = char;
    }

    return .{ .data = data.items };
}

pub fn @"textDocument/diagnostic"(
    self: *Dispatcher,
    arena: std.mem.Allocator,
    params: lsp.types.document_diagnostic.Params,
) !lsp.types.document_diagnostic.Report {
    std.log.debug("Received 'textDocument/diagnostics'", .{});
    const file_id = self.workspace.getId(params.textDocument.uri) orelse {
        std.log.warn("Diagnostics on non existent document: '{s}'", .{params.textDocument.uri});
        return error.InvalidRequest;
    };

    const file = self.workspace.files.getPtr(file_id) orelse unreachable;

    const diagnostics = file.diagnostics;

    const result = try arena.alloc(lsp.types.Diagnostic, diagnostics.records.items.len);

    for (diagnostics.records.items, result) |in, *out| {
        out.* = .{
            .message = in.message,
            .range = lsp.offsets.locToRange(
                file.source,
                .{
                    .start = in.span.start,
                    .end = in.span.end(),
                },
                self.offset_encodings,
            ),
            .severity = switch (in.severity) {
                .err => .Error,
                .warn => .Warning,
                .hint => .Hint,
            },
        };
    }

    return .{
        .related_full_document_diagnostic_report = .{
            .items = result,
        },
    };
}

pub fn onResponse(_: *Dispatcher, _: std.mem.Allocator, response: lsp.JsonRPCMessage.Response) void {
    std.log.warn("received unexpected response from client with id '{?}'!", .{response.id});
}
