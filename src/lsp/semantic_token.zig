const std = @import("std");

const lib = @import("lib");
const compiler = @import("compiler");
const cst = compiler.cst;
const ast = compiler.ast;

const Span = compiler.Span;

const Scope = compiler.scope.Scope;

pub const TokenType = enum(u32) {
    keyword,
    property,
    function,
    number,
    string,
    variable,
    parameter,
    operator,
    type,
    macro,
    decorator,
    namespace,
    builtin,
    comment,

    pub fn getNames() []const []const u8 {
        return std.meta.fieldNames(@This());
    }
};

pub const TokenModifier = enum(u32) {
    declaration = 1 << 0,
    readonly = 1 << 1,
    default_library = 1 << 2,

    attr_platform = 1 << 3,
    attr_current_platform = 1 << 4,
    attr_doc = 1 << 5,
    attr_modifier = 1 << 6,
    attr_validation = 1 << 7,

    pub fn getNames() []const []const u8 {
        return std.meta.fieldNames(@This());
    }

    fn modsToInt(mods: []const TokenModifier) u32 {
        var out: u32 = 0;

        for (mods) |mod| {
            out |= @intFromEnum(mod);
        }

        return out;
    }
};
const RawToken = struct {
    start: u32,
    end: u32,
    ttype: u32,
    mods: u32 = 0,

    pub fn make(span: Span, ttype: TokenType, mods: []const TokenModifier) RawToken {
        return .{
            .start = span.start,
            .end = span.end(),
            .ttype = @intFromEnum(ttype),
            .mods = TokenModifier.modsToInt(mods),
        };
    }
};

fn lessThan(_: void, l: RawToken, r: RawToken) bool {
    return l.start < r.start;
}

pub fn sortTokens(tokens: []RawToken) !void {
    std.mem.sortUnstable(RawToken, tokens, {}, lessThan);
}

const CURRENT_PLATFORM_ATTRIBUTE_ID = blk: {
    const attr_def = compiler.attributes.definitions.get(@tagName(compiler.platform.tag), null).?;
    break :blk attr_def.type;
};

