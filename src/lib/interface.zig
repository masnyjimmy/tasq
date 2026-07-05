const std = @import("std");

const InterfaceMethodDesc = struct {
    name: []const u8,
    params: []type = &.{},
    return_type: type = void,
};

fn GetFunctionPointer(comptime params: []const type, comptime return_type: type) type {
    comptime {
        const pattrs: [params.len]std.builtin.Type.Fn.Param.Attributes = .{ .@"noalias" = false };
        const attrs: [params.len]std.builtin.Type.Fn.Attributes = .{};

        return @Pointer(
            .one,
            .{ .@"const" = true },
            @Fn(
                &params,
                &pattrs,
                return_type,
                &attrs,
            ),
            null,
        );
    }
}

pub fn Create(comptime methods: []InterfaceMethodDesc) type {
    comptime {
        var name: [methods.len][]const u8 = undefined;
        var types: [methods.len]type = undefined;
        var attrs: [methods.len]std.builtin.Type.StructField.Attributes = .{};

        for (methods, 0..) |m, idx| {
            name[idx] = m.name;
            types[idx] = GetFunctionPointer(m.params, m.return_type);
        }

        return @Struct(
            .auto,
            null,
            name,
            types,
            &attrs,
        );
    }
}
