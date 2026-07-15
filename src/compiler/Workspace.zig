const std = @import("std");
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const Span = @import("span.zig");

const Diagnostics = @import("Diagnostics.zig");

const Workspace = @This();

pub const FileId = enum(u32) {
    _,
    const INVALID = std.math.maxInt(u32);
};

pub const FileState = struct {
    uri: []const u8, //owned
    version: i32,
    source: []const u8, // owned
    arena: std.heap.ArenaAllocator,
    span_registry: Span.Registry,
    tree: ?ast.File = null,
    ir: ?ir.File = null,
    diagnostics: Diagnostics,

    pub fn deinit(self: *FileState, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.source);
        self.arena.deinit();
        self.diagnostics.deinit();
        self.span_registry.deinit();
    }
};

const ViewType = enum {
    source,
    tree,
    ir,
    span,
    diagnostics,

    pub fn Type(comptime self: ViewType) type {
        return switch (self) {
            .source => []const u8,
            .tree => *const ast.File,
            .ir => *const ir.File,
            .span => *const Span.Registry,
            .diagnostics => *const Diagnostics,
        };
    }
};
pub fn FileView(comptime view_type: ViewType) type {
    return struct {
        workspace: *Workspace,
        id: FileId,
        source: view_type.Type(),
        diagnostics: *Diagnostics,

        fn fromFileState(workspace: *Workspace, id: FileId, fs: *FileState) @This() {
            return .{
                .workspace = workspace,
                .id = id,
                .source = switch (view_type) {
                    .source => fs.source,
                    .tree => &fs.tree.?,
                    .ir => &fs.ir.?,
                    .span => &fs.span_registry,
                    .diagnostics => &fs.diagnostics,
                },
                .diagnostics = &fs.diagnostics,
            };
        }
    };
}

pub const SourceView = FileView(.source);

files: std.array_hash_map.Auto(FileId, FileState) = .empty,
uri_to_id: std.StringHashMapUnmanaged(FileId) = .empty,
next_id: u32 = 0,

pub const init: Workspace = .{};

pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
    var iter = self.files.iterator();

    while (iter.next()) |kv| {
        kv.value_ptr.deinit(allocator);
    }

    self.files.deinit(allocator);
    self.uri_to_id.deinit(allocator);
    self.next_id = undefined;
}

pub const OpenResult = struct {
    valid: bool,
    id: FileId,
};

pub fn openFile(self: *Workspace, allocator: std.mem.Allocator, uri: []const u8, text: []const u8, version: i32) !OpenResult {
    std.debug.assert(self.getId(uri) == null);

    const id: FileId = @enumFromInt(self.next_id);
    self.next_id += 1;

    const owned_uri = try allocator.dupe(u8, uri);
    try self.uri_to_id.put(allocator, owned_uri, id);

    try self.files.put(allocator, id, .{
        .uri = owned_uri,
        .version = version,
        .source = try allocator.dupe(u8, text),
        .arena = .init(allocator),
        .span_registry = .init(allocator),
        .diagnostics = .init(allocator),
    });

    const valid = try self.reparse(id);

    return .{
        .valid = valid,
        .id = id,
    };
}

pub fn getId(self: *Workspace, uri: []const u8) ?FileId {
    return self.uri_to_id.get(uri);
}

pub fn view(self: *Workspace, id: FileId, comptime view_type: ViewType) FileView(view_type) {
    const file = self.files.getPtr(id).?;

    return .fromFileState(self, id, file);
}

pub fn reparse(self: *Workspace, id: FileId) !bool {
    const file = self.files.getPtr(id).?;

    _ = file.arena.reset(.retain_capacity);
    file.span_registry.clear();
    file.diagnostics.clear();
    file.tree = null;
    file.ir = null;

    const lex = @import("lexer.zig");
    const parse = @import("parser.zig");
    var lexer: lex.Lexer = .init(
        file.source,
        &file.span_registry,
    );

    var parser: parse.Parser = try .init(
        &file.arena,
        &lexer,
        &file.span_registry,
        &file.diagnostics,
    );

    const tree = try parser.parseFile();

    file.tree = tree;

    const Sema = @import("sema.zig").Sema;
    var sema: Sema = .init(
        &file.arena,
        &file.span_registry,
        &file.diagnostics,
    );

    file.ir = try sema.analyse(tree);

    return file.diagnostics.has_error == false;
}

pub fn changeFile(self: *Workspace, allocator: std.mem.Allocator, id: FileId, new_text: []const u8, version: i32) !bool {
    var file = self.files.getPtr(id).?;
    allocator.free(file.source);
    file.source = try allocator.dupe(u8, new_text);
    file.version = version;

    return try self.reparse(id);
}

pub fn closeFile(self: *Workspace, allocator: std.mem.Allocator, id: FileId) !void {
    if (self.files.fetchSwapRemove(id)) |kv| {
        var file = kv.value;
        _ = self.uri_to_id.remove(file.uri);
        file.deinit(allocator);
    }
}
