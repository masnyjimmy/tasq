const std = @import("std");
const cst = @import("cst.zig");
const Span = @import("Span.zig");

//============================================================
// generic helpers — iteration + node/token extraction
//============================================================

fn IterableBase(comptime T: type, comptime next_fn: fn (it: *cst.Iterator) ?T) type {
    return struct {
        const Self = @This();
        node: *const cst.Node,

        const Iterator = struct {
            it: cst.Iterator,

            fn init(it: cst.Iterator) Iterator {
                return .{ .it = it };
            }

            pub fn next(self: *Iterator) ?T {
                return next_fn(&self.it);
            }

            pub fn lastSpan(self: *Iterator) Span {
                return self.it.lastSpan();
            }
        };

        pub fn iter(self: *const Self) Iterator {
            return .init(self.node.iter());
        }

        pub fn collect(self: *const Self, allocator: std.mem.Allocator) ![]T {
            var out: std.ArrayList(T) = .empty;

            var it = self.iter();

            while (it.next()) |item| {
                try out.append(allocator, item);
            }

            return try out.toOwnedSlice(allocator);
        }

        pub fn from(node: *const cst.Node) Self {
            return .{ .node = node };
        }
    };
}

fn StrictIterable(comptime T: type, comptime next_fn: fn (it: *cst.Iterator) ?T) type {
    const Result = union(enum) {
        missing: Span,
        value: T,

        pub fn unwrap(self: *const @This()) ?T {
            return switch (self.*) {
                .value => |v| v,
                else => null,
            };
        }
    };

    const Struct = struct {
        fn next(it: *cst.Iterator) ?Result {
            return if (next_fn(it)) |val|
                .{ .value = val }
            else switch (it.state) {
                .eof => null,
                else => .{ .missing = it.lastSpan() },
            };
        }
    };

    return IterableBase(Result, Struct.next);
}

fn LooseIterable(comptime T: type, comptime next_fn: fn (it: *cst.Iterator) ?T) type {
    const Struct = struct {
        fn next(it: *cst.Iterator) ?T {
            while (true) {
                return next_fn(it) orelse switch (it.state) {
                    .eof => break,
                    else => continue,
                };
            }
            return null;
        }
    };
    return IterableBase(T, Struct.next);
}
const IterableType = enum {
    strict, // when position matters
    loose, // when it doesn't (broken elements are skipped automatically)

    fn Iterable(comptime self: IterableType, comptime T: type, comptime next_fn: fn (it: *cst.Iterator) ?T) type {
        return switch (self) {
            .strict => StrictIterable(T, next_fn),
            .loose => LooseIterable(T, next_fn),
        };
    }
};

fn KindIterable(comptime it_type: IterableType, comptime T: type, comptime kind: cst.NodeKind) type {
    const Struct = struct {
        fn next(it: *cst.Iterator) ?T {
            return if (it.expectNode(kind)) |node|
                .from(node)
            else
                null;
        }
    };

    return it_type.Iterable(T, Struct.next);
}

fn AnyKindIterable(comptime it_type: IterableType, comptime T: type, comptime kinds: []const cst.NodeKind) type {
    const Struct = struct {
        fn next(it: *cst.Iterator) ?T {
            return if (it.expectAnyNode(kinds)) |node|
                .from(node)
            else
                null;
        }
    };

    return it_type.Iterable(T, Struct.next);
}

fn expectNode(it: *cst.Iterator, comptime T: type, comptime kind: cst.NodeKind) ?T {
    return if (it.expectNode(kind)) |node| .from(node) else null;
}

fn expectAnyNode(it: *cst.Iterator, comptime T: type, comptime kinds: []const cst.NodeKind) ?T {
    return if (it.expectAnyNode(kinds)) |node| .from(node) else null;
}

fn eatNode(it: *cst.Iterator, comptime T: type, comptime kind: cst.NodeKind) ?T {
    return if (it.eatNode(kind)) |node| .from(node) else null;
}

fn eatAnyNode(it: *cst.Iterator, comptime T: type, comptime kinds: []const cst.NodeKind) ?T {
    return if (it.eatAnyNode(kinds)) |node| .from(node) else null;
}

//============================================================
// shared primitives — Name, literal wrappers (String, Char)
//============================================================

pub const Name = struct {
    node: *const cst.Node,
    ident: ?cst.Token,

    pub fn from(node: *const cst.Node) Name {
        return .{ .node = node, .ident = node.childToken(.ident) };
    }

    pub fn string(self: *const Name) ?[]const u8 {
        return if (self.ident) |tok| tok.lexeme else null;
    }
};

