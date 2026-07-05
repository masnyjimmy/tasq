const std = @import("std");

const LiteralParser = struct {
    gpa: std.mem.Allocator,
    input: []const u8,
    output: std.ArrayList(u8),
    pos: usize = 0,

    pub fn init(gpa: std.mem.Allocator, input: []const u8) !LiteralParser {
        return .{
            .gpa = gpa,
            .input = input,
            .output = try .initCapacity(gpa, input.len),
        };
    }

    pub fn processString(self: *@This()) ![]const u8 {
        while (self.pos < self.input.len) {
            try self.appendNextChar();
        }

        return try self.output.toOwnedSlice(self.gpa);
    }

    pub fn processChar(self: *@This()) !u21 {
        if (self.pos >= self.input.len) return error.EmptyCharLiteral;

        const cp = try self.readOneCodepoint();
        if (self.pos != self.input.len) return error.CharLiteralTooLong;

        return cp;
    }

    fn appendNextChar(self: *@This()) !void {
        const cp = try self.readOneCodepoint();

        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        try self.output.appendSlice(self.gpa, buf[0..n]);
    }

    fn readOneCodepoint(self: *@This()) !u21 {
        if (self.pos >= self.input.len) return error.InvalidStringFormat;

        switch (self.input[self.pos]) {
            '\\' => return try self.readEscapeCodepoint(),

            else => {
                // For now this treats one byte as one character.
                // If you later want full UTF-8 raw char support, decode UTF-8 here.
                const ch = self.input[self.pos];
                self.pos += 1;
                return @as(u21, ch);
            },
        }
    }

    fn readEscapeCodepoint(self: *@This()) !u21 {
        if (self.pos + 1 >= self.input.len) return error.InvalidStringFormat;

        const esc = self.input[self.pos + 1];

        switch (esc) {
            'n' => {
                self.pos += 2;
                return '\n';
            },
            't' => {
                self.pos += 2;
                return '\t';
            },
            'r' => {
                self.pos += 2;
                return '\r';
            },
            '\\' => {
                self.pos += 2;
                return '\\';
            },
            '"' => {
                self.pos += 2;
                return '"';
            },
            '\'' => {
                self.pos += 2;
                return '\'';
            },
            '0' => {
                self.pos += 2;
                return 0;
            },
            'x' => return try self.readHexEscape(),
            'u' => return try self.readUnicodeEscape(),
            else => return error.InvalidStringFormat,
        }
    }

    fn readHexEscape(self: *@This()) !u21 {
        if (self.pos + 3 >= self.input.len) return error.InvalidStringFormat;

        const a = self.input[self.pos + 2];
        const b = self.input[self.pos + 3];

        if (!std.ascii.isHex(a) or !std.ascii.isHex(b)) {
            return error.InvalidStringFormat;
        }

        const byte = try std.fmt.parseInt(u8, self.input[self.pos + 2 .. self.pos + 4], 16);
        self.pos += 4;
        return @as(u21, byte);
    }

    fn readUnicodeEscape(self: *@This()) !u21 {
        if (self.pos + 2 >= self.input.len or self.input[self.pos + 2] != '{') {
            return error.InvalidStringFormat;
        }

        var i: usize = self.pos + 3;
        var digits: usize = 0;

        while (i < self.input.len and self.input[i] != '}') : (i += 1) {
            if (!std.ascii.isHex(self.input[i])) return error.InvalidStringFormat;
            digits += 1;
        }

        if (i >= self.input.len or digits == 0) return error.InvalidStringFormat;

        const codepoint_u32 = try std.fmt.parseInt(u32, self.input[self.pos + 3 .. i], 16);
        if (codepoint_u32 > 0x10ffff or (codepoint_u32 >= 0xd800 and codepoint_u32 <= 0xdfff)) {
            return error.InvalidStringFormat;
        }

        self.pos = i + 1; // skip closing }
        return @as(u21, @intCast(codepoint_u32));
    }
};

pub const LiteralError = error{
    InvalidStringFormat,
    EmptyCharLiteral,
    CharLiteralTooLong,
};

pub fn processString(gpa: std.mem.Allocator, input: []const u8) ![]const u8 {
    var parser = try LiteralParser.init(gpa, input);
    return try parser.processString();
}

pub fn processChar(gpa: std.mem.Allocator, input: []const u8) !u21 {
    var parser = try LiteralParser.init(gpa, input);
    return try parser.processChar();
}

pub fn readFirstUnicode(data: []const u8) !u21 {
    if (data.len == 0)
        return 0;

    const len = try std.unicode.utf8ByteSequenceLength(data[0]);

    return try std.unicode.utf8Decode(data[0..len]);
}
