const std = @import("std");

const lib = @import("lib");
const enums = lib.enums;
const ct = lib.@"comptime";

const meta = @import("meta.zig");
const MetaType = meta.Type;

const ir = @import("ir.zig");

pub const Options = struct {
    pub const TaskLabel = enum {
        none,
        name,
        full,

        pub const map = lib.enums.generateEnumNameMap(TaskLabel);
    };

    shell: []const []const u8,
    script: []const []const u8,
    dotenv: ?[]const u8 = null,
    working_dir: ?[]const u8 = null,
    task_label: TaskLabel = .full,
    jobs: usize = 1,

    pub fn getDefaults() Options {
        return switch (lib.platform.tag) {
            .windows => .{
                .shell = &.{ "cmd", "/C" },
                .script = &.{ "cmd", "/C" },
                .jobs = std.Thread.getCpuCount() catch unreachable,
            },
            .linux => .{
                .shell = &.{ "/bin/sh", "-c" },
                .script = &.{ "/bin/sh", "-eu" },
                .jobs = std.Thread.getCpuCount() catch 1,
            },
        };
    }
};

pub fn formatValueTypes(allocator: std.mem.Allocator, def: definitions.DefinitionT) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);

    for (def.value_types, 0..) |vt, idx| {
        if (idx != 0) {
            try aw.writer.writeAll(",");
        }
        try aw.writer.print("{f}", .{vt});
    }

    return try aw.toOwnedSlice();
}

pub const definitions = Definitions(&.{
    .{
        .name = "shell",
        .value_types = &.{
            .{ .list = &.any_string },
        },
    },
    .{
        .name = "script",
        .value_types = &.{
            .{ .list = &.any_string },
        },
    },
    .{
        .name = "dotenv",
        .value_types = &.{
            .bool,
            .any_string,
        },
    },
    .{
        .name = "working_dir",
        .value_types = &.{
            .any_string,
        },
    },
    .{
        .name = "jobs",
        .value_types = &.{
            .{ .number = .{ .int = true, .min = 1 } },
        },
    },
    .{
        .name = "task_label",
        .value_types = &.{
            .{
                .string = .{
                    .options = std.meta.fieldNames(Options.TaskLabel),
                },
            },
        },
    },
});

fn Definitions(comptime specs: []const Spec) type {
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