pub const String = struct {
    node: *const cst.Node,
    lit: ?cst.Token,

    pub fn from(node: *const cst.Node) String {
        return .{ .node = node, .lit = node.childToken(.string) };
    }
};

pub const Char = struct {
    node: *const cst.Node,
    lit: ?cst.Token,

    pub fn from(node: *const cst.Node) Char {
        var it = node.iter();
        _ = it.expectToken(.apostrophe);
        return .{ .node = node, .lit = it.eatToken(.char) };
    }
};

//============================================================
// attributes + meta values — [name: meta, ...]
//============================================================

pub const Attributes = KindIterable(
    .loose,
    Attribute,
    .attribute,
);

pub const Attribute = struct {
    node: *const cst.Node,
    name: Name,
    value: ?Meta,

    pub fn from(node: *const cst.Node) Attribute {
        var it = node.iter();
        const name = expectNode(&it, Name, .name) orelse unreachable;
        const value = expectAnyNode(&it, Meta, Meta.KINDS);
        return .{ .node = node, .name = name, .value = value };
    }
};

pub const Meta = struct {
    const KINDS: []const cst.NodeKind = &.{ .literal, .tuple, .char, .string, .list };

    node: *const cst.Node,

    pub const Kind = union(enum) {
        literal: ?cst.Token,
        tuple: MetaIterated,
        char: ?cst.Token,
        string: ?cst.Token,
        list: MetaIterated,
    };

    pub fn from(node: *const cst.Node) Meta {
        return .{ .node = node };
    }

    pub fn classify(self: *const Meta) Kind {
        return switch (self.node.kind) {
            .literal => .{ .literal = self.node.childTokenOf(&.{ .null_kw, .true_kw, .false_kw, .number }) },
            .tuple => .{ .tuple = .from(self.node) },
            .char => .{ .char = self.node.childToken(.char) },
            .string => .{ .string = self.node.childToken(.string) },
            .list => .{ .list = .from(self.node) },
            else => unreachable,
        };
    }
};

pub const MetaIterated = AnyKindIterable(
    .loose,
    Meta,
    Meta.KINDS,
);

//============================================================
// expressions
//============================================================

pub const Expr = struct {
    const KINDS: []const cst.NodeKind = &.{
        .literal,     .list,       .name_ref,
        .paren_expr,  .string,     .string_expr,
        .binary_expr, .unary_expr, .builtin_call,
        .@"if",       .@"for",     .@"switch",
        .lambda,      .process,
    };

    node: *const cst.Node,

    pub const Kind = union(enum) {
        literal: ?cst.Token,
        name_ref: ?cst.Token,
        binary: BinaryExpr,
        unary: UnaryExpr,
        paren: ?Expr,
        string: String,
        string_expr: StringExpr,
        list: ListExpr,
        builtin_call: BuiltinCall,
        @"if": IfExpr,
        @"switch": SwitchExpr,
        @"for": ForExpr,
        process: Process,
        lambda: Lambda,
    };

    pub fn from(node: *const cst.Node) Expr {
        return .{ .node = node };
    }

    pub fn classify(self: *const Expr) Kind {
        return switch (self.node.kind) {
            .literal => .{ .literal = self.node.childTokenOf(&.{ .true_kw, .false_kw, .number }) },
            .name_ref => .{ .name_ref = self.node.childToken(.ident) },
            .paren_expr => .{ .paren = if (self.node.childNodeOf(KINDS)) |n| .from(n) else null },
            .binary_expr => .{ .binary = .from(self.node) },
            .unary_expr => .{ .unary = .from(self.node) },
            .string => .{ .string = .from(self.node) },
            .string_expr => .{ .string_expr = .from(self.node) },
            .list => .{ .list = .from(self.node) },
            .builtin_call => .{ .builtin_call = .from(self.node) },
            .@"if" => .{ .@"if" = .from(self.node) },
            .@"switch" => .{ .@"switch" = .from(self.node) },
            .@"for" => .{ .@"for" = .from(self.node) },
            .lambda => .{ .lambda = .from(self.node) },
            .process => .{ .process = .from(self.node) },
            else => unreachable,
        };
    }
};

