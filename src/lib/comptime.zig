const std = @import("std");

pub fn iter(comptime T: type, comptime max: comptime_int) [max]T {
    comptime {
        var out: [max]T = undefined;

        for (0..max) |idx| {
            out[idx] = idx;
        }

        return out;
    }
}

/// copy by each field, rest is left undefined
pub fn copyFields(comptime Out: type, in: anytype) Out {
    var out: Out = undefined;

    const in_ti = blk: {
        const T = @TypeOf(in);
        const ti = @typeInfo(T);

        if (ti != .@"struct") {
            @compileError("in must be struct");
        }

        break :blk ti.@"struct";
    };

    if (in_ti.is_tuple) @compileError("in cannot be tuple");

    inline for (in_ti.field_names, in_ti.field_types) |field_name, field_type| {
        if (@hasField(Out, field_name)) {
            if (field_type != @FieldType(Out, field_name)) @compileError("type mismatch: " ++ field_name);

            @field(out, field_name) = @field(in, field_name);
        }
    }

    return out;
}

pub const StringBuilder = struct {
    buffer: []const u8,

    pub fn init(comptime str: []const u8) StringBuilder {
        return .{ .buffer = str };
    }

    pub fn append(comptime self: *StringBuilder, comptime fmt: []const u8, args: anytype) void {
        self.buffer = self.buffer ++ std.fmt.comptimePrint(fmt, args);
    }

    pub fn appendRaw(comptime self: *StringBuilder, comptime str: []const u8) void {
        self.buffer = self.buffer ++ str;
    }
};
