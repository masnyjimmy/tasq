const std = @import("std");

const ast = @import("ast.zig");

const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;

const text = @import("text.zig");

const token_mod = @import("token.zig");
const Token = token_mod.Token;
const TokenKind = token_mod.TokenKind;

const Diagnostics = @import("Diagnostics.zig");

const Span = @import("span.zig");
const NodeId = Span.Registry.NodeId;
const Wrapped = Span.Registry.Wrapped;

const lib = @import("lib");

const ParseError = error{
    UnexpectedToken,
    UnableToRetreat,
} || std.mem.Allocator.Error;

fn parseTaskCall(value: []const u8) struct { []const u8, []const u8 } {
    const dot_index = std.mem.lastIndexOfScalar(u8, value, '.') orelse 0;
    return .{ value[0..dot_index], value[dot_index..] };
}

const ParseAs = enum {
    statement,
    expr,

    fn BranchT(comptime as: @This()) type {
        return switch (as) {
            .statement => ast.StatementBlock,
            .expr => ast.Expr,
        };
    }
};

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

    fn readCharacter(self: *Parser) ParseError!Token {
        var lexer = self.lexer.stringLexer();

        self.resyncToRaw();
        const tok = try lexer.lexCharacter();
        try self.resyncFromRaw(tok);

        if (tok.kind != .char) {
            try self.addDiagnostic(.err, "expected char, found '{s}'", .{@tagName(tok.kind)});
            return ParseError.UnexpectedToken;
        }

        return tok;
    }

    fn readString(self: *Parser, terminator: []const u8, comptime multiline: bool) ParseError!Token {
        var lexer = self.lexer.stringLexer();

        self.resyncToRaw();
        const tok = try lexer.lexString(&.{terminator}, multiline);
        try self.resyncFromRaw(tok);

        if (tok.kind != .string) {
            try self.addDiagnostic(.err, "expected string, found '{s}'", .{@tagName(tok.kind)});
            return ParseError.UnexpectedToken;
        }

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

        var options: std.ArrayList(ast.Set) = try .initCapacity(self.arena.allocator(), 1);
        var decls: std.ArrayList(ast.Decl) = try .initCapacity(self.arena.allocator(), 1);
        var groups: std.ArrayList(ast.Group) = try .initCapacity(self.arena.allocator(), 8);
        var tasks: std.ArrayList(ast.Task) = try .initCapacity(self.arena.allocator(), 5);

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

    fn parseGroup(self: *Parser, attrs: []ast.Attribute, start: u32) ParseError!ast.Group {
        const name = try self.eat(.ident);

        var arguments: []ast.Argument = &.{};
        var args_span: ?Span = null;

        if (try self.eat(.lparen)) |lp| {
            arguments = try self.parseArguments();
            args_span = self.spanFrom(lp.span.start);
        }

        _ = try self.expect(.lbrace);

        var decls: std.ArrayList(ast.Decl) = try .initCapacity(self.arena.allocator(), 5);
        var tasks: std.ArrayList(ast.Task) = try .initCapacity(self.arena.allocator(), 1);

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

        // FIX: body_start must be captured *after* consuming '{', otherwise
        // the registered body span (and the .wrap node below) includes the
        // brace itself -- inconsistent with parseGroup/parseSet, which both
        // capture body_start post-brace.

        const body = try self.parseStatementBlock(false);

        const id = try self.span_registry.addNode(
            self.spanFrom(start),
            .{ .task = .{
                .name = name.span,
                .args = args_span,
                .body = body.id,
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

    fn parseSet(self: *Parser, attributes: []ast.Attribute, start: u32) ParseError!ast.Set {
        var decls: std.ArrayList(ast.Set.SetDecl) = .empty;

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
        var value_id: ?NodeId = null;

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
            var value_id: ?NodeId = null;

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

        _ = self.expect(.rbracket) catch |err| switch (err) {
            ParseError.UnexpectedToken => {
                switch (try self.synchronizeTo(&.{.rbracket})) {
                    .rbracket => {
                        _ = try self.advance();
                    },
                    else => {},
                }
            },
            else => return err,
        };

        return attrs.toOwnedSlice(self.arena.allocator());
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
            var default_id: ?NodeId = null;

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

    /// ArgType doesn't need its own registry entry -- `argument.type` in the
    /// registry stores the whole type span directly, so this just hands
    /// back the span alongside the parsed value.
    fn parseArgType(self: *Parser) ParseError!struct { span: Span, value: ast.ArgType } {
        const start = self.currentPos();

        const list_op_span: ?Span = blk: {
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

    //================= statements =====================

    fn parseStatement(self: *Parser) ParseError!Wrapped(ast.Statement) {
        switch (self.peek()) {
            .backtick => {
                _ = self.expect(.backtick) catch unreachable;

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
                    var scope: ast.TaskCall.Scope = .closest;
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
                const if_kw = self.expect(.if_kw) catch unreachable;

                const result = try self.parseIf(if_kw.span.start, .statement);

                return .wrap(result.id, .{ .if_stmt = result });
            },
            .switch_kw => {
                const switch_kw = self.expect(.switch_kw) catch unreachable;

                const result = try self.parseSwitch(switch_kw.span.start, .statement);

                return .wrap(result.id, .{ .switch_stmt = result });
            },
            .for_kw => {
                const for_kw = try self.expect(.for_kw);

                const result = try self.parseFor(for_kw.span.start, .statement);

                return .wrap(result.id, .{ .for_stmt = result });
            },
            else => {
                const expr = try self.parseExpr();
                return .wrap(expr.id, .{
                    .expr = expr.payload,
                });
                // try self.addDiagnostic(.err, "expected statement, found '{s}'", .{@tagName(self.next.kind)});
                // return ParseError.UnexpectedToken;
            },
        }
    }

    fn parseStatementBlock(self: *Parser, comptime allow_single: bool) ParseError!Wrapped(ast.StatementBlock) {
        const start = self.currentPos();

        const lbrace: ?Token = if (allow_single)
            try self.eat(.lbrace)
        else
            try self.expect(.lbrace);

        var stmts: std.ArrayList(ast.Statement) = try .initCapacity(self.arena.allocator(), 0);

        var spans_nodes = try self.span_registry.getArrayList(NodeId, 0);
        errdefer spans_nodes.deinit();

        if (lbrace) |_| {
            while (try self.eat(.rbrace) == null) {
                const stmt = try self.parseStatement();
                try spans_nodes.append(stmt.id);
                try stmts.append(self.arena.allocator(), stmt.payload);
            }
        } else {
            const stmt = try self.parseStatement();
            try spans_nodes.append(stmt.id);
            try stmts.append(self.arena.allocator(), stmt.payload);
        }

        const id = try self.span_registry.addNode(
            self.spanFrom(start),
            .{
                .block = .{
                    .stmts = try spans_nodes.toOwnedSlice(),
                },
            },
        );

        return .wrap(id, try stmts.toOwnedSlice(self.arena.allocator()));
    }

    fn parseTaskCallArgs(self: *Parser) ParseError![]ast.TaskCall.Arg {
        var args: std.ArrayList(ast.TaskCall.Arg) = try .initCapacity(self.arena.allocator(), 1);

        _ = try self.expect(.lparen);

        while (try self.eat(.rparen) == null) {
            const arg_start = self.currentPos();

            var arg_name: ?Token = null;
            var value: ast.Expr = undefined;
            var value_id: NodeId = undefined;

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

    //============= advanced stmt / expr constructs helpers ==================

    fn parseAsTarget(self: *Parser, comptime as: ParseAs) ParseError!Wrapped(ParseAs.BranchT(as)) {
        return switch (as) {
            .statement => try self.parseStatementBlock(true),
            .expr => try self.parseExpr(),
        };
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
            .quote => {
                // parseStringExpr already registers/returns the correct id --
                // a plain literal reuses its single leaf id, an interpolated
                // one an `.expr` id -- so just forward it.
                _ = self.expect(.quote) catch unreachable;

                const string = try self.parseStringExpr("\"", false);
                _ = try self.expect(.quote);

                return .wrap(string.id, .{ .string = string.payload });
            },
            .pipe => {
                const pipe = self.expect(.pipe) catch unreachable;

                var params: std.ArrayList([]const u8) = try .initCapacity(self.arena.allocator(), 1);
                var params_spans = try self.span_registry.getArrayList(Span, 1);
                errdefer params_spans.deinit();

                while (true) {
                    const ident = try self.expect(.ident);

                    try params.append(self.arena.allocator(), ident.lexeme);
                    try params_spans.append(ident.span);

                    if (try self.eat(.comma) == null) {
                        _ = try self.expect(.pipe);
                        break;
                    }
                }

                const body = try self.parseExpr();

                const id = try self.span_registry.addNode(
                    self.spanFrom(pipe.span.start),
                    .{
                        .lambda = .{
                            .params = try params_spans.toOwnedSlice(),
                            .body = body.id,
                        },
                    },
                );

                const ptr = try self.arena.allocator().create(ast.Lambda);
                ptr.* = .{
                    .id = id,
                    .params = try params.toOwnedSlice(self.arena.allocator()),
                    .body = body.payload,
                };

                return .wrap(
                    id,
                    .{ .lambda = ptr },
                );
            },
            .lparen => {
                // Parens don't get their own registry entry: the span/id of
                // the enclosed expr is reused as-is.
                //TODO: consider wrapping it
                _ = self.expect(.lparen) catch unreachable;
                const expr = try self.parseExpr();
                _ = try self.expect(.rparen);

                return .wrap(expr.id, expr.payload);
            },
            .lbracket => { // list
                const lbracket = self.expect(.lbracket) catch unreachable;

                // for expr

                if (try self.eat(.for_kw)) |for_kw| {
                    const result = try self.parseFor(for_kw.span.start, .expr);

                    _ = try self.expect(.rbracket);

                    const ptr = try self.arena.allocator().create(ast.ForExpr);
                    ptr.* = result;

                    const id = try self.span_registry.addNode(
                        self.spanFrom(lbracket.span.start),
                        .{ .wrap = result.id },
                    );

                    return .wrap(id, .{ .for_expr = ptr });
                }

                var items: std.ArrayList(ast.Expr.ListItem) = .empty;

                var child_ids = try self.span_registry.getArrayList(NodeId, 2);
                errdefer child_ids.deinit();

                while (try self.eat(.rbracket) == null) {
                    const spread = try self.eat(.triple_dot);

                    const wrapped = try self.parseExpr();

                    const span_id = if (spread) |s|
                        try self.span_registry.addNode(self.spanFrom(s.span.start), .{ .wrap = wrapped.id })
                    else
                        wrapped.id;

                    try child_ids.append(span_id);

                    const expr_ptr = try self.arena.allocator().create(ast.Expr);
                    expr_ptr.* = wrapped.payload;

                    try items.append(self.arena.allocator(), .{
                        .expr = expr_ptr,
                        .is_spread = spread != null,
                    });

                    if (try self.eat(.comma) == null) {
                        _ = try self.expect(.rbracket);
                        break;
                    }
                }

                const id = try self.span_registry.addNode(
                    self.spanFrom(lbracket.span.start),
                    .{ .expr = .{
                        .list = try child_ids.toOwnedSlice(),
                    } },
                );

                return .wrap(id, .{
                    .list = try items.toOwnedSlice(self.arena.allocator()),
                });
            },
            .switch_kw => {
                const switch_kw = self.expect(.switch_kw) catch unreachable;

                const result = try self.parseSwitch(switch_kw.span.start, .expr);

                const ptr = try self.arena.allocator().create(ast.SwitchExpr);
                ptr.* = result;

                return .wrap(result.id, .{ .switch_expr = ptr });
            },
            .if_kw => {
                const if_kw = self.expect(.if_kw) catch unreachable;

                const result = try self.parseIf(if_kw.span.start, .expr);

                const ptr = try self.arena.allocator().create(ast.IfExpr);
                ptr.* = result;

                return .wrap(result.id, .{ .if_expr = ptr });
            },
            .at => {
                const builtin_call = try self.parseBuiltInCall();

                const ptr = try self.arena.allocator().create(ast.BuiltInCall);
                ptr.* = builtin_call;

                return .wrap(builtin_call.id, .{ .builtin_call = ptr });
            },
            .continue_kw => {
                const continue_kw = self.expect(.continue_kw) catch unreachable;
                const id = try self.span_registry.addNode(continue_kw.span, .leaf);
                return .wrap(id, .@"continue");
            },
            .break_kw => {
                const break_kw = self.expect(.break_kw) catch unreachable;
                const id = try self.span_registry.addNode(break_kw.span, .leaf);
                return .wrap(id, .@"break");
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

    fn parseFor(self: *Parser, for_start: u32, comptime as: ParseAs) ParseError!ast.ForCommon(ParseAs.BranchT(as)) {
        var subjects: std.ArrayList(ast.Expr) = .empty;
        var subjects_spans = try self.span_registry.getArrayList(NodeId, 0);
        errdefer subjects_spans.deinit();

        _ = try self.expect(.lparen);

        while (true) {
            const sub = try self.parseExpr();

            try subjects_spans.append(sub.id);

            try subjects.append(self.arena.allocator(), sub.payload);

            if (try self.eat(.comma) == null) {
                _ = try self.expect(.rparen);
                break;
            }
        }

        var captures: std.ArrayList(?[]const u8) = try .initCapacity(self.arena.allocator(), subjects.items.len);
        var captures_spans = try self.span_registry.getArrayList(Span, subjects.items.len);
        errdefer captures_spans.deinit();

        _ = try self.expect(.pipe);

        while (true) {
            const span: Span = blk: {
                if (try self.eat(.underscore)) |tok| {
                    try captures.append(self.arena.allocator(), null);
                    break :blk tok.span;
                }

                const ident = try self.expect(.ident);
                try captures.append(self.arena.allocator(), ident.lexeme);
                break :blk ident.span;
            };

            try captures_spans.append(span);

            if (try self.eat(.comma) == null) {
                _ = try self.expect(.pipe);
                break;
            }
        }

        const body = try self.parseAsTarget(as);

        const id = try self.span_registry.addNode(
            self.spanFrom(for_start),
            .{
                .@"for" = .{
                    .subjects = try subjects_spans.toOwnedSlice(),
                    .captures = try captures_spans.toOwnedSlice(),
                    .body = body.id,
                },
            },
        );

        return .{
            .id = id,
            .subjects = try subjects.toOwnedSlice(self.arena.allocator()),
            .captures = try captures.toOwnedSlice(self.arena.allocator()),
            .body = body.payload,
        };
    }

    fn parseSwitch(self: *Parser, switch_start: u32, comptime as: ParseAs) ParseError!ast.SwitchCommon(ParseAs.BranchT(as)) {
        _ = try self.expect(.lparen);

        const subject = try self.parseExpr();

        _ = try self.expect(.rparen);

        var cases: std.ArrayList(ast.SwitchCommon(as.BranchT()).Case) = .empty;

        _ = try self.expect(.lbrace);

        while (try self.eat(.rbrace) == null) {
            const case = try self.parseSwitchCase(as);

            try cases.append(self.arena.allocator(), case);

            if (try self.eat(.comma) == null) {
                _ = try self.expect(.rbrace);
                break;
            }
        }

        const id = try self.span_registry.addNode(
            self.spanFrom(switch_start),
            .{
                .@"switch" = .{
                    .subject = subject.id,
                },
            },
        );

        return .{
            .id = id,
            .subject = subject.payload,
            .cases = try cases.toOwnedSlice(self.arena.allocator()),
        };
    }

    fn parseSwitchCase(self: *Parser, comptime as: ParseAs) ParseError!ast.SwitchCommon(ParseAs.BranchT(as)).Case {
        const start = self.currentPos();

        var patterns_spans = try self.span_registry.getArrayList(NodeId, 1);
        errdefer patterns_spans.deinit();

        const pattern: ast.SwitchCommon(as.BranchT()).Pattern = blk: {
            if (try self.eat(.else_kw)) |tok| {
                _ = try self.expect(.fat_arrow);

                try patterns_spans.append(try self.span_registry.addNode(tok.span, .leaf));

                break :blk .@"else";
            }

            var patterns: std.ArrayList(ast.Expr) = try .initCapacity(self.arena.allocator(), 1);

            while (true) {
                const expr = try self.parseExpr();

                try patterns_spans.append(expr.id);

                try patterns.append(self.arena.allocator(), expr.payload);

                if (try self.eat(.comma) == null) {
                    _ = try self.expect(.fat_arrow);
                    break;
                }
            }

            break :blk .{ .expr = try patterns.toOwnedSlice(self.arena.allocator()) };
        };

        const body = try self.parseAsTarget(as);

        const id = try self.span_registry.addNode(
            self.spanFrom(start),
            .{
                .switch_case = .{
                    .patterns = try patterns_spans.toOwnedSlice(),
                    .body = body.id,
                },
            },
        );

        return .{
            .id = id,
            .pattern = pattern,
            .body = body.payload,
        };
    }

    fn parseIf(self: *Parser, if_start: u32, comptime as: ParseAs) ParseError!ast.IfCommon(ParseAs.BranchT(as)) {
        _ = try self.expect(.lparen);

        const cond = try self.parseExpr();

        _ = try self.expect(.rparen);

        const then = try self.parseAsTarget(as);

        const @"else" = if (try self.eat(.else_kw)) |_|
            try self.parseAsTarget(as)
        else
            null;

        const id = try self.span_registry.addNode(
            self.spanFrom(if_start),
            .{
                .@"if" = .{
                    .cond = cond.id,
                    .then = then.id,
                    .else_ = if (@"else") |e| e.id else null,
                },
            },
        );

        return .{
            .id = id,
            .cond = cond.payload,
            .then = then.payload,
            .@"else" = if (@"else") |e| e.payload else null,
        };
    }

    fn parseBuiltInCall(self: *Parser) ParseError!ast.BuiltInCall {
        const at = try self.expect(.at); // skip @

        const ident = try self.expect(.ident);

        var args = try std.ArrayList(ast.Expr).initCapacity(self.arena.allocator(), 1);

        var args_spans = try self.span_registry.getArrayList(NodeId, 2);
        errdefer args_spans.deinit();

        _ = try self.expect(.lparen);

        if (try self.eat(.rparen) == null) {
            while (true) {
                const expr = try self.parseExpr();
                try args_spans.append(expr.id);
                try args.append(self.arena.allocator(), expr.payload);
                if (try self.eat(.comma) == null) break;
            }
            _ = try self.expect(.rparen);
        }

        var fallback: ?ast.Expr = null;
        var fallback_span: ?NodeId = null;

        if (try self.eat(.fallback_kw)) |_| {
            const result = try self.parseExpr();
            fallback = result.payload;
            fallback_span = result.id;
        }

        const id = try self.span_registry.addNode(self.spanFrom(at.span.start), .{
            .builtin_call = .{
                .name = ident.span,
                .args = try args_spans.toOwnedSlice(),
                .fallback = fallback_span,
            },
        });

        return .{
            .id = id,
            .name = ident.lexeme,
            .args = try args.toOwnedSlice(self.arena.allocator()),
            .fallback = fallback,
        };
    }

    fn parseStringExpr(self: *Parser, terminator: []const u8, comptime multiline: bool) ParseError!Wrapped(ast.String) {
        //TODO: currently string token span doesn't include quotes, fix this

        const start = self.currentPos();
        var out: std.ArrayList(ast.StringPart) = .empty;

        var parts_spans = try self.span_registry.getArrayList(NodeId, 1);
        errdefer parts_spans.deinit();

        var lexer = self.lexer.stringLexer();

        while (true) {
            self.resyncToRaw();
            const part = try lexer.lexString(&.{ terminator, "{{" }, multiline);
            try self.resyncFromRaw(part);

            switch (part.kind) {
                .string => {
                    try parts_spans.append(try self.span_registry.addNode(part.span, .leaf));
                    try self.span_registry.put(.string, part.span);

                    try out.append(self.arena.allocator(), .{
                        .lit = part.lexeme,
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

            if (try self.eat(.ldbrace)) |_| {
                const expr = blk: {
                    const wrapped = self.parseExpr() catch |err| switch (err) {
                        ParseError.UnexpectedToken => {
                            switch (try self.synchronizeTo(&.{.rdbrace})) {
                                .rdbrace => {
                                    // TODO: handle error
                                    _ = try self.expect(.rdbrace);
                                    continue;
                                },
                                else => break,
                            }
                        },
                        else => return err,
                    };
                    try parts_spans.append(wrapped.id);
                    break :blk wrapped.payload;
                };
                try out.append(self.arena.allocator(), .{ .expr = expr });
                _ = try self.expect(.rdbrace);
            } else {
                break;
            }
        }

        const id = try self.span_registry.addNode(
            self.spanFrom(start),
            .{ .expr = .{
                .list = try parts_spans.toOwnedSlice(),
            } },
        );

        return .wrap(
            id,
            try out.toOwnedSlice(self.arena.allocator()),
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
                const quote = self.expect(.quote) catch unreachable;

                const string = try self.readString("\"", false);

                _ = try self.expect(.quote);

                const id = try self.span_registry.addNode(self.spanFrom(quote.span.start), .leaf);
                return .wrap(id, .{ .string = string.lexeme });
            },
            .lbracket => {
                const start = self.currentPos();
                _ = self.expect(.lbracket) catch unreachable;

                var items: std.ArrayList(ast.MetaValue) = .empty;

                var items_spans = try self.span_registry.getArrayList(NodeId, 2);
                errdefer items_spans.deinit();

                while (try self.eat(.rbracket) == null) {
                    const wrapped = try self.parseMetaValue();
                    try items_spans.append(wrapped.id);
                    try items.append(self.arena.allocator(), wrapped.payload);

                    if (try self.eat(.comma) == null) {
                        _ = try self.expect(.rbracket);
                        break;
                    }
                }

                const id = try self.span_registry.addNode(
                    self.spanFrom(start),
                    .{ .expr = .{
                        .list = try items_spans.toOwnedSlice(),
                    } },
                );

                return .wrap(id, .{
                    .list = try items.toOwnedSlice(self.arena.allocator()),
                });
            },
            .lparen => {
                const lparen = self.expect(.lparen) catch unreachable;

                var elems: std.ArrayList(ast.MetaValue) = .empty;

                var elems_spans = try self.span_registry.getArrayList(NodeId, 0);
                errdefer elems_spans.deinit();

                while (try self.eat(.rparen) == null) {
                    const element = try self.parseMetaValue();
                    try elems_spans.append(element.id);
                    try elems.append(self.arena.allocator(), element.payload);

                    if (try self.eat(.comma) == null) {
                        _ = try self.expect(.rparen);
                        break;
                    }
                }

                const id = try self.span_registry.addNode(
                    self.spanFrom(lparen.span.start),
                    .{ .expr = .{
                        .list = try elems_spans.toOwnedSlice(),
                    } },
                );

                return .wrap(id, .{
                    .tuple = try elems.toOwnedSlice(self.arena.allocator()),
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

    //================= Span helper =========================

    fn spanFrom(self: *Parser, start: u32) Span {
        const end = if (self.current) |p| p.span.end() else self.next.span.start;
        return .{
            .start = start,
            .len = end - start,
        };
    }

    fn peek(self: *Parser) TokenKind {
        return self.next.kind;
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

    fn advance(self: *Parser) !Token {
        const tok = try self.lexer.next();
        return self.setNextFetchCurrent(tok);
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

    /// after reading raw string or something,
    /// set token so parser is in valid state
    fn resyncFromRaw(self: *Parser, token: Token) !void {
        self.current = token;
        self.next = try self.lexer.next();
    }

    /// sets lexer pos to end of previous (last significant) token
    /// needed when reading string
    fn resyncToRaw(self: *Parser) void {
        if (self.current) |curr|
            self.lexer.pos = curr.span.end();
    }
};
