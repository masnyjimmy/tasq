const std = @import("std");
const ir = @import("ir.zig");

const lib = @import("lib");
const enums = lib.enums;
const ct = lib.@"comptime";

const @"type" = @import("type.zig");
const Type = @"type".Type;
const TypeExpr = @"type".TypeExpr;

pub const Error = error{
    UnknownFunction,
    InvalidArguments,
} || std.mem.Allocator.Error;

pub const ResolvedFunction = struct {
    id: definitions.Id,
    return_type: Type,
};

pub fn resolveArguments(allocator: std.mem.Allocator, params: []const Spec.Param, args: []const Type) !?std.StringHashMap(Type) {
    var bindings: std.StringHashMap(Type) = .init(allocator);
    defer bindings.deinit();

    for (params, args) |param, arg| {
        if (!try matchAndBind(&bindings, param.type, arg))
            return null;
    }

    return bindings.move(); // move to prevent deinit on returned map
}

fn matchAndBind(bindings: *std.StringHashMap(Type), p: TypeExpr, a: Type) !bool {
    return switch (p) {
        .concrete => |t| Type.eq(t, a),
        .generic => |name| {
            if (bindings.get(name)) |bound| return Type.eq(bound, a);
            try bindings.put(name, a);
            return true;
        },
        .list => |elem_p| a == .list and try matchAndBind(bindings, elem_p.*, a.list.*),
    };
}

fn resolveType(allocator: std.mem.Allocator, bindings: *const std.StringHashMap(Type), p: TypeExpr) !Type {
    return switch (p) {
        .concrete => |t| t,
        .generic => |name| bindings.get(name) orelse unreachable, // unbound generic, shouldn't ever happen on builtin functions
        .list => |elem_p| {
            const items_type = try allocator.create(Type);
            items_type.* = try resolveType(allocator, bindings, elem_p.*);

            return .{ .list = items_type };
        },
    };
}

pub const definitions = Functions(&.{
    .{
        .name = "env",
        .args = &.{
            .{
                .name = "key",
                .type = .{ .concrete = Type.string },
            },
            .{
                .name = "default",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .concrete = Type.string },
    },
    .{
        .name = "exists",
        .args = &.{
            .{
                .name = "path",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .concrete = Type.bool },
    },
    .{
        .name = "os",
        .args = &.{},
        .return_type = .{ .concrete = Type.string },
    },
    .{
        .name = "status_code",
        .args = &.{},
        .return_type = .{ .concrete = Type.number },
    },
    .{
        .name = "error",
        .args = &.{
            .{
                .name = "message",
                .type = .{ .concrete = Type.string },
            },
            // .{ .name = "code", .type = Type.number },
        },
        .return_type = .{ .concrete = Type.noreturn },
    },
    .{
        .name = "print",
        .args = &.{
            .{
                .name = "message",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .concrete = Type.void },
    },
    .{
        .name = "toArray",
        .args = &.{
            .{
                .name = "value",
                .type = .{ .generic = "T" },
            },
        },
        .return_type = .{
            .list = &.{
                .generic = "T",
            },
        },
    },
});

fn Functions(comptime specs: []const Spec) type {
    const FnIdent = blk: {
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

    // For each spec (by original index), which unique-name index (i.e. FnId) it maps to.
    const spec_to_id: [specs.len]FnIdent = blk: {
        var unique_names: [specs.len][]const u8 = undefined;
        var unique_count: usize = 0;
        var ids: [specs.len]FnIdent = undefined;

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

    const FunctionId = enum(usize) { _ };

    const Definition = struct {
        id: FunctionId,
        ident: FnIdent,
        args: []const Spec.Param,
        return_type: TypeExpr,
    };

    const defs = blk: {
        var defs: [specs.len]Definition = undefined;

        for (specs, 0..) |spec, idx| {
            defs[idx] = def: {
                var out = ct.copyFields(Definition, spec);
                out.id = @enumFromInt(idx);
                out.ident = spec_to_id[idx];

                break :def out;
            };
        }
        break :blk defs;
    };

    const name_map = enums.generateEnumNameMap(FnIdent);

    return struct {
        pub const items = defs;

        pub const Id = FunctionId;

        pub fn resolve(allocator: std.mem.Allocator, name: []const u8, args: []const Type) Error!ResolvedFunction {
            const ident = name_map.get(name) orelse return Error.UnknownFunction;

            for (defs) |def| {
                if (def.ident != ident)
                    continue;

                if (def.args.len != args.len)
                    continue;

                var resolved = try resolveArguments(allocator, def.args, args) orelse continue;
                defer resolved.deinit();

                const return_type = try resolveType(allocator, &resolved, def.return_type);

                return .{
                    .id = def.id,
                    .return_type = return_type,
                };
            }

            return Error.InvalidArguments;
        }
    };
}
const Spec = struct {
    const Param = struct {
        name: []const u8,
        type: TypeExpr,
    };

    name: []const u8,
    args: []const Param,
    return_type: TypeExpr,
};
