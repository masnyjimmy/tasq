const std = @import("std");
const builtin = @import("builtin");
const enums = @import("enums.zig");

pub const Tag = enum {
    windows,
    linux,
    ios,
    other,
};

pub const tag = enums.castEnum(builtin.os.tag, Tag) orelse @compileError("unsupported platform");
