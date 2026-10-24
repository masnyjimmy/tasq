const std = @import("std");
const ast = @import("ast.zig");
const Scope = @import("scope.zig").Scope;
const lib = @import("lib");

const Tag = enum {
    string,
    number,
    bool,
    list,
    noreturn,
    void,
    lambda,
    result,
    unknown,
};

pub const LambdaTemplate = struct {
    template: ast.Lambda,
    parent_scope: *Scope,
};

pub const Type = union(Tag) {
    string,
    number,
    bool,
    list: *const Type,
    noreturn,
    void,
    lambda: *const LambdaTemplate,
    result: *const Type,
    unknown,

    pub fn unify(left: Type, right: Type) ?Type {
        if (left == .noreturn) return right;
        if (right == .noreturn) return left;
        if (eq(left, right) == false) return null;
        return left;
    }

    pub fn eq(left: Type, right: Type) bool {
        std.debug.assert(left != .noreturn and right != .noreturn);

        const tag = blk: {
            const L = @as(Tag, left);
            const R = @as(Tag, right);
            if (L != R)
                return false;

            break :blk L;
        };

        return switch (tag) {
            .list => eq(left.list.*, right.list.*),
            .lambda => left.lambda.template.node == right.lambda.template.node, // only condition when lambda is the same if its exacly the same element,
            .result => eq(left.result.*, right.result.*),
            else => true,
        };
    }
    // unknown, // used during inference before type is resolved

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            .list => |t| try writer.print("[]{f}", .{t.*}),
            .result => |r| try writer.print("!{f}", .{r.*}),
            inline else => |_, tag| try writer.writeAll(@tagName(tag)),
        }
    }

    pub const MapContext = TypeMapContext;
};

pub const ArgType = enum {
    string,
    list_string,
    number,
    list_number,
    flag,

    pub fn typeOf(self: ArgType) Type {
        return switch (self) {
            .string => .string,
            .list_string => .{
                .list = &.string,
            },
            .number => .number,
            .list_number => .{
                .list = &.number,
            },
            .flag => .bool,
        };
    }

    pub fn format(self: ArgType, w: *std.Io.Writer) !void {
        const string = switch (self) {
            .list_string => "[]string",
            .list_number => "[]number",
            inline else => @tagName(self),
        };
        try w.writeAll(string);
    }

    pub fn isNamedOnly(self: ArgType) bool {
        return switch (self) {
            .list_string, .list_number, .flag => true,
            inline else => false,
        };
    }
};

pub const TypeExpr = union(enum) {
    concrete: Type,
    generic: []const u8,
    list: *const TypeExpr,
    lambda: *const LambdaTypeExpr,
    result: *const TypeExpr,
};

pub const LambdaTypeExpr = struct {
    params: []const TypeExpr,
    return_type: TypeExpr,
};

pub const TypeMapContext = struct {
    pub fn hash(_: @This(), value: Type) u64 {
        var hasher = std.hash.Wyhash.init(0);
        updateHasher(.from(&hasher), value);
        return hasher.final();
    }

    pub fn eql(_: @This(), a: Type, b: Type) bool {
        return Type.eq(a, b);
    }

    pub fn updateHasher(hasher: lib.hash.Hasher, value: Type) void {
        const tag = std.meta.activeTag(value);
        hasher.update(@tagName(tag));
        switch (value) {
            .list => |list| updateHasher(hasher, list.*),
            .lambda => |lambda| hasher.update(
                std.mem.asBytes(&lambda.template.node),
            ),
            .result => |result| updateHasher(hasher, result.*),
            else => {},
        }
    }
};
