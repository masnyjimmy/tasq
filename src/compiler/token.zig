const Diagnostics = @import("Diagnostics.zig");
const Span = Diagnostics.Span;
const WithSpan = Span.Wrapped;

// ── Token kinds ───────────────────────────────────────────────────────────────

pub const TokenKind = enum {
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
    comma, // ,
    apostrophe, // '
    quote, // "
    backtick, // `,
    eq, // =
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

    // Backtick process line — entire `...` including interpolations as raw span

    // Errors — descriptive kinds so parser can emit a useful message
    invalid_char,
    unterminated_string,

    string_inter,
    string_delim,
    eof,
};

// ── Token ─────────────────────────────────────────────────────────────────────

pub const Token = struct {
    kind: TokenKind,
    span: Span,
    lexeme: []const u8,

    pub fn sliceWithSpan(self: Token) WithSpan([]const u8) {
        return .{
            .span = self.span,
            .value = self.lexeme,
        };
    }
};
