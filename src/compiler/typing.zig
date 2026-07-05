const std = @import("std");

/// anytype to string => builin toString(...)
/// string to number => builtin parseNumber(number, options)
/// add numbers => number + number
// cmp T => T == T
/// concat string => string + string, string + char
/// concat lists => [list...,list...], [item,item], [list..., item]
pub const TypeTag = enum {
    string,
    char,
    number,
    bool,
    list,
};

pub const Type = union(TypeTag) {
    string,
    char,
    number,
    bool,
    list: *const Type,

    pub fn eq(left: Type, right: Type) bool {
        const tag = blk: {
            const L = @as(TypeTag, left);
            const R = @as(TypeTag, right);
            if (L != R)
                return false;

            break :blk L;
        };

        return switch (tag) {
            .list => eq(left.list.*, right.list.*),
            else => true,
        };
    }
    // unknown, // used during inference before type is resolved

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            .list => |t| try writer.print("[]{}", .{t.*}),
            inline else => |_, tag| try writer.writeAll(@tagName(tag)),
        }
    }
};

pub const Value = union(TypeTag) {
    pub const String = struct {
        data: []const u8,
        owned: bool,
    };
    pub const List = struct {
        items_type: *const Type,
        items: []const Value,
    };

    string: String,
    char: u21,
    number: f64,
    bool: bool,
    list: List,

    pub fn deinit(self: *const Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| {
                if (s.owned) {
                    allocator.free(s.data);
                }
            },
            .list => |l| {
                for (l.items) |*item|
                    item.deinit(allocator);
                allocator.free(l.items);
            },
            else => {},
        }
    }

    pub fn typeOf(self: *const Value) Type {
        return switch (self.*) {
            .list => |list| .{ .list = list.items_type },
            inline else => |_, tag| @unionInit(Type, @tagName(tag), {}),
        };
    }

    pub fn is(self: *const Value, t: Type) bool {
        return t.eq(self.typeOf());
    }

    pub fn format(self: *const Value, writer: *std.Io.Writer) !void {
        switch (self.*) {
            .string => |s| try writer.writeAll(s.data),
            .char => |ch| try writer.printUnicodeCodepoint(ch),
            .number => |f| try writer.printFloat(f, .{}),
            .bool => |b| try writer.print("{}", .{b}),
            .list => |l| {
                try writer.writeAll("[");
                for (l.items, 0..) |i, idx| {
                    const last = idx == l.items.len - 1;

                    try writer.print("{f}", .{i});

                    if (!last) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll("]");
            },
        }
    }
};

pub const ArgType = enum {
    string,
    list_string,
    number,
    list_number,
    flag,

    pub fn typeOf(self: @This()) Type {
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

    pub fn format(self: @This(), w: *std.Io.Writer) !void {
        try w.print("{s}", .{@tagName(self)});
    }

    pub fn isNamedOnly(self: @This()) bool {
        return switch (self) {
            .list_string, .list_number, .flag => true,
            inline else => false,
        };
    }
};
