const std = @import("std");
const lib = @import("lib");
const lsp = @import("lsp_kit");

const compiler = @import("compiler");
const ir = compiler.ir;
const Workspace = compiler.Workspace;

const Dispatcher = @This();

const sem = @import("semantic_token.zig");

allocator: std.mem.Allocator,
workspace: *Workspace,
capabilities: Capabilities = undefined,

pub fn init(allocator: std.mem.Allocator, workspace: *Workspace) Dispatcher {
    return .{
        .allocator = allocator,
        .workspace = workspace,
    };
}

const Capabilities = struct {
    offset_encoding: lsp.offsets.Encoding,
    snippets: bool,

    const default: Capabilities = .{
        .offset_encoding = .@"utf-16",
        .snippets = false,
    };

    fn from(capabilities: lsp.types.ClientCapabilities) Capabilities {
        var self: Capabilities = .default;

        if (capabilities.general) |general| {
            for (general.positionEncodings orelse &.{}) |enc| {
                self.offset_encoding = switch (enc) {
                    .custom_value => continue,
                    inline else => |_, tag| lib.enums.castEnum(tag, lsp.offsets.Encoding) orelse continue,
                };
                break;
            }
        }

        if (capabilities.textDocument) |textDocument| {
            if (textDocument.completion) |completion| {
                if (completion.completionItem) |completionItem| {
                    if (completionItem.snippetSupport) |snippetSupport|
                        self.snippets = snippetSupport;
                }
            }
        }

        return self;
    }
};

pub fn deinit(_: *Dispatcher) void {}

pub fn initialize(
    self: *Dispatcher,
    _: std.mem.Allocator,
    request: lsp.types.InitializeParams,
) lsp.types.InitializeResult {
    if (request.clientInfo) |info| {
        std.log.info("The client is '{s}' ({s})", .{ info.name, info.version orelse "unknown version" });
    }

    self.capabilities = .from(request.capabilities);
    std.log.info("Client capabilities:\n{any}\n", .{self.capabilities});

    return .{
        .serverInfo = .{ .name = "tasq-lsp", .version = "0.0.1" },
        .capabilities = .{
            .positionEncoding = switch (self.capabilities.offset_encoding) {
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

fn indexToPosition(self: *const Dispatcher, source: []const u8, index: u32) lsp.types.Position {
    return lsp.offsets.indexToPosition(source, @intCast(index), self.capabilities.offset_encoding);
}

fn positionToIndex(self: *const Dispatcher, source: []const u8, position: lsp.types.Position) u32 {
    const index = lsp.offsets.positionToIndex(source, position, self.capabilities.offset_encoding);
    return @intCast(index);
}

fn indexesToRange(self: *const Dispatcher, source: []const u8, start: u32, end: u32) lsp.types.Range {
    return .{
        .start = self.indexToPosition(source, start),
        .end = self.indexToPosition(source, end),
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

    const file = self.workspace.getFileState(file_id);

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(self.allocator);

    try buffer.appendSlice(self.allocator, file.source);

    for (notification.contentChanges) |cc| {
        switch (cc) {
            .text_document_content_change_whole_document => |change| {
                buffer.clearRetainingCapacity();
                try buffer.appendSlice(self.allocator, change.text);
            },
            .text_document_content_change_partial => |change| {
                const loc = lsp.offsets.rangeToLoc(
                    buffer.items,
                    change.range,
                    self.capabilities.offset_encoding,
                );
                try buffer.replaceRange(
                    self.allocator,
                    loc.start,
                    loc.end - loc.start,
                    change.text,
                );
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
    allocator: std.mem.Allocator,
    params: lsp.types.Hover.Params,
) !?lsp.types.Hover {
    const hover = @import("hover.zig");

    std.log.debug("Received 'textDocument/hover' request", .{});

    const file_id = blk: {
        if (self.workspace.getId(params.textDocument.uri)) |file_id|
            break :blk file_id;

        std.log.warn("Hover on non existent document: '{s}'", .{params.textDocument.uri});
        return null;
    };

    const file = self.workspace.getFileState(file_id);

    const source_index = lsp.offsets.positionToIndex(
        file.source,
        params.position,
        self.capabilities.offset_encoding,
    );

    std.log.debug("Hover position: line={d}, character={d}, index={d}", .{
        params.position.line, params.position.character, source_index,
    });

    const symbol_type = try hover.getSymbolType(
        allocator,
        file,
        @intCast(source_index),
    ) orelse return null;

    return .{
        .contents = .{
            .markup_content = .{
                .kind = .plaintext,
                .value = try allocator.print("{f}", .{symbol_type}),
            },
        },
    };
}

pub fn @"textDocument/completion"(
    self: *Dispatcher,
    arena: std.mem.Allocator,
    params: lsp.types.completion.Params,
) !?lsp.types.completion.Result {
    std.log.debug("Received 'textDocument/completion' notification", .{});

    const completions = @import("completions.zig");

    const file_id = self.workspace.getId(params.textDocument.uri) orelse return null;
    const file = self.workspace.getFileState(file_id);

    const result = try completions.getCompletions(
        arena,
        file,
        self.positionToIndex(
            file.source,
            params.position,
        ),
    );

    const raw = try arena.alloc(
        lsp.types.completion.Item,
        result.completions.len,
    );

    std.log.info("raw completions num: {}, range: '{s}'", .{ raw.len, file.source[result.range.start..result.range.end] });

    for (result.completions, raw) |in, *out| {
        out.* = .{
            .label = in.label,
            .labelDetails = if (in.labelDetail) |ld|
                .{
                    .detail = ld.detail,
                    .description = ld.description,
                }
            else
                null,
            .detail = in.detail,
            .textEdit = .{
                .text_edit = .{
                    .newText = in.snippet orelse in.new_text,
                    .range = self.indexesToRange(
                        file.source,
                        result.range.start,
                        result.range.end,
                    ),
                },
            },
            .insertTextFormat = .Snippet,
            .kind = in.kind,
        };
    }

    return .{ .completion_items = raw };
}

pub fn @"textDocument/semanticTokens/full"(
    self: *Dispatcher,
    arena: std.mem.Allocator,
    params: lsp.types.semantic_tokens.Params,
) !?lsp.types.semantic_tokens.Result {
    std.log.debug("Received 'textDocument/semanticTokens/full'", .{});

    const file_id = self.workspace.getId(params.textDocument.uri) orelse return null;

    const file = self.workspace.getFileState(file_id);

    const raw_tokens = try sem.Collector.collect(
        arena,
        file.tree.?,
        file.ir.?.scope,
    );

    var data: std.ArrayList(u32) = .empty;
    var prev_line: u32 = 0;
    var prev_char: u32 = 0;

    for (raw_tokens) |raw| {
        const start_pos = self.indexToPosition(
            file.source,
            raw.start,
        );
        const len = lsp.offsets.locLength(
            file.source,
            .{ .start = raw.start, .end = raw.end },
            self.capabilities.offset_encoding,
        );

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
            .message = .{
                .string = in.message,
            },
            .range = lsp.offsets.locToRange(
                file.source,
                .{
                    .start = in.span.start,
                    .end = in.span.end(),
                },
                self.capabilities.offset_encoding,
            ),
            .severity = switch (in.severity) {
                .err => .Error,
                .warn => .Warning,
                .hint => .Hint,
                .unnecessary => .Hint,
            },
            .tags = switch (in.severity) {
                .unnecessary => &.{.Unnecessary},
                else => null,
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
