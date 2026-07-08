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
        return std.meta.fieldNames(@This());
    }
};

pub const TokenModifier = enum(u32) {
    declaration = 1 << 0,
    readonly = 1 << 1,
    default_library = 1 << 2,

    pub fn getNames() []const []const u8 {
        return std.meta.fieldNames(@This());
    }

    fn modsToInt(comptime mods: []const TokenModifier) u32 {
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

    pub fn make(span: Span, comptime ttype: TokenType, comptime mods: []const TokenModifier) RawToken {
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
    span_registry: *const Span.Registry,

    const Error = std.mem.Allocator.Error;

    pub fn collect(allocator: std.mem.Allocator, file: *const ast.File, span_registry: *const Span.Registry) Error![]RawToken {
        var collector: Collector = .init(allocator, span_registry);

        for (span_registry.spans.items) |span_item| {
            const tt = lib.enums.castEnum(span_item.type, TokenType) orelse unreachable;

            try collector.add(span_item.span, tt, null);
        }

        try collector.walkFile(file);

        return try collector.tokens.toOwnedSlice(allocator);
    }

    fn init(allocator: std.mem.Allocator, span_registry: *const Span.Registry) Collector {
        return .{
            .allocator = allocator,
            .tokens = .empty,
            .span_registry = span_registry,
        };
    }

    fn add(self: *Collector, span: Span, comptime ttype: TokenType, comptime mods: ?[]const TokenModifier) Error!void {
        try self.tokens.append(self.allocator, .make(span, ttype, mods orelse &.{}));
    }

    fn walkFile(self: *Collector, file: *const ast.File) Error!void {
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

    fn walkGroup(self: *Collector, group: *const ast.Group) Error!void {
        if (group.name) |_| {
            const name_span = self.span_registry.getSpan(group.id, .name);
            try self.add(name_span, .variable, null);
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
        const name_span = self.span_registry.getSpan(task.id, .name);
        try self.add(name_span, .variable, null);

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

    fn walkStatement(self: *Collector, stmt: *const ast.Statement) Error!void {
        switch (stmt.*) {
            .process => |v| try self.walkStringExpr(&v),
            .decl => |v| try self.walkDecl(&v),
            else => {
                //TODO: implement
            },
        }
    }

    fn walkArgument(self: *Collector, arg: *const ast.Argument) Error!void {
        const name_span = self.span_registry.getSpan(arg.id, .name);
        try self.add(name_span, .variable, null);

        for (arg.attrs) |*attr| {
            try self.walkAttribute(attr);
        }

        if (arg.default) |*def| {
            try self.walkExpr(def);
        }

        const type_span = self.span_registry.getSpan(arg.id, .extra);
        try self.add(type_span, .type, null);
    }

    fn walkAttribute(self: *Collector, attr: *const ast.Attribute) Error!void {
        const name_span = self.span_registry.getSpan(attr.id, .name);
        try self.add(name_span, .variable, null);

        if (attr.value) |_| {
            //TODO: implement
        }
    }

    fn walkDecl(self: *Collector, decl: *const ast.Decl) Error!void {
        const name_span = self.span_registry.getSpan(decl.id, .name);
        try self.add(name_span, .variable, &.{TokenModifier.declaration});
        try self.walkExpr(&decl.value);
    }

    fn walkExpr(_: *Collector, _: *const ast.Expr) Error!void {
        // TODO: ensure that its already handled (keywords, operators, identifier, numbers, strings)
    }

    fn walkStringExpr(self: *Collector, str: *const ast.StringExpr) Error!void {}
};
