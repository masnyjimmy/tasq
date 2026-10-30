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
    .{
        .name = "which",
        .args = &.{
            .{
                .name = "name",
                .type = .{ .concrete = Type.string },
            },
        },
        .return_type = .{ .result = &.{ .concrete = Type.string } },
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
            ids[spec_idx] = @fromBackingInt(@intCast(uidx));
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
                @setEvalBranchQuota(2_000);
                var out = ct.copyFields(Definition, spec);
                out.id = @fromBackingInt(@intCast(idx));
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
        pub const DefinitionT = Definition;

        pub const items = defs;

        pub const Id = FunctionId;

        /// Picks the overload of `name` that accepts `args`.
        ///
        /// Overloads are told apart by argument count and by what each argument can be. An
        /// argument of type `unknown` can be anything, so it may fit several overloads. In that
        /// case the first matching overload is returned (its parameters are only ever used for
        /// lambda templates or after an error, where nothing runs) and the result type is only
        /// claimed when every matching overload agrees on it; otherwise it is `unknown`.
        pub fn resolve(allocator: std.mem.Allocator, name: []const u8, args: []const InArg) Error!ResolvedFunction {
            const ident = name_map.get(name) orelse return Error.UnknownFunction;

            var chosen: ?ResolvedFunction = null;

            for (defs) |def| {
                if (def.ident != ident)
                    continue;

                if (def.args.len != args.len)
                    continue;

                var bindings = try resolveArguments(allocator, def.args, args) orelse continue;
                defer bindings.deinit();

                const params = try allocator.alloc(OutArg, args.len);

                for (def.args, params) |in, *out| {
                    out.* = try resolveType(allocator, &bindings, in.type);
                }

                const return_type = (try resolveType(allocator, &bindings, def.return_type)).value;

                if (chosen) |*first| {
                    if (!Type.same(first.return_type, return_type))
                        first.return_type = .unknown;
                } else {
                    chosen = .{
                        .id = def.id,
                        .params = params,
                        .return_type = return_type,
                    };
                }
            }

            return chosen orelse Error.InvalidArguments;
        }
    };
}
pub const Spec = struct {
    pub const Param = struct {
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

/// What the generic parameters (`T`) of one overload were pinned to.
const Bindings = std.StringHashMap(Type);

pub fn resolveArguments(allocator: std.mem.Allocator, params: []const Spec.Param, args: []const InArg) !?Bindings {
    var bindings: Bindings = .init(allocator);
    defer bindings.deinit();

    for (params, args) |param, arg| {
        if (!try matchAndBind(&bindings, param.type, arg))
            return null;
    }

    return bindings.move(); // move to prevent deinit on returned map
}

/// A generic parameter accumulates information from every argument that mentions it. Arguments
/// are combined with `unify`, so a known type wins over `unknown` in either order, and a conflict
/// rejects the overload. A parameter nothing pinned stays `unknown`.
fn bind(bindings: *Bindings, name: []const u8, arg_type: Type) !bool {
    const gop = try bindings.getOrPut(name);

    if (!gop.found_existing) {
        gop.value_ptr.* = arg_type;
        return true;
    }

    gop.value_ptr.* = Type.unify(gop.value_ptr.*, arg_type) orelse return false;
    return true;
}

fn matchAndBind(bindings: *Bindings, param: TypeExpr, arg: InArg) !bool {
    switch (param) {
        .concrete => |t| switch (arg) {
            .value => |v| return Type.eq(t, v.type),
            .lambda => return false,
        },
        .generic => |name| switch (arg) {
            .value => |v| return try bind(bindings, name, v.type),
            .lambda => return false,
        },
        .list => |elem_param| switch (arg) {
            .value => |v| {
                // `unknown` (and a diverging `noreturn`) may be a list of anything: it fits the
                // parameter and tells us nothing about the element type
                const elem_type: Type = switch (v.type) {
                    .list => |items| items.*,
                    .unknown, .noreturn => .unknown,
                    else => return false,
                };

                return try matchAndBind(bindings, elem_param.*, .{
                    .value = .{ .type = elem_type },
                });
            },
            .lambda => return false,
        },
        .lambda => |lambda_param| switch (arg) {
            .lambda => |l| return lambda_param.params.len == l.params,
            // an `unknown` value may be a lambda: it fits, and there is nothing to instantiate
            .value => |v| return v.type == .unknown,
        },
        .result => |inner| switch (arg) {
            .value => |v| return try matchAndBind(bindings, inner.*, .{ .value = v }),
            .lambda => return false,
        },
    }
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

fn resolveType(allocator: std.mem.Allocator, bindings: *const Bindings, p: TypeExpr) !OutArg {
    return switch (p) {
        .concrete => |t| .{ .value = t },
        // a generic that no argument pinned down is `unknown`
        .generic => |name| .{ .value = bindings.get(name) orelse .unknown },
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
