const lib = @import("lib");
const enums = lib.enums;
const platform = lib.platform;
const ir = @import("ir.zig");

pub const Tag = platform.Tag;
pub const tag = platform.tag;

pub const default_options: ir.Options = switch (platform.tag) {
    .windows => .{
        .shell = &.{ "cmd", "/C" },
    },
    .linux => .{
        .shell = &.{ "/bin/bash", "-c" },
    },
    else => unreachable,
};
