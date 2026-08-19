const ast = @import("ast.zig");

const MetaType = ast.MetaType;

const lib = @import("lib");
const enums = lib.enums;
const ct = lib.@"comptime";

pub const options = OptionsGroup(&.{
    .{
        .name = "shell",
        .value_types = &.{.{ .list = &.string }},
    },
    .{
        .name = "dotenv",
        .value_types = &.{ .bool, .string },
    },
    .{
        .name = "working_dir",
        .value_types = &.{.string},
    },
    .{
        .name = "fail_fast",
        .value_types = &.{.bool},
    },
});

fn OptionsGroup(comptime specs: []const Spec) type {
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
        value_types: []const MetaType,
    };

    const defs: [specs.len]Definition = comptime blk: {
        var defs: [specs.len]Definition = undefined;

        for (specs, 0..) |spec, idx| {
            defs[idx] = def: {
                var out = ct.copyFields(Definition, spec);
                out.id = @enumFromInt(idx);

                break :def out;
            };
        }
        break :blk defs;
    };

    const name_map = enums.generateEnumNameMap(Id);

    return struct {
        pub const Type = Id;

        pub fn get(name: []const u8) ?Definition {
            const t = name_map.get(name) orelse return null;
            return defs[@intFromEnum(t)];
        }
    };
}

const Spec = struct {
    name: []const u8,
    value_types: []const MetaType,
};
