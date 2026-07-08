const std = @import("std");

const Diagnostics = @import("Diagnostics.zig");
const Span = @import("span.zig");

const SpanId = Span.Registry.SpanId;

const typing = @import("typing.zig");

pub const ArgType = typing.ArgType;

pub fn hasAttr(attrs: []const Attribute, name: []const u8) bool {
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.name.value, name))
            return true;
    }
    return false;
}

pub const File = struct {
    options: []Set,
    decls: []Decl,
    groups: []Group,
    tasks: []Task,
    span: Span,
};

pub const Set = struct {
    pub const SetDecl = struct {
        name: WithSpan([]const u8),
        value: ?MetaValue,
        span: Span,
    };

    attrs: []Attribute,
    body: []SetDecl,
    span: Span,
};
pub const Group = struct {
    name: ?WithSpan([]const u8),
    attrs: []Attribute,
    args: []Argument,
    decls: []Decl,
    tasks: []Task,
    span: Span,
};

pub const Task = struct {
    name: WithSpan([]const u8),
    attrs: []Attribute,
    args: []Argument,
    body: StatementBlock,
    span: Span,
};

pub const Argument = struct {
    name: WithSpan([]const u8),
    attrs: []Attribute,
    type: WithSpan(ArgType),
    default: ?Expr,
    span: Span,
};

pub const Attribute = struct {
    name: WithSpan([]const u8),
    value: ?MetaValue,
    span: Span,
};

pub const Decl = struct {
    name: WithSpan([]const u8),
    value: Expr,
    span: Span,
};

pub const StatementBlock = []Statement;

pub const Statement = union(enum) {
    process: ProcessStmt, // `echo {{name}}`
    task_call: TaskCall, // build  or  go.build
    decl: Decl, // declaration
    if_stmt: IfStmt,
    // for_stmt: forStmt,
};

// 'IF' DOESNT CREATE SCOPE
pub const IfStmt = struct {
    cond: Expr,
    then: StatementBlock,
    else_: ?StatementBlock,
};

pub const ProcessStmt = StringExpr;

pub const TaskCallScope = union(enum) {
    closest,
    root,
    group: WithSpan([]const u8),
};

pub const TaskCall = struct {
    scope: TaskCallScope, // null for same-group calls
    task: WithSpan([]const u8),
    args: []TaskCallArg,
    span: Span,
};

pub const TaskCallArg = struct {
    name: ?[]const u8,
    value: Expr,
    span: Span,
};

pub const Expr = union(enum) {
    bool_lit: WithSpan(bool),
    number_lit: WithSpan(f64),
    char_lit: WithSpan(u21),
    string: WithSpan(StringExpr),
    list: WithSpan([]const Expr),
    builtin_call: BuiltInCall,
    ident: WithSpan([]const u8),
    binary: *BinaryExpr,
    unary: *UnaryExpr,
    if_expr: *IfExpr,

    pub fn span(self: Expr) Span {
        return switch (self) {
            .bool_lit => |v| v.span,
            .char_lit => |v| v.span,
            .number_lit => |v| v.span,
            .string => |v| v.span,
            .list => |v| v.span,
            .builtin_call => |v| v.span,
            .ident => |v| v.span,
            .binary => |v| v.span,
            .unary => |v| v.span,
            .if_expr => |v| v.span,
        };
    }

    // TODO: consider if this can be removed
    pub fn spanStart(self: Expr) u32 {
        return self.span().start;
    }
};

pub const BuiltInCall = struct {
    name: WithSpan([]const u8),
    args: []Expr,
    span: Span,
};

pub const StringExpr = union(enum) { lit: WithSpan([]const u8), inter: []const InterStringSeg };

pub const InterStringSeg = union(enum) {
    lit: WithSpan([]const u8),
    expr: Expr,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: Expr,
    right: Expr,
    span: Span,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    eq,
    neq,
    lt,
    gt,
    lt_eq,
    gt_eq,
    and_op,
    or_op,

    pub fn format(self: @This(), w: *std.Io.Writer) !void {
        try w.print("{s}", .{@tagName(self)});
    }
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: Expr,
    span: Span,
};

pub const UnaryOp = enum { not_op, negate };

pub const IfExpr = struct {
    cond: Expr,
    then: Expr,
    else_: Expr,
    span: Span,
};

pub const MetaTypeTag = enum {
    null,
    bool,
    number,
    char,
    string,
    list,
};

pub const MetaType = union(MetaTypeTag) {
    null,
    bool,
    number,
    char,
    string,
    list: *const MetaType,

    pub fn format(self: @This(), w: *std.Io.Writer) !void {
        switch (self) {
            .list => |l| try w.print("[]{f}", .{l.*}),
            else => try w.print("{s}", .{@tagName(self)}),
        }
    }
};

pub const MetaValue = union(MetaTypeTag) {
    null,
    bool: bool,
    number: f64,
    char: u8,
    string: []const u8,
    list: []const MetaValue,

    pub fn validateType(self: *const MetaValue, target_type: MetaType) bool {
        const T: MetaTypeTag = blk: {
            const self_tag = std.meta.activeTag(self.*);
            const target_tag = std.meta.activeTag(target_type);

            if (self_tag != target_tag) {
                return false;
            }
            break :blk self_tag;
        };

        switch (T) {
            .list => {
                for (self.list) |item| {
                    if (item.validateType(target_type.list.*) == false) {
                        return false;
                    }
                }
                return true;
            },
            else => return true,
        }
    }
};
