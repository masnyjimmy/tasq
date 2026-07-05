const diag = @import("diagnostic.zig");
const utils = @import("utils.zig");

pub const Diagnostic = diag.Diagnostic;
pub const Span = diag.Span;
pub const Severity = diag.Severity;

pub const WithSpan = diag.WithSpan;

pub const Enum = struct {
    const Size = utils.EnumSize;
};

pub const isAssignable = utils.IsAssignable;

pub const debug = @import("debug.zig");

pub const Interface = @import("interface.zig");

pub const enums = @import("enums.zig");

pub const source_file = @import("source_file.zig");

pub const @"comptime" = @import("comptime.zig");