pub const Collector = struct {
    allocator: std.mem.Allocator,
    tokens: std.ArrayList(RawToken),
    context: Context,
    const Error = std.mem.Allocator.Error;

    // pub fn collect(allocator: std.mem.Allocator, file: *const ast.File, scope: *const Scope) Error![]RawToken {
    //     var collector: Collector = .init(allocator);

    //     // handle flat spans first

    //     try collector.walkFile(file, scope);

    //     const validate = comptime switch (@import("builtin").mode) {
    //         .Debug, .ReleaseSafe => true,
    //         else => false,
    //     };

    //     const out = try collector.tokens.toOwnedSlice(allocator);

    //     try sortTokens(out);

    //     if (comptime validate) {
    //         if (out.len == 0) return out;

    //         var max_end: u32 = out[0].end;
    //         var ttype = out[0].ttype;

    //         for (out[1..]) |tok| {
    //             if (tok.start < max_end) {
    //                 std.debug.panic(
    //                     "semantic token overlap: '{t}' [{d}, {d}] collides with a preceding token '{t}' ending at {d} -- some span was likely registered twice",
    //                     .{ @as(TokenType, @enumFromInt(tok.ttype)), tok.start, tok.end, @as(TokenType, @enumFromInt(ttype)), max_end },
    //                 );
    //             }
    //             max_end = @max(max_end, tok.end);
    //             if (max_end == tok.end) {
    //                 ttype = tok.ttype;
    //             }
    //         }

    //         return out;
    //     }
    // }
    fn init(allocator: std.mem.Allocator) Collector {
        return .{
            .allocator = allocator,
            .tokens = .empty,
            .context = .empty,
        };
    }

    fn deinit(self: *Collector) void {
        self.tokens.deinit(self.allocator);
        self.context.scope_stack.deinit(self.allocator);
        self.context.tree_stack.stack.deinit(self.allocator);
    }

    fn add(self: *Collector, span: Span, ttype: TokenType, mods: ?[]const TokenModifier) Error!void {
        try self.tokens.append(self.allocator, .make(span, ttype, mods orelse &.{}));
    }

    pub fn collect(allocator: std.mem.Allocator, file: *const cst.Node, root_scope: *Scope) Error![]RawToken {
        var collector: Collector = .init(allocator);

        try collector.context.scope_stack.append(
            allocator,
            root_scope,
        );

        try collector.handleNode(file);

        const validate = comptime switch (@import("builtin").mode) {
            .Debug, .ReleaseSafe => true,
            else => false,
        };

        const out = try collector.tokens.toOwnedSlice(allocator);

        //TODO: consider if sorting is needed
        if (comptime validate) {
            if (out.len == 0) return out;

            var max_end: u32 = out[0].end;
            var ttype = out[0].ttype;

            for (out[1..]) |tok| {
                if (tok.start < max_end) {
                    std.debug.panic(
                        "semantic token overlap: '{t}' [{d}, {d}] collides with a preceding token '{t}' ending at {d} -- some span was likely registered twice",
                        .{ @as(TokenType, @enumFromInt(tok.ttype)), tok.start, tok.end, @as(TokenType, @enumFromInt(ttype)), max_end },
                    );
                }
                max_end = @max(max_end, tok.end);
                if (max_end == tok.end) {
                    ttype = tok.ttype;
                }
            }

            return out;
        }
    }

    pub fn scope(self: *Collector) *Scope {
        return self.context.scope_stack.getLast();
    }

    fn significantParentNode(self: *const Collector, comptime kinds: []const cst.NodeKind) ?cst.NodeKind {
        return self.context.tree_stack.closest(kinds);
    }

    fn parentNode(self: *const Collector) cst.NodeKind {
        return self.context.tree_stack.stack.getLast();
    }

    fn handleNode(self: *Collector, node: *const cst.Node) Error!void {
        const node_scope = self.scope().child(node);
        if (node_scope) |ns| try self.context.scope_stack.append(self.allocator, ns);
        defer {
            if (node_scope != null) {
                _ = self.context.scope_stack.pop();
            }
        }

        try self.context.tree_stack.enter(self.allocator, node.kind);
        defer self.context.tree_stack.pop();

        for (node.children) |*child| {
            try self.handleElement(child);
        }
    }

    fn handleElement(self: *Collector, element: *const cst.Element) Error!void {
        switch (element.*) {
            .node => |node| try self.handleNode(node),
            .token => |token| try self.handleToken(token),
            else => {},
        }
    }

    fn handleToken(self: *Collector, token: cst.Token) Error!void {
        const parent = self.parentNode();

        switch (parent) {
            .builtin_call => switch (token.kind) {
                .fallback_kw => try self.add(token.span, .keyword, null),
                else => try self.add(token.span, .builtin, &.{.default_library}),
            },
            else => switch (token.kind) {
                .ident => switch (parent) {
                    .name => {
                        const significant = self.significantParentNode(&.{
                            .task, .group, .binding, .parameter, .captures, .attribute,
                        }) orelse return;
                        switch (significant) {
                            .group => {
                                try self.add(
                                    token.span,
                                    .namespace,
                                    &.{.declaration},
                                );
                            },
                            .task => {
                                try self.add(
                                    token.span,
                                    .function,
                                    &.{.declaration},
                                );
                            },
                            .parameter, .captures => {
                                try self.add(
                                    token.span,
                                    .parameter,
                                    &.{.declaration},
                                );
                            },
                            .binding => {
                                try self.add(
                                    token.span,
                                    .variable,
                                    &.{.declaration},
                                );
                            },
                            .attribute => {
                                const attr_def = compiler.attributes.definitions.get(token.lexeme, null) orelse return;

                                const mod: TokenModifier = mod: {
                                    break :mod switch (attr_def.kind) {
                                        .platform => if (attr_def.type == CURRENT_PLATFORM_ATTRIBUTE_ID)
                                            TokenModifier.attr_current_platform
                                        else
                                            TokenModifier.attr_platform,
                                        inline else => |tag| {
                                            const mod_name = "attr_" ++ @tagName(tag);
                                            const ti = @typeInfo(TokenModifier).@"enum";
                                            inline for (ti.fields) |f| {
                                                if (std.mem.eql(u8, f.name, mod_name))
                                                    break :mod @enumFromInt(f.value);
                                            } else unreachable;
                                        },
                                    };
                                };

                                try self.add(
                                    token.span,
                                    .decorator,
                                    &.{mod},
                                );
                            },
                            else => unreachable,
                        }
                    },
                    .name_ref => {
                        const significant = self.significantParentNode(&.{.task_call});

                        if (significant) |s| switch (s) {
                            .task_call => {
                                const tt: TokenType = if (self.scope().resolve(token.lexeme, .group)) |_|
                                    .namespace
                                else if (self.scope().resolve(token.lexeme, .task)) |_|
                                    .function
                                else
                                    return;

                                try self.add(token.span, tt, null);
                            },
                            else => unreachable,
                        } else {
                            const symbol = self.scope().resolve(
                                token.lexeme,
                                .variable,
                            ) orelse return;

                            const tt: TokenType = switch (symbol.origin) {
                                .argument, .capture => .parameter,
                                .binding => .variable,
                                else => unreachable,
                            };

                            try self.add(token.span, tt, null);
                        }
                    },
                    else => {}, //TODO: consider if safe
                },

                else => try self.lexical(token),
            },
        }
    }
    fn lexical(self: *Collector, token: cst.Token) Error!void {
        const ttype: TokenType = switch (token.kind) {
            .number => .number,

            // KEYWORDS
            .set_kw,
            .task_kw,
            .group_kw,
            .if_kw,
            .else_kw,
            .and_kw,
            .or_kw,
            .not_kw,
            .for_kw,
            .switch_kw,
            .continue_kw,
            .break_kw,
            .fallback_kw,
            => .keyword,

            // constants
            .true_kw, .false_kw, .null_kw => {
                try self.add(token.span, .variable, &.{ .readonly, .default_library });
                return;
            },

            // OPERATORS
            .plus,
            .minus,
            .star,
            .slash,
            .colon_eq,
            .eq,
            .eq_eq,
            .bang_eq,
            .lt,
            .lt_eq,
            .gt,
            .gt_eq,
            .dollar,
            .fat_arrow,
            .dcolon,
            .triple_dot,
            => .operator,
            // STRING
            .quote, .backtick, .apostrophe, .string, .char => .string,
            // TYPES
            .string_type, .number_type, .flag_type => .type,
            .comment => .comment,
            else => return,
        };
        try self.add(token.span, ttype, null);
    }
};

const Context = struct {
    tree_stack: TreeStack = .empty,
    scope_stack: ScopeStack = .empty,

    const empty: Context = .{};
};

const ScopeStack = std.ArrayList(*compiler.scope.Scope);

const TreeStack = struct {
    stack: std.ArrayList(cst.NodeKind),

    const empty: TreeStack = .{
        .stack = .empty,
    };

    fn enter(self: *TreeStack, allocator: std.mem.Allocator, kind: cst.NodeKind) !void {
        try self.stack.append(
            allocator,
            kind,
        );
    }

    fn pop(self: *TreeStack) void {
        _ = self.stack.pop();
    }

    fn closest(self: *const TreeStack, comptime kinds: []const cst.NodeKind) ?cst.NodeKind {
        const set: std.EnumSet(cst.NodeKind) = comptime .initMany(kinds);

        var it = std.mem.reverseIterator(self.stack.items);

        while (it.next()) |kind| {
            if (set.contains(kind))
                return kind;
        }

        return null;
    }
};
