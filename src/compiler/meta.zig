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

pub const String = union(enum) {
    any,
    options: []const []const u8,
};
pub const Number = struct {
    int: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,

    pub const default: Number = .{};
};
pub const Type = union(TypeTag) {
    null,
    bool,
    number: Number,
    char,
    string: String,
    list: *const Type,
    tuple: []const Type,

    pub const any_string: Type = .{ .string = .any };
    pub const any_number: Type = .{ .number = .default };

    pub fn format(self: *const Type, w: *std.Io.Writer) !void {
        switch (self.*) {
            .string => |str| switch (str) {
                .options => |opts| {
                    try w.writeByte('[');

                    for (opts, 0..) |opt, idx| {
                        if (idx != 0)
                            try w.writeByte(',');

                        try w.writeAll(opt);
                    }

                    try w.writeByte(']');
                },
                .any => try w.writeAll("string"),
            },
            .number => |num| {
                const name = if (num.int)
                    "int"
                else
                    "number";

                if (num.min) |min|
                    try w.print("{}<", .{min});

                try w.writeAll(name);

                if (num.max) |max|
                    try w.print("<{}", .{max});
            },
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

    pub fn match(self: *const Value, target_type: Type) bool {
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
                    if (item.match(target_type.list.*) == false)
                        return false;
                }
                return true;
            },
            .tuple => {
                for (self.tuple, target_type.tuple) |elem, target| {
                    if (elem.match(target) == false)
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
