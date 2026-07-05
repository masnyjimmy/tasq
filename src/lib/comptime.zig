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

    inline for (in_ti.fields) |field| {
        if (@hasField(Out, field.name)) {
            if (field.type != @FieldType(Out, field.name)) @compileError(.{ "type mismatch", field.name });

            @field(out, field.name) = @field(in, field.name);
        }
    }

    return out;
}
