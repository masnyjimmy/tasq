const std = @import("std");

pub fn parse(io: std.Io, filepath: []const u8, out: *std.process.Environ.Map) !void {
    const file = try std.Io.Dir.cwd().openFile(
        io,
        filepath,
        .{},
    );
    defer file.close(io);

    var buffer: [128]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    const reader = &file_reader.interface;

    while (true) {
        // Read one line at a time; stop cleanly at EOF.
        const raw_line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        // Handle stray \r from CRLF files.
        const line = std.mem.trim(u8, raw_line, " \t\r");

        // Skip blank lines and comments.
        if (line.len == 0 or line[0] == '#') continue;

        // Split on the first '='.
        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        var value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");

        if (key.len == 0) continue;

        // Strip a single matching pair of surrounding quotes, if present.
        if (value.len >= 2 and
            ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1];
        }

        // Drop an inline comment on unquoted values (e.g. FOO=bar # comment).
        if (std.mem.indexOfScalar(u8, value, '#')) |hash_index| {
            if (hash_index > 0 and value[hash_index - 1] == ' ') {
                if (std.mem.cutSuffix(u8, value[0..hash_index], " \t")) |v|
                    value = v;
            }
        }

        const key_dup = try out.allocator.dupe(u8, key);
        errdefer out.allocator.free(key_dup);
        const value_dup = try out.allocator.dupe(u8, value);
        errdefer out.allocator.free(value_dup);

        try out.putMove(key_dup, value_dup);
    }
}
