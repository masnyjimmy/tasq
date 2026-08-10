const std = @import("std");
const lib = @import("lib");

const token = @import("token.zig");

const TokenKind = token.TokenKind;
const Token = token.Token;

const Span = @import("span.zig");

// ── Keyword map ───────────────────────────────────────────────────────────────

const keywords = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "set", .set_kw },
    .{ "task", .task_kw },
    .{ "group", .group_kw },
    .{ "if", .if_kw },
    .{ "else", .else_kw },
    .{ "and", .and_kw },
    .{ "or", .or_kw },
    .{ "not", .not_kw },
    .{ "true", .true_kw },
    .{ "false", .false_kw },
    .{ "string", .string_type },
    .{ "flag", .flag_type },
    .{ "number", .number_type },
    .{ "null", .null_kw },
    .{ "switch", .switch_kw },
    // .{ "for", .for_kw },
});

// ── Lexer ─────────────────────────────────────────────────────────────────────

fn hexValue(c: u8) u32 {
    return switch (c) {
        '0'...'9' => @as(u32, c - '0'),
        'a'...'f' => @as(u32, 10 + (c - 'a')),
        'A'...'F' => @as(u32, 10 + (c - 'A')),
        else => unreachable,
    };
}
pub const Lexer = struct {
    source: []const u8,
    pos: u32,

    span_registry: *Span.Registry,

    pub fn init(source: []const u8, span_registry: *Span.Registry) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .span_registry = span_registry,
        };
    }

    // ── Public interface ──────────────────────────────────────────────────────

    pub fn next(self: *Lexer) !Token {
        while (true) {
            self.skipWhitespace();

            switch (self.peek()) {
                0 => return try self.makeToken(.eof, self.pos, 0),
                // Comments — skip and loop
                '/' => {
                    if (self.peekAt(1) == '/') {
                        self.skipLineComment();
                        continue;
                    }
                    // Single / is always invalid in TSQ
                    return self.consumeChar(.slash);
                },

                // Single-char symbols
                '{' => {
                    if (self.peekAt(1) == '{') {
                        return self.consumeTwo(.ldbrace);
                    }

                    return self.consumeChar(.lbrace);
                },
                '}' => {
                    if (self.peekAt(1) == '}') {
                        return self.consumeTwo(.rdbrace);
                    }

                    return self.consumeChar(.rbrace);
                },
                '[' => return self.consumeChar(.lbracket),
                ']' => return self.consumeChar(.rbracket),
                '(' => return self.consumeChar(.lparen),
                ')' => return self.consumeChar(.rparen),
                ':' => {
                    switch (self.peekAt(1)) {
                        '=' => return self.consumeTwo(.colon_eq),
                        ':' => return self.consumeTwo(.dcolon),
                        else => return self.consumeChar(.colon),
                    }
                },
                '\'' => return self.consumeChar(.apostrophe),
                '"' => return self.consumeChar(.quote),
                '`' => return self.consumeChar(.backtick),
                '.' => {
                    if (self.peekAt(1) == '.' and self.peekAt(2) == '.') {
                        return self.consumeN(.triple_dot, 3);
                    }

                    return self.consumeChar(.dot);
                },
                '+' => return self.consumeChar(.plus),
                '-' => return self.consumeChar(.minus),
                '*' => return self.consumeChar(.star),
                ',' => return self.consumeChar(.comma),

                // Two-char symbols
                '=' => {
                    switch (self.peekAt(1)) {
                        '=' => return self.consumeTwo(.eq_eq),
                        '>' => return self.consumeTwo(.fat_arrow),
                        else => {},
                    }

                    return self.consumeChar(.eq);
                },
                '!' => {
                    if (self.peekAt(1) == '=') return self.consumeTwo(.bang_eq);
                    return self.consumeInvalid();
                },
                '<' => {
                    if (self.peekAt(1) == '=') return self.consumeTwo(.lt_eq);
                    return self.consumeChar(.lt);
                },
                '>' => {
                    if (self.peekAt(1) == '=') return self.consumeTwo(.gt_eq);
                    return self.consumeChar(.gt);
                },
                '|' => {
                    return self.consumeChar(.pipe);
                },
                '@' => {
                    return self.consumeChar(.at);
                },
                // Numbers
                '0'...'9' => return self.lexNumber(),

                // Identifiers and keywords
                'a'...'z', 'A'...'Z', '_' => return self.lexIdent(),

                // Everything else
                else => return self.consumeInvalid(),
            }
        }
    }

    const StringLexer = struct {
        lexer: *Lexer,

        fn init(lexer: *Lexer) StringLexer {
            return .{ .lexer = lexer };
        }

        pub fn checkTerminator(self: *StringLexer, terminator: []const u8) bool {
            std.debug.assert(terminator.len > 0);
            return std.mem.startsWith(u8, self.lexer.source[self.lexer.pos..], terminator);
        }

        /// Reads as string while handling escape sequences till terminator found.
        ///
        /// **Important**: terminator is not consumed!
        pub fn lexString(
            self: *StringLexer,
            terminators: []const []const u8,
            allow_new_line: bool,
        ) !Token {
            const start = self.lexer.pos;

            while (true) {
                for (terminators) |terminator| {
                    if (self.checkTerminator(terminator)) {
                        return try self.lexer.makeToken(.string, start, self.lexer.pos - start);
                    }
                }

                switch (self.lexer.peek()) {
                    // new line is normal char if allowed
                    0 => return try self.lexer.makeToken(.unterminated_string, start, self.lexer.pos - start),
                    '\n' => {
                        if (allow_new_line == false) {
                            return self.lexer.consumeInvalid();
                        }
                    },
                    // escape character => handle through lexCharacter,
                    '\\' => {
                        const out = try self.lexCharacter();
                        if (out.kind == .invalid_char)
                            return out;

                        continue;
                    },
                    // else check delimiter
                    else => {},
                }

                // if normal char then just add 1

                self.lexer.pos += 1;
            }

            unreachable;
        }

        pub fn lexCharacter(self: *StringLexer) !Token {
            // TODO: handle non escape unicode characters

            return if (self.lexer.peek() == '\\') // if escape char
                switch (self.lexer.peekAt(1)) {
                    // basic escape characters
                    'n', 't', 'r', '\\', '\"', '\'', '0' => try self.lexer.consumeN(.char, 2),
                    // hex escape (\xNN)
                    'x' => try self.lexHexEscape(),
                    // unicode codepoint escape \u{NNNN...}
                    'u' => try self.lexUnicodeEscape(),
                    // invalid escape sequence
                    else => try self.lexer.consumeInvalid(),
                }
            else // ascii character
                try self.lexer.consumeChar(.char);
        }

        fn lexHexEscape(self: *StringLexer) !Token {
            inline for (2..4) |i| {
                if (!std.ascii.isHex(self.lexer.peekAt(i))) {
                    return try self.lexer.consumeN(.invalid_char, 4);
                }
            }

            return try self.lexer.consumeN(.char, 4);
        }

        fn lexUnicodeEscape(self: *StringLexer) !Token {
            if (self.lexer.peekAt(2) != '{') {
                return try self.lexer.consumeN(.invalid_char, 3);
            }

            var i: u32 = 3;
            var digits: u32 = 0;
            var codepoint: u32 = 0;

            while (true) : (i += 1) {
                const ch = self.lexer.peekAt(i);

                if (ch == '}') break;

                if (!std.ascii.isHex(ch)) return self.lexer.consumeN(.invalid_char, i + 1);

                const digit = hexValue(ch);

                if (codepoint > (@as(u32, 0x10FFFF) >> 4)) {
                    return try self.lexer.consumeN(.invalid_char, i + 1);
                }

                codepoint = (codepoint << 4) | digit;
                digits += 1;
            }

            if (digits == 0) {
                return try self.lexer.consumeN(.invalid_char, i + 1);
            }

            if (codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF)) {
                return try self.lexer.consumeN(.invalid_char, i + 1);
            }

            return try self.lexer.consumeN(.char, i + 1);
        }
    };

    pub fn stringLexer(self: *Lexer) StringLexer {
        return StringLexer.init(self);
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    inline fn length(self: *Lexer) usize {
        return self.source.len;
    }

    inline fn isValidPos(self: *Lexer, pos: usize) bool {
        return pos < self.length();
    }

    fn peek(self: *Lexer) u8 {
        if (self.isValidPos(self.pos) == false) return 0;
        return self.source[self.pos];
    }

    fn peekAt(self: *Lexer, offset: u32) u8 {
        const i = self.pos + offset;
        if (self.isValidPos(i) == false) return 0;
        return self.source[i];
    }

    fn skipWhitespace(self: *Lexer) void {
        while (true) {
            if (std.ascii.isWhitespace(self.peek()) == false)
                break;

            self.pos += 1;
        }
    }

    fn skipLineComment(self: *Lexer) void {
        // caller already confirmed source[pos..pos+2] == "//"
        while (true) {
            switch (self.peek()) {
                0, '\n' => break,
                else => {},
            }
        }
    }

    // ── Token constructors ────────────────────────────────────────────────────

    fn makeToken(self: *Lexer, kind: TokenKind, start: u32, len: u32) !Token {
        const span: Span = .{
            .start = start,
            .len = len,
        };
        switch (kind) {
            .set_kw,
            .task_kw,
            .group_kw,
            .if_kw,
            .else_kw,
            .and_kw,
            .or_kw,
            .not_kw,
            .switch_kw,
            => {
                try self.span_registry.put(.keyword, span);
            },
            .string_type, .flag_type, .number_type => {
                try self.span_registry.put(.type, span);
            },
            .number => {
                try self.span_registry.put(.number, span);
            },
            .colon_eq, .eq_eq, .plus, .minus, .star, .slash, .bang_eq, .lt, .lt_eq, .gt, .gt_eq, .triple_dot => {
                try self.span_registry.put(.operator, span);
            },
            else => {},
        }

        return .{
            .kind = kind,
            .span = .{
                .start = start,
                .len = len,
            },
            .lexeme = self.source[start .. start + len],
        };
    }

    fn consumeN(self: *Lexer, kind: TokenKind, n: u32) !Token {
        const start = self.pos;
        self.pos += n;

        return try self.makeToken(kind, start, n);
    }

    fn consumeChar(self: *Lexer, kind: TokenKind) !Token {
        return try self.consumeN(kind, 1);
    }

    fn consumeTwo(self: *Lexer, kind: TokenKind) !Token {
        return try self.consumeN(kind, 2);
    }

    fn consumeInvalid(self: *Lexer) !Token {
        const start = self.pos;
        self.pos += 1;
        return try self.makeToken(.invalid_char, start, 1);
    }

    // ── Scanners ──────────────────────────────────────────────────────────────

    fn lexIdent(self: *Lexer) !Token {
        const start = self.pos;
        while (true) {
            switch (self.peek()) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => self.pos += 1,
                else => break,
            }
        }
        const text = self.source[start..self.pos];
        const kind = keywords.get(text) orelse .ident;
        return try self.makeToken(kind, start, self.pos - start);
    }

    fn lexNumber(self: *Lexer) !Token {
        const start = self.pos;

        while (std.ascii.isDigit(self.peek())) {
            self.pos += 1;
        }

        // Check for decimal point followed by more digits
        if (self.peek() == '.' and std.ascii.isDigit(self.peekAt(1))) {
            self.pos += 1; // consume .

            while (std.ascii.isDigit(self.peek())) {
                self.pos += 1;
            }
        }

        return try self.makeToken(.number, start, self.pos - start);
    }

    fn lexString(self: *Lexer) !Token {
        const start = self.pos;
        self.pos += 1; // consume opening "

        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                '"' => {
                    self.pos += 1; // consume closing "
                    return try self.makeToken(.string, start, self.pos - start);
                },
                '\\' => {
                    // skip backslash + next char — escape validation is
                    // a semantic concern, not a lexer concern
                    self.pos += 1;
                    if (self.pos < self.source.len) self.pos += 1;
                },
                '\n' => {
                    // do NOT consume the newline — let next call start cleanly
                    return try self.makeToken(.unterminated_string, start, self.pos - start);
                },
                else => self.pos += 1,
            }
        }

        // reached EOF without closing quote
        return try self.makeToken(.unterminated_string, start, self.pos - start);
    }

    fn lexBacktick(self: *Lexer) !Token {
        const start = self.pos;
        self.pos += 1; // consume opening `

        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                '`' => {
                    self.pos += 1; // consume closing `
                    return try self.makeToken(.backtick, start, self.pos - start);
                },
                '\n' => {
                    // backtick lines must be single-line
                    return try self.makeToken(.unterminated_backtick, start, self.pos - start);
                },
                '\\' => {
                    // allow escaping backtick itself: \`
                    self.pos += 1;
                    if (self.pos < self.source.len) self.pos += 1;
                },
                else => self.pos += 1,
            }
        }

        return try self.makeToken(.unterminated_backtick, start, self.pos - start);
    }

    // ── Char utils ────────────────────────────────────────────────────────────
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "eof on empty input" {
    var lex = Lexer.init("");
    try std.testing.expectEqual(TokenKind.eof, lex.next().kind);
}

