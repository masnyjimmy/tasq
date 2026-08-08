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
    noreturn,
};

pub const Type = union(TypeTag) {
    string,
    char,
    number,
    bool,
    list: *const Type,
    noreturn,

    pub fn unify(left: Type, right: Type) ?Type {
        if (left == .noreturn) return right;
        if (right == .noreturn) return left;
        if (eq(left, right) == false) return null;
        return left;
    }

    pub fn eq(left: Type, right: Type) bool {
        std.debug.assert(left != .noreturn and right != .noreturn);

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
            .list => |t| try writer.print("[]{f}", .{t.*}),
            inline else => |_, tag| try writer.writeAll(@tagName(tag)),
        }
    }
};

pub const ValueContext = struct {
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

pub const Value = union(TypeTag) {
    pub const List = struct {
        items_type: *const Type,
        items: []const Value,
    };

    string: []const u8,
    char: u21,
    number: f64,
    bool: bool,
    list: List,
    noreturn,

    pub fn clone(self: *const Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
        return switch (self.*) {
            .string => |str| .{ .string = try allocator.dupe(u8, str) },
            .list => |list| {
                const out = try allocator.alloc(Value, list.items.len);

                for (list.items, out) |in, *o| {
                    o.* = try in.clone(allocator);
                }

                return .{ .list = .{
                    .items = out,
                    .items_type = list.items_type,
                } };
            },
            else => self.*,
        };
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
            .string => |s| try writer.writeAll(s),
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
            .noreturn => try writer.print("<noreturn>", .{}),
        }
    }

    pub fn eql(a: Value, b: Value) bool {
        const t: TypeTag = blk: {
            const a_tag = std.meta.activeTag(a);
            const b_tag = std.meta.activeTag(b);

            if (a_tag != b_tag)
                return false;

            break :blk a_tag;
        };

        return switch (t) {
            .string => std.mem.eql(u8, a.string, b.string),
            .char => a.char == b.char,
            .number => a.number == b.number,
            .bool => a.bool == b.bool,
            .list => {
                for (a.list.items, b.list.items) |l, r| {
                    if (!eql(l, r))
                        return false;
                }
                return true;
            },
            else => unreachable,
        };
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
        const string = switch (self) {
            .list_string => "[]string",
            .list_number => "[]number",
            inline else => @tagName(self),
        };
        try w.writeAll(string);
    }

    pub fn isNamedOnly(self: @This()) bool {
        return switch (self) {
            .list_string, .list_number, .flag => true,
            inline else => false,
        };
    }
};
