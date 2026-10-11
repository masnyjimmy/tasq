const ir = @import("ir.zig");

const Diagnostics = @import("Diagnostics.zig");
const Span = @import("Span.zig");
const @"type" = @import("type.zig");

pub const Origin = union(enum) {
    capture: *ir.Capture,
    binding: *ir.Decl,
    argument: *ir.Argument,
    task: *ir.Task,
    group: *ir.Group,

    pub fn valueType(self: *const Origin) ?@"type".Type {
        return switch (self.*) {
            .capture => |c| c.type,
            .binding => |b| b.type,
            .argument => |a| a.type.typeOf(),
            else => null,
        };
    }
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
        value_type: ?@"type".Type,
    } {
        return .{
            .name = self.name,
            .type = self.typeOf(),
            .value_type = self.origin.valueType(),
        };
    }
};
