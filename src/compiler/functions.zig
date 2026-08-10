const std = @import("std");
const ir = @import("ir.zig");

const lib = @import("lib");
const enums = lib.enums;
const ct = lib.@"comptime";

const typing = @import("typing.zig");
const Type = typing.Type;

pub const definitions = Functions(&.{
    .{
        .name = "env",
        .args = &.{
            .{ .name = "key", .type = Type.string },
        },
        .return_type = Type.string,
    },
    .{
        .name = "env",
        .args = &.{
            .{ .name = "key", .type = Type.string },
            .{ .name = "default", .type = Type.string },
        },
        .return_type = Type.string,
    },
    .{
        .name = "exists",
        .args = &.{
            .{ .name = "path", .type = Type.string },
        },
        .return_type = Type.bool,
    },
    .{
        .name = "os",
        .args = &.{},
        .return_type = Type.string,
    },
    .{
        .name = "status_code",
        .args = &.{},
        .return_type = Type.number,
    },
    .{
        .name = "error",
        .args = &.{
            .{ .name = "message", .type = Type.string },
            // .{ .name = "code", .type = Type.number },
        },
        .return_type = Type.noreturn,
    },
    .{
        .name = "print",
        .args = &.{
            .{ .name = "message", .type = Type.string },
        },
        .return_type = Type.void,
    },
});

fn Functions(comptime specs: []const Spec) type {
    const FnId = blk: {
        const EnumTag = enums.FitUnsigned(specs.len);

        var unique_names: [specs.len][]const u8 = undefined;
        var unique_count: usize = 0;

        outer: for (specs) |spec| {
            for (unique_names[0..unique_count]) |existing| {
                if (std.mem.eql(u8, existing, spec.name)) continue :outer;
            }
            unique_names[unique_count] = spec.name;
            unique_count += 1;
        }

        const values = ct.iter(EnumTag, unique_count);

        break :blk @Enum(
            EnumTag,
            .exhaustive,
            unique_names[0..unique_count],
            &values,
        );
    };

    const Definition = struct {
        id: FnId,
        args: []const Spec.Arg,
        return_type: typing.Type,
    };

    // For each spec (by original index), which unique-name index (i.e. FnId) it maps to.
    const spec_to_id: [specs.len]FnId = blk: {
        var unique_names: [specs.len][]const u8 = undefined;
        var unique_count: usize = 0;
        var ids: [specs.len]FnId = undefined;

        for (specs, 0..) |spec, spec_idx| {
            var found: ?usize = null;
            for (unique_names[0..unique_count], 0..) |existing, uidx| {
                if (std.mem.eql(u8, existing, spec.name)) {
                    found = uidx;
                    break;
                }
            }
            const uidx = found orelse blk2: {
                unique_names[unique_count] = spec.name;
                unique_count += 1;
                break :blk2 unique_count - 1;
            };
            ids[spec_idx] = @enumFromInt(uidx);
        }

        break :blk ids;
    };

    const defs = blk: {
        var defs: [specs.len]Definition = undefined;

        for (specs, 0..) |spec, idx| {
            defs[idx] = def: {
                var out = ct.copyFields(Definition, spec);
                out.id = spec_to_id[idx];

                break :def out;
            };
        }
        break :blk defs;
    };

    const name_map = enums.generateEnumNameMap(FnId);

    return struct {
        pub const Type = FnId;

        pub const items = defs;

        pub fn get(name: []const u8, arg_num: usize) !Definition {
            const idx = try getIndex(name, arg_num);

            return defs[idx];
        }

        pub fn getById(id: FnId, arg_num: usize) !Definition {
            const idx = getIndexById(id, arg_num) orelse return Error.InvalidArguments;

            return defs[idx];
        }

        pub fn getIndexById(id: FnId, arg_num: usize) ?usize {
            std.debug.assert(enums.isValidEnumValue(FnId, id));

            for (defs, 0..) |def, idx| {
                if (def.id != id) continue;

                if (def.args.len == arg_num) {
                    return idx;
                }
            }

            return null;
        }

        pub fn getIndex(name: []const u8, arg_num: usize) !usize {
            const id = name_map.get(name) orelse return Error.UnknownFunction;
            return getIndexById(id, arg_num) orelse return Error.InvalidArguments;
        }

        pub fn getByIndex(index: usize) Definition {
            return defs[index];
        }

        pub const Error = error{
            UnknownFunction,
            InvalidArguments,
        };
    };
}
const Spec = struct {
    const Arg = struct {
        name: []const u8,
        type: Type,
    };

    name: []const u8,
    args: []const Arg,
    return_type: typing.Type,
};
