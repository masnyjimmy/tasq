const VTable = struct {
    update: *const fn (self: *anyopaque, data: []const u8) void,

    fn create(comptime T: type) VTable {
        const Table = struct {
            fn get(self: *anyopaque) T {
                return @ptrCast(@alignCast(self));
            }
            fn update(self: *anyopaque, data: []const u8) void {
                get(self).update(data);
            }
        };

        return .{
            .update = Table.update,
        };
    }
};

pub const Hasher = struct {
    ptr: *anyopaque,
    _vtable: VTable,

    pub fn update(self: Hasher, data: []const u8) void {
        self._vtable.update(self.ptr, data);
    }

    pub fn from(hasher: anytype) Hasher {
        const T = @TypeOf(hasher);

        // if (@typeInfo(hasher) != .pointer)
        //     @compileError("'hasher' must be pointer to hasher");

        // const Fns = struct {
        //     fn get(self: *anyopaque) T {
        //         return @ptrCast(self);
        //     }
        //     fn update(self: *anyopaque, data: []const u8) void {
        //         get(self).update(data);
        //     }
        // };

        return .{
            .ptr = hasher,
            ._vtable = .create(T),
        };
    }
};
