const std = @import("std");

pub fn StaticSet(comptime T: type) type {
    const ti = @typeInfo(T);

    if (ti != .@"enum")
        @compileError("T must be enum");

    const enumInfo = ti.@"enum";

    const len = enumInfo.fields.len;

    return struct {
        const Self = @This();

        const Iter = struct {
            const Elem = struct {
                key: T,
                value: bool,
            };

            index: usize = 0,
            src: *Self,

            pub fn next(self: *Iter) ?Elem {
                if (self.index == self.src.data.len)
                    return null;

                defer self.index += 1;
                return .{
                    .key = @enumFromInt(self.index),
                    .value = self.src.data[self.index],
                };
            }
        };

        data: [len]bool,

        pub fn initComptime(comptime values: [len]T) Self {
            comptime var data: [len]bool = .{};

            for (values) |v| {
                const idx = @intFromEnum(v);

                data[idx] = true;
            }

            return .{
                .data = data,
            };
        }

        pub fn has(self: *Self, key: T) bool {
            const idx = @intFromEnum(key);
            return self.data[idx];
        }

        pub fn none(self: *Self) bool {
            for (self.data) |b| {
                if (b)
                    return false;
            }

            return true;
        }

        pub fn iter(self: *Self) Iter {
            return .{
                .src = self,
                .index = 0,
            };
        }
    };
}

pub fn generateEnumNameMap(comptime T: type) std.StaticStringMap(T) {
    comptime {
        const ti = switch (@typeInfo(T)) {
            .@"enum" => |e| e,
            else => @compileError("T must be enum"),
        };

        var out: [ti.fields.len]struct { []const u8, T } = undefined;

        for (ti.fields, 0..) |f, idx| {
            out[idx] = .{ f.name, @as(T, @enumFromInt(f.value)) };
        }

        return .initComptime(out);
    }
}

pub fn castEnum(value: anytype, comptime T: type) ?T {
    const map = comptime generateEnumNameMap(T);

    return map.get(@tagName(value));
}

pub fn enumFromString(name: []const u8, comptime T: type) ?T {
    const map = generateEnumNameMap(T);
    return map.get(name);
}

pub fn FitUnsigned(comptime value: usize) type {
    return @Int(.unsigned, @intCast(std.math.log2_int_ceil(usize, value)));
}

pub fn EnumMultimap(comptime E: type, comptime V: type) type {
    return struct {
        pub const Array = std.ArrayList(V);
        pub const Keys = std.EnumSet(E);
        pub const Storage = std.EnumArray(E, Array);
        const Self = @This();

        keys: Keys = .initEmpty(),
        storage: Storage = .initFill(.empty),

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (&self.storage.values) |*val| {
                val.deinit(allocator);
            }
        }

        pub fn add(
            self: *Self,
            allocator: std.mem.Allocator,
            key: E,
            value: V,
        ) !void {
            try self.storage.getPtr(key).append(allocator, value);
            self.keys.insert(key);
        }

        pub fn get(self: *Self, key: E) ?[]const V {
            return if (self.contains(key))
                self.storage.getPtr(key).items
            else
                null;
        }

        pub fn getAssertOne(self: *Self, key: E) ?V {
            const count_ = self.countOf(key);
            std.debug.assert(count_ <= 1);

            return switch (count_) {
                0 => null,
                1 => self.storage.getPtr(key).getLast(),
                else => unreachable,
            };
        }

        pub fn contains(self: *const Self, key: E) bool {
            return self.keys.contains(key);
        }

        pub fn count(self: *const Self) usize {
            return self.keys.count();
        }

        pub fn countOf(self: *const Self, key: E) usize {
            return self.storage.getPtrConst(key).items.len;
        }
    };
}