test "single char tokens" {
    var lex = Lexer.init("{}[]():.");
    const expected = [_]TokenKind{
        .lbrace, .rbrace, .lbracket, .rbracket,
        .lparen, .rparen, .colon,    .dot,
    };
    for (expected) |kind| {
        try std.testing.expectEqual(kind, lex.next().kind);
    }
    try std.testing.expectEqual(TokenKind.eof, lex.next().kind);
}

test "two char tokens" {
    var lex = Lexer.init("== != <= >=");
    const expected = [_]TokenKind{ .eq_eq, .bang_eq, .lt_eq, .gt_eq };
    for (expected) |kind| {
        try std.testing.expectEqual(kind, lex.next().kind);
    }
}

test "single eq is not eq_eq" {
    var lex = Lexer.init("= ==");
    try std.testing.expectEqual(TokenKind.eq, lex.next().kind);
    try std.testing.expectEqual(TokenKind.eq_eq, lex.next().kind);
}

test "keywords" {
    var lex = Lexer.init("const val set arg task group if else and or not true false");
    const expected = [_]TokenKind{
        .const_kw, .val_kw,   .set_kw, .arg_kw,
        .task_kw,  .group_kw, .if_kw,  .else_kw,
        .and_kw,   .or_kw,    .not_kw, .true_kw,
        .false_kw,
    };
    for (expected) |kind| {
        try std.testing.expectEqual(kind, lex.next().kind);
    }
}

