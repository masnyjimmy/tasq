const std = @import("std");

pub const Error = error{
    /// Bad escape sequence: unknown escape, bad \xNN, bad or out-of-range \u{...}, trailing `\`.
    InvalidEscape,
    InvalidUtf8,
};

pub const CharError = Error || error{
    EmptyCharLiteral,
    CharLiteralTooLong,
};

/// Where an error happened, relative to the `src` / `input` that was passed in.
/// The failing bytes are `src[offset..][0..len]`.
pub const Diag = struct {
    offset: usize = 0,
    len: usize = 0,
};

/// Processes the escape sequences of `src` into `dst`, returns the number of bytes written.
/// Never allocates.
///
/// `dst.len` must be >= `src.len`. That is always enough, because every escape is at least as
/// long as the UTF-8 it produces (`\n` 2→1, `\xNN` 4→≤2, `\u{N}` ≥5→≤4, ...).
/// `dst` and `src` must not overlap.
pub fn unescape(dst: []u8, src: []const u8, diag: *Diag) Error!usize {
    std.debug.assert(dst.len >= src.len);

    var parser: Parser = .{ .input = src, .diag = diag };
    var used: usize = 0;
    while (parser.pos < src.len) {
        const cp = try parser.readOneCodepoint();

        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return parser.fail(error.InvalidUtf8, 1);
        @memcpy(dst[used..][0..n], buf[0..n]);
        used += n;
    }
    return used;
}

/// Content of a char literal (without the quotes): exactly one code point.
pub fn processChar(input: []const u8, diag: *Diag) CharError!u21 {
    if (input.len == 0) {
        diag.* = .{};
        return error.EmptyCharLiteral;
    }

    var parser: Parser = .{ .input = input, .diag = diag };
    const cp = try parser.readOneCodepoint();
    if (parser.pos != input.len) {
        diag.* = .{ .offset = parser.pos, .len = input.len - parser.pos };
        return error.CharLiteralTooLong;
    }
    return cp;
}

pub fn readFirstUnicode(data: []const u8) error{InvalidUtf8}!u21 {
    if (data.len == 0)
        return 0;

    const len = std.unicode.utf8ByteSequenceLength(data[0]) catch return error.InvalidUtf8;
    if (len > data.len) return error.InvalidUtf8;

    return std.unicode.utf8Decode(data[0..len]) catch return error.InvalidUtf8;
}

const Parser = struct {
    input: []const u8,
    diag: *Diag,
    pos: usize = 0,

    // `pos` only advances after a successful read, so on failure it still points at the
    // start of the offending character or escape, which is what `fail` records.
    fn fail(self: *Parser, err: Error, len: usize) Error {
        self.diag.* = .{
            .offset = self.pos,
            .len = @min(len, self.input.len - self.pos),
        };
        return err;
    }

    fn readOneCodepoint(self: *Parser) Error!u21 {
        if (self.pos >= self.input.len) return self.fail(error.InvalidUtf8, 1);

        switch (self.input[self.pos]) {
            '\\' => return try self.readEscapeCodepoint(),

            else => {
                const first = self.input[self.pos];
                const len = std.unicode.utf8ByteSequenceLength(first) catch
                    return self.fail(error.InvalidUtf8, 1);
                if (self.pos + len > self.input.len) return self.fail(error.InvalidUtf8, len);

                const bytes = self.input[self.pos .. self.pos + len];

                const cp: u21 = switch (len) {
                    1 => bytes[0],
                    2 => std.unicode.utf8Decode2(bytes[0..2].*) catch return self.fail(error.InvalidUtf8, len),
                    3 => std.unicode.utf8Decode3(bytes[0..3].*) catch return self.fail(error.InvalidUtf8, len),
                    4 => std.unicode.utf8Decode4(bytes[0..4].*) catch return self.fail(error.InvalidUtf8, len),
                    else => return self.fail(error.InvalidUtf8, len),
                };

                self.pos += len;
                return cp;
            },
        }
    }

    fn readEscapeCodepoint(self: *Parser) Error!u21 {
        if (self.pos + 1 >= self.input.len) return self.fail(error.InvalidEscape, 1); // trailing `\`

        switch (self.input[self.pos + 1]) {
            'n' => return self.simple('\n'),
            't' => return self.simple('\t'),
            'r' => return self.simple('\r'),
            '\\' => return self.simple('\\'),
            '"' => return self.simple('"'),
            '\'' => return self.simple('\''),
            '`' => return self.simple('`'),
            '{', '}' => |ch| return self.simple(ch),
            '0' => return self.simple(0),
            'x' => return try self.readHexEscape(),
            'u' => return try self.readUnicodeEscape(),
            else => return self.fail(error.InvalidEscape, 2),
        }
    }

    /// Two-character escape (`\n`, `\\`, ...).
    fn simple(self: *Parser, cp: u21) u21 {
        self.pos += 2;
        return cp;
    }

    fn readHexEscape(self: *Parser) Error!u21 {
        if (self.pos + 3 >= self.input.len) return self.fail(error.InvalidEscape, 4);

        const a = self.input[self.pos + 2];
        const b = self.input[self.pos + 3];
        if (!std.ascii.isHex(a) or !std.ascii.isHex(b)) return self.fail(error.InvalidEscape, 4);

        const byte = std.fmt.parseInt(u8, self.input[self.pos + 2 .. self.pos + 4], 16) catch
            return self.fail(error.InvalidEscape, 4);
        self.pos += 4;
        return @as(u21, byte);
    }

    fn readUnicodeEscape(self: *Parser) Error!u21 {
        if (self.pos + 2 >= self.input.len or self.input[self.pos + 2] != '{') {
            return self.fail(error.InvalidEscape, 2);
        }

        var i: usize = self.pos + 3;
        var digits: usize = 0;

        while (i < self.input.len and self.input[i] != '}') : (i += 1) {
            if (!std.ascii.isHex(self.input[i])) return self.fail(error.InvalidEscape, i + 1 - self.pos);
            digits += 1;
        }

        // span of the whole escape, `\u{...}` (clamped to the input if the `}` is missing)
        const escape_len = i + 1 - self.pos;
        if (i >= self.input.len or digits == 0) return self.fail(error.InvalidEscape, escape_len);

        const codepoint_u32 = std.fmt.parseInt(u32, self.input[self.pos + 3 .. i], 16) catch
            return self.fail(error.InvalidEscape, escape_len);
        if (codepoint_u32 > 0x10ffff or (codepoint_u32 >= 0xd800 and codepoint_u32 <= 0xdfff)) {
            return self.fail(error.InvalidEscape, escape_len);
        }

        self.pos = i + 1; // skip closing }
        return @as(u21, @intCast(codepoint_u32));
    }
};
