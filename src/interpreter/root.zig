const std = @import("std");

pub const Runtime = @import("Runtime.zig");

test {
    std.testing.refAllDecls(@import("test.zig"));
}
