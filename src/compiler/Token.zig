const Span = @import("Span.zig");

const Token = @This();
// ── Token kinds ───────────────────────────────────────────────────────────────

pub const Kind = enum {
    // Literals
    char,
    string,
    number,
    true_kw,
    false_kw,
    null_kw,

    // Keywords
    set_kw,
    task_kw,
    group_kw,
    if_kw,
    else_kw,
    and_kw,
    or_kw,
    not_kw,
    for_kw,
    switch_kw,
    continue_kw,
    break_kw,
    fallback_kw,

    // Type keywords
    string_type,
    flag_type,
    number_type,

    // Identifiers (anything that is not a keyword)
    ident,

    // Symbols
    lbrace, // {
    rbrace, // }
    ldbrace, // {{
    rdbrace, // }}
    lbracket, // [
    rbracket, // ]
    lparen, // (
    rparen, // )
    colon, // :
    dcolon, // ::
    dot, // .
    triple_dot, // ...
    comma, // ,
    apostrophe, // '
    quote, // "
    backtick, // `,
    eq, // =
    fat_arrow, // =>
    colon_eq, // :=
    plus, // +
    minus, // -
    star, // *
    slash, // /
    eq_eq, // ==
    bang_eq, // !=
    lt, // <
    gt, // >
    lt_eq, // <=
    gt_eq, // >=
    pipe, // |
    at, // @
    underscore, // _
    dollar, // $
    percent, // %

    // trivia
    whitespace,
    comment,

    // Backtick process line — entire `...` including interpolations as raw span

    // Errors — descriptive kinds so parser can emit a useful message
    invalid_char,
    unterminated_string,

    string_inter,
    string_delim,
    eof,

    pub fn isTrivia(self: Kind) bool {
        return switch (self) {
            .whitespace, .comment => true,
            else => false,
        };
    }
};

// ── Token ─────────────────────────────────────────────────────────────────────

kind: Kind,
span: Span,
lexeme: []const u8,

pub fn isSyntetic(self: *Token) bool {
    return self.kind != .eof and self.span.len == 0;
}
