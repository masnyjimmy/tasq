const ir = @import("ir.zig");

const Diagnostics = @import("Diagnostics.zig");
const Span = @import("span.zig");

pub const Origin = union(enum) {
    capture: *ir.Capture,
    binding: *ir.Decl,
    argument: *ir.Argument,
    task: *ir.Task,
    group: *ir.Group,
};

pub const Symbol = struct {
    name: []const u8,
    span: Span,
    origin: Origin,

    pub const Type = enum {
        variable,
        task,
        group,
    };

    pub fn typeOf(self: *const Symbol) Type {
        return switch (self.origin) {
            .capture, .binding, .argument => .variable,
            .task => .task,
            .group => .group,
        };
    }

    pub fn debugDump(self: *const Symbol) struct {
        name: []const u8,
        type: Type,
    } {
        return .{
            .name = self.name,
            .type = self.typeOf(),
        };
    }
};
