const std = @import("std");

const builtin = @import("builtin");

const ir = @import("ir.zig");

const lib = @import("lib");
const enums = lib.enums;

pub const Tag = enum {
    windows,
    linux,
    ios,
};

pub const tag = enums.castEnum(builtin.os.tag, Tag) orelse @compileError("unsupported platform");

pub const default_options: ir.Options = switch (tag) {
    .windows => .{
        .shell = &.{ "cmd", "/C" },
        .script = undefined, //TODO: add
    },
    else => unreachable,
};
