const std = @import("std");

const lib = @import("lib");
const compiler = @import("compiler");
const ast = compiler.ast;

const Span = compiler.Span;

pub const TokenType = enum(u32) {
    keyword,
    property,
    function,
    number,
    string,
    variable,
    parameter,
    type,

    pub fn getNames() []const []const u8 {
        std.meta.fieldNames(@This());
    }
};

pub const TokenModifier = enum(u32) {
    declaration = 1 << 0,
    readonly = 1 << 1,
    default_library = 1 << 2,

    pub fn getNames() []const []const u8 {
        std.meta.fieldNames(@This());
    }

    fn modsToInt(comptime mods: []TokenModifier) u32 {
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

    pub fn make(span: Span, comptime ttype: TokenType, comptime mods: []TokenModifier) RawToken {
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

pub const Collector = struct {
    allocator: std.mem.Allocator,
    tokens: std.ArrayList(RawToken),

    pub fn collect(allocator: std.mem.Allocator, file: *const ast.File) ![]RawToken {
        var collector: Collector = .init(allocator);

        try collector.walkFile(file);

        return try collector.tokens.toOwnedSlice(allocator);
    }

    fn init(allocator: std.mem.Allocator) Collector {
        return .{
            .allocator = allocator,
            .tokens = .empty,
        };
    }

    fn add(self: *Collector, span: Span, comptime ttype: TokenType, comptime mods: ?[]TokenModifier) !void {
        self.tokens.append(self.allocator, .make(span, ttype, mods orelse &.{}));
    }

    fn walkFile(self: *Collector, file: *const ast.File) !void {
        for (file.decls) |*decl| {
            try self.walkDecl(decl);
        }

        for (file.groups) |*group| {
            try self.walkGroup(group);
        }

        for (file.tasks) |*task| {
            try self.walkTask(task);
        }
    }

    fn walkGroup(self: *Collector, group: *const ast.Group) !void {
        if (group.name) |name| {
            try self.add(name.span, .variable);
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

    fn walkTask(self: *Collector, task: *const ast.Task) !void {
        try self.add(task.name.span, .variable);

        for (task.args) |*arg| {
            try self.walkArgument(arg);
        }

        for (task.attrs) |*attr| {
            try self.walkAttribute(attr);
        }

        for (task.body) |*stmt| {
            try self.walkStatement(stmt);
        }
    }

    fn walkStatement(self: *Collector, stmt: *const ast.Statement) !void {
        switch (stmt.*) {
            .process => |v| try self.walkStringExpr(&v),
            .decl => |v| try self.walkDecl(&v),
            else => {
                //TODO: implement
            },
        }
    }

    fn walkArgument(self: *Collector, arg: *const ast.Argument) !void {
        try self.add(arg.name.span, .variable);

        for (arg.attrs) |*attr| {
            try self.walkAttribute(attr);
        }

        if (arg.default) |*def| {
            try self.walkExpr(def);
        }

        try self.add(arg.type.span, .type);
    }

    fn walkAttribute(self: *Collector, attr: *const ast.Attribute) !void {
        try self.add(attr.name.span, .variable);

        if (attr.value) |val| {
            //TODO: implement
        }
    }

    fn walkDecl(self: *Collector, decl: *const ast.Decl) !void {
        self.add(decl.name.span, .variable, &.{TokenModifier.declaration});
        self.walkExpr(&decl.value);
    }

    fn walkExpr(self: *Collector, expr: *const ast.Expr) !void {
        switch (expr.*) {
            .bool_lit => |v| try self.add(v.span, .keyword, null),
            .number_lit => |v| try self.add(v.span, .number, null),
            .char_lit => |v| try self.add(v.span, .string, null),
            .string => |v| try self.walkStringExpr(&v.value),
            .list => |v| for (v.value) |item| try self.walkExpr(&item),
            .builtin_call => |v| {
                try self.add(v.name.span, .function, null);
                for (v.args) |a| try self.walkExpr(&a);
            },
            .ident => |v| try self.add(v.span, .variable),
            .binary => |v| {
                try self.walkExpr(&v.left);
                try self.walkExpr(&v.right);
            },
            .unary => |v| try self.walkExpr(&v.operand),
            .if_expr => |v| {
                //TODO: add if and else keywords spans
                try self.walkExpr(&v.cond);
                try self.walkExpr(&v.else_);
                try self.walkExpr(&v.then);
            },
        }
    }

    fn walkStringExpr(self: *Collector, str: *const ast.StringExpr) !void {
        switch (str.*) {
            .lit => |lit| try self.add(lit.span, .string),
            .inter => |inter| for (inter) |seg|
                switch (seg) {
                    .lit => |lit| try self.add(lit.span, .string),
                    .expr => |expr| try self.walkExpr(&expr),
                },
        }
    }
};
