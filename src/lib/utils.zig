const std = @import("std");

pub fn EnumSize(comptime E: type) usize {
    comptime {
        const a = std.EnumArray(E, i32).initFill(5);
        @compileLog(a.get(@fromBackingInt(@intCast(0))));
    }
    return @typeInfo(E).@"enum".fields.len;
}

fn CoreType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| CoreType(o.child),
        else => T,
    };
}

pub fn IsAssignable(comptime L: type, comptime R: type) bool {
    if (CoreType(L) == CoreType(R)) {
        return true;
    }

    return false;
}

pub fn replace(value_: anytype, rep: anytype) @TypeOf(value_) {
    var value = value_;
    const T = @TypeOf(value);
    const ti = @typeInfo(T);

    const U = @TypeOf(rep);
    const ui = @typeInfo(U);

    if (ti != .@"struct" or ui != .@"struct") {
        @compileError("both inputs needs to be structures");
    }

    inline for (ui.@"struct".field_names) |field| {
        @field(value, field) = @field(rep, field);
    }

    return value;
}
