const std = @import("std");
pub const Token = @import("Token.zig");
const Span = @import("Span.zig");

pub const NodeKind = enum {
    source_file,
    group,
    group_body,
    task,
    task_deps,
    set,
    set_body,
    set_decl,
    params,
    parameter,
    param_type,
    list_type,

    attributes,
    attribute,

    stmt_block,
    process,

    binding,
    task_call,
    task_call_args,
    task_call_arg,
    task_call_named_arg,

    expr_stmt,

    tuple,
    char,
    string,
    expr,

    literal,
    list,
    name_ref,
    paren_expr,
    string_expr,
    binary_expr,
    unary_expr,

    lambda,
    lambda_params,

    @"if",

    builtin_call,
    builtin_call_args,
    builtin_call_fallback,

    @"switch",
    switch_body,
    switch_case,
    switch_case_pattern,
    @"for",
    subjects,
    captures,

    name,
    path,

    error_tree,
};

pub const Element = union(enum) {
    token: Token,
    node: *Node,
    missing: Span,

    pub fn span(self: *const Element) Span {
        return switch (self.*) {
            .token => |tok| tok.span,
            .node => |node| node.span,
            .missing => |missing| missing,
        };
    }

    pub fn trimmedSpan(self: *const Element) Span {
        return switch (self.*) {
            .token => |tok| tok.span,
            .node => |node| node.trimmedSpan(),
            .missing => |missing| missing,
        };
    }
};

pub const Node = struct {
    kind: NodeKind,
    parent: ?*Node = null,
    children: []const Element,
    span: Span,

    pub fn trimmedSpan(self: *const Node) Span {
        if (self.children.len == 0)
            return self.span;

        const first: *const Element = for (self.children) |child| {
            switch (child) {
                .token => |token| {
                    if (token.kind.isTrivia())
                        continue;
                },
                else => {},
            }
            break &child;
        } else return self.span; // trivia only? weird but ok

        const last = &self.children[self.children.len - 1];

        return Span.between(
            first.trimmedSpan(),
            last.span(),
        );
    }

    pub fn childNodeOf(self: *const Node, comptime kinds: []const NodeKind) ?*Node {
        const set = comptime std.EnumSet(NodeKind).initMany(kinds);

        for (self.children) |el| switch (el) {
            .node => |n| if (set.contains(n.kind)) return n,
            else => {},
        };
        return null;
    }

    pub fn childNode(self: *const Node, comptime kind: NodeKind) ?*const Node {
        return self.childNodeOf(&.{kind});
    }

    pub fn childTokenOf(self: *const Node, comptime kinds: []const Token.Kind) ?Token {
        const set = comptime std.EnumSet(Token.Kind).initMany(kinds);

        for (self.children) |el| switch (el) {
            .token => |t| if (set.contains(t.kind)) return t,
            else => {},
        };

        return null;
    }

    pub fn childToken(self: *const Node, comptime kind: Token.Kind) ?Token {
        return self.childTokenOf(&.{kind});
    }

    pub fn nthNode(self: *const Node, n: usize) ?*Node {
        var i = 0;
        for (self.children) |el| switch (el) {
            .node => |node| {
                if (i == n) return node;
                i += 1;
            },
            else => {},
        };
        return null;
    }

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        for (self.children) |child| {
            switch (child) {
                .node => |node| {
                    node.deinit(allocator);
                    allocator.destroy(node);
                },
                else => {},
            }
        }

        allocator.free(self.children);
    }

    pub fn iter(self: *const Node) Iterator {
        return .init(self);
    }
};

