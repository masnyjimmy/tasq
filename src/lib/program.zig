const std = @import("std");
const platform = @import("platform.zig");

const PlatformDesc = struct {
    path_var_name: []const u8,
    separator: []const u8,
    extensions: []const []const u8 = &.{},
    program_separator: []const u8,

    const current: PlatformDesc = switch (platform.tag) {
        .windows => .{
            .path_var_name = "path",
            .separator = ";",
            .extensions = &.{ ".ext", ".cmd", ".bat", ".com" },
            .program_separator = "\\",
        },
        else => .{
            .path_var_name = "PATH",
            .separator = ":",
            .program_separator = "/",
        },
    };
};

fn isExecutableFile(dir: std.Io.Dir, io: std.Io, path: []const u8) !bool {
    const stat = dir.statFile(io, path, .{}) catch return false;
    if (stat.kind != .file) return false;

    dir.access(io, path, .{ .execute = true }) catch return false;
    return true;
}

fn tryOne(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    base: ?[]const u8,
    file_name: []const u8,
) !?[]u8 {
    const full = if (base) |b|
        try std.fs.path.join(allocator, &.{ b, file_name })
    else
        try allocator.dupe(u8, file_name);
    errdefer allocator.free(full);

    if (isExecutableFile(dir, io, full)) return full;
    allocator.free(full);
    return null;
}

fn probe(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, base: ?[]const u8, name: []const u8) !?[]u8 {
    const exts = PlatformDesc.current.extensions;

    const has_ext = exts.len == 0 or for (exts) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) break true;
    } else false;

    if (has_ext) return tryOne(allocator, dir, io, base, name);

    for (exts) |ext| {
        const with_ext = try std.mem.concat(allocator, u8, &.{ name, ext });
        defer allocator.free(with_ext);
        if (try tryOne(allocator, dir, io, base, with_ext)) |found| return found;
    }
    return null;
}

pub fn which(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    name: []const u8,
) !?[]u8 {
    if (name.len == 0) return null;

    if (std.mem.findAny(u8, name, PlatformDesc.current.program_separator) != null) {
        return probe(allocator, dir, io, null, name);
    }

    const PATH = environ.get(PlatformDesc.current.path_var_name) orelse return null;

    const it = std.mem.splitSequence(
        u8,
        PATH,
        PlatformDesc.current.separator,
    );

    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (try probe(allocator, dir, io, entry, name)) |found| return found;
    }

    return null;
}
