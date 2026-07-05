const std = @import("std");

pub const SourceFile = struct {
    path: [:0]const u8,
    text: []const u8,
};

pub const SourceId = u32;

pub const INVALID_FILE_ID = std.math.maxInt(SourceId);

pub const SourceView = struct {
    id: SourceId,
    text: []const u8,
};

fn readFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, filename: []const u8) ![]const u8 {
    return try dir.readFileAlloc(io, filename, allocator, .unlimited);
}

pub const SourceStore = struct {
    files: std.ArrayList(SourceFile),
    indexes: std.StringArrayHashMapUnmanaged(u32),
    cwd: std.Io.Dir,
    pub fn init() SourceStore {
        return .{
            .files = .empty,
            .indexes = .empty,
            .cwd = std.Io.Dir.cwd(),
        };
    }

    pub fn deinit(self: *SourceStore, allocator: std.mem.Allocator) void {
        for (self.files.items) |file| {
            allocator.free(file.path);
            allocator.free(file.text);
        }

        self.files.deinit(allocator);
        self.indexes.deinit(allocator);
    }

    fn realFilepath(self: *SourceStore, allocator: std.mem.Allocator, io: std.Io, filepath: []const u8) ![:0]const u8 {
        return try self.cwd.realPathFileAlloc(io, filepath, allocator);
    }

    pub fn loadFile(self: *SourceStore, allocator: std.mem.Allocator, io: std.Io, filepath: []const u8) !SourceId {
        const real_filepath = try self.realFilepath(allocator, io, filepath);

        if (self.indexes.get(real_filepath)) |idx| {
            allocator.free(real_filepath);
            return idx;
        }

        const source_id: SourceId = @intCast(self.files.items.len);

        const file = try readFile(allocator, io, self.cwd, real_filepath);

        try self.files.append(allocator, .{
            .path = real_filepath,
            .text = file,
        });

        try self.indexes.putNoClobber(allocator, real_filepath, source_id);

        return source_id;
    }

    fn getSourceId(self: *SourceStore, name: []const u8) ?SourceId {
        return self.indexes.get(name);
    }

    pub fn getFilePtr(self: *SourceStore, id: SourceId) !*SourceFile {
        std.debug.assert(id != INVALID_FILE_ID); // should never happen, check if handled span == Span.Unknown correctly

        if (self.files.items.len <= id)
            return error.InvalidSourceId;

        return &self.files.items[id];
    }

    pub fn getFile(self: *SourceStore, id: SourceId) !SourceFile {
        const ptr = try self.getFilePtr(id);
        return ptr.*;
    }

    pub fn view(self: *SourceStore, id: SourceId) !SourceView {
        const file = try self.getFilePtr(id);

        return .{ .id = id, .text = file.text };
    }
};
