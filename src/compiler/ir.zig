// src/compiler/ir.zig

const std = @import("std");
const ast = @import("ast.zig");
const functions = @import("functions.zig");
const typing = @import("typing.zig");
const attrib = @import("attributes.zig");
const opt = @import("options.zig");

const Symbol = @import("symbol.zig").Symbol;
const Scope = @import("scope.zig").Scope;

pub const Type = typing.Type;
const ArgType = typing.ArgType;

const TaskId = @import("taskId.zig");

pub const File = struct {
    // TODO: implement
    scope: *Scope,
    options: Options,
    decls: []*Decl,
    groups: []*Group,
    tasks: []*Task,

    pub fn findTask(self: *const File, task_id: TaskId) ?*Task {
        const scope = blk: {
            if (task_id.groupName) |group_name| {
                if (self.scope.resolve(group_name, .group)) |group|
                    break :blk group.details.group.origin.scope;

                return null;
            }

            break :blk self.scope;
        };

        if (scope.resolveLocal(task_id.name, .task)) |task| {
            return task.details.task.origin;
        }

        return null;
    }

    pub fn getGroup(self: *const File, groupName: []const u8) ?*Group {
        for (self.groups) |group| {
            if (group.name) |gname|
                if (std.mem.eql(u8, gname, groupName))
                    return group;
        }

        return null;
    }

    pub fn getTask(self: *const File, name: []const u8, groupName: ?[]const u8) ?*Task {
        if (groupName) |gn| {
            if (self.getGroup(gn)) |group| {
                return group.getTask(name);
            }
        } else {
            for (self.tasks) |task| {
                if (std.mem.eql(u8, task.name, name)) {
                    return task;
                }
            }
        }
        return null;
    }
};

pub const Options = struct {
    shell: []const []const u8,
};

// pub const SetDecl = struct {
//     option: opt.OptionId,
//     payload: opt.OptionPayload,
// };

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

const ResolvedTaskAttributes = std.EnumMap(attrib.TaskAttributeType, attrib.TaskAttributeValue);

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
    type: typing.ArgType,
    default: ?typing.Value,
    is_positional: bool,

    short: ?u8,
    long: ?[]const u8,
    desc: ?[]const u8,

    pattern: ?[]const u8,

    int: bool,
};

pub const InterStringSeg = union(enum) {
    lit: []const u8,
    expr: Expr,
};

pub const String = union(enum) {
    lit: []const u8,
    inter: []InterStringSeg,
};

//=========== Statements ===============

//TODO: remove statement block - useless

pub const StatementBlock = struct {
    scope: *Scope,
    statements: []Statement,
};

pub const Statement = union(enum) {
    decl: *Decl,
    process: ProcessStmt,
    task_call: TaskCall,
    if_stmt: IfStmt,
    switch_stmt: SwitchStmt,
    expr: Expr,
};

pub const SwitchStmt = struct {
    pub const CasesStorage = std.hash_map.HashMapUnmanaged(
        typing.Value,
        StatementBlock,
        typing.ValueContext,
        60,
    );

    subject: Expr,
    cases: CasesStorage,
    else_case: StatementBlock,
};

pub const Decl = struct {
    name: []const u8,
    value: Expr,
    type: Type,
    scope: *Scope, //TODO: consider moving it into symbol details, or somewhere else
    is_static: bool, // inferred by sema
};

pub const ProcessStmt = String;

pub const TaskCall = struct {
    task: *Task,
    args: TaskCallArgs,

    pub fn debugDump(self: *const TaskCall) struct {
        group: ?[]const u8,
        task: []const u8,
        args: TaskCallArgs,
    } {
        return .{
            .group = if (self.task.group) |g| g.name else null,
            .task = self.task.name,
            .args = self.args,
        };
    }
};

pub const TaskCallArgs = std.StringHashMap(Expr);

pub const IfStmt = struct {
    cond: Expr,
    then: StatementBlock,
    else_: ?StatementBlock,
};
//========== expressions =============

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
    char_lit: u21,
    number_lit: f64,
    bool_lit: bool,
    list: List,
    ident: ResolvedIdent, // name + what it resolved to
    binary: *BinaryExpr,
    unary: *UnaryExpr,
    if_expr: *IfExpr,
    switch_expr: *SwitchExpr,
    builtin_call: BuiltinCall,
};

// after sema, ident carries its resolved symbol — no more string lookup at runtime
pub const ResolvedIdent = struct {
    name: []const u8,
    symbol: *Symbol,
};

pub const BuiltinCall = struct {
    id: functions.definitions.Type,
    args: []Expr,
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

pub const IfExpr = struct {
    cond: Expr,
    then: Expr,
    else_: Expr,
    type: Type, // both branches must match — filled by sema
};

pub const SwitchExpr = struct {
    pub const CasesStorage = std.hash_map.HashMapUnmanaged(
        typing.Value,
        Expr,
        typing.ValueContext,
        60,
    );
    subject: Expr,
    cases: CasesStorage,
    else_case: Expr,
};