test "type keywords" {
    var lex = Lexer.init("string flag int number list");
    const expected = [_]TokenKind{
        .string_type, .flag_type, .int_type, .number_type,
    };
    for (expected) |kind| {
        try std.testing.expectEqual(kind, lex.next().kind);
    }
}

test "keyword prefix is not a keyword" {
    // 'constant' starts with 'const' but is an ident
    var lex = Lexer.init("constant tasker grouped");
    try std.testing.expectEqual(TokenKind.ident, lex.next().kind);
    try std.testing.expectEqual(TokenKind.ident, lex.next().kind);
    try std.testing.expectEqual(TokenKind.ident, lex.next().kind);
}

test "ident slice" {
    const src = "hello_world";
    var lex = Lexer.init(src);
    const tok = lex.next();
    try std.testing.expectEqual(TokenKind.ident, tok.kind);
    try std.testing.expectEqualStrings("hello_world", tok.slice(src));
}

test "integer" {
    const src = "42";
    var lex = Lexer.init(src);
    const tok = lex.next();
    try std.testing.expectEqual(TokenKind.int, tok.kind);
    try std.testing.expectEqualStrings("42", tok.slice(src));
}

test "float" {
    const src = "3.14";
    var lex = Lexer.init(src);
    const tok = lex.next();
    try std.testing.expectEqual(TokenKind.float, tok.kind);
    try std.testing.expectEqualStrings("3.14", tok.slice(src));
}

