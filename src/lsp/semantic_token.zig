const std = @import("std");

const lib = @import("lib");
const compiler = @import("compiler");
const ast = compiler.ast;

const Span = compiler.Span;
const NodeId = Span.Registry.NodeId;

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

    pub fn collect(allocator: std.mem.Allocator, file: *const ast.File, span_registry: *const Span.Registry) Error![]RawToken {
        var collector: Collector = .init(allocator, span_registry);

        // handle flat spans first
        for (span_registry.spans.items) |span_item| {
            const tt = lib.enums.castEnum(span_item.type, TokenType) orelse unreachable;

            try collector.add(span_item.span, tt, null);
        }

        try collector.walkFile(file);

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

    fn walkFile(self: *Collector, file: *const ast.File) Error!void {
        for (file.decls) |*decl| {
            try self.walkDecl(decl);
        }

        for (file.options) |*opt| {
            try self.walkSet(opt);
        }

        for (file.groups) |*group| {
            try self.walkGroup(group);
        }

        for (file.tasks) |*task| {
            try self.walkTask(task);
        }
    }

    fn walkSet(self: *Collector, set: *const ast.Set) Error!void {
        for (set.attrs) |*attr| {
            try self.walkAttribute(attr);
        }
    }

    fn walkGroup(self: *Collector, group: *const ast.Group) Error!void {
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

        for (group.decls) |*decl| {
            try self.walkDecl(decl);
        }

        for (group.tasks) |*task| {
            try self.walkTask(task);
        }
    }

    fn walkTask(self: *Collector, task: *const ast.Task) Error!void {
        const span_node = self.span_registry.get(task.id);

        try self.add(span_node.details.task.name, .function, null);

        for (task.args) |*arg| {
            try self.walkArgument(arg);
        }

        for (task.attrs) |*attr| {
            try self.walkAttribute(attr);
        }

        const stmts_spans = self.span_registry.get(span_node.details.task.body).details.block;

        for (task.body, stmts_spans.stmts) |*stmt, stmt_node_id| {
            try self.walkStatement(stmt, stmt_node_id);
        }
    }

    fn walkStatement(self: *Collector, stmt: *const ast.Statement, node_id: NodeId) Error!void {
        switch (stmt.*) {
            .process => |v| try self.walkStringExpr(&v, node_id),
            .decl => |v| try self.walkDecl(&v),
            .task_call => |v| try self.walkTaskCall(&v),
            .if_stmt => |v| try self.walkIfStmt(&v),
            .switch_stmt => |s| try self.walkSwitchStmt(&s),
            .expr => |e| try self.walkExpr(&e, node_id),
        }
    }

    fn walkSwitchStmt(self: *Collector, switch_stmt: *const ast.SwitchStmt) Error!void {
        const switch_node = self.span_registry.get(switch_stmt.id);

        try self.walkExpr(&switch_stmt.subject, switch_node.details.switch_stmt.subject);

        for (switch_stmt.cases) |case| {
            const case_node = self.span_registry.get(case.id).details.switch_case;
            const case_body_node = self.span_registry.get(case_node.body).details.block.stmts;
            for (case.body, case_body_node) |*stmt, node| {
                try self.walkStatement(stmt, node);
            }
        }
    }

    fn walkIfStmt(self: *Collector, if_stmt: *const ast.IfStmt) Error!void {
        const span_node = self.span_registry.get(if_stmt.id);
        const if_spans = span_node.details.if_stmt;

        _ = if_spans;

        //TODO: handle if needed
    }

    fn walkTaskCall(self: *Collector, task_call: *const ast.TaskCall) Error!void {
        const span_node = self.span_registry.get(task_call.id);
        const task_call_spans = span_node.details.task_call;

        if (task_call_spans.group) |group| {
            try self.add(group, .variable, null);
        }

        try self.add(task_call_spans.task, .variable, null);

        for (task_call.args) |*arg| {
            try self.walkTaskCallArgs(arg);
        }
    }

    fn walkTaskCallArgs(self: *Collector, args: *const ast.TaskCallArg) Error!void {
        const span_node = self.span_registry.get(args.id);
        const arg_spans = span_node.details.task_call_arg;

        if (arg_spans.name) |name| {
            try self.add(name, .variable, null);
        }

        try self.walkExpr(&args.value, arg_spans.value);
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

    fn walkDecl(self: *Collector, decl: *const ast.Decl) Error!void {
        const span_node = self.span_registry.get(decl.id).details.decl;
        try self.add(span_node.name, .variable, &.{TokenModifier.declaration});
        try self.walkExpr(&decl.value, span_node.value);
    }
    fn walkExpr(self: *Collector, expr: *const ast.Expr, id: NodeId) Error!void {
        const node = self.span_registry.get(id);

        switch (expr.*) {
            .builtin_call => |call| {
                try self.add(
                    node.details.builtin_call.name,
                    .builtin,
                    null,
                );

                for (call.args, node.details.builtin_call.args) |arg, arg_span| {
                    try self.walkExpr(&arg, arg_span);
                }
            },
            else => {},
        }
    }

    fn walkStringExpr(_: *Collector, _: *const ast.StringExpr, _: NodeId) Error!void {}
};
