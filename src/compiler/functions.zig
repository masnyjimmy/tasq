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

const debug_functions: []const Spec = &.{
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
};

const type_cast_functions: []const Spec = &.{
    .{
        .name = "parse_number",
        .args = &.{
            .{
                .name = "str",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .result = &.{ .concrete = Type.number } },
    },
};

const fs_functions: []const Spec = &.{
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
};

const string_functions: []const Spec = &.{
    .{
        .name = "len",
        .args = &.{
            .{
                .name = "str",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .concrete = Type.number },
    },
    .{
        .name = "split",
        .args = &.{
            .{
                .name = "str",
                .type = .{ .concrete = Type.string },
            },
            .{
                .name = "sep",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .list = &.{ .concrete = Type.string } },
    },
    .{
        .name = "join",
        .args = &.{
            .{
                .name = "strings",
                .type = .{ .list = &.{ .concrete = Type.string } },
            },
            .{
                .name = "sep",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .concrete = Type.string },
    },
    .{
        .name = "lower",
        .args = &.{
            .{
                .name = "str",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .concrete = Type.string },
    },
    .{
        .name = "upper",
        .args = &.{
            .{
                .name = "str",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .concrete = Type.string },
    },
    .{
        .name = "contains",
        .args = &.{
            .{
                .name = "str",
                .type = .{ .concrete = Type.string },
            },
            .{
                .name = "sub",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .concrete = Type.bool },
    },
    .{
        .name = "starts_with",
        .args = &.{
            .{
                .name = "str",
                .type = .{ .concrete = Type.string },
            },
            .{
                .name = "sub",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .concrete = Type.bool },
    },
    .{
        .name = "ends_with",
        .args = &.{
            .{
                .name = "str",
                .type = .{ .concrete = Type.string },
            },
            .{
                .name = "sub",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .concrete = Type.bool },
    },

    .{
        .name = "replace",
        .args = &.{
            .{
                .name = "str",
                .type = .{ .concrete = Type.string },
            },
            .{
                .name = "old",
                .type = .{ .concrete = Type.string },
            },
            .{
                .name = "new",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .concrete = Type.string },
    },
};

const collections_functions: []const Spec = &.{
    .{
        .name = "len",
        .args = &.{
            .{
                .name = "list",
                .type = .{ .list = &.{ .generic = "T" } },
            },
        },
        .return_type = .{ .concrete = Type.number },
    },
    .{
        .name = "replace",
        .args = &.{
            .{
                .name = "list",
                .type = .{ .list = &.{ .generic = "T" } },
            },
            .{
                .name = "old",
                .type = .{ .generic = "T" },
            },
            .{
                .name = "new",
                .type = .{ .generic = "T" },
            },
        },
        .return_type = .{ .list = &.{ .generic = "T" } },
    },
    .{
        .name = "any",
        .args = &.{
            .{
                .name = "list",
                .type = .{
                    .list = &.{
                        .generic = "T",
                    },
                },
            },
            .{
                .name = "fn",
                .type = .{
                    .lambda = &.{
                        .params = &.{
                            .{ .generic = "T" },
                        },
                        .return_type = .{
                            .concrete = Type.bool,
                        },
                    },
                },
            },
        },
        .return_type = .{ .concrete = Type.bool },
    },
    .{
        .name = "all",
        .args = &.{
            .{
                .name = "list",
                .type = .{
                    .list = &.{
                        .generic = "T",
                    },
                },
            },
            .{
                .name = "fn",
                .type = .{
                    .lambda = &.{
                        .params = &.{
                            .{ .generic = "T" },
                        },
                        .return_type = .{
                            .concrete = Type.bool,
                        },
                    },
                },
            },
        },
        .return_type = .{ .concrete = Type.bool },
    },
    .{
        .name = "reduce",
        .args = &.{
            .{
                .name = "list",
                .type = .{ .list = &.{ .generic = "T" } },
            },
            .{
                .name = "init",
                .type = .{ .generic = "T" },
            },
            .{
                .name = "fn",
                .type = .{
                    .lambda = &.{
                        .params = &.{
                            .{ .generic = "T" },
                            .{ .generic = "T" },
                        },
                        .return_type = .{ .generic = "T" },
                    },
                },
            },
        },
        .return_type = .{ .generic = "T" },
    },
};

const misc_functions: []const Spec = &.{
    .{
        .name = "env",
        .args = &.{
            .{
                .name = "key",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .result = &.{ .concrete = Type.string } },
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
};

pub const definitions = Functions(
    debug_functions ++
        type_cast_functions ++
        fs_functions ++
        string_functions ++
        collections_functions ++
        misc_functions,
);

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

    // FIX: heavy comptime meta programming, need this
    @setEvalBranchQuota(5_000);
    const name_map = enums.generateEnumNameMap(FnIdent);

    return struct {
        pub const items = defs;

        pub const Id = FunctionId;

        pub fn resolve(allocator: std.mem.Allocator, name: []const u8, args: []const InArg) Error!ResolvedFunction {
            const ident = name_map.get(name) orelse return Error.UnknownFunction;

            for (defs) |def| {
                if (def.ident != ident)
                    continue;

                if (def.args.len != args.len)
                    continue;

                var resolved = try resolveArguments(allocator, def.args, args) orelse continue;
                defer resolved.deinit();

                const params = try allocator.alloc(OutArg, args.len);

                for (def.args, params) |in, *out| {
                    out.* = try resolveType(allocator, &resolved, in.type);
                }

                const return_type = try resolveType(allocator, &resolved, def.return_type);

                return .{
                    .id = def.id,
                    .params = params,
                    .return_type = return_type.value,
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

pub const InArg = union(enum) {
    lambda: struct {
        params: usize,
    },
    value: struct {
        type: Type,
    },
};

pub fn resolveArguments(allocator: std.mem.Allocator, params: []const Spec.Param, args: []const InArg) !?std.StringHashMap(Type) {
    var bindings: std.StringHashMap(Type) = .init(allocator);
    defer bindings.deinit();

    for (params, args) |param, arg| {
        if (!try matchAndBind(&bindings, param.type, arg))
            return null;
    }

    return bindings.move(); // move to prevent deinit on returned map
}

fn matchAndBind(bindings: *std.StringHashMap(Type), p: TypeExpr, a: InArg) !bool {
    return switch (p) {
        .concrete => |t| switch (a) {
            .value => |T| Type.eq(t, T.type),
            .lambda => false,
        },
        .generic => |name| switch (a) {
            .value => |T| {
                if (bindings.get(name)) |bound| return Type.eq(bound, T.type);
                try bindings.put(name, T.type);
                return true;
            },
            .lambda => false,
        },
        .list => |elem_p| switch (a) {
            .value => |T| T.type == .list and try matchAndBind(bindings, elem_p.*, .{
                .value = .{
                    .type = T.type.list.*,
                },
            }),
            .lambda => false,
        },
        .lambda => |lambda| switch (a) {
            .value => false,
            .lambda => |L| lambda.params.len == L.params,
        },
        .result => |result| switch (a) {
            .value => |T| try matchAndBind(bindings, result.*, .{ .value = .{ .type = T.type } }),
            .lambda => false,
        },
    };
}

pub const OutArg = union(enum) {
    value: Type,
    lambda: struct {
        params: []const Type,
        return_type: Type,
    },
};

pub const ResolvedFunction = struct {
    id: definitions.Id,
    params: []const OutArg,
    return_type: Type,
};

fn resolveType(allocator: std.mem.Allocator, bindings: *const std.StringHashMap(Type), p: TypeExpr) !OutArg {
    return switch (p) {
        .concrete => |t| .{ .value = t },
        .generic => |name| .{ .value = bindings.get(name) orelse unreachable }, // unbound generic, shouldn't ever happen on builtin functions
        .list => |elem_p| {
            const items_type = try allocator.create(Type);

            const resolved_type = try resolveType(allocator, bindings, elem_p.*);
            items_type.* = resolved_type.value;

            return .{
                .value = .{ .list = items_type },
            };
        },
        .lambda => |lambda| {
            const params = try allocator.alloc(Type, lambda.params.len);

            for (lambda.params, params) |in, *out| {
                const resolved_type = try resolveType(allocator, bindings, in);
                out.* = resolved_type.value;
            }

            const return_type = try resolveType(allocator, bindings, lambda.return_type);

            return .{
                .lambda = .{
                    .params = params,
                    .return_type = return_type.value,
                },
            };
        },
        .result => |result| {
            const result_type = try allocator.create(Type);
            const resolved_type = try resolveType(allocator, bindings, result.*);
            result_type.* = resolved_type.value;

            return .{
                .value = .{ .result = result_type },
            };
        },
    };
}
