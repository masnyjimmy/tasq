const std = @import("std");

pub const Interpreter = @import("interpreter.zig");

test {
    std.testing.refAllDecls(@import("test.zig"));
}