pub const BinaryExpr = struct {
    const OP_TOKENS: []const cst.Token.Kind = &.{
        .plus,  .minus,   .star,   .slash,
        .eq_eq, .bang_eq, .lt,     .gt,
        .lt_eq, .gt_eq,   .and_kw, .or_kw,
    };

    node: *const cst.Node,
    left: ?Expr,
    op: ?cst.Token,
    right: ?Expr,

    pub fn from(node: *const cst.Node) BinaryExpr {
        var it = node.iter();
        const left = expectAnyNode(&it, Expr, Expr.KINDS);
        const op = it.expectAnyToken(OP_TOKENS);
        const right = expectAnyNode(&it, Expr, Expr.KINDS);
        return .{ .node = node, .left = left, .op = op, .right = right };
    }
};

pub const UnaryExpr = struct {
    const OP_TOKENS: []const cst.Token.Kind = &.{ .not_kw, .minus };

    node: *const cst.Node,
    op: ?cst.Token,
    operand: ?Expr,

    pub fn from(node: *const cst.Node) UnaryExpr {
        var it = node.iter();
        const op = it.expectAnyToken(OP_TOKENS);
        const operand = expectAnyNode(&it, Expr, Expr.KINDS);
        return .{ .node = node, .op = op, .operand = operand };
    }
};

pub const ListExpr = AnyKindIterable(
    .loose,
    Expr,
    Expr.KINDS,
);

pub const BuiltinCall = struct {
    pub const Fallback = struct {
        node: *const cst.Node,
        expr: ?Expr,

        pub fn from(node: *const cst.Node) Fallback {
            var it = node.iter();
            const expr = expectAnyNode(&it, Expr, Expr.KINDS);

            return .{
                .node = node,
                .expr = expr,
            };
        }
    };

    node: *const cst.Node,
    name: ?cst.Token,
    args: BuiltinCallArgs,
    fallback: ?Fallback,

    pub fn from(node: *const cst.Node) BuiltinCall {
        var it = node.iter();

        _ = it.expectToken(.at);

        const name = it.expectToken(.ident);
        const args = expectNode(&it, BuiltinCallArgs, .builtin_call_args) orelse unreachable;
        const fallback = eatNode(&it, Fallback, .builtin_call_fallback);

        return .{
            .node = node,
            .name = name,
            .args = args,
            .fallback = fallback,
        };
    }
};

pub const BuiltinCallArgs = AnyKindIterable(.strict, Expr, Expr.KINDS);

pub const Lambda = struct {
    node: *const cst.Node,
    params: Captures,
    body: ?Expr,

    pub fn from(node: *const cst.Node) Lambda {
        var it = node.iter();

        const params = expectNode(&it, Captures, .captures) orelse unreachable;
        const body = expectAnyNode(&it, Expr, Expr.KINDS);

        return .{
            .node = node,
            .params = params,
            .body = body,
        };
    }
};

pub const StringPart = union(enum) {
    lit: cst.Token,
    expr: Expr,

    fn next(it: *cst.Iterator) ?StringPart {
        if (it.idx == 0 or it.idx == it.items.len - 1)
            _ = it.expectToken(.backtick);

        if (it.eatToken(.lbrace) != null) {
            const expr = expectAnyNode(it, Expr, Expr.KINDS);
            _ = it.expectToken(.rbrace);

            return if (expr) |e|
                .{ .expr = e }
            else
                null;
        }

        return if (it.expectToken(.string)) |token|
            .{ .lit = token }
        else
            null;
    }
};

pub const StringExpr = LooseIterable(StringPart, StringPart.next);

pub const IfExpr = struct {
    node: *const cst.Node,
    cond: ?Expr,
    then: ?Expr,
    @"else": ?Expr,

    pub fn from(node: *const cst.Node) IfExpr {
        var it = node.iter();
        const cond = expectAnyNode(&it, Expr, Expr.KINDS);
        const then = expectAnyNode(&it, Expr, Expr.KINDS);
        const @"else" = expectAnyNode(&it, Expr, Expr.KINDS);
        return .{ .node = node, .cond = cond, .then = then, .@"else" = @"else" };
    }
};

pub const SwitchExpr = struct {
    node: *const cst.Node,
    subject: ?Expr,
    body: SwitchExprBody,

    pub fn from(node: *const cst.Node) SwitchExpr {
        var it = node.iter();
        const subject = expectAnyNode(&it, Expr, Expr.KINDS);
        const body = expectNode(&it, SwitchExprBody, .switch_body) orelse unreachable;
        return .{ .node = node, .subject = subject, .body = body };
    }
};

pub const SwitchExprBody = KindIterable(.loose, SwitchExprCase, .switch_case);

