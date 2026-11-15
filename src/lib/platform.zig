const std = @import("std");
const builtin = @import("builtin");
const enums = @import("enums.zig");

pub const Tag = enum {
    windows,
    linux,
};

pub const tag = enums.castEnum(builtin.target.os.tag, Tag) orelse @compileError("unsupported platform");

pub const Desc = struct {
    path_var_name: []const u8,
    path_separator: []const u8,
    extensions: []const []const u8 = &.{},
    script_extensions: []const u8 = "",
    program_separator: []const u8,

    pub const current: Desc = switch (tag) {
        .windows => .{
            .path_var_name = "path",
            .path_separator = ";",
            .extensions = &.{ ".exe", ".cmd", ".bat", ".com" },
            .script_extensions = ".cmd",
            .program_separator = "\\",
        },
        else => .{
            .path_var_name = "PATH",
            .path_separator = ":",
            .program_separator = "/",
        },
    };
};
