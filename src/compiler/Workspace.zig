const std = @import("std");
const ast = @import("ast.zig");
const ir = @import("ir.zig");

const Diagnostics = @import("diagnostics.zig");

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
    tree: ?ast.File = null,
    ir: ?ir.File = null,
    diagnostics: Diagnostics,

    pub fn deinit(self: *FileState, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.source);
        self.arena.deinit();
        self.diagnostics.deinit();
    }
};

const ViewType = enum {
    source,
    tree,
    ir,

    pub fn Type(comptime self: ViewType) type {
        return switch (self) {
            .source => []const u8,
            .tree => *const ast.File,
            .ir => *const ir.File,
        };
    }
};
pub fn FileView(comptime view_type: ViewType) type {
    return struct {
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

pub fn openFile(self: *Workspace, allocator: std.mem.Allocator, uri: []const u8, text: []const u8, version: i32) !FileId {
    const id: FileId = @enumFromInt(self.next_id);
    self.next_id += 1;

    const owned_uri = try allocator.dupe(u8, uri);
    try self.uri_to_id.put(allocator, id, uri);

    try self.files.put(allocator, id, .{
        .uri = owned_uri,
        .version = version,
        .source = try allocator.dupe(u8, text),
        .arena = .init(allocator),
        .diagnostics = .init(allocator),
    });

    try self.reparse(id);
    return id;
}

pub fn view(self: *Workspace, id: FileId, comptime view_type: ViewType) FileView(view_type) {
    const file = self.files.getPtr(id).?;

    return .fromFileState(self, id, file);
}

pub fn reparse(self: *Workspace, id: FileId) !void {
    const file = self.files.getPtr(id).?;

    file.arena.reset(.retain_capacity);
    file.diagnostics.clear();
    file.tree = null;
    file.ir = null;

    const lex = @import("lexer.zig");
    const parse = @import("parser.zig");
    var lexer: lex.Lexer = .init(file.source);

    var parser: parse.Parser = .init(&file.arena, &lexer, &file.diagnostics);

    file.tree = try parser.parseFile();
}

pub fn changeFile(self: *Workspace, allocator: std.mem.Allocator, id: FileId, new_text: []const u8, version: i32) !void {
    var file = self.files.getPtr(id).?;
    allocator.free(file.source);
    file.source = try allocator.dupe(u8, new_text);
    file.version = version;

    try self.reparse(id);
}

pub fn closeFile(self: *Workspace, allocator: std.mem.Allocator, id: FileId) !void {
    if (self.files.fetchSwapRemove(id)) |kv| {
        var file = kv.value;
        _ = self.uri_to_id.remove(file.uri);
        file.deinit(allocator);
    }
}
