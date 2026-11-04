const std = @import("std");
const glob = @import("libglob");

pub const Error = error{
    InvalidGlob,
} || std.mem.Allocator.Error || std.Io.Dir.OpenError;

const OPTIONS: glob.Options = .{
    .escapes = true,
    .ignore_case = false,
    .pathname = true,
    .period = true, // leading '.' must be matched explicitly
};

pub const Iterator = struct {
    patterns: []const []const u8, // brace-expanded
    arena: std.heap.ArenaAllocator,
    walker: std.Io.Dir.Walker,
    io: std.Io,
    root: std.Io.Dir,

    /// The returned path is only valid until the next call to `next` or `deinit`.
    pub fn next(self: *Iterator) !?[]const u8 {
        while (try self.walker.next(self.io)) |entry| {
            for (self.patterns) |pattern| {
                if (matchPath(pattern, entry.path)) return entry.path;
            }
        }
        return null;
    }

    pub fn deinit(self: *Iterator) void {
        self.walker.deinit();
        self.root.close(self.io);
        self.arena.deinit();
    }
};

pub fn iterate(
    allocator: std.mem.Allocator,
    cwd: std.Io.Dir,
    io: std.Io,
    pattern: []const u8,
) Error!Iterator {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();

    var patterns: std.ArrayList([]const u8) = .empty;
    try expandBraces(arena.allocator(), pattern, &patterns);

    const root = try cwd.openDir(io, ".", .{ .iterate = true });
    errdefer root.close(io);
    const walker = try root.walk(allocator);

    return .{
        .patterns = patterns.items,
        .arena = arena,
        .walker = walker,
        .io = io,
        .root = root,
    };
}

/// `{a,b}` -> two patterns, recursively (nesting and several groups work).
fn expandBraces(arena: std.mem.Allocator, pattern: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    const open = findUnescaped(pattern, '{') orelse return out.append(arena, pattern);

    var depth: usize = 0;
    var start = open + 1;
    var alts: std.ArrayList([]const u8) = .empty;
    var i = open + 1;

    const close = while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => i += 1,
            '{' => depth += 1,
            ',' => if (depth == 0) {
                try alts.append(arena, pattern[start..i]);
                start = i + 1;
            },
            '}' => {
                if (depth == 0) break i;
                depth -= 1;
            },
            else => {},
        }
    } else return error.InvalidGlob; // unclosed '{'

    try alts.append(arena, pattern[start..close]);

    for (alts.items) |alt| {
        const joined = try std.mem.concat(arena, u8, &.{ pattern[0..open], alt, pattern[close + 1 ..] });
        try expandBraces(arena, joined, out);
    }
}

fn findUnescaped(s: []const u8, c: u8) ?usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == c) return i;
    }
    return null;
}

/// Segment-wise match. A `**` segment matches zero or more whole path segments
/// (never hidden ones). Everything else goes through libglob, one segment at a time.
fn matchPath(pat: ?[]const u8, path: ?[]const u8) bool {
    const p = pat orelse return path == null;
    const p_seg, const p_rest = splitFirst(p);

    if (std.mem.eql(u8, p_seg, "**")) {
        if (matchPath(p_rest, path)) return true; // zero segments

        const s = path orelse return false;
        const s_seg, const s_rest = splitFirst(s);
        if (s_seg.len > 0 and s_seg[0] == '.') return false;
        return matchPath(p, s_rest); // consume one, keep the `**`
    }

    const s = path orelse return false;
    const s_seg, const s_rest = splitFirst(s);

    // can't fail on a segment that was only produced by walking
    if (!(glob.match(p_seg, s_seg, OPTIONS) catch false)) return false;
    return matchPath(p_rest, s_rest);
}

fn splitFirst(s: []const u8) struct { []const u8, ?[]const u8 } {
    const i = std.mem.indexOfScalar(u8, s, '/') orelse return .{ s, null };
    return .{ s[0..i], s[i + 1 ..] };
}
