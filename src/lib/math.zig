pub const Operation = enum {
    add,
    sub,
    div,
    mul,
};

pub fn asInt(comptime T: type, in: anytype) T {
    const U = @TypeOf(in);
    const ti = @typeInfo(U);

    return switch (ti) {
        .int => @intCast(in),
        .float => @ceil(in),
        else => @compileError("in must be either int or float type"),
    };
}

pub fn asFloat(comptime T: type, in: anytype) T {
    const U = @TypeOf(in);
    const ti = @typeInfo(U);

    return switch (ti) {
        .int => @floatFromInt(in),
        .float => @floatCast(in),
        else => @compileError("in must be either int or float type"),
    };
}

pub fn as(comptime T: type, in: anytype) T {
    const ti = @typeInfo(T);

    return switch (ti) {
        .int => asInt(T, in),
        .float => asFloat(T, in),
        else => @compileError("T must be either int or float type"),
    };
}

pub fn op(comptime T: type, left: anytype, right: anytype, comptime operation: Operation) T {
    const l = as(T, left);
    const r = as(T, right);

    return switch (operation) {
        inline .add => l + r,
        inline .sub => l - r,
        inline .div => l / r,
        inline .mul => l * r,
    };
}
