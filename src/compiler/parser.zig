const ast = @import("ast.zig");
const std = @import("std");

const lex = @import("lexer.zig");
const Lexer = lex.Lexer;

const text = @import("text.zig");

const token = @import("token.zig");
const Token = token.Token;
const TokenKind = token.TokenKind;

const Diagnostics = @import("Diagnostics.zig");

const lib = @import("lib");

const Span = @import("span.zig");
const SpanId = Span.Registry.NodeId;
const Wrapped = Span.Registry.Wrapped;

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

    pub fn init(
        arena: *std.heap.ArenaAllocator,
        lexer: *Lexer,
        span_registry: *Span.Registry,
        diagnostics: *Diagnostics,
    ) !Parser {
        const first = try lexer.next();

        return .{
            .arena = arena,
            .lexer = lexer,
            .diagnostics = diagnostics,
            .span_registry = span_registry,
            .current = null,
            .next = first,
        };
    }

    fn create(self: *Parser, comptime T: type, value: T) !*T {
        const ptr = try self.arena.allocator().create(T);
        ptr.* = value;
        return ptr;
    }

    /// Shared builder for every binary-expr precedence level.
    fn makeBinary(
        self: *Parser,
        start: u32,
        op: ast.BinaryOp,
        left: Wrapped(ast.Expr),
        right: Wrapped(ast.Expr),
    ) ParseError!Wrapped(ast.Expr) {
        const node = try self.arena.allocator().create(ast.BinaryExpr);
        node.* = .{ .op = op, .left = left.payload, .right = right.payload };

        const id = try self.span_registry.addNode(
            self.spanFrom(start),
            .{ .expr = .{
                .binary = .{
                    .left = left.id,
                    .right = right.id,
                },
            } },
        );

        return .wrap(id, .{ .binary = node });
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

    fn advance(self: *Parser) !Token {
        const tok = try self.lexer.next();
        return self.setNextFetchCurrent(tok);
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        if (self.next.kind == kind) return self.advance();

        try self.addDiagnostic(
            .err,
            "expected '{s}', found {s}",
            .{ @tagName(kind), @tagName(self.next.kind) },
        );

        return ParseError.UnexpectedToken;
    }

    fn eat(self: *Parser, kind: TokenKind) !?Token {
        if (self.next.kind == kind) return try self.advance();
        return null;
    }

    fn resyncFromRaw(self: *Parser) !void {
        self.next = try self.lexer.next();
    }

    fn resyncToRaw(self: *Parser) void {
        if (self.current) |curr|
            self.lexer.pos = curr.span.end();
    }

    fn readCharacter(self: *Parser) ParseError!Token {
        var lexer = self.lexer.stringLexer();
        const tok = try lexer.lexCharacter();
        if (tok.kind != .char) {
            try self.addDiagnostic(.err, "expected char, found '{s}'", .{@tagName(tok.kind)});
            return ParseError.UnexpectedToken;
        }

        try self.resyncFromRaw();
        return tok;
    }

    fn readString(self: *Parser, terminator: []const u8, comptime multiline: bool) ParseError!Token {
        var lexer = self.lexer.stringLexer();
        const tok = try lexer.lexString(&.{terminator}, multiline);

        if (tok.kind != .string) {
            try self.addDiagnostic(.err, "expected string, found '{s}'", .{@tagName(tok.kind)});
            return ParseError.UnexpectedToken;
        }

        try self.resyncFromRaw();
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

    fn synchronize(self: *Parser) !TokenKind {
        return try self.synchronizeTo(&.{
            .task_kw, .group_kw, .set_kw, .rbrace, .eof,
        });
    }

    fn synchronizeTo(self: *Parser, comptime tts: []const TokenKind) !TokenKind {
        const to_map = comptime std.enums.EnumSet(TokenKind).initMany(tts);

        while (true) {
            const tk = self.peek();
            if (to_map.contains(tk)) {
                return tk;
            }

            _ = try self.advance();
        }
    }

    pub fn parseFile(self: *Parser) ParseError!ast.File {
        const start = self.currentPos();

        var options = try std.ArrayList(ast.Set).initCapacity(self.arena.allocator(), 1);
        var decls = try std.ArrayList(ast.Decl).initCapacity(self.arena.allocator(), 1);
        var groups = try std.ArrayList(ast.Group).initCapacity(self.arena.allocator(), 8);
        var tasks = try std.ArrayList(ast.Task).initCapacity(self.arena.allocator(), 5);

        while (self.peek() != .eof) {
            const attrs = try self.collectAttributes();
            const tok_start = self.currentPos();
            const tok = try self.advance();

            switch (tok.kind) {
                .set_kw => {
                    const set = try self.parseSet(attrs, tok_start);
                    try options.append(self.arena.allocator(), set);
                },
                .ident => {
                    if (attrs.len != 0) {
                        try self.addDiagnostic(.err, "unexpected attributes before declaration", .{});
                    }

                    _ = self.expect(.colon_eq) catch |err| switch (err) {
                        ParseError.UnexpectedToken => {
                            _ = try self.synchronize();
                            continue;
                        },
                        else => return err,
                    };

                    const value = try self.parseExpr();

                    const id = try self.span_registry.addNode(
                        self.spanFrom(tok_start),
                        .{ .decl = .{ .name = tok.span, .value = value.id } },
                    );

                    const decl = ast.Decl{
                        .id = id,
                        .name = tok.lexeme,
                        .value = value.payload,
                    };

                    try decls.append(self.arena.allocator(), decl);
                },
                .group_kw => {
                    const group = self.parseGroup(attrs, tok_start) catch |err| switch (err) {
                        ParseError.UnexpectedToken => {
                            _ = try self.synchronize();
                            continue;
                        },
                        else => return err,
                    };
                    try groups.append(self.arena.allocator(), group);
                },
                .task_kw => {
                    const task = self.parseTask(attrs, tok_start) catch |err| switch (err) {
                        ParseError.UnexpectedToken => {
                            _ = try self.synchronize();
                            continue;
                        },
                        else => return err,
                    };
                    try tasks.append(self.arena.allocator(), task);
                    continue;
                },
                else => |invalid_token| {
                    try self.addDiagnostic(.err, "Unexpected token: '{s}'", .{@tagName(invalid_token)});
                    // synchronize
                    _ = try self.synchronize();
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

    fn collectAttributes(self: *Parser) ParseError![]ast.Attribute {
        var attributes = try std.ArrayList(ast.Attribute).initCapacity(self.arena.allocator(), 1);

        while (try self.eat(.lbracket) != null) {
            const attr = try self.parseAttribute();
            try attributes.appendSlice(self.arena.allocator(), attr);
        }

        return try attributes.toOwnedSlice(self.arena.allocator());
    }

    fn parseAttribute(self: *Parser) ParseError![]ast.Attribute {
        var attrs = try std.ArrayList(ast.Attribute).initCapacity(self.arena.allocator(), 1);

        while (true) {
            const attr_start = self.currentPos();
            const name = self.expect(.ident) catch |err| switch (err) {
                ParseError.UnexpectedToken => {
                    switch (try self.synchronizeTo(&.{ .comma, .rbracket, .eof })) {
                        .comma => {
                            // skip lbracket and start over
                            _ = try self.advance();
                            continue;
                        },
                        else => break,
                    }
                },
                else => return err,
            };

            var value: ?ast.MetaValue = null;
            var value_id: ?SpanId = null;

            if (try self.eat(.colon)) |_| {
                const wrapped = self.parseMetaValue() catch |err| switch (err) {
                    ParseError.UnexpectedToken => {
                        switch (try self.synchronizeTo(&.{ .comma, .rbracket, .eof })) {
                            .comma => {
                                // skip lbracket and start over
                                _ = try self.advance();
                                continue;
                            },
                            else => break,
                        }
                    },
                    else => return err,
                };
                value = wrapped.payload;
                value_id = wrapped.id;
            }

            const id = try self.span_registry.addNode(
                self.spanFrom(attr_start),
                .{ .attribute = .{ .name = name.span, .value = value_id } },
            );

            try attrs.append(
                self.arena.allocator(),
                .{
                    .id = id,
                    .name = name.lexeme,
                    .value = value,
                },
            );

            if (try self.eat(.comma) == null) {
                break;
            }
        }

        _ = try self.expect(.rbracket);

        return attrs.toOwnedSlice(self.arena.allocator());
    }

    fn parseGroup(self: *Parser, attrs: []ast.Attribute, start: u32) ParseError!ast.Group {
        const name = try self.eat(.ident);

        var arguments: []ast.Argument = &.{};
        var args_span: ?Span = null;

        if (try self.eat(.lparen)) |lp| {
            arguments = try self.parseArguments();
            args_span = self.spanFrom(lp.span.start);
        }

        _ = try self.expect(.lbrace);

        var decls = try std.ArrayList(ast.Decl).initCapacity(self.arena.allocator(), 5);
        var tasks = try std.ArrayList(ast.Task).initCapacity(self.arena.allocator(), 1);

        const body_start = self.currentPos();

        while (try self.eat(.rbrace) == null) {
            const temp_attrs = try self.collectAttributes();
            const tok_start = self.currentPos();
            const tok = try self.advance();

            switch (tok.kind) {
                .ident => {
                    if (temp_attrs.len != 0) {
                        try self.addDiagnostic(.err, "unexpected attributes before declaration", .{});
                    }

                    _ = try self.expect(.colon_eq);
                    //TODO: skip declaration if expression is invalid instead of poison
                    const value = try self.parseExpr();

                    const id = try self.span_registry.addNode(
                        self.spanFrom(tok_start),
                        .{ .decl = .{ .name = tok.span, .value = value.id } },
                    );

                    const decl = ast.Decl{
                        .id = id,
                        .name = tok.lexeme,
                        .value = value.payload,
                    };

                    try decls.append(self.arena.allocator(), decl);
                    continue;
                },
                .task_kw => {
                    const task = try self.parseTask(temp_attrs, tok.span.start);
                    try tasks.append(self.arena.allocator(), task);
                    continue;
                },
                else => {
                    try self.addDiagnostic(.err, "Unexpected token: {s}.", .{@tagName(tok.kind)});
                    _ = try self.synchronizeTo(&.{ .task_kw, .rbrace, .eof });
                },
            }
        }

        const body_span = self.spanFrom(body_start);

        const id = try self.span_registry.addNode(
            self.spanFrom(start),
            .{ .group = .{
                .name = if (name) |n| n.span else null,
                .args = args_span,
                .body = body_span,
            } },
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

    fn parseTask(self: *Parser, attrs: []ast.Attribute, start: u32) ParseError!ast.Task {
        const name = try self.expect(.ident);

        var arguments: []ast.Argument = &.{};
        var args_span: ?Span = null;

        if (try self.eat(.lparen) != null) {
            const args_start = self.currentPos();
            arguments = try self.parseArguments();
            args_span = self.spanFrom(args_start);
        }

        _ = try self.expect(.lbrace);

        // FIX: body_start must be captured *after* consuming '{', otherwise
        // the registered body span (and the .wrap node below) includes the
        // brace itself -- inconsistent with parseGroup/parseSet, which both
        // capture body_start post-brace.
        const body_start = self.currentPos();

        const body: Wrapped([]ast.Statement) = blk: {
            if (ast.hasAttr(attrs, "script")) {
                self.resyncToRaw();
                const script_start = self.currentPos();

                const process = try self.parseStringExpr("}", true);

                _ = try self.expect(.rbrace);

                const process_stmts = try self.arena.allocator().alloc(ast.Statement, 1);
                process_stmts[0] = .{ .process = process.payload };

                // whole body as string, for highlighting purposes
                try self.span_registry.put(.string, self.spanFrom(script_start));

                break :blk .wrap(process.id, process_stmts);
            }

            break :blk try self.parseStatements();
        };

        const body_id = try self.span_registry.addNode(self.spanFrom(body_start), .{ .wrap = body.id });

        const id = try self.span_registry.addNode(
            self.spanFrom(start),
            .{ .task = .{
                .name = name.span,
                .args = args_span,
                .body = body_id,
            } },
        );

        return .{
            .id = id,
            .name = name.lexeme,
            .attrs = attrs,
            .args = arguments,
            .body = body.payload,
        };
    }

    fn parseStatements(self: *Parser) ParseError!Wrapped([]ast.Statement) {
        var stmts = try std.ArrayList(ast.Statement).initCapacity(self.arena.allocator(), 1);

        const start = self.currentPos();
        var child_ids = try self.span_registry.getArrayList(SpanId, 1);
        errdefer child_ids.deinit();

        while (try self.eat(.rbrace) == null) {
            const wrapped = self.parseOneStatement() catch |err| switch (err) {
                ParseError.UnexpectedToken => {
                    switch (try self.synchronizeTo(&.{ .backtick, .ident, .dcolon, .if_kw, .rbrace, .eof })) {
                        .rbrace => {
                            _ = try self.advance();
                            break;
                        },
                        .eof => break,
                        else => continue,
                    }
                },
                else => return err,
            };
            try child_ids.append(wrapped.id);
            try stmts.append(self.arena.allocator(), wrapped.payload);
        }

        const id = try self.span_registry.addNode(
            self.spanFrom(start),
            .{ .block = .{ .stmts = try child_ids.toOwnedSlice() } },
        );

        return .wrap(id, try stmts.toOwnedSlice(self.arena.allocator()));
    }

    fn parseOneStatement(self: *Parser) ParseError!Wrapped(ast.Statement) {
        switch (self.peek()) {
            .backtick => {
                try self.span_registry.put(.string, self.next.span); // opening backtick highlight

                const string = try self.parseStringExpr("`", false);

                const backtick = try self.expect(.backtick);
                try self.span_registry.put(.string, backtick.span); // closing backtick highlight

                return .wrap(string.id, .{ .process = string.payload });
            },
            .ident => {
                const start = self.currentPos();
                const ident_tok = try self.advance();

                if (try self.eat(.colon_eq)) |_| {
                    const value = try self.parseExpr();

                    const id = try self.span_registry.addNode(
                        self.spanFrom(start),
                        .{ .decl = .{ .name = ident_tok.span, .value = value.id } },
                    );

                    return .wrap(id, .{ .decl = .{
                        .id = id,
                        .name = ident_tok.lexeme,
                        .value = value.payload,
                    } });
                } else { // must be task call
                    var scope: ast.TaskCallScope = .closest;
                    var group_span: ?Span = null;
                    var task = ident_tok;

                    if (try self.eat(.dcolon)) |_| {
                        const group = task;
                        task = try self.expect(.ident);
                        group_span = group.span;
                        scope = .{ .group = group.lexeme };
                    }

                    const args_start = self.currentPos();
                    const args = try self.parseTaskCallArgs();

                    const args_span = self.spanFrom(args_start);
                    const span = self.spanFrom(start);

                    const id = try self.span_registry.addNode(span, .{ .task_call = .{
                        .group = group_span,
                        .task = task.span,
                        .args = args_span,
                    } });

                    return .wrap(id, .{ .task_call = .{
                        .id = id,
                        .task = task.lexeme,
                        .scope = scope,
                        .args = args,
                    } });
                }
            },
            // ::task => root task call
            .dcolon => {
                const start = self.currentPos();
                _ = try self.advance();
                const ident_tok = try self.expect(.ident);

                const args_start = self.currentPos();
                const args = try self.parseTaskCallArgs();

                const args_span = self.spanFrom(args_start);
                const span = self.spanFrom(start);

                const id = try self.span_registry.addNode(span, .{ .task_call = .{
                    .group = null,
                    .task = ident_tok.span,
                    .args = args_span,
                } });

                return .wrap(id, .{
                    .task_call = .{
                        .id = id,
                        .task = ident_tok.lexeme,
                        .scope = .root,
                        .args = args,
                    },
                });
            },
            .if_kw => {
                const if_kw = try self.advance();

                const cond = try self.parseExpr();

                var then: []ast.Statement = undefined;
                var then_id: SpanId = undefined;
                var else_: ?[]ast.Statement = null;
                var else_id: ?SpanId = null;

                if (try self.eat(.lbrace)) |_| {
                    const wrapped = try self.parseStatements();
                    then = wrapped.payload;
                    then_id = wrapped.id;
                } else {
                    const wrapped = try self.parseOneStatement();
                    const arr = try self.arena.allocator().alloc(ast.Statement, 1);
                    arr[0] = wrapped.payload;
                    then = arr;
                    then_id = wrapped.id;
                }

                if (try self.eat(.else_kw)) |_| {
                    if (try self.eat(.lbrace)) |_| {
                        const wrapped = try self.parseStatements();
                        else_ = wrapped.payload;
                        else_id = wrapped.id;
                    } else {
                        const wrapped = try self.parseOneStatement();
                        const arr = try self.arena.allocator().alloc(ast.Statement, 1);
                        arr[0] = wrapped.payload;
                        else_ = arr;
                        else_id = wrapped.id;
                    }
                }

                const span = self.spanFrom(if_kw.span.start);

                const id = try self.span_registry.addNode(span, .{ .if_stmt = .{
                    .cond = cond.id,
                    .then = then_id,
                    .else_ = else_id,
                } });

                return .wrap(id, .{
                    .if_stmt = .{
                        .id = id,
                        .cond = cond.payload,
                        .then = then,
                        .else_ = else_,
                    },
                });
            },
            else => {
                try self.addDiagnostic(.err, "expected statement, found '{s}'", .{@tagName(self.next.kind)});
                return ParseError.UnexpectedToken;
            },
        }
    }

    fn parseTaskCallArgs(self: *Parser) ParseError![]ast.TaskCallArg {
        var args = try std.ArrayList(ast.TaskCallArg).initCapacity(self.arena.allocator(), 1);

        _ = try self.expect(.lparen);

        while (try self.eat(.rparen) == null) {
            const arg_start = self.currentPos();

            var arg_name: ?Token = null;
            var value: ast.Expr = undefined;
            var value_id: SpanId = undefined;

            if (try self.eat(.ident)) |tok| {
                if (try self.eat(.colon)) |_| {
                    arg_name = tok;

                    const wrapped = try self.parseExpr();
                    value = wrapped.payload;
                    value_id = wrapped.id;
                } else {
                    _ = try self.retreat();

                    const wrapped = try self.parseExpr();
                    value = wrapped.payload;
                    value_id = wrapped.id;
                }
            } else {
                const wrapped = try self.parseExpr();
                value = wrapped.payload;
                value_id = wrapped.id;
            }

            const id = try self.span_registry.addNode(
                self.spanFrom(arg_start),
                .{ .task_call_arg = .{
                    .name = if (arg_name) |v| v.span else null,
                    .value = value_id,
                } },
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

    fn parseArguments(self: *Parser) ParseError![]ast.Argument {
        var arguments = try std.ArrayList(ast.Argument).initCapacity(self.arena.allocator(), 1);

        while (try self.eat(.rparen) == null) {
            const arg_start = self.currentPos();
            const attrs = try self.collectAttributes();

            const name = self.expect(.ident) catch |err| switch (err) {
                ParseError.UnexpectedToken => {
                    switch (try self.synchronizeTo(&.{ .comma, .rparen, .lbrace, .eof })) {
                        .comma => {
                            _ = try self.advance();
                            continue;
                        },
                        .rparen => {
                            _ = try self.advance();
                            break;
                        },
                        else => break,
                    }
                },
                else => return err,
            };

            _ = self.expect(.colon) catch |err| switch (err) {
                ParseError.UnexpectedToken => {
                    switch (try self.synchronizeTo(&.{ .comma, .rparen, .lbrace, .eof })) {
                        .comma => {
                            _ = try self.advance();
                            continue;
                        },
                        .rparen => {
                            _ = try self.advance();
                            break;
                        },
                        else => break,
                    }
                },
                else => return err,
            };

            const arg_type = self.parseArgType() catch |err| switch (err) {
                ParseError.UnexpectedToken => {
                    switch (try self.synchronizeTo(&.{ .comma, .rparen, .lbrace, .eof })) {
                        .comma => {
                            _ = try self.advance();
                            continue;
                        },
                        .rparen => {
                            _ = try self.advance();
                            break;
                        },
                        else => break,
                    }
                },
                else => return err,
            };

            var default: ?ast.Expr = null;
            var default_id: ?SpanId = null;

            if (try self.eat(.eq)) |_| blk: {
                const wrapped = self.parseExpr() catch |err| switch (err) {
                    ParseError.UnexpectedToken => {
                        switch (try self.synchronizeTo(&.{ .comma, .rparen, .lbrace, .eof })) {
                            .comma => {
                                _ = try self.advance();
                                break :blk;
                            },
                            .rparen => {
                                _ = try self.advance();
                                break;
                            },
                            else => break,
                        }
                    },
                    else => return err,
                };
                default = wrapped.payload;
                default_id = wrapped.id;
            }

            const id = try self.span_registry.addNode(
                self.spanFrom(arg_start),
                .{ .argument = .{
                    .name = name.span,
                    .type = arg_type.span,
                    .default = default_id,
                } },
            );

            try arguments.append(self.arena.allocator(), .{
                .id = id,
                .name = name.lexeme,
                .attrs = attrs,
                .type = arg_type.value,
                .default = default,
            });

            //TODO: comma is kinda not needed to parse this so just make it optional for now
            _ = try self.eat(.comma);
        }

        return try arguments.toOwnedSlice(self.arena.allocator());
    }

    fn parseSet(self: *Parser, attributes: []ast.Attribute, start: u32) ParseError!ast.Set {
        var decls: std.ArrayList(ast.Set.SetDecl) = .empty;
        errdefer decls.deinit(self.arena.allocator());

        const body_start = self.currentPos();

        if (try self.eat(.lbrace)) |_| { // block
            while (try self.eat(.rbrace) == null) {
                const decl = try self.parseSetDecl();
                try decls.append(self.arena.allocator(), decl);
            }
        } else {
            const decl = try self.parseSetDecl();
            try decls.append(self.arena.allocator(), decl);
        }

        const body_span = self.spanFrom(body_start);

        const id = try self.span_registry.addNode(
            self.spanFrom(start),
            .{ .set = .{ .body = body_span } },
        );

        return .{
            .id = id,
            .attrs = attributes,
            .body = try decls.toOwnedSlice(self.arena.allocator()),
        };
    }

    fn parseSetDecl(self: *Parser) ParseError!ast.Set.SetDecl {
        const start = self.currentPos();

        const name = try self.expect(.ident);

        var value: ?ast.MetaValue = null;
        var value_id: ?SpanId = null;

        if (try self.eat(.eq)) |_| {
            const wrapped = try self.parseMetaValue();
            value = wrapped.payload;
            value_id = wrapped.id;
        }

        const id = try self.span_registry.addNode(
            self.spanFrom(start),
            .{ .set_decl = .{ .name = name.span, .value = value_id } },
        );

        return .{
            .id = id,
            .name = name.lexeme,
            .value = value,
        };
    }

    /// ArgType doesn't need its own registry entry -- `argument.type` in the
    /// registry stores the whole type span directly, so this just hands
    /// back the span alongside the parsed value.
    fn parseArgType(self: *Parser) ParseError!struct { span: Span, value: ast.ArgType } {
        const start = self.currentPos();

        const list_op_span: ?Span = blk: {
            // TODO: handle brackets span separately if ever needed
            if (try self.eat(.lbracket)) |lb| {
                _ = try self.expect(.rbracket);
                break :blk self.spanFrom(lb.span.start);
            }
            break :blk null;
        };

        const tok = try self.advance();

        const result: ast.ArgType = switch (tok.kind) {
            .string_type => if (list_op_span != null) .list_string else .string,
            .number_type => if (list_op_span != null) .list_number else .number,
            .flag_type => blk: {
                if (list_op_span != null) {
                    try self.addDiagnostic(
                        .err,
                        "invalid type for list argument, only string and number can be accepted as list",
                        .{},
                    );
                    return ParseError.UnexpectedToken;
                }
                break :blk .flag;
            },
            else => {
                try self.addDiagnostic(.err, "Invalid token: {s}", .{@tagName(tok.kind)});
                return ParseError.UnexpectedToken;
            },
        };

        return .{ .span = self.spanFrom(start), .value = result };
    }

    fn parseExpr(self: *Parser) ParseError!Wrapped(ast.Expr) {
        return try self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!Wrapped(ast.Expr) {
        const start = self.currentPos();
        const left = try self.parseAnd();

        if (try self.eat(.or_kw) == null) return left;

        const right = try self.parseAnd();
        return self.makeBinary(start, .or_op, left, right);
    }

    fn parseAnd(self: *Parser) ParseError!Wrapped(ast.Expr) {
        const start = self.currentPos();
        const left = try self.parseNot();

        if (try self.eat(.and_kw) == null) return left;

        const right = try self.parseNot();
        return self.makeBinary(start, .and_op, left, right);
    }

    fn parseNot(self: *Parser) ParseError!Wrapped(ast.Expr) {
        if (try self.eat(.not_kw)) |_| {
            const start = self.currentPos();
            const operand = try self.parseNot();

            const node = try self.arena.allocator().create(ast.UnaryExpr);
            node.* = .{ .op = .not_op, .operand = operand.payload };

            const id = try self.span_registry.addNode(
                self.spanFrom(start),
                .{ .expr = .{
                    .unary = .{
                        .operand = operand.id,
                    },
                } },
            );

            return .wrap(id, .{ .unary = node });
        }

        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) ParseError!Wrapped(ast.Expr) {
        const start = self.currentPos();
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
        _ = try self.advance();

        const right = try self.parseAddSub();
        return self.makeBinary(start, op, left, right);
    }

    fn parseAddSub(self: *Parser) ParseError!Wrapped(ast.Expr) {
        const start = self.currentPos();
        const left = try self.parseMulDiv();

        const op: ast.BinaryOp = switch (self.peek()) {
            .plus => .add,
            .minus => .sub,
            else => return left,
        };
        _ = try self.advance();

        const right = try self.parseMulDiv();
        return self.makeBinary(start, op, left, right);
    }

    fn parseMulDiv(self: *Parser) ParseError!Wrapped(ast.Expr) {
        const start = self.currentPos();
        const left = try self.parseUnary();

        const op: ast.BinaryOp = switch (self.peek()) {
            .star => .mul,
            .slash => .div,
            else => return left,
        };
        _ = try self.advance();

        const right = try self.parseUnary();
        return self.makeBinary(start, op, left, right);
    }

    fn parseUnary(self: *Parser) ParseError!Wrapped(ast.Expr) {
        if (try self.eat(.minus)) |_| {
            const start = self.currentPos();
            const operand = try self.parseUnary();

            const node = try self.arena.allocator().create(ast.UnaryExpr);
            node.* = .{ .op = .negate, .operand = operand.payload };

            const id = try self.span_registry.addNode(
                self.spanFrom(start),
                .{
                    .expr = .{
                        .unary = .{
                            .operand = operand.id,
                        },
                    },
                },
            );

            return .wrap(id, .{ .unary = node });
        }

        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) ParseError!Wrapped(ast.Expr) {
        switch (self.peek()) {
            .true_kw => {
                const tok = self.expect(.true_kw) catch unreachable;
                const id = try self.span_registry.addNode(tok.span, .leaf);
                return .wrap(id, .{ .bool_lit = true });
            },
            .false_kw => {
                const tok = self.expect(.false_kw) catch unreachable;
                const id = try self.span_registry.addNode(tok.span, .leaf);
                return .wrap(id, .{ .bool_lit = false });
            },
            .ident => {
                const tok = self.expect(.ident) catch unreachable;
                const id = try self.span_registry.addNode(tok.span, .leaf);
                return .wrap(id, .{ .ident = tok.lexeme });
            },
            .number => {
                const tok = self.expect(.number) catch unreachable;
                const val = std.fmt.parseFloat(f64, tok.lexeme) catch unreachable; // should be validated by lexer

                const id = try self.span_registry.addNode(tok.span, .leaf);
                return .wrap(id, .{ .number_lit = val });
            },
            .lbracket => { // list
                const start = self.currentPos();
                _ = self.expect(.lbracket) catch unreachable;

                var items: std.ArrayList(ast.Expr) = .empty;
                errdefer items.deinit(self.arena.allocator());

                var child_ids = try self.span_registry.getArrayList(SpanId, 2);
                errdefer child_ids.deinit();

                while (try self.eat(.rbracket) == null) {
                    const wrapped = try self.parseExpr();
                    try child_ids.append(wrapped.id);
                    try items.append(self.arena.allocator(), wrapped.payload);

                    if (try self.eat(.comma) == null) {
                        _ = try self.expect(.rbracket);
                        break;
                    }
                }

                const id = try self.span_registry.addNode(
                    self.spanFrom(start),
                    .{ .expr = .{
                        .list = try child_ids.toOwnedSlice(),
                    } },
                );

                return .wrap(id, .{
                    .list = try items.toOwnedSlice(self.arena.allocator()),
                });
            },
            .apostrophe => {
                const start = self.currentPos();
                const ch = try self.readCharacter();
                _ = try self.expect(.apostrophe);

                const result = text.processChar(self.arena.allocator(), ch.lexeme) catch unreachable;

                const id = try self.span_registry.addNode(self.spanFrom(start), .leaf);
                return .wrap(id, .{ .char_lit = result });
            },
            .quote => {
                // parseStringExpr already registers/returns the correct id --
                // a plain literal reuses its single leaf id, an interpolated
                // one an `.expr` id -- so just forward it.
                const string = try self.parseStringExpr("\"", false);
                _ = try self.expect(.quote);

                return .wrap(string.id, .{ .string = string.payload });
            },
            .lparen => {
                // Parens don't get their own registry entry: the span/id of
                // the enclosed expr is reused as-is.
                _ = self.expect(.lparen) catch unreachable;
                const expr = try self.parseExpr();
                _ = try self.expect(.rparen);

                return .wrap(expr.id, expr.payload);
            },
            .if_kw => {
                const if_expr = try self.parseIfExpr();

                const ptr = try self.arena.allocator().create(ast.IfExpr);
                ptr.* = if_expr.payload;

                return .wrap(if_expr.id, .{ .if_expr = ptr });
            },
            .at => {
                const builtin_call = try self.parseBuiltInCall();
                return .wrap(builtin_call.id, .{ .builtin_call = builtin_call });
            },
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

    fn parseBuiltInCall(self: *Parser) ParseError!ast.BuiltInCall {
        const at = try self.expect(.at); // skip @

        const ident = try self.expect(.ident);

        var args = try std.ArrayList(ast.Expr).initCapacity(self.arena.allocator(), 1);

        var child_ids = try self.span_registry.getArrayList(SpanId, 2);
        errdefer child_ids.deinit();

        _ = try self.expect(.lparen);

        if (try self.eat(.rparen) == null) {
            while (true) {
                const expr = try self.parseExpr();
                try child_ids.append(expr.id);
                try args.append(self.arena.allocator(), expr.payload);
                if (try self.eat(.comma) == null) break;
            }
            _ = try self.expect(.rparen);
        }

        const id = try self.span_registry.addNode(self.spanFrom(at.span.start), .{
            .builtin_call = .{
                .name = ident.span,
                .args = try child_ids.toOwnedSlice(),
            },
        });

        return .{
            .id = id,
            .name = ident.lexeme,
            .args = try args.toOwnedSlice(self.arena.allocator()),
        };
    }

    fn parseIfExpr(self: *Parser) ParseError!Wrapped(ast.IfExpr) {
        const @"if" = try self.advance(); // consume 'if'

        _ = try self.expect(.lparen);

        const cond = try self.parseExpr();

        _ = try self.expect(.rparen);

        const then = try self.parseExpr();

        _ = try self.expect(.else_kw);

        const else_ = try self.parseExpr();

        const id = try self.span_registry.addNode(
            self.spanFrom(@"if".span.start),
            .{ .expr = .{ .if_expr = .{
                .cond = cond.id,
                .then = then.id,
                .else_ = else_.id,
            } } },
        );

        return .wrap(id, .{
            .cond = cond.payload,
            .then = then.payload,
            .else_ = else_.payload,
        });
    }

    fn parseStringExpr(self: *Parser, terminator: []const u8, comptime multiline: bool) ParseError!Wrapped(ast.StringExpr) {
        var out: std.ArrayList(ast.InterStringSeg) = .empty;

        var child_ids = try self.span_registry.getArrayList(SpanId, 1);
        errdefer child_ids.deinit();

        var lexer = self.lexer.stringLexer();
        const start = self.currentPos();

        while (true) {
            const seg = try lexer.lexString(&.{ terminator, "{{" }, multiline);

            switch (seg.kind) {
                .string => {
                    try child_ids.append(try self.span_registry.addNode(seg.span, .leaf));
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

            try self.resyncFromRaw();
            if (try self.eat(.ldbrace)) |_| { //TODO: handle ld/rd brace span
                const expr = blk: {
                    const wrapped = try self.parseExpr();
                    try child_ids.append(wrapped.id);
                    break :blk wrapped.payload;
                };
                try out.append(self.arena.allocator(), .{ .expr = expr });
                _ = try self.expect(.rdbrace);
                self.resyncToRaw();
            } else {
                break;
            }
        }

        // A pure literal (no interpolation) just reuses the single segment's
        // leaf id -- no need to wrap it in another `.expr` node.
        if (out.items.len == 1) {
            std.debug.assert(out.items[0] == .lit);
            defer out.deinit(self.arena.allocator());

            const id = child_ids.items[0];
            child_ids.deinit();

            return .wrap(id, .{ .lit = out.items[0].lit });
        }

        const id = try self.span_registry.addNode(
            self.spanFrom(start),
            .{ .expr = .{
                .list = try child_ids.toOwnedSlice(),
            } },
        );

        return .wrap(
            id,
            .{
                .inter = try out.toOwnedSlice(self.arena.allocator()),
            },
        );
    }

    fn parseMetaValue(self: *Parser) ParseError!Wrapped(ast.MetaValue) {
        switch (self.peek()) {
            .null_kw => {
                const tok = self.expect(.null_kw) catch unreachable;
                const id = try self.span_registry.addNode(tok.span, .leaf);
                return .wrap(id, .null);
            },
            .true_kw => {
                const tok = self.expect(.true_kw) catch unreachable;
                const id = try self.span_registry.addNode(tok.span, .leaf);
                return .wrap(id, .{ .bool = true });
            },
            .false_kw => {
                const tok = self.expect(.false_kw) catch unreachable;
                const id = try self.span_registry.addNode(tok.span, .leaf);
                return .wrap(id, .{ .bool = false });
            },
            .number => {
                const tok = try self.advance();

                const val = std.fmt.parseFloat(f64, tok.lexeme) catch {
                    try self.addDiagnostic(.err, "invalid number literal", .{});
                    return ParseError.UnexpectedToken;
                };

                const id = try self.span_registry.addNode(tok.span, .leaf);
                return .wrap(id, .{ .number = val });
            },
            .apostrophe => {
                const start = self.currentPos();
                const ch = try self.readCharacter();
                _ = try self.expect(.apostrophe);

                const id = try self.span_registry.addNode(self.spanFrom(start), .leaf);
                return .wrap(id, .{ .char = ch.lexeme[0] });
            },
            .quote => {
                const start = self.currentPos();

                const string = try self.readString("\"", false);
                _ = try self.expect(.quote);

                const id = try self.span_registry.addNode(self.spanFrom(start), .leaf);
                return .wrap(id, .{ .string = string.lexeme });
            },
            .lbracket => {
                const start = self.currentPos();
                _ = self.expect(.lbracket) catch unreachable;

                var items: std.ArrayList(ast.MetaValue) = .empty;
                errdefer items.deinit(self.arena.allocator());

                var child_ids = try self.span_registry.getArrayList(SpanId, 2);
                errdefer child_ids.deinit();

                while (try self.eat(.rbracket) == null) {
                    const wrapped = try self.parseMetaValue();
                    try child_ids.append(wrapped.id);
                    try items.append(self.arena.allocator(), wrapped.payload);

                    if (try self.eat(.comma) == null) {
                        _ = try self.expect(.rbracket);
                        break;
                    }
                }

                const id = try self.span_registry.addNode(
                    self.spanFrom(start),
                    .{ .expr = .{
                        .list = try child_ids.toOwnedSlice(),
                    } },
                );

                return .wrap(id, .{
                    .list = try items.toOwnedSlice(self.arena.allocator()),
                });
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