test "dot between ints is not float" {
    // 42.foo should lex as int, dot, ident — not float
    var lex = Lexer.init("42.foo");
    try std.testing.expectEqual(TokenKind.int, lex.next().kind);
    try std.testing.expectEqual(TokenKind.dot, lex.next().kind);
    try std.testing.expectEqual(TokenKind.ident, lex.next().kind);
}

test "string" {
    const src = "\"hello world\"";
    var lex = Lexer.init(src);
    const tok = lex.next();
    try std.testing.expectEqual(TokenKind.string, tok.kind);
    try std.testing.expectEqualStrings("\"hello world\"", tok.slice(src));
}

test "string with escape" {
    var lex = Lexer.init("\"say \\\"hi\\\"\"");
    try std.testing.expectEqual(TokenKind.string, lex.next().kind);
}

test "unterminated string at newline" {
    var lex = Lexer.init("\"hello\nworld");
    try std.testing.expectEqual(TokenKind.unterminated_string, lex.next().kind);
    // lexer should recover — next token is the ident on the new line
    try std.testing.expectEqual(TokenKind.ident, lex.next().kind);
}

test "unterminated string at eof" {
    var lex = Lexer.init("\"hello");
    try std.testing.expectEqual(TokenKind.unterminated_string, lex.next().kind);
    try std.testing.expectEqual(TokenKind.eof, lex.next().kind);
}

