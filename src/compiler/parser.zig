const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const cst = @import("cst.zig");
const Span = @import("Span.zig");
const Diagnostics = @import("Diagnostics.zig");
const tt = @import("tree.zig");

const Token = @import("Token.zig");
const TokenKind = Token.Kind;

const SET_DECL_START: FollowSet = .set(&.{.ident});
const DECL_START: FollowSet = .set(&.{ .ident, .lparen, .set_kw, .task_kw, .group_kw });
const TARGET_START: FollowSet = .set(&.{ .ident, .lparen });
const ATTR_START: FollowSet = .set(&.{.ident});
const META_START: FollowSet = .set(&.{
    .null_kw, .false_kw,   .true_kw, .number,
    .lparen,  .apostrophe, .quote,   .lbracket,
});
const PARAM_TYPE_START: FollowSet = .set(&.{
    .lbracket, .string_type, .number_type, .flag_type,
});
const EXPR_START: FollowSet = .set(&.{
    .true_kw,   .false_kw, .number,      .ident,
    .lparen,    .quote,    .backtick,    .lbracket,
    .switch_kw, .if_kw,    .at,          .not_kw,
    .minus,     .dollar,   .continue_kw, .break_kw,
});
// A list element is either an expression or a spread (`...expr`).
// `...` is NOT part of EXPR_START: a spread is only valid directly inside
// a list literal, not anywhere an expression may appear.
const LIST_ELEM_START: FollowSet = EXPR_START.with(&.{.triple_dot});
const STMT_START: FollowSet = FollowSet.set(&.{
    .ident,  .if_kw,  .switch_kw,
    .for_kw, .dcolon, .dollar,
}).withSet(EXPR_START);

const SWITCH_CASE_START: FollowSet = EXPR_START.with(&.{.else_kw});
const TASK_CALL_START: FollowSet = .set(&.{ .ident, .dcolon });
const PARAM_START: FollowSet = .set(&.{ .ident, .lbracket });

