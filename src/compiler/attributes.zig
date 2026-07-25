const std = @import("std");

const typing = @import("typing.zig");

const ast = @import("ast.zig");
const MetaType = ast.MetaType;

const lib = @import("lib");
const enums = lib.enums;
const ct = lib.@"comptime";

const platform = @import("platform.zig");

pub const Kind = enum {
    platform,
    doc,
    modifier,
    validation,
};

const platform_specs = blk: {
    const ti = @typeInfo(platform.Tag).@"enum";

    var specs: [ti.fields.len]Spec = undefined;

    for (ti.fields, 0..) |f, idx| {
        specs[idx] = .{
            .name = f.name,
            .value_types = &.{},
            .allow_default = true,
            .unique = true,
            .kind = .platform,
            .valid_for = &.{ .setting, .group, .task },
        };
    }

    break :blk specs;
};

const attr_specs: []const Spec = &.{
    // documentation
    .{
        .name = "desc",
        .value_types = &.{.string},
        .allow_default = false,
        .unique = true,
        .kind = .doc,
        .valid_for = &.{
            .group,
            .task,
            .any_argument,
        },
    },
    .{
        .name = "private",
        .value_types = &.{},
        .allow_default = true,
        .unique = true,
        .kind = .doc,
        .valid_for = &.{ .group, .task },
    },
    // modifiers
    .{
        .name = "long",
        .value_types = &.{ .null, .string },
        .allow_default = true,
        .unique = true,
        .kind = .modifier,
        .valid_for = &.{.any_argument},
    },
    .{
        .name = "short",
        .value_types = &.{ .null, .char },
        .allow_default = true,
        .unique = true,
        .kind = .modifier,
        .valid_for = &.{.any_argument},
    },
    // validators
    .{
        .name = "int",
        .value_types = &.{},
        .allow_default = true,
        .unique = true,
        .kind = .validation,
        .valid_for = &.{.arguments(&.{ .number, .list_number })},
    },
    .{
        .name = "min",
        .value_types = &.{.number},
        .allow_default = false,
        .unique = true,
        .kind = .validation,
        .valid_for = &.{.arguments(&.{ .number, .list_string })},
    },
    .{
        .name = "max",
        .value_types = &.{.number},
        .allow_default = false,
        .unique = true,
        .kind = .validation,
        .valid_for = &.{.arguments(&.{ .number, .list_number })},
    },
    .{
        .name = "pattern",
        .value_types = &.{.string},
        .allow_default = false,
        .unique = true,
        .kind = .validation,
        .valid_for = &.{.arguments(&.{ .string, .list_string })},
    },
    .{
        .name = "min_items",
        .value_types = &.{.number},
        .allow_default = false,
        .unique = true,
        .kind = .validation,
        .valid_for = &.{.arguments(&.{ .list_string, .list_number })},
    },
    .{
        .name = "max_items",
        .value_types = &.{.number},
        .allow_default = false,
        .unique = true,
        .kind = .validation,
        .valid_for = &.{.arguments(&.{ .list_string, .list_number })},
    },
};

pub const definitions = Attributes(platform_specs ++ attr_specs);

fn Attributes(comptime specs: []const Spec) type {
    const AttributeType = blk: {
        const EnumTag = enums.FitUnsigned(specs.len);

        var names: [specs.len][]const u8 = undefined;

        for (specs, 0..) |spec, idx| {
            names[idx] = spec.name;
        }

        const values = ct.iter(EnumTag, specs.len);

        break :blk @Enum(EnumTag, .exhaustive, &names, &values);
    };

    const Definition = struct {
        type: AttributeType,
        value_types: []const MetaType,
        allow_default: bool,
        unique: bool,
        kind: Kind,
        valid_for: []const ValidFor,
    };

    const defs = blk: {
        var defs: [specs.len]Definition = undefined;

        for (specs, 0..) |spec, idx| {
            defs[idx] = def: {
                var out = ct.copyFields(Definition, spec);
                out.type = @enumFromInt(idx);

                break :def out;
            };
        }
        break :blk defs;
    };

    const name_map = enums.generateEnumNameMap(AttributeType);

    return struct {
        pub const Type = AttributeType;

        pub const Target = union(TargetType) {
            task,
            group,
            setting,
            argument: typing.ArgType,

            fn validate(self: *const Target, vf: *const ValidFor) bool {
                const tt: TargetType = blk: {
                    const left = std.meta.activeTag(self.*);
                    const right = std.meta.activeTag(vf.*);

                    if (left != right)
                        return false;

                    break :blk left;
                };

                return switch (tt) {
                    .argument => vf.argument.count() == 0 or vf.argument.contains(self.argument),
                    else => true,
                };
            }
        };

        pub fn get(name: []const u8, target: ?Target) ?Definition {
            const def = blk: {
                const @"type" = name_map.get(name) orelse return null;
                break :blk defs[@intFromEnum(@"type")];
            };

            // validate

            if (target) |t| {
                for (def.valid_for) |vf| {
                    if (t.validate(&vf)) break;
                } else {
                    return null;
                }
            }

            return def;
        }
    };
}

const Spec = struct {
    name: []const u8,
    value_types: []const MetaType,
    allow_default: bool,
    unique: bool,
    kind: Kind,
    valid_for: []const ValidFor,
};

const TargetType = enum { task, group, setting, argument };

pub const ValidFor = union(TargetType) {
    task,
    group,
    setting,
    argument: std.EnumSet(typing.ArgType),

    pub const any_argument: ValidFor = .{ .argument = .initEmpty() };

    pub fn arguments(types: []const typing.ArgType) ValidFor {
        return .{ .argument = .initMany(types) };
    }
};

pub fn typesListToString(allocator: std.mem.Allocator, ts: []const ast.MetaType, default: bool) ![]const u8 {
    const out = blk: {
        var out = try std.ArrayList([]const u8).initCapacity(allocator, ts.len);

        if (default) {
            try out.append(allocator, "default");
        }

        for (ts) |t| {
            const str = try std.fmt.allocPrint(allocator, "{f}", .{t});
            try out.append(allocator, str);
        }
        break :blk try out.toOwnedSlice(allocator);
    };
    defer allocator.free(out);

    const joined = try std.mem.join(allocator, ", ", out);
    defer allocator.free(joined);

    return try std.fmt.allocPrint(allocator, "{{{s}}}", .{joined});
}
