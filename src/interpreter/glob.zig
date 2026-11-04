const std = @import("std");
const glob = @import("libglob");

pub const Error = error{
    InvalidGlob,
} || std.mem.Allocator.Error || std.Io.Dir.OpenError;

const OPTIONS: glob.Options = .{
    .escapes = true,
    .ignore_case = false,
    .pathname = true, // `*` and `?` don't cross `/`, like a shell
    .period = false,
};

pub const Iterator = struct {
    pattern: []const u8,
    walker: std.Io.Dir.Walker,
    io: std.Io,
    root: std.Io.Dir,

    /// The returned path is only valid until the next call to `next` or `deinit`.
    pub fn next(self: *Iterator) !?[]const u8 {
        while (try self.walker.next(self.io)) |entry| {
            // pattern was validated in `iterate`, so this can't fail
            if (glob.match(self.pattern, entry.path, OPTIONS) catch unreachable) {
                return entry.path;
            }
        }
        return null;
    }

    pub fn deinit(self: *Iterator) void {
        self.root.close(self.io);
        self.walker.deinit();
    }
};

pub fn iterate(
    allocator: std.mem.Allocator,
    cwd: std.Io.Dir,
    io: std.Io,
    pattern: []const u8,
) Error!Iterator {
    // validate the pattern up front
    _ = glob.match(pattern, "", OPTIONS) catch return Error.InvalidGlob;

    const root = try cwd.openDir(io, ".", .{ .iterate = true });
    errdefer root.close(io);
    const walker = try root.walk(allocator);

    return .{
        .pattern = pattern,
        .walker = walker,
        .io = io,
        .root = root,
    };
}