pub const SwitchExprCase = struct {
    node: *const cst.Node,
    pattern: SwitchPattern,
    expr: ?Expr,

    pub fn from(node: *const cst.Node) SwitchExprCase {
        var it = node.iter();

        const pattern = expectNode(&it, SwitchPattern, .switch_case_pattern) orelse unreachable;
        const expr = expectAnyNode(&it, Expr, Expr.KINDS);

        return .{
            .node = node,
            .pattern = pattern,
            .expr = expr,
        };
    }
};

const SwitchPattern = struct {
    const Kind = union(enum) {
        expr: AnyKindIterable(.loose, Expr, Expr.KINDS),
        @"else": cst.Token,
    };

    node: *const cst.Node,

    pub fn from(node: *const cst.Node) SwitchPattern {
        return .{
            .node = node,
        };
    }

    pub fn classify(self: *const SwitchPattern) Kind {
        if (self.node.childToken(.else_kw)) |token|
            return .{ .@"else" = token };

        return .{ .expr = .from(self.node) };
    }
};

pub const ForExpr = struct {
    node: *const cst.Node,
    subjects: Subjects,
    captures: Captures,
    body: ?Expr,

    pub fn from(node: *const cst.Node) ForExpr {
        var it = node.iter();
        const subjects = expectNode(&it, Subjects, .subjects) orelse unreachable;
        const captures = expectNode(&it, Captures, .captures) orelse unreachable;
        const body = expectAnyNode(&it, Expr, Expr.KINDS);
        return .{ .node = node, .subjects = subjects, .captures = captures, .body = body };
    }
};

pub const Subjects = AnyKindIterable(.strict, Expr, Expr.KINDS);

pub const Captures = StrictIterable(Capture, Capture.next);
const Capture = union(enum) {
    none: cst.Token,
    name: Name,

    fn next(it: *cst.Iterator) ?Capture {
        if (it.eatToken(.underscore)) |token|
            return .{ .none = token };

        return .{
            .name = expectNode(it, Name, .name) orelse return null,
        };
    }
};

//============================================================
// declarations — binding, task, group members
//============================================================

pub const File = IterableBase(FileElement, FileElement.next);

pub const FileElement = union(enum) {
    const KINDS: []const cst.NodeKind = &.{ .set, .task, .group, .binding };

    set: Set,
    task: Task,
    group: Group,
    binding: BindingDecl,

    fn next(it: *cst.Iterator) ?FileElement {
        while (true) {
            const node = it.expectAnyNode(KINDS) orelse switch (it.state) {
                .eof => break,
                else => continue,
            };

            return switch (node.kind) {
                .set => .{ .set = .from(node) },
                .task => .{ .task = .from(node) },
                .group => .{ .group = .from(node) },
                .binding => .{ .binding = .from(node) },
                else => unreachable,
            };
        }
        return null;
    }
};

pub const Set = struct {
    node: *const cst.Node,
    attributes: ?Attributes,
    body: SetBody,

    pub fn from(node: *const cst.Node) Set {
        var it = node.iter();

        const attributes = eatNode(&it, Attributes, .attributes);
        const body = expectNode(&it, SetBody, .set_body) orelse unreachable;

        return .{
            .node = node,
            .attributes = attributes,
            .body = body,
        };
    }
};

pub const SetBody = KindIterable(.loose, SetDecl, .set_decl);

pub const SetDecl = struct {
    node: *const cst.Node,
    name: Name,
    value: ?Meta,

    pub fn from(node: *const cst.Node) SetDecl {
        var it = node.iter();

        const name = expectNode(&it, Name, .name) orelse unreachable;
        const value = expectAnyNode(&it, Meta, Meta.KINDS);

        return .{
            .node = node,
            .name = name,
            .value = value,
        };
    }
};

pub const BindingDecl = struct {
    node: *const cst.Node,
    attributes: ?Attributes,
    name: Name,
    value: ?Expr,

    pub fn from(node: *const cst.Node) BindingDecl {
        var it = node.iter();
        const attributes = eatNode(&it, Attributes, .attributes);
        const name = expectNode(&it, Name, .name) orelse unreachable;
        const value = expectAnyNode(&it, Expr, Expr.KINDS);

        return .{
            .node = node,
            .attributes = attributes,
            .name = name,
            .value = value,
        };
    }
};

