const std = @import("std");

const Tag = enum {
    string,
    char,
    number,
    bool,
    list,
    noreturn,
    void,
    lambda,
};

pub const FuncType = struct {
    params: []const Type,
    return_type: Type,
};

pub const Type = union(Tag) {
    string,
    char,
    number,
    bool,
    list: *const Type,
    noreturn,
    void,
    lambda: *const FuncType,

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
            .lambda => {
                if (left.lambda.params.len != right.lambda.params.len)
                    return false;

                for (left.lambda.params, right.lambda.params) |l, r| {
                    if (eq(l, r) == false)
                        return false;
                }

                return eq(left.lambda.return_type, right.lambda.return_type);
            },
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
            inline else => |_, tag| try writer.writeAll(@tagName(tag)),
        }
    }
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
};

pub const LambdaTypeExpr = struct {
    params: []const TypeExpr,
    return_type: TypeExpr,
};
