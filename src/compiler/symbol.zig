const ir = @import("ir.zig");

const Diagnostics = @import("Diagnostics.zig");
const Span = Diagnostics.Span;

const BindingDetails = struct {
    static: bool,
    type: ir.Type,
    origin: *ir.Decl,
};

const ArgumentDetails = struct {
    type: ir.Type,
    origin: *ir.Argument,
};

const TaskDetails = struct {
    origin: *ir.Task,
};

const GroupDetails = struct {
    origin: *ir.Group,
};

pub const Details = union(enum) {
    binding: BindingDetails,
    argument: ArgumentDetails,
    task: TaskDetails,
    group: GroupDetails,
};

pub const Symbol = struct {
    name: []const u8,
    span: Span,
    details: Details,

    pub const Type = enum {
        variable,
        task,
        group,
    };

    pub fn typeOf(self: *const Symbol) Type {
        return switch (self.details) {
            .binding, .argument => .variable,
            .task => .task,
            .group => .group,
        };
    }
};