pub const Group = struct {
    node: *const cst.Node,
    attributes: ?Attributes,
    name: ?Name,
    params: ?Parameters,
    body: GroupBody,

    pub fn from(node: *const cst.Node) Group {
        var it = node.iter();

        const attributes = eatNode(&it, Attributes, .attributes);

        const name = eatNode(&it, Name, .name);

        const params = eatNode(&it, Parameters, .params);

        const body = expectNode(&it, GroupBody, .group_body) orelse unreachable;

        return .{
            .node = node,
            .attributes = attributes,
            .name = name,
            .params = params,
            .body = body,
        };
    }

    pub fn debugDump(_: *const Group) []const u8 {
        return "<Group Node>";
    }
};

pub const GroupBody = IterableBase(GroupBodyElement, GroupBodyElement.next);

pub const GroupBodyElement = union(enum) {
    const KINDS: []const cst.NodeKind = &.{ .task, .binding };

    task: Task,
    binding: BindingDecl,

    fn next(it: *cst.Iterator) ?GroupBodyElement {
        while (true) {
            const node = it.expectAnyNode(KINDS) orelse switch (it.state) {
                .eof => break,
                else => continue,
            };

            return switch (node.kind) {
                .task => .{ .task = .from(node) },
                .binding => .{ .binding = .from(node) },
                else => unreachable,
            };
        }
        return null;
    }
};

pub const Task = struct {
    node: *const cst.Node,
    attributes: ?Attributes,
    name: Name,
    params: ?Parameters,
    dependencies: ?Dependencies,
    body: Statements,

    pub fn from(node: *const cst.Node) Task {
        var it = node.iter();

        const attributes = eatNode(&it, Attributes, .attributes);
        const name = expectNode(&it, Name, .name) orelse unreachable;
        const params = eatNode(&it, Parameters, .params);
        const dependencies = eatNode(&it, Dependencies, .task_deps);
        const body = expectNode(&it, Statements, .stmt_block) orelse unreachable;

        return .{
            .node = node,
            .attributes = attributes,
            .name = name,
            .params = params,
            .dependencies = dependencies,
            .body = body,
        };
    }

    pub fn debugDump(_: *const Task) []const u8 {
        return "<Task Node>";
    }
};

pub const Parameters = KindIterable(.loose, Parameter, .parameter);

//TODO: result Parameter with missing field, or with optional Parameter ?
pub const Parameter = struct {
    node: *const cst.Node,
    attributes: ?Attributes,
    name: Name,
    type: ParameterType,
    default: ?Expr,

    pub fn from(node: *const cst.Node) Parameter {
        var it = node.iter();
        const attributes = eatNode(&it, Attributes, .attributes);
        const name = expectNode(&it, Name, .name) orelse unreachable;
        const param_type = expectNode(&it, ParameterType, .param_type) orelse unreachable;
        const default = eatAnyNode(&it, Expr, Expr.KINDS);
        return .{
            .node = node,
            .attributes = attributes,
            .name = name,
            .type = param_type,
            .default = default,
        };
    }
};

pub const ParameterType = struct {
    node: *const cst.Node,
    is_list: bool,
    type: ?cst.Token,

    pub fn from(node: *const cst.Node) ParameterType {
        if (node.childNode(.list_type)) |list| {
            return .{
                .node = node,
                .is_list = true,
                .type = list.childTokenOf(&.{ .number_type, .string_type }),
            };
        }

        return .{
            .node = node,
            .is_list = false,
            .type = node.childTokenOf(&.{ .flag_type, .number_type, .string_type }),
        };
    }
};

//============================================================
// task dependencies + task calls (used by deps and by statements)
//============================================================

pub const Dependencies = KindIterable(.loose, TaskCall, .task_call);

pub const Scope = union(enum) {
    root,
    closest,
    group: Name,
};

pub const TaskCall = struct {
    node: *const cst.Node,
    scope: Scope,
    task: Name,
    args: TaskCallArgs,

    pub fn from(node: *const cst.Node) TaskCall {
        var it = node.iter();

        const scope: Scope, const task: Name = blk: {
            var path = it.expectNode(.path).?.iter();

            if (path.eatToken(.dcolon) != null) {
                const t = expectNode(&path, Name, .name_ref) orelse unreachable;
                break :blk .{ .root, t };
            }

            const first = expectNode(&path, Name, .name_ref) orelse unreachable;
            if (path.eatToken(.dcolon) == null) {
                break :blk .{ .closest, first };
            }

            const second = expectNode(&path, Name, .name_ref) orelse unreachable;

            break :blk .{
                .{ .group = first },
                second,
            };
        };

        const args: TaskCallArgs = expectNode(&it, TaskCallArgs, .task_call_args).?;
        return .{ .node = node, .scope = scope, .task = task, .args = args };
    }
};