pub const Iterator = struct {
    const State = enum { valid, @"error", missing, eof };

    items: []const Element,
    idx: usize = 0,
    state: State = .valid,

    fn init(node: *const Node) Iterator {
        return .{ .items = node.children };
    }

    fn last(self: *Iterator) *const Element {
        std.debug.assert(self.idx != 0);
        return &self.items[self.idx - 1];
    }

    pub fn reset(self: *Iterator) void {
        self.idx = 0;
        self.state = .valid;
    }

    pub fn lastSpan(self: *Iterator) Span {
        return self.last().span();
    }

    pub fn assertNext(self: *Iterator) Element {
        return self.next().?;
    }

    pub fn next(self: *Iterator) ?Element {
        const i = self.peekIndex() orelse {
            self.state = .eof;
            return null;
        };
        self.idx = i + 1;
        self.state = .valid;
        return self.items[i];
    }

    pub fn nextNode(self: *Iterator) ?*const Node {
        while (self.next()) |elem| {
            switch (elem) {
                .node => |n| return n,
                else => {},
            }
        }
        return null;
    }

    pub fn peek(self: *Iterator) ?Element {
        const i = self.peekIndex() orelse return null;
        return self.items[i];
    }

    /// Index of the next non-trivia element, without consuming it.
    fn peekIndex(self: *Iterator) ?usize {
        var i = self.idx;
        while (i < self.items.len) : (i += 1) {
            if (!isTrivia(self.items[i])) return i;
        }
        return null;
    }

    /// Index of the next non-trivia element that is a `.node`, skipping
    /// over any interleaved tokens or `.missing` markers along the way.
    ///
    /// Safe because, in this grammar, `.missing` only ever stands in for
    /// a failed TOKEN — a failed node always shows up as a real `.node`
    /// of kind `.error_tree` instead, never as `.missing`. If that
    /// invariant ever changes, this needs revisiting.
    fn skipToNode(self: *Iterator) ?usize {
        var i = self.idx;
        while (i < self.items.len) : (i += 1) {
            switch (self.items[i]) {
                .node => return i,
                else => {},
            }
        }
        return null;
    }

    // ── node ─────────────────────────────────────────────────────────────

    /// Looks ahead past tokens/missing for the next node of `kind`.
    /// Consumes it if found; leaves the cursor untouched otherwise.
    pub fn eatNode(self: *Iterator, comptime kind: NodeKind) ?*Node {
        return self.eatAnyNode(&.{kind});
    }

    pub fn eatAnyNode(self: *Iterator, comptime kinds: []const NodeKind) ?*Node {
        const set: std.EnumSet(NodeKind) = comptime .initMany(kinds);
        const i = self.skipToNode() orelse return null;

        return switch (self.items[i]) {
            .node => |n| if (set.contains(n.kind)) blk: {
                self.idx = i + 1;
                break :blk n;
            } else null,
            else => unreachable, // skipToNode only ever lands on .node
        };
    }

    /// Consumes the next node (skipping past tokens/missing to find it),
    /// asserting it is one of `kind`. Sets `state` to `.error` if what
    /// was found is an `error_tree`, or `.eof` if nothing was left.
    pub fn expectNode(self: *Iterator, comptime kind: NodeKind) ?*Node {
        return self.expectAnyNode(&.{kind});
    }

    pub fn expectAnyNode(self: *Iterator, comptime kinds: []const NodeKind) ?*Node {
        const set: std.EnumSet(NodeKind) = comptime .initMany(kinds);
        const i = self.skipToNode() orelse {
            self.state = .eof;
            return null;
        };
        self.idx = i + 1;

        return switch (self.items[i]) {
            .node => |n| if (n.kind == .error_tree) blk: {
                self.state = .@"error";
                break :blk null;
            } else blk: {
                std.debug.assert(set.contains(n.kind));
                self.state = .valid;
                break :blk n;
            },
            else => unreachable,
        };
    }

    // ── token ────────────────────────────────────────────────────────────

    /// Consumes the very next non-trivia slot only if it's a token of
    /// `kind`. Does NOT skip past anything — a node or a missing marker
    /// sitting there means "not found," cursor untouched.
    pub fn eatToken(self: *Iterator, comptime kind: Token.Kind) ?Token {
        return self.eatAnyToken(&.{kind});
    }

    pub fn eatAnyToken(self: *Iterator, comptime kinds: []const Token.Kind) ?Token {
        const set: std.EnumSet(Token.Kind) = comptime .initMany(kinds);
        const i = self.peekIndex() orelse return null;

        return switch (self.items[i]) {
            .token => |t| if (set.contains(t.kind)) blk: {
                self.idx = i + 1;
                break :blk t;
            } else null,
            .missing => {
                self.idx = i + 1;
                return null;
            },
            .node => null,
        };
    }

    /// Consumes the very next non-trivia slot, asserting it is a token
    /// of one of `kinds`. Sets `state` to `.missing` if that slot was a
    /// missing marker, or `.error` if it was an unexpected error node.
    pub fn expectToken(self: *Iterator, comptime kind: Token.Kind) ?Token {
        return self.expectAnyToken(&.{kind});
    }

    pub fn expectAnyToken(self: *Iterator, comptime kinds: []const Token.Kind) ?Token {
        const set: std.EnumSet(Token.Kind) = comptime .initMany(kinds);
        const elem = self.next() orelse return null;

        return switch (elem) {
            .token => |t| blk: {
                std.debug.assert(set.contains(t.kind));
                break :blk t;
            },
            .missing => blk: {
                self.state = .missing;
                break :blk null;
            },
            .node => |n| blk: {
                std.debug.assert(n.kind == .error_tree);
                self.state = .@"error";
                break :blk null;
            },
        };
    }

    fn isTrivia(element: Element) bool {
        return switch (element) {
            .token => |t| switch (t.kind) {
                .whitespace, .comment => true,
                else => false,
            },
            else => false,
        };
    }
};

pub const debug = struct {
    const lib = @import("lib");

    const MAX_DEPTH = 128;

    const Error = std.Io.Writer.Error;
    pub fn printTree(w: *std.Io.Writer, node: *const Node) Error!void {
        var is_last_stack: [MAX_DEPTH]bool = undefined;
        try w.print("{s}\n", .{@tagName(node.kind)});
        try printChildren(w, node.children, &is_last_stack, 0);
    }

    fn printChildren(w: *std.Io.Writer, children: []const Element, is_last_stack: []bool, depth: usize) Error!void {
        for (children, 0..) |child, i| {
            const is_last = i == children.len - 1;
            is_last_stack[depth] = is_last;
            try printPrefix(w, is_last_stack, depth + 1);
            try printElement(w, child, is_last_stack, depth + 1);
        }
    }

    fn printPrefix(w: *std.Io.Writer, is_last_stack: []const bool, depth: usize) Error!void {
        var i: usize = 0;
        while (i < depth) : (i += 1) {
            const last = is_last_stack[i];
            if (i == depth - 1) {
                try w.print("{s}", .{if (last) "└── " else "├── "});
            } else {
                try w.print("{s}", .{if (last) "    " else "│   "});
            }
        }
    }

    fn printElement(w: *std.Io.Writer, el: Element, is_last_stack: []bool, depth: usize) Error!void {
        switch (el) {
            .token => |tok| try w.print("Token({s}) \"{f}\"\n", .{ @tagName(tok.kind), lib.debug.vstring(tok.lexeme) }),
            .node => |n| {
                try w.print("{s}\n", .{@tagName(n.kind)});
                try printChildren(w, n.children, is_last_stack, depth);
            },
            .missing => try w.print("Missing\n", .{}),
        }
    }
};
