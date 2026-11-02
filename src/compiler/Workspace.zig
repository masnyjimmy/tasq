const std = @import("std");
const cst = @import("cst.zig");
const ir = @import("ir.zig");
const Span = @import("Span.zig");

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
    tree: ?*cst.Node = null,
    ir: ?ir.File = null,
    diagnostics: Diagnostics,

    pub fn deinit(self: *FileState, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.source);
        self.arena.deinit();
        self.diagnostics.deinit();
    }
};
allocator: std.mem.Allocator,
files: std.array_hash_map.Auto(FileId, FileState) = .empty,
uri_to_id: std.StringHashMapUnmanaged(FileId) = .empty,
next_id: u32 = 0,

pub fn init(allocator: std.mem.Allocator) Workspace {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Workspace) void {
    var iter = self.files.iterator();

    while (iter.next()) |kv| {
        kv.value_ptr.deinit(self.allocator);
    }

    self.files.deinit(self.allocator);
    self.uri_to_id.deinit(self.allocator);
    self.next_id = undefined;
}

pub const OpenResult = struct {
    valid: bool,
    id: FileId,
};

pub fn openFile(self: *Workspace, uri: []const u8, text: []const u8, version: i32) !OpenResult {
    std.debug.assert(self.getId(uri) == null);

    const id: FileId = @fromBackingInt(@intCast(self.next_id));
    self.next_id += 1;

    const owned_uri = try self.allocator.dupe(u8, uri);
    try self.uri_to_id.put(self.allocator, owned_uri, id);

    try self.files.put(self.allocator, id, .{
        .uri = owned_uri,
        .version = version,
        .source = try self.allocator.dupe(u8, text),
        .arena = .init(self.allocator),
        .diagnostics = .init(self.allocator),
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

pub fn getFileState(self: *Workspace, id: FileId) *const FileState {
    return self.files.getPtr(id).?;
}

pub fn reparse(self: *Workspace, id: FileId) !bool {
    const file = self.files.getPtr(id).?;

    _ = file.arena.reset(.retain_capacity);
    file.diagnostics.clear();
    file.tree = null;
    file.ir = null;

    file.tree = blk: {
        const lex = @import("lexer.zig");
        const tree = @import("tree.zig");
        const parse = @import("parser.zig");

        var lexer: lex.Lexer = .init(file.arena.allocator(), file.source);
        defer lexer.deinit();

        const lex_tree = try tree.TreeReader.read(
            file.arena.allocator(),
            &lexer,
            &file.diagnostics,
        );

        var cursor: tree.Cursor = .init(lex_tree);

        var parser: parse.Parser = try .init(
            file.arena.allocator(),
            &cursor,
            &file.diagnostics,
        );
        defer parser.deinit();

        break :blk try parser.parseFile();
    };

    file.ir = blk: {
        const sem = @import("sema.zig");
        var sema: sem.Sema = .init(
            &file.arena,
            &file.diagnostics,
        );

        break :blk try sema.analyseFile(file.tree.?);
    };

    return file.diagnostics.errors_count == 0;
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
