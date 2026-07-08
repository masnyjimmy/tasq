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
        id: SpanId,
        name: []const u8,
        value: ?MetaValue,
    };
    id: SpanId,
    attrs: []Attribute,
    body: []SetDecl,
};
pub const Group = struct {
    id: SpanId,
    name: []const u8,
    attrs: []Attribute,
    args: []Argument,
    decls: []Decl,
    tasks: []Task,
};

pub const Task = struct {
    id: SpanId,
    name: []const u8,
    attrs: []Attribute,
    args: []Argument,
    body: StatementBlock,
};

pub const Argument = struct {
    id: SpanId,
    name: []const u8,
    attrs: []Attribute,
    type: ArgType,
    default: ?Expr,
};

pub const Attribute = struct {
    id: SpanId,
    name: []const u8,
    value: ?MetaValue,
};

pub const Decl = struct {
    id: SpanId,
    name: []const u8,
    value: Expr,
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
    id: SpanId,
    cond: Expr, // [Span] Node.object
    then: StatementBlock,
    else_: ?StatementBlock,
};

pub const ProcessStmt = StringExpr;

pub const TaskCallScope = union(enum) {
    closest,
    root,
    group: []const u8, // [Span] TaskCall::extra
};

pub const TaskCall = struct {
    id: SpanId,
    scope: TaskCallScope, // null for same-group calls
    task: []const u8, // [Span] This::name
    args: []TaskCallArg,
};

pub const TaskCallArg = struct {
    id: SpanId,
    name: ?[]const u8,
    value: Expr,
};

pub const Expr = union(enum) {
    bool_lit: bool,
    number_lit: f64,
    char_lit: u21,
    string: StringExpr,
    list: []const Expr,
    builtin_call: BuiltInCall,
    ident: []const u8,
    binary: *BinaryExpr,
    unary: *UnaryExpr,
    if_expr: *IfExpr,

    // TODO: consider if this can be removed
    pub fn spanStart(self: Expr) u32 {
        return self.span().start;
    }
};

pub const BuiltInCall = struct {
    id: SpanId,
    name: []const u8,
    args: []Expr,
};

pub const StringExpr = union(enum) { lit: []const u8, inter: []const InterStringSeg };

pub const InterStringSeg = union(enum) {
    lit: []const u8,
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
