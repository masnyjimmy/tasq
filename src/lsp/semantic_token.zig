const std = @import("std");

const lib = @import("lib");
const compiler = @import("compiler");
const ast = compiler.ast;

const Span = compiler.Span;
const NodeId = Span.Registry.NodeId;

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
    span_registry: *const Span.Registry,

    const Error = std.mem.Allocator.Error;

    pub fn collect(allocator: std.mem.Allocator, file: *const ast.File, scope: *const Scope, span_registry: *const Span.Registry) Error![]RawToken {
        var collector: Collector = .init(allocator, span_registry);

        // handle flat spans first
        for (span_registry.spans.items) |span_item| {
            const tt = lib.enums.castEnum(span_item.type, TokenType) orelse unreachable;

            try collector.add(span_item.span, tt, null);
        }

        try collector.walkFile(file, scope);

        const validate = comptime switch (@import("builtin").mode) {
            .Debug, .ReleaseSafe => true,
            else => false,
        };

        const out = try collector.tokens.toOwnedSlice(allocator);

        try sortTokens(out);

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
    fn init(allocator: std.mem.Allocator, span_registry: *const Span.Registry) Collector {
        return .{
            .allocator = allocator,
            .tokens = .empty,
            .span_registry = span_registry,
        };
    }

    fn add(self: *Collector, span: Span, ttype: TokenType, mods: ?[]const TokenModifier) Error!void {
        try self.tokens.append(self.allocator, .make(span, ttype, mods orelse &.{}));
    }

    fn walkFile(self: *Collector, file: *const ast.File, scope: *const Scope) Error!void {
        for (file.decls) |*decl| {
            try self.walkDecl(decl, scope);
        }

        for (file.options) |*opt| {
            try self.walkSet(opt);
        }

        for (file.groups) |*group| {
            try self.walkGroup(group, scope);
        }

        for (file.tasks) |*task| {
            try self.walkTask(task, scope);
        }
    }

    fn walkSet(self: *Collector, set: *const ast.Set) Error!void {
        for (set.attrs) |*attr| {
            try self.walkAttribute(attr);
        }
    }

    fn walkGroup(self: *Collector, group: *const ast.Group, scope: *const Scope) Error!void {
        const span_node = self.span_registry.get(group.id);
        const group_span_node = span_node.details.group;

        if (group_span_node.name) |span| {
            try self.add(span, .namespace, null);
        }

        for (group.args) |*arg| {
            try self.walkArgument(arg);
        }

        for (group.attrs) |*attr| {
            try self.walkAttribute(attr);
        }

        const group_scope = if (group.name) |_|
            scope.child(group.id).?
        else
            scope;

        for (group.decls) |*decl| {
            try self.walkDecl(decl, group_scope);
        }
        for (group.tasks) |*task| {
            try self.walkTask(task, group_scope);
        }
    }

    fn walkTask(self: *Collector, task: *const ast.Task, scope: *const Scope) Error!void {
        const span_node = self.span_registry.get(task.id);

        try self.add(span_node.details.task.name, .function, null);

        for (task.attrs) |*attr| {
            try self.walkAttribute(attr);
        }

        for (task.args) |*arg| {
            try self.walkArgument(arg);
        }

        const task_scope = scope.child(task.id).?;

        for (task.dependencies) |*dep| {
            try self.walkTaskCall(dep, task_scope);
        }

        const stmts_spans = self.span_registry.get(span_node.details.task.body).details.block;

        const task_body_scope = task_scope.child(task.id).?;

        for (task.body, stmts_spans.stmts) |*stmt, stmt_node_id| {
            try self.walkStatement(stmt, task_body_scope, stmt_node_id);
        }
    }

    fn walkStatement(self: *Collector, stmt: *const ast.Statement, scope: *const Scope, node_id: NodeId) Error!void {
        switch (stmt.*) {
            .process => |v| try self.walkStringExpr(&v, scope, node_id),
            .decl => |v| try self.walkDecl(&v, scope),
            .task_call => |v| try self.walkTaskCall(&v, scope),
            .if_stmt => |v| try self.walkIfStmt(&v, scope),
            .switch_stmt => |s| try self.walkSwitchStmt(&s, scope),
            .for_stmt => |f| try self.walkForStmt(&f, scope),
            .expr => |e| try self.walkExpr(&e, scope, node_id),
        }
    }

    fn walkForStmt(self: *Collector, for_stmt: *const ast.ForStmt, scope: *const Scope) Error!void {
        const for_node = self.span_registry.get(for_stmt.id);

        const for_scope = scope.child(for_stmt.id).?;

        for (for_stmt.subjects, for_node.details.@"for".subjects) |sub, sub_node| {
            try self.walkExpr(&sub, for_scope, sub_node);
        }

        const body = self.span_registry.get(for_node.details.@"for".body).details.block;
        for (for_stmt.body, body.stmts) |stmt, stmt_node| {
            try self.walkStatement(&stmt, for_scope, stmt_node);
        }
    }

    fn walkSwitchStmt(self: *Collector, switch_stmt: *const ast.SwitchStmt, scope: *const Scope) Error!void {
        const switch_node = self.span_registry.get(switch_stmt.id);

        try self.walkExpr(&switch_stmt.subject, scope, switch_node.details.@"switch".subject);

        for (switch_stmt.cases) |case| {
            const case_node = self.span_registry.get(case.id).details.switch_case;
            const case_body_node = self.span_registry.get(case_node.body).details.block.stmts;
            for (case.body, case_body_node) |*stmt, node| {
                try self.walkStatement(stmt, scope, node);
            }
        }
    }

    fn walkIfStmt(self: *Collector, if_stmt: *const ast.IfStmt, scope: *const Scope) Error!void {
        const span_node = self.span_registry.get(if_stmt.id);
        const if_spans = span_node.details.@"if";

        try self.walkExpr(&if_stmt.cond, scope, if_spans.cond);

        const then_scope = scope.child(if_spans.then).?;
        const then_spans = self.span_registry.get(if_spans.then).details.block;

        for (if_stmt.then, then_spans.stmts) |stmt, stmt_span| {
            try self.walkStatement(&stmt, then_scope, stmt_span);
        }

        const else_scope = scope.child(if_spans.else_.?).?;
        const else_spans = self.span_registry.get(if_spans.else_.?).details.block;

        for (if_stmt.@"else".?, else_spans.stmts) |stmt, stmt_span| {
            try self.walkStatement(&stmt, else_scope, stmt_span);
        }
    }

    fn walkTaskCall(self: *Collector, task_call: *const ast.TaskCall, scope: *const Scope) Error!void {
        const span_node = self.span_registry.get(task_call.id);
        const task_call_spans = span_node.details.task_call;

        if (task_call_spans.group) |group| {
            try self.add(group, .namespace, null);
        }

        try self.add(task_call_spans.task, .function, null);

        for (task_call.args) |*arg| {
            try self.walkTaskCallArgs(arg, scope);
        }
    }

    fn walkTaskCallArgs(self: *Collector, args: *const ast.TaskCall.Arg, scope: *const Scope) Error!void {
        const span_node = self.span_registry.get(args.id);
        const arg_spans = span_node.details.task_call_arg;

        if (arg_spans.name) |name| {
            try self.add(name, .variable, null);
        }

        try self.walkExpr(&args.value, scope, arg_spans.value);
    }

    fn walkArgument(self: *Collector, arg: *const ast.Argument) Error!void {
        const span_node = self.span_registry.get(arg.id);

        try self.add(span_node.details.argument.name, .parameter, null);

        for (arg.attrs) |*attr| {
            try self.walkAttribute(attr);
        }

        // if (span_node.details.argument.default) |*def| {
        //     try self.walkExpr(def);
        // }

        // type already added
        // try self.add(span_node.details.argument.type, .type, null);
    }

    fn walkAttribute(self: *Collector, attr: *const ast.Attribute) Error!void {
        const span_node = self.span_registry.get(attr.id);

        const attr_def = compiler.attributes.definitions.get(attr.name, null) orelse return;

        const mod: TokenModifier = blk: {
            break :blk switch (attr_def.kind) {
                .platform => if (attr_def.type == CURRENT_PLATFORM_ATTRIBUTE_ID)
                    TokenModifier.attr_current_platform
                else
                    TokenModifier.attr_platform,
                inline else => |tag| {
                    const name = "attr_" ++ @tagName(tag);
                    const ti = @typeInfo(TokenModifier).@"enum";
                    inline for (ti.fields) |f| {
                        if (std.mem.eql(u8, f.name, name))
                            break :blk @enumFromInt(f.value);
                    } else unreachable;
                },
            };
        };

        try self.add(span_node.details.attribute.name, .decorator, &.{mod});

        if (attr.value) |_| {
            //TODO: implement
            // may be handles as flat spans?
        }
    }

    fn walkDecl(self: *Collector, decl: *const ast.Decl, scope: *const Scope) Error!void {
        const span_node = self.span_registry.get(decl.id).details.decl;
        try self.add(span_node.name, .variable, &.{TokenModifier.declaration});
        try self.walkExpr(&decl.value, scope, span_node.value);
    }

    fn walkExpr(self: *Collector, expr: *const ast.Expr, scope: *const Scope, id: NodeId) Error!void {
        switch (expr.*) {
            .string => |str| {
                try self.walkStringExpr(&str, scope, id);
            },
            .list => |list| {
                const items_spans = self.span_registry.get(id).details.expr.list;
                for (list, items_spans) |item, item_span| {
                    try self.walkExpr(item.expr, scope, item_span);
                }
            },
            .ident => |ident| {
                const is_param = blk: {
                    if (scope.resolve(ident, .variable)) |sym| switch (sym.origin) {
                        .argument, .capture => break :blk true,
                        else => {},
                    };

                    break :blk false;
                };

                if (is_param) {
                    try self.add(self.span_registry.getSpan(id), .parameter, &.{});
                } else {
                    try self.add(self.span_registry.getSpan(id), .variable, &.{});
                }
            },
            .binary => |binary| {
                const binary_spans = self.span_registry.get(id).details.expr.binary;
                try self.walkExpr(&binary.left, scope, binary_spans.left);
                try self.walkExpr(&binary.right, scope, binary_spans.right);
            },
            .unary => |unary| {
                const unary_spans = self.span_registry.get(id).details.expr.unary;
                try self.walkExpr(&unary.operand, scope, unary_spans.operand);
            },
            .if_expr => |if_expr| {
                const if_spans = self.span_registry.get(if_expr.id).details.@"if";
                try self.walkExpr(&if_expr.cond, scope, if_spans.cond);
                try self.walkExpr(&if_expr.then, scope, if_spans.then);
                try self.walkExpr(&if_expr.@"else".?, scope, if_spans.else_.?);
            },
            .switch_expr => |switch_expr| {
                const switch_spans = self.span_registry.get(switch_expr.id).details.@"switch";

                try self.walkExpr(&switch_expr.subject, scope, switch_spans.subject);

                for (switch_expr.cases) |case| {
                    const case_spans = self.span_registry.get(case.id).details.switch_case;

                    switch (case.pattern) {
                        .expr => |patterns| {
                            for (patterns, case_spans.patterns) |pattern, span| {
                                try self.walkExpr(&pattern, scope, span);
                            }
                        },
                        else => {},
                    }

                    try self.walkExpr(&case.body, scope, case_spans.body);
                }
            },
            .for_expr => |for_expr| {
                const for_spans = self.span_registry.get(for_expr.id).details.@"for";

                const for_scope = scope.child(for_expr.id).?;

                for (for_expr.subjects, for_spans.subjects) |subject, subject_span| {
                    try self.walkExpr(&subject, scope, subject_span);
                }

                for (for_expr.captures, for_spans.captures) |capture, capture_span| {
                    if (capture) |_| {
                        try self.add(capture_span, .parameter, &.{.declaration});
                    }
                }

                try self.walkExpr(&for_expr.body, for_scope, for_spans.body);
            },
            .builtin_call => |call| {
                const builtin_call_spans = self.span_registry.get(id).details.builtin_call;
                try self.add(
                    builtin_call_spans.name,
                    .builtin,
                    null,
                );

                for (call.args, builtin_call_spans.args) |arg, arg_span| {
                    try self.walkExpr(&arg, scope, arg_span);
                }
            },
            .lambda => |lambda| {
                const lambda_spans = self.span_registry.get(lambda.id).details.lambda;

                for (lambda.params, lambda_spans.params) |_, param_span| {
                    try self.add(param_span, .parameter, &.{.declaration});
                }

                const lambda_scope = scope.child(lambda.id).?;

                try self.walkExpr(&lambda.body, lambda_scope, lambda_spans.body);
            },
            else => {},
        }
    }

    fn walkStringExpr(self: *Collector, str: *const ast.String, scope: *const Scope, id: NodeId) Error!void {
        const spans = self.span_registry.get(id).details.expr.list;

        for (str.*, spans) |part, span| {
            switch (part) {
                .expr => |e| {
                    try self.walkExpr(&e, scope, span);
                },
                else => {},
            }
        }
    }
};
