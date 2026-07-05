const std = @import("std");

pub fn EnumSize(comptime E: type) usize {
    comptime {
        const a = std.EnumArray(E, i32).initFill(5);
        @compileLog(a.get(@enumFromInt(0)));
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
