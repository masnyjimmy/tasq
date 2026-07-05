const ast = @import("ast.zig");

const MetaType = ast.MetaType;

const lib = @import("lib");
const enums = lib.enums;
const ct = lib.@"comptime";

pub const options = OptionsGroup(&.{
    .{
        .name = "shell",
        .value_type = .{
            .list = &.string,
        },
    },
    .{
        .name = "script",
        .value_type = .{
            .list = &.string,
        },
    },
});

fn OptionsGroup(comptime specs: []const OptionSpec) type {
    const Id = blk: {
        const TagType = enums.FitUnsigned(specs.len);

        var names: [specs.len][]const u8 = undefined;
        const values: [specs.len]TagType = ct.iter(TagType, specs.len);

        for (specs, 0..) |spec, idx| {
            names[idx] = spec.name;
        }

        break :blk @Enum(TagType, .exhaustive, &names, &values);
    };

    const Definition = struct {
        id: Id,
        value_type: MetaType,
    };

    const defs: [specs.len]Definition = comptime blk: {
        var defs: [specs.len]Definition = undefined;

        for (specs, 0..) |spec, idx| {
            defs[idx] = .{
                .id = @enumFromInt(idx),
                .value_type = spec.value_type,
            };
        }
        break :blk defs;
    };

    const map = enums.generateEnumNameMap(Id);

    return struct {
        pub const Type = Id;

        pub fn get(name: []const u8) ?Definition {
            const t = map.get(name) orelse return null;
            return defs[@intFromEnum(t)];
        }
    };
}

const OptionSpec = struct {
    name: []const u8,
    value_type: MetaType,
};
