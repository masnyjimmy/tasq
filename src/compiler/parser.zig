const ast = @import("ast.zig");
const std = @import("std");

const lex = @import("lexer.zig");
const Lexer = lex.Lexer;

const text = @import("text.zig");

const token = @import("token.zig");
const Token = token.Token;
const TokenKind = token.TokenKind;

const Diagnostics = @import("Diagnostics.zig");

const Span = @import("span.zig");

const ParseError = error{
    UnexpectedToken,
    UnableToRetreat,
} || std.mem.Allocator.Error;

fn parseTaskCall(value: []const u8) struct { []const u8, []const u8 } {
    const dot_index = std.mem.lastIndexOfScalar(u8, value, '.') orelse 0;
    return .{ value[0..dot_index], value[dot_index..] };
}

//TODO: make parser conserve order of nodes

pub const Parser = struct {
    arena: *std.heap.ArenaAllocator,
    lexer: *Lexer,
    diagnostics: *Diagnostics,
    span_registry: *Span.Registry,

    current: ?Token,
    next: Token,

    pub fn init(arena: *std.heap.ArenaAllocator, lexer: *Lexer, diagnostics: *Diagnostics) Parser {
        const first = lexer.next();

        return .{
            .arena = arena,
            .lexer = lexer,
            .diagnostics = diagnostics,
            .current = null,
            .next = first,
        };
    }

    // ── Span helper ───────────────────────────────────────────────────────────

    fn spanFrom(self: *Parser, start: u32) Span {
        const end = if (self.current) |p| p.span.start + p.span.len else self.next.span.start;
        return .{
            .start = start,
            .len = end - start,
        };
    }

    fn peek(self: *Parser) TokenKind {
        return self.next.kind;
    }

    fn setNextFetchCurrent(self: *Parser, tok: Token) Token {
        const curr = self.next;
        self.current = curr;
        self.next = tok;
        return curr;
    }

    fn retreat(self: *Parser) !Token {
        if (self.current) |prev| {
            self.lexer.pos = self.next.span.start;
            self.next = prev;
            self.current = null;
            return prev;
        } else {
            return error.UnableToRetreat;
        }
    }

    fn advance(self: *Parser) Token {
        const tok = self.lexer.next();
        return self.setNextFetchCurrent(tok);
    }

    fn expect(self: *Parser, kind: TokenKind) !Token {
        if (self.next.kind == kind) return self.advance();

        try self.addDiagnostic(
            .err,
            "expected '{s}', found {s}",
            .{ @tagName(kind), @tagName(self.next.kind) },
        );

        return error.UnexpectedToken;
    }

    fn eat(self: *Parser, kind: TokenKind) ?Token {
        if (self.next.kind == kind) return self.advance();
        return null;
    }

    fn resyncFromRaw(self: *Parser) void {
        self.next = self.lexer.next();
    }

    fn resyncToRaw(self: *Parser) void {
        if (self.current) |curr|
            self.lexer.pos = curr.span.end();
    }

    fn readCharacter(self: *Parser) !Token {
        var lexer = self.lexer.stringLexer();
        const tok = lexer.lexCharacter();
        if (tok.kind != .char) {
            try self.addDiagnostic(.err, "expected char, found '{s}'", .{@tagName(tok.kind)});
            return ParseError.UnexpectedToken;
        }

        self.resyncFromRaw();
        return tok;
    }

    fn readString(self: *Parser, terminator: []const u8, comptime multiline: bool) !Token {
        var lexer = self.lexer.stringLexer();
        const tok = lexer.lexString(&.{terminator}, multiline);

        if (tok.kind != .string) {
            try self.addDiagnostic(.err, "expected string, found '{s}'", .{@tagName(tok.kind)});
            return ParseError.UnexpectedToken;
        }

        self.resyncFromRaw();
        return tok;
    }

    fn addDiagnostic(
        self: *Parser,
        comptime severity: Diagnostics.Severity,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.diagnostics.append(
            severity,
            self.next.span,
            fmt,
            args,
        );
    }

    fn synchronize(self: *Parser) void {
        while (true) {
            switch (self.peek()) {
                TokenKind.task_kw,
                TokenKind.group_kw,
                TokenKind.set_kw,
                TokenKind.rbrace,
                TokenKind.eof,
                => return,
                // FIX: explicitly discard return value
                else => _ = self.advance(),
            }
        }
    }

    pub fn parseFile(self: *Parser) !ast.File {
        const start = self.currentPos();

        var options = try std.ArrayList(ast.Set).initCapacity(self.arena.allocator(), 1);
        var decls = try std.ArrayList(ast.Decl).initCapacity(self.arena.allocator(), 1);
        var groups = try std.ArrayList(ast.Group).initCapacity(self.arena.allocator(), 8);
        var tasks = try std.ArrayList(ast.Task).initCapacity(self.arena.allocator(), 5);

        while (self.peek() != .eof) {
            const attrs = try self.collectAttributes();
            const tok_start = self.currentPos();
            const tok = self.advance();

            switch (tok.kind) {
                .set_kw => {
                    const set = try self.parseSet(attrs, tok_start);
                    try options.append(self.arena.allocator(), set);
                    continue;
                },
                .ident => {
                    if (attrs.len != 0) {
                        try self.addDiagnostic(.err, "unexpected attributes before declaration", .{});
                        return error.UnexpectedToken;
                    }
                    _ = try self.expect(.colon_eq);

                    const value_start = self.currentPos();
                    const value = try self.parseExpr();

                    const id = try self.span_registry.putNode(
                        self.spanFrom(tok_start),
                        tok.span,
                        self.spanFrom(value_start),
                        null,
                    );

                    const decl = ast.Decl{
                        .id = id,
                        .name = tok.lexeme,
                        .value = value,
                    };

                    try decls.append(self.arena.allocator(), decl);
                    continue;
                },
                .group_kw => {
                    const group = try self.parseGroup(attrs, tok_start);
                    try groups.append(self.arena.allocator(), group);
                    continue;
                },
                .task_kw => {
                    const task = try self.parseTask(attrs, tok_start);
                    try tasks.append(self.arena.allocator(), task);
                    continue;
                },
                else => {
                    try self.addDiagnostic(.err, "Unexpected token", .{});
                    return error.UnexpectedToken;
                },
            }
        }

        return .{
            .options = try options.toOwnedSlice(self.arena.allocator()),
            .decls = try decls.toOwnedSlice(self.arena.allocator()),
            .groups = try groups.toOwnedSlice(self.arena.allocator()),
            .tasks = try tasks.toOwnedSlice(self.arena.allocator()),
            .span = self.spanFrom(start),
        };
    }

    fn collectAttributes(self: *Parser) ![]ast.Attribute {
        var attributes = try std.ArrayList(ast.Attribute).initCapacity(self.arena.allocator(), 1);

        while (self.eat(.lbracket) != null) {
            const attr = try self.parseAttribute();
            try attributes.appendSlice(self.arena.allocator(), attr);
            // FIX: removed arena free — arena allocators don't release individual allocations,
            // this was a no-op and misleading.
        }

        return try attributes.toOwnedSlice(self.arena.allocator());
    }

    fn parseAttribute(self: *Parser) ![]ast.Attribute {
        var attrs = try std.ArrayList(ast.Attribute).initCapacity(self.arena.allocator(), 1);

        while (true) {
            const attr_start = self.currentPos();
            const name = try self.expect(.ident);

            var value: ?ast.MetaValue = null;
            var span: ?Span = null;

            if (self.eat(.colon) != null) { //TODO: handle color span
                const meta_start = self.currentPos();
                value = try self.parseMetaValue();
                span = self.spanFrom(meta_start);
            }

            const id = try self.span_registry.putNode(
                self.span_registry(attr_start),
                name.span,
                span,
                null,
            );

            try attrs.append(
                self.arena.allocator(),
                .{
                    .id = id,
                    .name = name.lexeme,
                    .value = value,
                },
            );

            if (self.eat(.comma) == null) {
                break;
            }
        }

        _ = try self.expect(.rbracket);

        return attrs.toOwnedSlice(self.arena.allocator());
    }

    fn parseGroup(self: *Parser, attrs: []ast.Attribute, start: u32) !ast.Group {
        const name = self.eat(.ident);

        var arguments: []ast.Argument = &.{};

        if (self.eat(.lparen) != null) {
            arguments = try self.parseArguments();
        }

        _ = try self.expect(.lbrace);

        var decls = try std.ArrayList(ast.Decl).initCapacity(self.arena.allocator(), 5);
        var tasks = try std.ArrayList(ast.Task).initCapacity(self.arena.allocator(), 1);

        while (self.eat(.rbrace) == null) {
            const tmpAttr = try self.collectAttributes();
            const tok_start = self.currentPos();
            const tok = self.advance();

            switch (tok.kind) {
                .ident => {
                    // FIX: was checking `attrs` (the group's own attrs) instead of
                    // `tmpAttr` (the attrs just collected for this inner declaration).
                    if (tmpAttr.len != 0) {
                        try self.addDiagnostic(.err, "unexpected attributes before declaration", .{});
                        return error.UnexpectedToken;
                    }
                    _ = try self.expect(.colon_eq);
                    const value_start = self.currentPos();
                    const value = try self.parseExpr();

                    const id = try self.span_registry.putNode(
                        self.spanFrom(tok_start),
                        tok.span,
                        self.spanFrom(value_start),
                        null,
                    );

                    const decl = ast.Decl{
                        .id = id,
                        .name = tok.lexeme,
                        .value = value,
                    };

                    try decls.append(self.arena.allocator(), decl);
                    continue;
                },
                .task_kw => {
                    const task = try self.parseTask(tmpAttr, tok.span.start);
                    try tasks.append(self.arena.allocator(), task);
                    continue;
                },
                else => {
                    try self.addDiagnostic(.err, "Unexpected token: {s}.", .{@tagName(tok.kind)});
                    return error.UnexpectedToken;
                },
            }
        }

        const id = try self.span_registry.putNode(
            self.spanFrom(start),
            if (name) |v| v.span else null,
            null,
            null,
        );

        return .{
            .id = id,
            .name = if (name) |v| v.lexeme else null,
            .attrs = attrs,
            .args = arguments,
            .decls = try decls.toOwnedSlice(self.arena.allocator()),
            .tasks = try tasks.toOwnedSlice(self.arena.allocator()),
        };
    }

    fn parseTask(self: *Parser, attrs: []ast.Attribute, start: u32) !ast.Task {
        const name = try self.expect(.ident);

        var arguments: []ast.Argument = &.{};

        if (self.eat(.lparen) != null) {
            arguments = try self.parseArguments();
        }

        _ = try self.expect(.lbrace);

        const body = blk: {
            if (ast.hasAttr(attrs, "script")) {
                const body_start = self.currentPos();
                self.resyncToRaw();

                const str = try self.parseStringExpr("}", true);

                _ = try self.expect(.rbrace);

                const stmts = try self.arena.allocator().alloc(ast.Statement, 1);
                stmts[0] = .{ .process = str };

                // whole body as string
                try self.span_registry.put(.string, self.spanFrom(body_start));

                break :blk stmts;
            }

            break :blk try self.parseStatements();
        };

        const id = try self.span_registry.putNode(
            self.spanFrom(start),
            name.span,
            null,
            null,
        );

        return .{
            .id = id,
            .name = name.lexeme,
            .attrs = attrs,
            .args = arguments,
            .body = body,
        };
    }

    fn parseStatements(self: *Parser) ParseError![]ast.Statement {
        var stmts = try std.ArrayList(ast.Statement).initCapacity(self.arena.allocator(), 1);

        while (self.eat(.rbrace) == null) {
            try stmts.append(self.arena.allocator(), try self.parseOneStatement());
        }

        return try stmts.toOwnedSlice(self.arena.allocator());
    }

    fn parseOneStatement(self: *Parser) ParseError!ast.Statement {
        switch (self.peek()) {
            .backtick => {
                try self.span_registry.put(.string, self.next.span); // backstick is string part

                const str = try self.parseStringExpr("`", false);

                if (try self.expect(.backtick)) |tok| {
                    try self.span_registry.put(.string, tok.span); // here too
                }

                return .{ .process = str };
            },

            .ident => {
                const ident_start = self.currentPos();
                const identName = self.advance();

                if (self.eat(.colon_eq)) |_| {
                    const value_start = self.currentPos();
                    const value = try self.parseExpr();

                    const id = try self.span_registry.putNode(
                        self.spanFrom(ident_start),
                        identName.span,
                        self.spanFrom(value_start),
                        null,
                    );

                    return .{
                        .decl = .{
                            .id = id,
                            .name = identName.lexeme,
                            .value = value,
                        },
                    };
                } else { // must be task call
                    const call_start = ident_start;
                    var scope: ast.TaskCallScope = .closest;

                    var group_scope_span: ?Span = null;

                    var task = identName;

                    if (self.eat(.dcolon)) |_| {
                        const group = task;
                        task = try self.expect(.ident);

                        group_scope_span = group.span;
                        scope = .{ .group = group.lexeme };
                    }

                    const args = try self.parseTaskCallArgs();

                    const id = try self.span_registry.putNode(
                        self.spanFrom(call_start),
                        task.span,
                        null,
                        group_scope_span,
                    );

                    return .{
                        .task_call = .{
                            .id = id,
                            .task = task.lexeme,
                            .scope = scope,
                            .args = args,
                        },
                    };
                }
            },
            // ::task => root task call
            .dcolon => {
                const start = self.currentPos();
                _ = self.advance();
                const identName = try self.expect(.ident);

                const args = try self.parseTaskCallArgs();

                const id = try self.span_registry.putNode(
                    self.spanFrom(start),
                    identName.span,
                    null,
                    null,
                );
                return .{
                    .task_call = .{
                        .id = id,
                        .task = identName.lexeme,
                        .scope = .root,
                        .args = args,
                    },
                };
            },
            .if_kw => {
                _ = self.advance();

                const cond, const cond_span = blk: {
                    const cond_start = self.currentPos();
                    const cond = try self.parseExpr();
                    break :blk .{ cond, self.spanFrom(cond_start) };
                };
                var then: []ast.Statement = undefined;
                var else_: ?[]ast.Statement = null;

                if (self.eat(.lbrace)) |_| {
                    then = try self.parseStatements();
                } else {
                    then = blk: {
                        var arr = try self.arena.allocator().alloc(ast.Statement, 1);
                        arr[0] = try self.parseOneStatement();
                        break :blk arr;
                    };
                }

                if (self.eat(.else_kw)) |_| {
                    if (self.eat(.lbrace)) |_| {
                        else_ = try self.parseStatements();
                    } else {
                        else_ = blk: {
                            var arr = try self.arena.allocator().alloc(ast.Statement, 1);
                            arr[0] = try self.parseOneStatement();
                            break :blk arr;
                        };
                    }
                }

                const id = try self.span_registry.putNode(cond_span, null, null, null);

                return .{
                    .if_stmt = .{
                        .id = id,
                        .cond = cond,
                        .then = then,
                        .else_ = else_,
                    },
                };
            },
            else => {
                try self.addDiagnostic(.err, "unexpected token: {s}", .{@tagName(self.next.kind)});
                return error.UnexpectedToken;
            },
        }
    }

    fn parseTaskCallArgs(self: *Parser) ![]ast.TaskCallArg {
        var args = try std.ArrayList(ast.TaskCallArg).initCapacity(self.arena.allocator(), 1);

        _ = try self.expect(.lparen);

        while (self.eat(.rparen) == null) {
            const arg_start = self.currentPos();

            var arg_name: ?Token = null;

            var value: ast.Expr = undefined;
            var value_span: ?Span = null;

            if (self.eat(.ident)) |tok| {
                if (self.eat(.colon)) |_| {
                    arg_name = tok;
                    const value_start = self.currentPos();
                    value = try self.parseExpr();
                    value_span = self.spanFrom(value_start);
                } else {
                    _ = try self.retreat();
                    const value_start = self.currentPos();
                    value = try self.parseExpr();
                    value_span = self.spanFrom(value_start);
                }
            } else {
                const value_start = self.currentPos();
                value = try self.parseExpr();
                value_span = self.spanFrom(value_start);
            }

            const id = self.span_registry.putNode(
                self.spanFrom(arg_start),
                if (arg_name) |v| v.span else null,
                value_span,
                null,
            );

            try args.append(self.arena.allocator(), .{
                .id = id,
                .name = if (arg_name) |v| v.lexeme else null,
                .value = value,
            });

            if (self.peek() != .rparen) {
                _ = try self.expect(.comma);
            }
        }

        return try args.toOwnedSlice(self.arena.allocator());
    }

    fn parseArguments(self: *Parser) ![]ast.Argument {
        var arguments = try std.ArrayList(ast.Argument).initCapacity(self.arena.allocator(), 1);

        while (self.eat(.rparen) == null) {
            const arg_start = self.currentPos();
            const attrs = try self.collectAttributes();

            const name = try self.expect(.ident);

            _ = try self.expect(.colon);

            const arg_type, const arg_span = blk: {
                const start = self.currentPos();
                const out = try self.parseArgType();

                break :blk .{ out, self.spanFrom(start) };
            };

            var default: ?ast.Expr = null;
            var default_span: ?Span = null;

            if (self.eat(.eq) != null) {
                const default_start = self.currentPos();
                default = try self.parseExpr();
                default_span = self.spanFrom(default_start);
            }
            const id = try self.span_registry.putNode(
                self.spanFrom(arg_start),
                name.span,
                default_span,
                arg_span,
            );
            try arguments.append(self.arena.allocator(), .{
                .id = id,
                .name = name.lexeme,
                .attrs = attrs,
                .type = arg_type,
                .default = default,
            });

            //TODO: comma is kinda not needed to parse this so just make it optional for now
            _ = self.eat(.comma);
        }

        return try arguments.toOwnedSlice(self.arena.allocator());
    }
    fn parseSet(self: *Parser, attributes: []ast.Attribute, start: u32) !ast.Set {
        var decls: std.ArrayList(ast.Set.SetDecl) = .empty;

        if (self.eat(.lbrace)) |_| { // block
            while (self.eat(.rbrace) == null) {
                const decl = try self.parseSetDecl();
                try decls.append(self.arena.allocator(), decl);
            }
        } else {
            try decls.append(self.arena.allocator(), try self.parseSetDecl());
        }

        const id = try self.span_registry.putNode(
            self.spanFrom(start),
            null,
            null,
            null,
        );

        return .{
            .id = id,
            .attrs = attributes,
            .body = try decls.toOwnedSlice(self.arena.allocator()),
        };
    }

    fn parseSetDecl(self: *Parser) !ast.Set.SetDecl {
        const start = self.currentPos();

        const ident = try self.expect(.ident);
        var value: ?ast.MetaValue = null;
        var value_span: ?Span = null;

        if (self.eat(.eq)) |_| {
            const value_start = self.currentPos();
            value = try self.parseMetaValue();
            value_span = self.spanFrom(value_start);
        }

        const id = try self.span_registry.putNode(
            self.spanFrom(start),
            ident.span,
            value_span,
            null,
        );

        return .{
            .id = id,
            .name = ident.lexeme,
            .value = value,
        };
    }

    fn parseArgType(self: *Parser) !ast.ArgType {
        const list = blk: {
            // TODO: handle brackets span
            if (self.eat(.lbracket)) |_| {
                _ = try self.expect(.rbracket);
                break :blk true;
            }
            break :blk false;
        };

        const tok = self.advance();

        switch (tok.kind) {
            .string_type => return if (list) .list_string else .string,
            .number_type => return if (list) .list_number else .number,
            .flag_type => {
                if (list) {
                    try self.addDiagnostic(
                        .err,
                        "invalid type for list argument, only string and number can be accepted as list",
                        .{},
                    );
                    return ParseError.UnexpectedToken;
                }
                return .flag;
            },
            else => {
                try self.addDiagnostic(.err, "Invalid token: {s}", .{@tagName(tok.kind)});
                return ParseError.UnexpectedToken;
            },
        }
    }

    fn parseBuiltInCall(self: *Parser) ParseError!ast.Expr {
        const start = self.currentPos();
        _ = self.advance(); // skip @

        const ident = try self.expect(.ident);

        _ = try self.expect(.lparen);

        var args = try std.ArrayList(ast.Expr).initCapacity(self.arena.allocator(), 1);

        // FIX: previously the loop unconditionally tried to parse an expression,
        // making @foo() (empty args) a parse error. Now we check for ) first.
        if (self.eat(.rparen) == null) {
            while (true) {
                const expr = try self.parseExpr();
                try args.append(self.arena.allocator(), expr);
                if (self.eat(.comma) == null) break;
            }
            _ = try self.expect(.rparen);
        }

        const id = try self.span_registry.putNode(
            self.spanFrom(start),
            ident.span,
            null,
            null,
        );

        return ast.Expr{
            .builtin_call = .{
                .id = id,
                .name = ident.lexeme,
                .args = try args.toOwnedSlice(self.arena.allocator()),
            },
        };
    }

    fn parseIfExpr(self: *Parser) ParseError!ast.Expr {
        const start = self.currentPos();

        _ = self.advance(); // consume 'if'

        _ = try self.expect(.lparen);

        const cond = try self.parseExpr();

        _ = try self.expect(.rparen);
        const then = try self.parseExpr();

        _ = try self.expect(.else_kw);

        const else_ = try self.parseExpr();

        const node = try self.arena.allocator().create(ast.IfExpr);
        node.* = .{
            .cond = cond,
            .then = then,
            .else_ = else_,
            .span = self.spanFrom(start),
        };
        return ast.Expr{ .if_expr = node };
    }

    fn parseExpr(self: *Parser) ParseError!ast.Expr {
        return try self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseAnd();

        while (self.eat(.or_kw) != null) {
            const right = try self.parseAnd();
            const node = try self.arena.allocator().create(ast.BinaryExpr);
            node.* = .{ .op = .or_op, .left = left, .right = right, .span = self.spanFrom(left.spanStart()) };
            left = .{ .binary = node };
        }

        return left;
    }

    fn parseAnd(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseNot();

        while (self.eat(.and_kw) != null) {
            const right = try self.parseNot();
            const node = try self.arena.allocator().create(ast.BinaryExpr);
            node.* = .{ .op = .and_op, .left = left, .right = right, .span = self.spanFrom(left.spanStart()) };
            left = .{ .binary = node };
        }

        return left;
    }

    fn parseNot(self: *Parser) ParseError!ast.Expr {
        const start = self.currentPos();
        if (self.eat(.not_kw) != null) {
            const operand = try self.parseNot();
            const node = try self.arena.allocator().create(ast.UnaryExpr);
            node.* = .{ .op = .not_op, .operand = operand, .span = self.spanFrom(start) };
            return .{ .unary = node };
        }

        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) ParseError!ast.Expr {
        const left = try self.parseAddSub();

        const op: ast.BinaryOp = switch (self.peek()) {
            .eq_eq => .eq,
            .bang_eq => .neq,
            .lt => .lt,
            .gt => .gt,
            .lt_eq => .lt_eq,
            .gt_eq => .gt_eq,
            else => return left,
        };

        _ = self.advance();
        const right = try self.parseAddSub();
        const node = try self.arena.allocator().create(ast.BinaryExpr);
        node.* = .{ .op = op, .left = left, .right = right, .span = self.spanFrom(left.spanStart()) };
        return .{ .binary = node };
    }

    fn parseAddSub(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseMulDiv();

        while (true) {
            const op: ast.BinaryOp = switch (self.peek()) {
                .plus => .add,
                .minus => .sub,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseMulDiv();
            const node = try self.arena.allocator().create(ast.BinaryExpr);
            node.* = .{ .op = op, .left = left, .right = right, .span = self.spanFrom(left.spanStart()) };
            left = .{ .binary = node };
        }

        return left;
    }

    fn parseMulDiv(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseUnary();
        while (true) {
            const op: ast.BinaryOp = switch (self.peek()) {
                .star => .mul,
                .slash => .div,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseUnary();
            const node = try self.arena.allocator().create(ast.BinaryExpr);
            node.* = .{ .op = op, .left = left, .right = right, .span = self.spanFrom(left.spanStart()) };
            left = .{ .binary = node };
        }

        return left;
    }

    fn parseUnary(self: *Parser) ParseError!ast.Expr {
        const start = self.currentPos();
        if (self.eat(.minus) != null) {
            const operand = try self.parseUnary();
            const node = try self.arena.allocator().create(ast.UnaryExpr);
            node.* = .{ .op = .negate, .operand = operand, .span = self.spanFrom(start) };
            return .{ .unary = node };
        }

        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) ParseError!ast.Expr {
        //TODO: ensure that every span handled correctly
        switch (self.peek()) {
            .number => {
                const tok = self.advance();
                const val = std.fmt.parseFloat(f64, tok.lexeme) catch {
                    try self.addDiagnostic(.err, "invalid float literal", .{});
                    return ParseError.UnexpectedToken;
                };

                return .{
                    .number_lit = .{
                        .span = self.spanFrom(tok.span.start),
                        .value = val,
                    },
                };
            },
            .lbracket => { // list
                const start = self.currentPos();
                _ = self.advance();

                var items: std.ArrayList(ast.Expr) = .empty;
                errdefer items.deinit(self.arena.allocator());

                while (self.eat(.rbracket) == null) {
                    try items.append(self.arena.allocator(), try self.parseExpr());

                    if (self.eat(.comma) == null) {
                        _ = try self.expect(.rbracket);
                        break;
                    }
                }

                return .{
                    .list = .{
                        .span = self.spanFrom(start),
                        .value = try items.toOwnedSlice(self.arena.allocator()),
                    },
                };
            },
            .apostrophe => {
                const start = self.currentPos();
                const ch = try self.readCharacter();
                _ = try self.expect(.apostrophe);

                const result = text.processChar(self.arena.allocator(), ch.lexeme) catch unreachable;

                return .{
                    .char_lit = .{
                        .span = self.spanFrom(start),
                        .value = result,
                    },
                };
            },
            .quote => {
                const start = self.currentPos();

                const string = try self.parseStringExpr("\"", false);
                _ = try self.expect(.quote);
                return .{
                    .string = .{
                        .span = self.spanFrom(start),
                        .value = string,
                    },
                };
            },
            .true_kw => {
                const tok = self.expect(.true_kw) catch unreachable;
                return ast.Expr{
                    .bool_lit = .{
                        .span = tok.span,
                        .value = true,
                    },
                };
            },
            .false_kw => {
                const tok = self.expect(.false_kw) catch unreachable;
                return ast.Expr{
                    .bool_lit = .{
                        .span = tok.span,
                        .value = false,
                    },
                };
            },
            .ident => {
                const tok = self.expect(.ident) catch unreachable;
                return ast.Expr{
                    .ident = tok.sliceWithSpan(),
                };
            },
            .lparen => {
                _ = self.expect(.lparen) catch unreachable;
                const expr = try self.parseExpr();
                _ = try self.expect(.rparen);
                return expr;
            },
            .if_kw => return try self.parseIfExpr(),
            .at => return try self.parseBuiltInCall(),
            else => {
                try self.addDiagnostic(
                    .err,
                    "expected expression, found '{s}'",
                    .{@tagName(self.peek())},
                );
                return ParseError.UnexpectedToken;
            },
        }
    }

    fn parseStringExpr(self: *Parser, terminator: []const u8, comptime multiline: bool) !ast.StringExpr {
        var out: std.ArrayList(ast.InterStringSeg) = .empty;
        var lexer = self.lexer.stringLexer();

        while (true) {
            const seg = lexer.lexString(&.{ terminator, "{{" }, multiline);

            switch (seg.kind) {
                .string => {
                    try self.span_registry.put(.string, seg.span);
                    try out.append(self.arena.allocator(), .{
                        .lit = seg.lexeme,
                    });
                },
                .unterminated_string => {
                    try self.addDiagnostic(.err, "unterminated string", .{});
                    return ParseError.UnexpectedToken;
                },
                else => {
                    try self.addDiagnostic(.err, "expected character, interpolation or '{s}'", .{terminator});
                    return ParseError.UnexpectedToken;
                },
            }

            self.resyncFromRaw();
            if (self.eat(.ldbrace)) |_| { //TODO: handle ld/rd brace span
                const expr = try self.parseExpr();
                try out.append(self.arena.allocator(), .{ .expr = expr });
                _ = try self.expect(.rdbrace);
                self.resyncToRaw();
            } else {
                break;
            }
        }

        // TODO: handle if just string lit

        if (out.items.len == 1) {
            std.debug.assert(out.items[0] == .lit);
            defer out.deinit(self.arena.allocator());

            return .{ .lit = out.items[0].lit };
        }

        return .{ .inter = try out.toOwnedSlice(self.arena.allocator()) };
    }

    fn parseMetaValue(self: *Parser) ParseError!ast.MetaValue {
        switch (self.peek()) {
            .null_kw => {
                _ = self.expect(.null_kw) catch unreachable;
                return .null;
            },
            .true_kw => {
                _ = self.expect(.true_kw) catch unreachable;
                return .{
                    .bool = true,
                };
            },
            .false_kw => {
                _ = self.expect(.false_kw) catch unreachable;
                return .{
                    .bool = false,
                };
            },
            .number => {
                const tok = self.advance();
                const val = std.fmt.parseFloat(f64, tok.lexeme) catch {
                    try self.addDiagnostic(.err, "invalid number literal", .{});
                    return ParseError.UnexpectedToken;
                };
                return .{ .number = val };
            },
            .apostrophe => {
                const ch = try self.readCharacter();
                _ = try self.expect(.apostrophe);
                return .{
                    .char = ch.lexeme[0],
                };
            },
            .quote => {
                const string = try self.readString("\"", false);
                _ = try self.expect(.quote);
                return .{
                    .string = string.lexeme,
                };
            },
            .lbracket => {
                _ = self.expect(.lbracket) catch unreachable;

                var items: std.ArrayList(ast.MetaValue) = .empty;
                errdefer items.deinit(self.arena.allocator());

                while (self.eat(.rbracket) == null) {
                    try items.append(self.arena.allocator(), try self.parseMetaValue());

                    if (self.eat(.comma) == null) {
                        _ = try self.expect(.rbracket);
                        break;
                    }
                }

                if (items.items.len == 0) {
                    try self.addDiagnostic(.err, "list cannot be empty", .{});
                    return ParseError.UnexpectedToken; //TODO: consider if its sensible
                }

                return .{
                    .list = try items.toOwnedSlice(self.arena.allocator()),
                };
            },
            else => {
                try self.addDiagnostic(.err, "expected meta literal, found '{s}'", .{@tagName(self.peek())});
                return ParseError.UnexpectedToken;
            },
        }
    }

    //============== private helpers ===================

    inline fn currentPos(self: *Parser) u32 {
        return self.next.span.start;
    }
};
