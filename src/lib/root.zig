const utils = @import("utils.zig");

pub const Enum = struct {
    const Size = utils.EnumSize;
};

pub const isAssignable = utils.IsAssignable;

pub const debug = @import("debug.zig");

pub const Interface = @import("interface.zig");

pub const enums = @import("enums.zig");

pub const @"comptime" = @import("comptime.zig");

pub const dotenv = @import("dotenv.zig");

pub const platform = @import("platform.zig");

pub const program = @import("program.zig");

pub const hash = @import("hash.zig");
