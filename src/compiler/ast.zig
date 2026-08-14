const std = @import("std");

const Diagnostics = @import("Diagnostics.zig");
const Span = @import("span.zig");

const NodeId = Span.Registry.NodeId;

const @"type" = @import("type.zig");

pub const ArgType = @"type".ArgType;

pub fn hasAttr(attrs: []const Attribute, name: []const u8) bool {
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.name, name))
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
        id: NodeId,
        name: []const u8,
        value: ?MetaValue,
    };
    id: NodeId,
    attrs: []Attribute,
    body: []SetDecl,
};

pub const Group = struct {
    id: NodeId,
    name: ?[]const u8,
    attrs: []Attribute,
    args: []Argument,
    decls: []Decl,
    tasks: []Task,
};

pub const Task = struct {
    id: NodeId,
    name: []const u8,
    attrs: []Attribute,
    args: []Argument,
    body: StatementBlock,
};

pub const Attribute = struct {
    id: NodeId,
    name: []const u8,
    value: ?MetaValue,
};

pub const Argument = struct {
    id: NodeId,
    name: []const u8,
    attrs: []Attribute,
    type: ArgType,
    default: ?Expr,
};

//================= Statements ===================

pub const StatementBlock = []Statement;

pub const Statement = union(enum) {
    process: ProcessStmt, // `echo {{name}}`
    task_call: TaskCall, // build  or  go.build
    decl: Decl, // declaration
    if_stmt: IfStmt,
    switch_stmt: SwitchStmt,
    expr: Expr,
    for_stmt: ForStmt,
};

pub const Decl = struct {
    id: NodeId,
    name: []const u8,
    value: Expr,
};

pub const ForStmt = ForCommon(StatementBlock);

pub const SwitchStmt = SwitchCommon(StatementBlock);

pub const IfStmt = IfCommon(StatementBlock);

pub const ProcessStmt = String;

pub const TaskCall = struct {
    pub const Scope = union(enum) {
        closest,
        root,
        group: []const u8, // [Span] TaskCall::extra
    };
    pub const Arg = struct {
        id: NodeId,
        name: ?[]const u8,
        value: Expr,
    };

    id: NodeId,
    scope: Scope, // null for same-group calls
    task: []const u8, // [Span] This::name
    args: []const Arg,
};

//================= Expressions ===================

pub const Expr = union(enum) {
    pub const ListItem = struct {
        expr: *Expr,
        is_spread: bool,
    };

    bool_lit: bool,
    number_lit: f64,
    char_lit: u21,
    string: String,
    list: []const ListItem,
    builtin_call: BuiltInCall,
    ident: []const u8,
    binary: *BinaryExpr,
    unary: *UnaryExpr,
    if_expr: *IfExpr,
    switch_expr: *SwitchExpr,
    for_expr: *ForExpr,
    @"continue",
    @"break",
};

pub const ForExpr = ForCommon(Expr);

pub const SwitchExpr = SwitchCommon(Expr);

/// [span] wrapped in brackets
pub const IfExpr = IfCommon(Expr);

pub const BuiltInCall = struct {
    id: NodeId,
    name: []const u8,
    args: []Expr,
};

pub const String = []const StringPart;

pub const StringPart = union(enum) {
    lit: []const u8,
    expr: Expr,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: Expr,
    right: Expr,
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
};

pub const UnaryOp = enum { not_op, negate };

pub fn ForCommon(comptime BodyT: type) type {
    return struct {
        id: NodeId,
        subjects: []const Expr,
        captures: []?[]const u8,
        body: BodyT,
    };
}

pub fn SwitchCommon(comptime BranchT: type) type {
    return struct {
        pub const Pattern = union(enum) {
            expr: []const Expr,
            @"else",
        };

        pub const Case = struct {
            id: NodeId,
            pattern: Pattern,
            body: BranchT,
        };

        id: NodeId,
        subject: Expr,
        cases: []const Case,
    };
}

pub fn IfCommon(comptime BranchT: type) type {
    return struct {
        id: NodeId,
        cond: Expr,
        then: BranchT,
        @"else": ?BranchT,
    };
}

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