test "backtick" {
    const src = "`echo {{name}}`";
    var lex = Lexer.init(src);
    const tok = lex.next();
    try std.testing.expectEqual(TokenKind.backtick, tok.kind);
    try std.testing.expectEqualStrings("`echo {{name}}`", tok.slice(src));
}

test "unterminated backtick" {
    var lex = Lexer.init("`echo hello\nnext line");
    try std.testing.expectEqual(TokenKind.unterminated_backtick, lex.next().kind);
    try std.testing.expectEqual(TokenKind.ident, lex.next().kind); // "next"
}

test "line comment is skipped" {
    var lex = Lexer.init("// this is a comment\nconst");
    try std.testing.expectEqual(TokenKind.const_kw, lex.next().kind);
}

test "single slash is invalid" {
    var lex = Lexer.init("/ const");
    try std.testing.expectEqual(TokenKind.invalid_char, lex.next().kind);
    try std.testing.expectEqual(TokenKind.const_kw, lex.next().kind);
}

test "invalid char recovers" {
    var lex = Lexer.init("@ const");
    try std.testing.expectEqual(TokenKind.invalid_char, lex.next().kind);
    try std.testing.expectEqual(TokenKind.const_kw, lex.next().kind);
}

test "attribute tokens" {
    // [shell] lexes as lbracket ident rbracket
    var lex = Lexer.init("[shell]");
    try std.testing.expectEqual(TokenKind.lbracket, lex.next().kind);
    try std.testing.expectEqual(TokenKind.ident, lex.next().kind);
    try std.testing.expectEqual(TokenKind.rbracket, lex.next().kind);
}

test "attribute with value" {
    // [short = "x"] lexes as lbracket ident eq string rbracket
    var lex = Lexer.init("[short = \"x\"]");
    try std.testing.expectEqual(TokenKind.lbracket, lex.next().kind);
    try std.testing.expectEqual(TokenKind.ident, lex.next().kind);
    try std.testing.expectEqual(TokenKind.eq, lex.next().kind);
    try std.testing.expectEqual(TokenKind.string, lex.next().kind);
    try std.testing.expectEqual(TokenKind.rbracket, lex.next().kind);
}

test "full snippet" {
    const src =
        \\group go {
        \\    arg dev : flag = false
        \\    const path = "./bin/"
        \\    `go build -o {{path}}`
        \\}
    ;
    const expected = [_]TokenKind{
        .group_kw,  .ident,    .lbrace,
        .arg_kw,    .ident,    .colon,
        .flag_type, .eq,       .false_kw,
        .const_kw,  .ident,    .eq,
        .string,    .backtick, .rbrace,
        .eof,
    };
    var lex = Lexer.init(src);
    for (expected) |kind| {
        const tok = lex.next();
        try std.testing.expectEqual(kind, tok.kind);
    }
}