pub const Parser = struct {
    pub const Error = std.mem.Allocator.Error;

    allocator: std.mem.Allocator,

    cursor: *tt.Cursor,
    pending_trivia: std.ArrayList(Token) = .empty,

    stack: std.ArrayList(Frame) = .empty,
    last_error_at: ?usize = null,
    diagnostics: *Diagnostics,

    pub fn init(
        allocator: std.mem.Allocator,
        cursor: *tt.Cursor,
        diagnostics: *Diagnostics,
    ) !Parser {
        return .{
            .allocator = allocator,
            .cursor = cursor,
            .diagnostics = diagnostics,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.pending_trivia.deinit(self.allocator);
        self.stack.deinit(self.allocator);
    }

    pub fn parseFile(self: *Parser) Error!*cst.Node {
        try self.open();

        while (!try self.atHardStop()) {
            try self.parseAttributes(DECL_START);

            switch (try self.peek()) {
                .set_kw => try self.parseSet(DECL_START),
                .ident, .lparen => try self.parseBinding(DECL_START),
                .task_kw => try self.parseTask(DECL_START),
                .group_kw => try self.parseGroup(DECL_START),
                else => |tag| try self.unexpectedNode(
                    DECL_START,
                    "expected declaration, found '{t}'",
                    .{tag},
                ),
            }
        }
        return self.finish(.source_file);
    }

    fn atBinding(self: *Parser) Error!bool {
        try self.skipTrivia();
        const cursor = self.cursor;
        var pos = cursor.pos;

        while (true) {
            switch (cursor.kindAt(pos)) {
                .ident => pos += 1,
                .lparen => pos = cursor.afterGroup(pos),
                else => return false,
            }
            pos = cursor.skipTriviaAt(pos);

            switch (cursor.kindAt(pos)) {
                .comma => pos = cursor.skipTriviaAt(pos + 1),
                .colon_eq => return true,
                else => return false,
            }
        }
    }

    const StmtKind = enum {
        binding,
        task_call,
        process,
        @"if",
        @"switch",
        @"for",
        in,
        expr,
    };
    fn classifyStmt(self: *Parser) Error!StmtKind {
        return switch (try self.peek()) {
            .dollar => .process,
            .if_kw => .@"if",
            .switch_kw => .@"switch",
            .for_kw => .@"for",
            .in_kw => .in,
            .dcolon => .task_call,
            .ident, .lparen => blk: {
                if (try self.atBinding()) break :blk .binding;

                // A call needs its '(' (or '::') glued to the name, with no
                // trivia in between. Otherwise `x` on one line followed by
                // `(a, b)` on the next would be read as the call `x(a, b)`.
                if (try self.peek() == .ident) switch (try self.peekAdjacent()) {
                    .lparen, .dcolon => break :blk .task_call,
                    else => {},
                };
                break :blk .expr;
            },
            else => .expr,
        };
    }

    fn parseAttributes(self: *Parser, follow: FollowSet) Error!void {
        if (try self.at(.lbracket) == false)
            return;

        try self.open();

        while (try self.at(.lbracket)) {
            try self.parseSequence(
                .lbracket,
                .rbracket,
                .comma,
                follow.withSet(ATTR_START), // fixed: elem-start wasn't in follow
                parseAttribute,
            );
        }

        try self.close(.attributes);
    }

    fn parseAttribute(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.expectAs(
            .ident,
            .name,
            follow.with(&.{.colon}),
        );

        if (try self.eat(.colon)) {
            try self.parseMeta(follow);
        }

        try self.close(.attribute);
    }

    fn parseMeta(self: *Parser, follow: FollowSet) Error!void {
        switch (try self.peek()) {
            .null_kw, .false_kw, .true_kw, .number => try self.advanceAs(.literal),
            .lparen => {
                try self.open();

                try self.parseSequence(
                    .lparen,
                    .rparen,
                    .comma,
                    follow.withSet(META_START), // fixed: elem-start wasn't in follow
                    parseMeta,
                );

                try self.close(.tuple);
            },
            .apostrophe => try self.parseChar(follow),
            .quote => try self.parseString(follow),
            .lbracket => {
                try self.open();
                try self.parseSequence(
                    .lbracket,
                    .rbracket,
                    .comma,
                    follow.withSet(META_START), // fixed: elem-start wasn't in follow
                    parseMeta,
                );
                try self.close(.list);
            },
            else => |tag| try self.unexpectedNode(
                follow,
                "expected meta value, found '{t}'",
                .{tag},
            ),
        }
    }

    fn parseGroup(self: *Parser, follow: FollowSet) Error!void {
        try self.precedeTarget(.attributes);

        try self.expect(.group_kw, follow);

        _ = try self.eatAs(.ident, .name);

        if (try self.at(.lparen)) {
            try self.parseParams(follow.with(&.{.lbrace}));
        }

        try self.parseGroupBody(follow);

        try self.close(.group);
    }

    fn parseGroupBody(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        const decl_start = comptime FollowSet.set(&.{ .ident, .lparen, .task_kw });
        try self.expect(.lbrace, follow.withSet(decl_start));

        while (!try self.atHardStop()) {
            try self.parseAttributes(follow.withSet(decl_start));

            switch (try self.peek()) {
                .ident, .lparen => try self.parseBinding(decl_start),
                .task_kw => try self.parseTask(decl_start),
                else => |tag| try self.unexpectedNode(
                    decl_start,
                    "expected declaration, found '{t}'",
                    .{tag},
                ),
            }
        }

        try self.expect(.rbrace, follow);
        try self.close(.group_body);
    }

    fn parseBinding(self: *Parser, follow: FollowSet) Error!void {
        try self.precedeTarget(.attributes);

        try self.parseBindingTarget(follow);
        try self.expect(.colon_eq, follow.withSet(EXPR_START));
        try self.parseExpr(follow);

        try self.close(.binding);
    }

    fn parseBindingTarget(self: *Parser, follow: FollowSet) Error!void {
        const inner = follow.with(&.{ .comma, .colon_eq });

        try self.parseTarget(inner);

        if (try self.at(.comma)) {
            try self.precedeLast();
            while (try self.eat(.comma))
                try self.parseTarget(inner);
            try self.close(.target);
        }
    }

    fn parseTarget(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        if (try self.at(.lparen)) {
            try self.parseSequence(
                .lparen,
                .rparen,
                .comma,
                follow.withSet(TARGET_START),
                parseTarget,
            );
        } else {
            try self.expectAs(.ident, .name, follow);
        }

        try self.close(.target);
    }

    fn parseSet(self: *Parser, follow: FollowSet) Error!void {
        try self.precedeTarget(.attributes);

        try self.expect(.set_kw, follow.with(&.{ .lbrace, .ident }).withoutSet(META_START));

        try self.parseSetBody(follow);

        try self.close(.set);
    }

    fn parseSetBody(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        if (try self.eat(.lbrace)) {
            while (!try self.atHardStop()) {
                const before = self.cursor.pos;
                try self.parseSetDecl(SET_DECL_START);

                if (self.cursor.pos == before) {
                    try self.open();
                    try self.skipOne();
                    try self.close(.error_tree);
                }
            }
            try self.expect(.rbrace, follow);
        } else {
            try self.parseSetDecl(follow);
        }

        try self.close(.set_body);
    }

    fn parseSetDecl(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.expectAs(.ident, .name, follow.with(&.{.eq}).withSet(META_START));
        if (try self.eat(.eq))
            try self.parseMeta(follow);

        try self.close(.set_decl);
    }

    fn parseTask(self: *Parser, follow: FollowSet) Error!void {
        try self.precedeTarget(.attributes);

        try self.expect(.task_kw, follow.with(&.{.ident}));
        try self.expectAs(.ident, .name, follow.with(&.{ .lparen, .lbracket, .lbrace }));

        if (try self.at(.lparen)) {
            try self.parseParams(follow.with(&.{ .lbracket, .lbrace }));
        }

        if (try self.at(.lbracket)) {
            try self.parseTaskDependencies(follow.with(&.{.lbrace}));
        }

        try self.parseStatementBlock(follow);

        try self.close(.task);
    }

    fn parseParams(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.parseSequence(
            .lparen,
            .rparen,
            .comma,
            follow.withSet(PARAM_START),
            parseParameter,
        );

        try self.close(.params);
    }

    fn parseParameter(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.parseAttributes(follow.with(&.{ .ident, .colon, .eq }).withSet(PARAM_TYPE_START));

        try self.expectAs(.ident, .name, follow.with(&.{ .colon, .eq }).withSet(PARAM_TYPE_START));
        try self.expect(.colon, follow.withSet(PARAM_TYPE_START).with(&.{.eq}).withSet(PARAM_TYPE_START));
        try self.parseParamType(follow.withoutSet(PARAM_START).with(&.{.eq}));

        if (try self.eat(.eq)) {
            try self.parseExpr(follow);
        }

        try self.close(.parameter);
    }

    fn parseParamType(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        if (try self.peek() == .lbracket) {
            try self.open();

            try self.expect(.lbracket, follow.with(&.{.rbracket}));
            try self.expect(.rbracket, follow.with(&.{ .string_type, .number_type }));

            try self.expectOneOf(.set(&.{ .string_type, .number_type }), "'string' or 'number'", follow);

            try self.close(.list_type);
        } else {
            try self.expectOneOf(.set(&.{ .string_type, .number_type, .flag_type }), "a type", follow);
        }

        try self.close(.param_type);
    }

    fn parseTaskDependencies(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.parseSequence(
            .lbracket,
            .rbracket,
            .comma,
            follow.withSet(TASK_CALL_START), // fixed: elem-start wasn't in follow
            parseTaskCall,
        );

        try self.close(.task_deps);
    }

    //================== << statements >> ==================//

    fn parseStatementBlock(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        if (try self.eat(.lbrace)) {
            while (!try self.atHardStop()) {
                try self.parseStatement(STMT_START);
            }
            try self.expect(.rbrace, follow);
        } else if (STMT_START.contains(try self.peek())) {
            try self.parseStatement(follow);
        } else {
            // Neither a '{' nor anything that could start a bare
            // statement is here — the body is simply missing. Report
            // that directly instead of forcing a doomed descent through
            // parseStatement -> parseExprStmt -> parsePrimary just to
            // discover the same thing three frames deeper.
            try self.err("expected '{{' or a statement, found '{t}'", .{try self.peek()});
            try self.missing();
        }

        try self.close(.stmt_block);
    }

    fn parseStatement(self: *Parser, follow: FollowSet) Error!void {
        switch (try self.classifyStmt()) {
            .binding => try self.parseBinding(follow),
            .task_call => try self.parseTaskCall(follow),
            .process => try self.parseProcess(follow, .stmt),
            .@"if" => try self.parseIfStmt(follow),
            .@"switch" => try self.parseSwitch(.stmt, follow),
            .@"for" => try self.parseFor(.stmt, follow),
            .in => try self.parseIn(.stmt, follow),
            .expr => {
                try self.open();
                try self.parseExpr(follow);
                try self.close(.expr_stmt);
            },
            // .underscore, .ident => switch (try self.peekAt(1)) {
            //     .colon_eq => try self.parseBinding(follow, true),
            //     .dcolon, .lparen => try self.parseTaskCall(follow),
            //     else => {
            //         try self.open();
            //         try self.parseExpr(follow);
            //         try self.close(.expr_stmt);
            //     },
            // },
            // .dollar => try self.parseProcess(follow, .stmt),
            // .if_kw => try self.parseIfStmt(follow),
            // .switch_kw => try self.parseSwitch(.stmt, follow),
            // .for_kw => try self.parseFor(.stmt, follow),
            // .dcolon => {
            //     try self.open();

            //     {
            //         try self.open();
            //         try self.expect(.dcolon, follow.with(&.{ .ident, .lparen }));
            //         try self.expectAs(.ident, .name_ref, follow.with(&.{.lparen}));
            //         try self.close(.path);
            //     }
            //     try self.parseTaskCallArgs(follow);
            //     try self.close(.task_call);
            // },
            // else => {
            //     try self.open();
            //     try self.parseExpr(follow);
            //     try self.close(.expr_stmt);
            // },
        }
    }

    fn parseProcess(self: *Parser, follow: FollowSet, comptime target: enum { stmt, expr }) Error!void {
        try self.open();

        try self.expect(.dollar, follow.with(&.{.backtick}));
        if (try self.at(.lbracket)) {
            try self.parseAttributes(follow);
        }
        try self.parseStringExpr(follow);

        switch (target) {
            .expr => {
                if (try self.at(.fallback_kw))
                    try self.parseFallback(follow);

                try self.close(.process_expr);
            },
            .stmt => try self.close(.process_stmt),
        }
    }

    fn parseTaskCall(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.parsePath(follow.with(&.{.lparen}));
        try self.parseTaskCallArgs(follow);

        try self.close(.task_call);
    }

    fn parseTaskCallArgs(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.parseSequence(
            .lparen,
            .rparen,
            .comma,
            follow.withSet(EXPR_START),
            parseTaskCallArg,
        );

        try self.close(.task_call_args);
    }

    fn parseTaskCallArg(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        const named = try self.at(.ident) and try self.peekAt(1) == .colon;
        if (named) {
            try self.advanceAs(.name);
            try self.advance();
        }

        try self.parseExpr(follow);

        try self.close(if (named) .task_call_named_arg else .task_call_arg);
    }

    fn parseIfStmt(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.expect(.if_kw, follow.with(&.{.lparen}));

        try self.expect(.lparen, follow.withSet(EXPR_START));

        try self.parseExpr(follow.with(&.{.rparen}));
        try self.expect(.rparen, follow.withSet(STMT_START).with(&.{.lbrace}));

        try self.parseStatementBlock(follow.with(&.{.else_kw}));

        if (try self.eat(.else_kw)) {
            try self.parseStatementBlock(follow);
        }

        try self.close(.@"if");
    }

    //==================== << Stmt / Expr Commons >> ====================//

    fn parseSwitch(self: *Parser, comptime body_type: BodyType, follow: FollowSet) Error!void {
        try self.open();

        try self.expect(.switch_kw, follow.with(&.{.lparen}));
        try self.expect(.lparen, follow.withSet(EXPR_START));
        try self.parseExpr(follow.with(&.{.rparen}));
        try self.expect(.rparen, follow.with(&.{.lbrace})); // fixed: was .rbrace

        try self.parseSwitchBody(body_type, follow);

        try self.close(.@"switch");
    }

    fn parseSwitchBody(self: *Parser, comptime body_type: BodyType, follow: FollowSet) Error!void {
        const Bindings = struct {
            fn caseExpr(p: *Parser, f: FollowSet) Error!void {
                try parseSwitchCase(p, .expr, f);
            }

            fn stmtExpr(p: *Parser, f: FollowSet) Error!void {
                try parseSwitchCase(p, .stmt, f); // fixed: was .expr
            }
        };

        try self.open();

        try self.parseSequence(
            .lbrace,
            .rbrace,
            .comma,
            follow.withSet(SWITCH_CASE_START),
            switch (body_type) {
                .expr => Bindings.caseExpr,
                .stmt => Bindings.stmtExpr,
            },
        );

        try self.close(.switch_body);
    }

    fn parseSwitchCase(self: *Parser, comptime body_type: BodyType, follow: FollowSet) Error!void {
        try self.open();

        try self.parseSwitchCasePattern(
            follow
                .with(&.{.fat_arrow})
                .withSet(body_type.bodyStart()),
        );

        try self.expect(.fat_arrow, follow.withSet(body_type.bodyStart()));

        try body_type.parse(self, follow);

        try self.close(.switch_case);
    }

    fn parseSwitchCasePattern(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        if (try self.eat(.else_kw) == false) {
            while (true) {
                try self.parseExpr(
                    follow
                        .with(&.{.comma})
                        .withoutSet(EXPR_START),
                );

                if (try self.eat(.comma) == false)
                    break;
            }
        }

        try self.close(.switch_case_pattern);
    }

    fn parseFor(self: *Parser, comptime body_type: BodyType, follow: FollowSet) Error!void {
        try self.open();

        try self.expect(.for_kw, follow.with(&.{.lparen}));
        try self.parseForSubjects(follow.with(&.{.pipe}));
        if (try self.at(.parallel_kw))
            try self.parseParallel(follow.with(&.{.pipe}));
        try self.parseCaptures(follow.withSet(body_type.bodyStart()));
        try body_type.parse(self, follow);

        try self.close(.@"for");
    }

    fn parseForSubjects(self: *Parser, follow: FollowSet) Error!void {
        try self.open();
        try self.parseSequence(
            .lparen,
            .rparen,
            .comma,
            follow.withSet(EXPR_START),
            parseForSubject,
        );
        try self.close(.subjects);
    }

    fn parseForSubject(self: *Parser, follow: FollowSet) Error!void {
        try self.parseExpr(follow);

        if (try self.at(.double_dot)) {
            try self.precedeLast();
            try self.advance();
            if (EXPR_START.contains(try self.peek()))
                try self.parseExpr(follow);

            try self.close(.range);
        }
    }

    fn parseCaptures(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        const inner = follow.withSet(TARGET_START).with(&.{ .comma, .pipe });

        try self.expect(.pipe, inner);

        while (!try self.at(.pipe) and !try self.atHardStop()) {
            const before = self.cursor.pos;

            try self.parseTarget(inner);

            if (try self.eat(.comma)) continue;
            if (try self.at(.pipe) or try self.atHardStop()) break;

            try self.expect(.comma, inner);
            if (self.cursor.pos == before) break;
        }

        try self.expect(.pipe, follow);
        try self.close(.captures);
    }

    fn parseIn(self: *Parser, comptime body_type: BodyType, follow: FollowSet) Error!void {
        try self.open();

        try self.expect(.in_kw, follow.with(&.{.lparen}));
        try self.expect(.lparen, follow.withSet(EXPR_START));
        try self.parseExpr(follow.with(&.{.rparen}));
        try self.expect(.rparen, body_type.bodyStart());
        try body_type.parse(self, follow.with(&.{.else_kw}));
        if (try self.eat(.else_kw))
            try body_type.parse(self, follow);

        try self.close(.in);
    }

    const BodyType = enum {
        expr,
        stmt,

        pub fn bodyStart(comptime self: BodyType) FollowSet {
            return switch (self) {
                .expr => EXPR_START,
                .stmt => STMT_START.with(&.{.lbrace}),
            };
        }

        pub fn parse(comptime self: BodyType, parser: *Parser, follow: FollowSet) Error!void {
            const FuncT = fn (*Parser, FollowSet) Error!void; // fixed: was missing the FollowSet param
            const func: FuncT = switch (self) {
                .expr => Parser.parseExpr,
                .stmt => Parser.parseStatementBlock,
            };

            try func(parser, follow);
        }
    };

    //================== << Expressions >> ========================//

    fn parseExpr(self: *Parser, follow: FollowSet) Error!void {
        try self.parseBinaryBp(0, follow);
    }

    fn parseBinaryBp(self: *Parser, min_bp: u8, follow: FollowSet) Error!void {
        try self.parsePrefix(follow);

        while (infixBp(try self.peek())) |bp| {
            if (bp[0] < min_bp) break;

            try self.precedeLast();
            try self.advance();
            try self.parseBinaryBp(bp[1], follow);
            try self.close(.binary_expr);
        }
    }

    fn infixBp(op: TokenKind) ?struct { u8, u8 } {
        const x: u8 = switch (op) {
            .or_kw => 1,
            .and_kw => 2,
            .eq_eq, .bang_eq, .lt, .gt, .lt_eq, .gt_eq => 3,
            .plus, .minus => 4,
            .star, .slash, .percent => 5,
            else => return null,
        };
        const a = x * 2;
        return .{ a - 1, a };
    }

    fn parsePrefix(self: *Parser, follow: FollowSet) Error!void {
        if (unaryBp(try self.peek())) |bp| {
            try self.open();
            try self.advance();
            try self.parseBinaryBp(bp, follow);
            try self.close(.unary_expr);
            return;
        }

        try self.parsePostfix(follow);
    }

    fn unaryBp(op: TokenKind) ?u8 {
        return switch (op) {
            .not_kw => 5,
            .minus => 11,
            else => null,
        };
    }

    fn parsePostfix(self: *Parser, follow: FollowSet) Error!void {
        try self.parsePrimary(follow);
        while (try self.atImmediate(.lbracket)) {
            try self.precedeLast();
            try self.advance();
            try self.parseRange(follow);
            try self.expect(.rbracket, follow);
            try self.close(.slice);
        }
    }

    fn parsePrimary(self: *Parser, follow: FollowSet) Error!void {
        switch (try self.peek()) {
            .true_kw, .false_kw, .number => try self.advanceAs(.literal),
            // A lambda call needs its '(' glued to the name. With a newline
            // (or any trivia) in between, `i` and a following `(check(..))`
            // are two separate things, not the call `i(check(..))`.
            .ident => switch (try self.peekAdjacent()) {
                .lparen => try self.parseLambdaCall(follow),
                else => try self.advanceAs(.name_ref),
            },
            .lparen => {
                try self.open();
                try self.parseSequence(
                    .lparen,
                    .rparen,
                    .comma,
                    follow,
                    parseExpr,
                );
                try self.close(.paren_expr);
            },
            .dollar => try self.parseProcess(follow, .expr),
            .backtick => try self.parseStringExpr(follow),
            .quote => try self.parseString(follow),
            .lbracket => {
                try self.open();

                try self.parseSequence(
                    .lbracket,
                    .rbracket,
                    .comma,
                    follow.withSet(LIST_ELEM_START),
                    parseListElem,
                );

                try self.close(.list);
            },
            .for_kw => try self.parseFor(.expr, follow.with(&.{.rbracket})),
            .pipe => try self.parseLambdaExpr(follow),
            .switch_kw => try self.parseSwitch(.expr, follow),
            .at => try self.parseBuiltin(follow),
            .if_kw => try self.parseIfExpr(follow),
            .continue_kw => try self.advanceAs(.@"continue"),
            .break_kw => try self.advanceAs(.@"break"),
            .with_kw => try self.parseWithExpr(follow),
            .in_kw => try self.parseIn(.expr, follow),
            else => |tag| try self.unexpectedNode(
                follow,
                "expected an expression, found '{t}'",
                .{tag},
            ),
        }
    }

    /// One element of a list literal: either a plain expression or a spread,
    /// `...expr`, which splices the elements of another list into this one.
    fn parseListElem(self: *Parser, follow: FollowSet) Error!void {
        if (try self.at(.triple_dot)) {
            try self.open();
            try self.advance();
            try self.parseExpr(follow);
            try self.close(.spread);
        } else {
            try self.parseExpr(follow);
        }
    }

    fn parseWithExpr(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.expect(.with_kw, follow);

        try self.open();
        try self.parseSequence(
            .lparen,
            .rparen,
            .comma,
            follow,
            parseExpr,
        );
        try self.close(.subjects);

        try self.parseCaptures(follow);

        try self.parseExpr(follow);

        try self.close(.with);
    }

    fn parseRange(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.parseExpr(follow);
        try self.expect(.double_dot, follow);

        if (EXPR_START.contains(try self.peek()))
            try self.parseExpr(follow);

        try self.close(.range);
    }

    fn parseLambdaCall(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.expectAs(.ident, .name_ref, follow.with(&.{.lparen}));

        try self.parseCallArgs(follow);

        try self.close(.lambda_call);
    }

    fn parseFallback(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.expect(.fallback_kw, follow.withoutSet(EXPR_START));
        try self.parseExpr(follow);

        try self.close(.fallback);
    }

    fn parseParallel(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.expect(.parallel_kw, follow.with(&.{.lparen}));
        if (try self.eat(.lparen)) {
            try self.parseExpr(follow.with(&.{.rparen}));
            try self.expect(.rparen, follow);
        }

        try self.close(.parallel);
    }

    fn parseLambdaExpr(self: *Parser, follow: FollowSet) Error!void {
        try self.open();
        try self.parseCaptures(follow.withSet(EXPR_START));

        // body
        try self.parseExpr(follow);

        try self.close(.lambda);
    }

    fn parseIfExpr(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.expect(.if_kw, follow.with(&.{.lparen}));

        try self.expect(.lparen, follow.withSet(EXPR_START));
        try self.parseExpr(follow.with(&.{.rparen}));
        try self.expect(.rparen, follow.withSet(EXPR_START));

        try self.parseExpr(follow.with(&.{.else_kw}));
        try self.expect(.else_kw, follow.withSet(EXPR_START));
        try self.parseExpr(follow);

        try self.close(.@"if");
    }

    fn parseBuiltin(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.expect(.at, follow.with(&.{.ident}));
        try self.expect(.ident, follow.with(&.{.lparen}));
        try self.parseCallArgs(follow.withSet(EXPR_START).with(&.{.fallback_kw}));

        if (try self.at(.fallback_kw))
            try self.parseFallback(follow);

        try self.close(.builtin_call);
    }

    fn parseCallArgs(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.parseSequence(
            .lparen,
            .rparen,
            .comma,
            follow.withSet(EXPR_START),
            parseExpr,
        );

        try self.close(.call_args);
    }

    fn parseChar(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.expect(.apostrophe, follow.with(&.{ .char, .apostrophe }));
        try self.expect(.char, follow.with(&.{.apostrophe}));
        try self.expect(.apostrophe, follow);

        try self.close(.char);
    }

    fn parseString(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        try self.expect(.quote, follow.with(&.{ .string, .quote }));
        _ = try self.eat(.string);
        try self.expect(.quote, follow);

        try self.close(.string);
    }

    fn parseStringExpr(self: *Parser, follow: FollowSet) Error!void {
        try self.open();

        const inner = follow.with(&.{ .backtick, .string, .lbrace });
        try self.expect(.backtick, inner);

        while (!try self.at(.backtick) and !try self.atHardStop()) { // fixed: was eat(token), double-consumed the closer
            const before = self.cursor.pos;

            if (try self.eat(.lbrace)) {
                try self.parseExpr(follow.with(&.{.rbrace}));
                try self.expect(.rbrace, inner);
            } else {
                try self.expect(.string, inner);
            }

            if (before == self.cursor.pos) break;
        }

        try self.expect(.backtick, follow);
        try self.close(.string_expr);
    }

    //================= << sequence >> ======================//

    fn parseSequence(
        self: *Parser,
        comptime open_token: TokenKind,
        comptime close_token: TokenKind,
        comptime sep_token: TokenKind,
        follow: FollowSet,
        comptime elem: fn (*Parser, FollowSet) Error!void,
    ) Error!void {
        const inner = follow.with(&.{ sep_token, close_token });

        try self.expect(open_token, inner);

        while (!try self.atHardStop()) {
            const before = self.cursor.pos;

            try elem(self, inner);

            if (try self.eat(sep_token)) continue;
            if (try self.atHardStop()) break;

            try self.expect(sep_token, inner);
            if (self.cursor.pos == before) break;
        }

        try self.expect(close_token, follow);
    }

    //======================== << misc >> =========================//

    fn parsePath(self: *Parser, follow: FollowSet) Error!void {
        try self.open();
        if (try self.eatAs(.ident, .name_ref)) {
            // '::' must be glued to the group name, same reasoning as calls:
            // `name` followed by a statement starting with `::task()` on the
            // next line must not be merged into one path.
            if (try self.atImmediate(.dcolon)) {
                try self.advance();
                try self.expectAs(.ident, .name_ref, follow);
            }
        } else {
            try self.expect(.dcolon, follow.with(&.{.ident}));
            try self.expectAs(.ident, .name_ref, follow);
        }
        try self.close(.path);
    }

    //============= << base utility functions >> ==============//

    fn expectAs(self: *Parser, comptime kind: TokenKind, as: cst.NodeKind, follow: FollowSet) Error!void {
        try self.open();
        try self.expect(kind, follow);
        try self.close(as);
    }

    fn expect(self: *Parser, comptime kind: TokenKind, follow: FollowSet) Error!void {
        try self.expectOneOf(.set(&.{kind}), "'" ++ @tagName(kind) ++ "'", follow);
    }

    fn expectOneOf(self: *Parser, wanted: FollowSet, comptime what: []const u8, follow: FollowSet) Error!void {
        if (try self.atAny(wanted)) {
            try self.advance();
            return;
        }

        try self.err("expected {s}, found '{t}'", .{ what, try self.peek() });

        if (try self.atHardStop() or follow.contains(try self.peek())) {
            try self.missing();
            return;
        }

        try self.open();

        while (!try self.atHardStop() and !try self.atAny(wanted) and !follow.contains(try self.peek()))
            try self.skipOne();

        try self.close(.error_tree);

        if (try self.atAny(wanted)) {
            try self.advance();
        } else {
            try self.missing();
        }
    }

    fn unexpectedNode(self: *Parser, follow: FollowSet, comptime fmt: []const u8, args: anytype) Error!void {
        try self.err(fmt, args);

        try self.open();
        while (!try self.atHardStop() and !follow.contains(try self.peek()))
            try self.skipOne();

        try self.close(.error_tree);
    }

    fn missing(self: *Parser) Error!void {
        try self.skipTrivia();
        try self.frame().children.append(self.allocator, .{
            .missing = .{ .start = self.cursor.spanAt(self.cursor.pos).start, .len = 0 },
        });
    }

    fn eatAs(self: *Parser, comptime kind: TokenKind, as: cst.NodeKind) Error!bool {
        if (!try self.at(kind)) return false;
        try self.advanceAs(as);
        return true;
    }

    fn eat(self: *Parser, kind: TokenKind) Error!bool {
        if (!try self.at(kind)) return false;
        try self.advance();
        return true;
    }

    fn advanceAs(self: *Parser, kind: cst.NodeKind) Error!void {
        try self.open();
        try self.advance();
        try self.close(kind);
    }

    fn precedeLast(self: *Parser) Error!void {
        const left = self.frame().children.pop() orelse unreachable;
        try self.open();
        try self.frame().children.append(self.allocator, left);
    }

    fn precedeTarget(self: *Parser, comptime kind: cst.NodeKind) Error!void {
        const is_target = blk: {
            const last = self.frame().children.getLastOrNull() orelse break :blk false;

            switch (last) {
                .node => |node| {
                    if (node.kind == kind)
                        break :blk true;
                },
                else => {},
            }
            break :blk false;
        };

        if (is_target)
            try self.precedeLast()
        else
            try self.open();
    }

    fn open(self: *Parser) Error!void {
        try self.skipTrivia();
        try self.stack.append(self.allocator, .{
            .start = self.cursor.spanAt(self.cursor.pos).start,
            .children = .empty,
        });
    }

    fn close(self: *Parser, kind: cst.NodeKind) Error!void {
        const node = try self.finish(kind);

        try self.frame().children.append(
            self.allocator,
            .{ .node = node },
        );
    }

    fn finish(self: *Parser, kind: cst.NodeKind) Error!*cst.Node {
        var curr_frame = self.stack.pop() orelse unreachable;
        const children = try curr_frame.children.toOwnedSlice(self.allocator);
        const span: Span = blk: {
            if (children.len == 0)
                break :blk .{
                    .start = curr_frame.start,
                    .len = 0,
                };
            // // trim whitespaces and comments
            // const first: Span = for (children) |child| {
            //     if (child == .token and child.token.kind.isTrivia())
            //         continue;

            //     break child.span();
            // } else unreachable;

            // const last: Span = inner: {
            //     var it = std.mem.reverseIterator(children);

            //     while (it.next()) |child| {
            //         if (child == .token and child.token.kind.isTrivia())
            //             continue;

            //         break :inner child.span();
            //     } else unreachable;
            // };

            const first = children[0].span();
            const last = children[children.len - 1].span();

            break :blk .{
                .start = first.start,
                .len = (last.start + last.len) - first.start,
            };
        };

        const ptr = try self.allocator.create(cst.Node);

        ptr.* = .{
            .kind = kind,
            .children = children,
            .span = span,
        };

        // setup children's parent

        for (ptr.children) |ch| {
            switch (ch) {
                .node => |n| n.parent = ptr,
                else => {},
            }
        }

        return ptr;
    }

    fn advance(self: *Parser) Error!void {
        try self.skipTrivia();
        const pos = self.cursor.pos;
        try self.flushTrivia();

        try self.frame().children.append(
            self.allocator,
            if (self.cursor.advance()) |token|
                .{ .token = token }
            else
                .{
                    .missing = .{
                        .start = self.cursor.spanAt(pos).start,
                        .len = 0,
                    },
                },
        );
    }

    fn skipOne(self: *Parser) Error!void {
        std.debug.assert(!try self.atHardStop());
        const d = self.cursor.depth;
        try self.advance();
        while (self.cursor.depth > d) try self.advance();
    }

    // fetches trivia and peeks,
    fn peek(self: *Parser) Error!TokenKind {
        try self.skipTrivia();
        return self.cursor.peek();
    }

    /// True when the next token is `token` AND nothing (whitespace, newline,
    /// comment) separates it from the previous token. Used for postfix forms
    /// that would otherwise be ambiguous across lines: slices `x[..]`,
    /// `name::task` paths.
    fn atImmediate(self: *Parser, token: TokenKind) Error!bool {
        return try self.at(token) and self.pending_trivia.items.len == 0;
    }

    /// Kind of the raw token directly after the next significant token,
    /// WITHOUT skipping trivia: a space or newline shows up as its own
    /// (trivia) kind. Use it to decide whether a name is immediately followed
    /// by '(' or '::', as in `name(...)`, before the name is consumed.
    fn peekAdjacent(self: *Parser) Error!TokenKind {
        try self.skipTrivia();
        return self.cursor.kindAt(self.cursor.pos + 1);
    }

    fn peekAt(self: *Parser, offset: usize) Error!TokenKind {
        try self.skipTrivia();
        var pos = self.cursor.pos;
        var left = offset;
        while (left > 0) : (left -= 1) {
            pos += 1;
            while (self.cursor.kindAt(pos).isTrivia()) : (pos += 1) {}
        }
        return self.cursor.kindAt(pos);
    }

    fn at(self: *Parser, token: TokenKind) Error!bool {
        return try self.peek() == token;
    }

    fn atAny(self: *Parser, tokens: FollowSet) Error!bool {
        return tokens.contains(try self.peek());
    }

    fn atEnd(self: *Parser) Error!bool {
        return try self.peek() == .eof;
    }

    fn atHardStop(self: *Parser) Error!bool {
        return (try self.peek()) == .eof or self.cursor.atClose();
    }

    fn err(self: *Parser, comptime fmt: []const u8, args: anytype) Error!void {
        try self.skipTrivia();
        const pos = self.cursor.pos;
        if (self.last_error_at) |p| if (p == pos) return;
        self.last_error_at = pos;
        try self.diagnostics.err(self.cursor.spanAt(pos), fmt, args);
    }

    fn flushTrivia(self: *Parser) Error!void {
        if (self.pending_trivia.items.len == 0) return;
        for (self.pending_trivia.items) |tok| {
            try self.frame().children.append(self.allocator, .{ .token = tok });
        }
        self.pending_trivia.clearRetainingCapacity();
    }

    fn skipTrivia(self: *Parser) Error!void {
        while (self.cursor.peek().isTrivia()) {
            const tok = self.cursor.advance().?;
            try self.pending_trivia.append(self.allocator, tok);
        }
    }

    const Frame = struct {
        start: u32,
        children: std.ArrayList(cst.Element),
    };

    fn frame(self: *Parser) *Frame {
        const last_index = self.stack.items.len - 1;
        return &self.stack.items[last_index];
    }
};

const FollowSet = struct {
    data: std.EnumSet(TokenKind),

    fn set(comptime tokens: []const TokenKind) FollowSet {
        return .{
            .data = comptime .initMany(tokens),
        };
    }

    fn with(curr: *const FollowSet, comptime tokens: []const TokenKind) FollowSet {
        return curr.withSet(.set(tokens));
    }

    fn withSet(curr: *const FollowSet, other: FollowSet) FollowSet {
        return .{
            .data = curr.data.unionWith(other.data), // fixed: was unioning against `other`, not `other.data`
        };
    }

    fn without(curr: *const FollowSet, comptime tokens: []const TokenKind) FollowSet {
        return curr.withoutSet(.set(tokens));
    }

    fn withoutSet(curr: *const FollowSet, other: FollowSet) FollowSet {
        return .{
            .data = curr.data.differenceWith(other.data),
        };
    }

    fn contains(self: *const FollowSet, kind: TokenKind) bool {
        return self.data.contains(kind);
    }
};