pub const TaskCallArgs = KindIterable(.strict, TaskCallArg, .task_call_arg);

pub const TaskCallArg = struct {
    node: *const cst.Node,
    name: ?Name,
    value: ?Expr,

    pub fn from(node: *const cst.Node) TaskCallArg {
        var it = node.iter();
        const name = expectNode(&it, Name, .name);
        const value = expectAnyNode(&it, Expr, Expr.KINDS);
        return .{ .node = node, .name = name, .value = value };
    }
};

//============================================================
// statements
//============================================================

pub const Statements = AnyKindIterable(.loose, Statement, Statement.KINDS);

pub const Statement = struct {
    const KINDS: []const cst.NodeKind = &.{
        .binding,   .process, .task_call,
        .@"for",    .@"if",   .@"switch",
        .expr_stmt,
    };
    node: *const cst.Node,

    pub const Kind = union(enum) {
        binding: BindingDecl,
        process: Process,
        task_call: TaskCall,
        @"for": ForStmt,
        @"if": IfStmt,
        @"switch": SwitchStmt,
        expr: ?Expr,
    };

    pub fn from(node: *const cst.Node) Statement {
        return .{ .node = node };
    }

    pub fn classify(self: *const Statement) Kind {
        return switch (self.node.kind) {
            .binding => .{ .binding = .from(self.node) },
            .process => .{ .process = .from(self.node) },
            .task_call => .{ .task_call = .from(self.node) },
            .@"for" => .{ .@"for" = .from(self.node) },
            .@"if" => .{ .@"if" = .from(self.node) },
            .@"switch" => .{ .@"switch" = .from(self.node) },
            .expr_stmt => .{
                .expr = if (self.node.childNodeOf(Expr.KINDS)) |n| .from(n) else null,
            },
            else => unreachable,
        };
    }
};

pub const SwitchStmt = struct {
    node: *const cst.Node,
    subject: ?Expr,
    body: SwitchStmtBody,

    pub fn from(node: *const cst.Node) SwitchStmt {
        var it = node.iter();

        const subject = expectAnyNode(&it, Expr, Expr.KINDS);
        const body = expectNode(&it, SwitchStmtBody, .switch_body) orelse unreachable;

        return .{
            .node = node,
            .subject = subject,
            .body = body,
        };
    }
};

pub const SwitchStmtBody = KindIterable(.loose, SwitchStmtCase, .switch_case);

pub const SwitchStmtCase = struct {
    node: *const cst.Node,
    pattern: SwitchPattern,
    body: Statements,

    pub fn from(node: *const cst.Node) SwitchStmtCase {
        var it = node.iter();

        const pattern = expectNode(&it, SwitchPattern, .switch_case_pattern) orelse unreachable;
        const body = expectNode(&it, Statements, .stmt_block) orelse unreachable;

        return .{
            .node = node,
            .pattern = pattern,
            .body = body,
        };
    }
};

pub const IfStmt = struct {
    node: *const cst.Node,
    cond: ?Expr,
    then: Statements,
    @"else": ?Statements,

    pub fn from(node: *const cst.Node) IfStmt {
        var it = node.iter();

        const cond = expectAnyNode(&it, Expr, Expr.KINDS);
        const then = expectNode(&it, Statements, .stmt_block) orelse unreachable;
        const @"else" = eatNode(&it, Statements, .stmt_block);

        return .{
            .node = node,
            .cond = cond,
            .then = then,
            .@"else" = @"else",
        };
    }
};

pub const ForStmt = struct {
    node: *const cst.Node,
    subjects: Subjects,
    captures: Captures,
    body: Statements,

    pub fn from(node: *const cst.Node) ForStmt {
        var it = node.iter();

        const subjects = expectNode(&it, Subjects, .subjects) orelse unreachable;
        const captures = expectNode(&it, Captures, .captures) orelse unreachable;
        const body = expectNode(&it, Statements, .stmt_block) orelse unreachable;

        return .{
            .node = node,
            .subjects = subjects,
            .captures = captures,
            .body = body,
        };
    }
};

pub const Process = struct {
    node: *const cst.Node,
    string: StringExpr,

    pub fn from(node: *const cst.Node) Process {
        const string = node.childNode(.string_expr) orelse unreachable;
        return .{ .node = node, .string = .from(string) };
    }
};
