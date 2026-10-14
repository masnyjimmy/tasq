const std = @import("std");

pub const TypeTag = enum {
    null,
    bool,
    number,
    char,
    string,
    list,
    tuple,
};

pub const Type = union(TypeTag) {
    null,
    bool,
    number,
    char,
    string,
    list: *const Type,
    tuple: []const Type,

    pub fn format(self: *const Type, w: *std.Io.Writer) !void {
        switch (self.*) {
            .list => |l| try w.print("[]{f}", .{l}),
            .tuple => |t| {
                try w.writeAll("(");

                for (t, 0..) |item, idx| {
                    const is_last = idx == t.len - 1;
                    try w.print("{f}", .{item});

                    if (is_last == false) {
                        try w.writeAll(",");
                    }
                }

                try w.writeAll(")");
            },
            else => |tag| try w.print("{t}", .{tag}),
        }
    }
};

pub const Value = union(TypeTag) {
    null,
    bool: bool,
    number: f64,
    char: u8,
    string: []const u8,
    list: []const Value,
    tuple: []const Value,

    pub fn validateType(self: *const Value, target_type: Type) bool {
        const T: TypeTag = blk: {
            const self_tag = std.meta.activeTag(self.*);
            const target_tag = std.meta.activeTag(target_type);

            if (self_tag != target_tag)
                return false;

            break :blk self_tag;
        };

        switch (T) {
            .list => {
                for (self.list) |item| {
                    if (item.validateType(target_type.list.*) == false)
                        return false;
                }
                return true;
            },
            .tuple => {
                for (self.tuple, target_type.tuple) |elem, target| {
                    if (elem.validateType(target) == false)
                        return false;
                }
                return true;
            },
            else => return true,
        }
    }

    pub fn format(self: *const Value, w: *std.Io.Writer) !void {
        switch (self.*) {
            .null => try w.writeAll("null"),
            .bool => |v| try w.print("{}", .{v}),
            .number => |v| try w.print("{}", .{v}),
            .char => |v| try w.print("{c}", .{v}),
            .string => |v| try w.print("{s}", .{v}),
            .list => |v| {
                try w.writeAll("[");

                for (v, 0..) |item, idx| {
                    try w.print("{f}", .{item});

                    if (idx != v.len - 1)
                        try w.writeAll(",");
                }

                try w.writeAll("]");
            },
            .tuple => |v| {
                try w.writeAll("(");

                for (v, 0..) |item, idx| {
                    try w.print("{f}", .{item});

                    if (idx != v.len - 1)
                        try w.writeAll(",");
                }

                try w.writeAll(")");
            },
        }
    }
};
