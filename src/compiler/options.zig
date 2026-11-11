const std = @import("std");

const lib = @import("lib");
const enums = lib.enums;
const ct = lib.@"comptime";

const meta = @import("meta.zig");
const MetaType = meta.Type;

const ir = @import("ir.zig");

pub const Options = struct {
    shell: []const []const u8,
    dotenv: ?[]const u8 = null,
    working_dir: ?[]const u8 = null,
    jobs: usize = 1,

    pub fn getDefaults() Options {
        return switch (lib.platform.tag) {
            .windows => .{
                .shell = &.{ "cmd", "/C" },
                .jobs = std.Thread.getCpuCount() catch unreachable,
            },
            .linux => .{
                .shell = &.{ "/bin/bash", "-c" },
                .jobs = std.Thread.getCpuCount() catch 1,
            },
        };
    }
};

pub fn formatValueTypes(allocator: std.mem.Allocator, def: definitions.DefinitionT) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    const last = def.value_types.len - 1;

    for (def.value_types, 0..) |vt, idx| {
        try aw.writer.print("{f}", .{vt});

        if (idx != last) {
            try aw.writer.writeAll(",");
        }
    }

    return try aw.toOwnedSlice();
}

pub const definitions = OptionsGroup(&.{
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
        .name = "jobs",
        .value_types = &.{.number},
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
                out.id = @fromBackingInt(@intCast(idx));

                break :def out;
            };
        }
        break :blk defs;
    };

    const name_map = enums.generateEnumNameMap(Id);

    return struct {
        pub const DefinitionT = Definition;
        pub const raw = defs;
        pub const Type = Id;

        pub fn get(name: []const u8) ?Definition {
            const t = name_map.get(name) orelse return null;
            return defs[@backingInt(t)];
        }
    };
}

const Spec = struct {
    name: []const u8,
    value_types: []const MetaType,
};
