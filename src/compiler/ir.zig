// src/compiler/ir.zig

const std = @import("std");
const ast = @import("ast.zig");
const functions = @import("functions.zig");

const @"type" = @import("type.zig");
const Type = @"type".Type;
const ArgType = @"type".ArgType;

const value = @import("value.zig");
const Value = value.Value;

const attrib = @import("attributes.zig");
const opt = @import("options.zig");

const Symbol = @import("symbol.zig").Symbol;
const Scope = @import("scope.zig").Scope;

const TaskId = @import("taskId.zig");

pub const File = struct {
    scope: *Scope,
    options: Options,
    decls: []*Decl,
    groups: []*Group,
    tasks: []*Task,

    pub fn findGroup(self: *const File, group: []const u8) ?*Group {
        return self.scope.resolve(group, .group);
    }

    pub fn findTask(self: *const File, task_id: TaskId) ?*Task {
        const scope = blk: {
            if (task_id.groupName) |group_name| {
                if (self.scope.resolve(group_name, .group)) |symbol|
                    break :blk symbol.origin.group.scope;

                return null;
            }

            break :blk self.scope;
        };

        if (scope.resolveLocal(task_id.name, .task)) |task| {
            return task.origin.task;
        }

        return null;
    }
};

/// compiled settings
pub const Options = struct {
    shell: []const []const u8,
};

pub const Group = struct {
    name: ?[]const u8, // null = anonymous
    args: []*Argument,
    decls: []*Decl,
    tasks: []*Task,
    scope: *Scope,
    desc: ?[]const u8,

    pub fn getTask(self: *const Group, name: []const u8) ?*Task {
        for (self.tasks) |task| {
            if (std.mem.eql(u8, task.name, name))
                return task;
        }

        return null;
    }
};

pub const Task = struct {
    ast_ref: *const ast.Task,
    name: []const u8,
    args: []*Argument,
    private: bool,
    desc: ?[]const u8,
    body: StatementBlock,
    group: ?*Group = null,
};

// resolved argument — attributes unpacked into concrete fields
pub const Argument = struct {
    name: []const u8,
    type: ArgType,
    default: ?Value,
    is_positional: bool,

    short: ?u8,
    long: ?[]const u8,
    desc: ?[]const u8,

    pattern: ?[]const u8,

    int: bool,
};

//=========== Statements ===============

pub const StatementBlock = struct {
    scope: *Scope,
    statements: []Statement,
};

pub const Statement = union(enum) {
    decl: *Decl,
    process: ProcessStmt,
    task_call: TaskCall,
    for_stmt: ForStmt,
    switch_stmt: SwitchStmt,
    if_stmt: IfStmt,
    expr: Expr, // else
};

pub const Capture = struct {
    name: []const u8,
    type: Type,
};

pub const ForStmt = struct {
    subjects: []const Expr,
    captures: []?*Capture,
    body: StatementBlock,
};

pub const SwitchStmt = struct {
    pub const CasesStorage = SwitchCasesStorage(StatementBlock);

    subject: Expr,
    cases: CasesStorage,
    else_case: ?StatementBlock,
};

pub const IfStmt = struct {
    cond: Expr,
    then: StatementBlock,
    else_: ?StatementBlock,
};

pub const Decl = struct {
    name: []const u8,
    value: Expr,
    type: Type,
    scope: *Scope,
    is_static: bool, // inferred by sema
};

pub const ProcessStmt = String;

pub const TaskCall = struct {
    pub const Arg = union(enum) {
        default: Value,
        value: Expr,
    };

    pub const ArgsMap = std.array_hash_map.String(Arg);
    task: *Task,
    args: ArgsMap,

    // pub fn debugDump(self: *const TaskCall) struct {
    //     group: ?[]const u8,
    //     task: []const u8,
    //     args: TaskCallArgs,
    // } {
    //     return .{
    //         .group = if (self.task.group) |g| g.name else null,
    //         .task = self.task.name,
    //         .args = self.args,
    //     };
    // }
};

//=============== expressions ==================

pub const Expr = union(enum) {
    pub const List = struct {
        pub const Item = struct {
            expr: *Expr,
            is_spread: bool,
        };
        items_type: Type,
        items: []const Item,
    };

    string: String,
    number_lit: f64,
    bool_lit: bool,
    list: List,
    ident: ResolvedIdent, // name + what it resolved to
    binary: *BinaryExpr,
    unary: *UnaryExpr,
    if_expr: *IfExpr,
    switch_expr: *SwitchExpr,
    for_expr: *ForExpr,
    builtin_call: *BuiltinCall,
    lambda: *Lambda,
    @"continue",
    @"break",
};

pub const Lambda = struct {
    captures: []const Capture,
    body: Expr,
    scope: *Scope,
};

pub const ForExpr = struct {
    subjects: []const Expr,
    captures: []?*Capture,
    scope: *Scope,
    body: Expr,
    type: Type,
};

pub const SwitchExpr = struct {
    pub const CasesStorage = SwitchCasesStorage(Expr);
    subject: Expr,
    cases: CasesStorage,
    else_case: Expr,
    type: Type,
};

pub fn SwitchCasesStorage(comptime T: type) type {
    return std.hash_map.HashMapUnmanaged(
        Value,
        T,
        Value.MapContext,
        60,
    );
}

pub const IfExpr = struct {
    cond: Expr,
    then: Expr,
    @"else": Expr,
    type: Type, // both branches must match — filled by sema
};

pub const String = []const StringPart;

pub const StringPart = union(enum) {
    lit: []const u8,
    expr: Expr,
};

// after sema, ident carries its resolved symbol — no more string lookup at runtime
pub const ResolvedIdent = struct {
    name: []const u8,
    symbol: *Symbol,
};

pub const BuiltinCall = struct {
    function: functions.ResolvedFunction,
    args: []Expr,
    fallback: ?Expr,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: Expr,
    right: Expr,
    type: Type, // result type — filled by sema
};

pub const BinaryOp = ast.BinaryOp;

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: Expr,
    type: Type,
};

pub const UnaryOp = ast.UnaryOp;
