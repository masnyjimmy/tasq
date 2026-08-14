const std = @import("std");

const Type = @import("type.zig").Type;

pub const ValueMapContext = struct {
    pub fn hash(_: @This(), value: Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hashValue(&hasher, value);
        return hasher.final();
    }

    pub fn eql(_: @This(), a: Value, b: Value) bool {
        return Value.eql(a, b);
    }

    fn hashValue(hasher: *std.hash.Wyhash, value: Value) void {
        const tag = std.meta.activeTag(value);
        hasher.update(@tagName(tag));
        switch (value) {
            .string => |s| hasher.update(s),
            .char => |c| hasher.update(std.mem.asBytes(&c)),
            .bool => |b| hasher.update(std.mem.asBytes(&b)),
            .number => |n| {
                std.debug.assert(n == 0 or std.math.isNormal(n));
                hasher.update(std.mem.asBytes(&n));
            },
            .list => |l| for (l.items) |item| hashValue(hasher, item),
            else => unreachable,
        }
    }
};

pub const List = struct {
    items_type: *const Type,
    items: []const Value,
};

const Tag = enum {
    string,
    char,
    number,
    bool,
    list,
    void,
};

pub const Value = union(Tag) {
    string: []const u8,
    char: u21,
    number: f64,
    bool: bool,
    list: List,
    void,

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
            .string => |s| try writer.writeAll(s),
            .char => |ch| try writer.printUnicodeCodepoint(ch),
            .number => |f| try writer.printFloat(f, .{}),
            .bool => |b| try writer.print("{}", .{b}),
            .list => |l| {
                try writer.writeAll("[");
                for (l.items, 0..) |item, idx| {
                    const last = idx == l.items.len - 1;

                    try writer.print("{f}", .{item});

                    if (last == false) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll("]");
            },
            inline else => |_, tag| try writer.print("<{t}>", .{tag}),
        }
    }

    pub fn eql(left: Value, right: Value) bool {
        const common: Tag = blk: {
            const left_tag = std.meta.activeTag(left);
            const right_tag = std.meta.activeTag(right);

            if (left_tag != right_tag)
                return false;

            break :blk left_tag;
        };

        return switch (common) {
            .string => std.mem.eql(u8, left.string, right.string),
            .char => left.char == right.char,
            .number => left.number == right.number,
            .bool => left.bool == right.bool,
            .list => {
                if (left.list.items.len != right.list.items.len)
                    return false;

                for (left.list.items, right.list.items) |l, r| {
                    if (eql(l, r) == false)
                        return false;
                }

                return true;
            },
            else => unreachable,
        };
    }

    pub fn clone(self: *const Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
        return switch (self.*) {
            .string => |str| .{ .string = try allocator.dupe(u8, str) },
            .list => |list| {
                const result = try allocator.alloc(Value, list.items.len);

                for (list.items, result) |in, *out| {
                    out.* = try in.clone(allocator);
                }

                return .{
                    .list = .{
                        .items = result,
                        .items_type = list.items_type,
                    },
                };
            },
            else => self.*,
        };
    }

    pub const MapContext = ValueMapContext;
};
