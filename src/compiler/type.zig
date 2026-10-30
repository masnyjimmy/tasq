const std = @import("std");
const ast = @import("ast.zig");
const Scope = @import("scope.zig").Scope;
const lib = @import("lib");

const Tag = enum {
    string,
    number,
    bool,
    list,
    noreturn,
    void,
    lambda,
    result,
    unknown,
};

pub const LambdaTemplate = struct {
    template: ast.Lambda,
    parent_scope: *Scope,
};

pub const Type = union(Tag) {
    string,
    number,
    bool,
    list: *const Type,
    noreturn,
    void,
    lambda: *const LambdaTemplate,
    result: *const Type,
    /// "No information about this type." It is never a real type of a value that reaches the
    /// interpreter. It comes from lambda templates (parameters are not known yet), from error
    /// recovery, and from empty list literals (`[]` is a list of `unknown` until a context gives
    /// it its element type).
    unknown,

    /// The most informative type compatible with both `left` and `right`, or `null` when they
    /// conflict. This is the one rule everything else is built on:
    ///
    ///   - `noreturn` diverges, so it takes whatever the other side is
    ///   - `unknown` carries no information, so the other side wins (`unify([]number, []unknown)`
    ///     is `[]number`, in either argument order)
    ///   - otherwise the shapes must match, recursively for lists and results
    ///   - two lambdas are compatible only if they are the same lambda
    ///
    /// No allocation is needed: a type is a chain of wrappers (list, result) ending in a leaf, and
    /// the chain that carries more information is always one of the two inputs.
    pub fn unify(left: Type, right: Type) ?Type {
        switch (left) {
            .noreturn, .unknown => return right,
            else => {},
        }

        switch (right) {
            .noreturn, .unknown => return left,
            else => {},
        }

        if (@as(Tag, left) != @as(Tag, right)) return null;

        switch (left) {
            .list => |l| {
                const inner = unify(l.*, right.list.*) orelse return null;
                if (same(inner, l.*)) return left;
                std.debug.assert(same(inner, right.list.*));
                return right;
            },
            .result => |l| {
                const inner = unify(l.*, right.result.*) orelse return null;
                if (same(inner, l.*)) return left;
                std.debug.assert(same(inner, right.result.*));
                return right;
            },
            .lambda => return if (same(left, right)) left else null,
            else => return left,
        }
    }

    /// Strict structural identity. `unknown` is only the same as `unknown`.
    /// Use it where types are keys (hashing, caches); use `unify` / `eq` for compatibility.
    pub fn same(left: Type, right: Type) bool {
        if (@as(Tag, left) != @as(Tag, right)) return false;

        return switch (left) {
            .list => |l| same(l.*, right.list.*),
            .result => |r| same(r.*, right.result.*),
            // a lambda has no signature, it is its own type: the same syntax node is the same lambda
            .lambda => |l| l.template.node == right.lambda.template.node,
            else => true,
        };
    }

    /// Compatibility: could a value of one type be used where the other is expected?
    pub fn eq(left: Type, right: Type) bool {
        return unify(left, right) != null;
    }

    pub fn containsUnknown(self: Type) bool {
        return switch (self) {
            .unknown => true,
            .list => |items| items.containsUnknown(),
            .result => |t| t.containsUnknown(),
            else => false,
        };
    }

    /// Partially known: `[]unknown` is partial, `unknown` itself is not (it says nothing at all,
    /// so there is nothing to complete, and whoever produced it has already reported why).
    pub fn isPartial(self: Type) bool {
        return self != .unknown and self.containsUnknown();
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            .list => |t| try writer.print("[]{f}", .{t.*}),
            .result => |r| try writer.print("!{f}", .{r.*}),
            inline else => |_, tag| try writer.writeAll(@tagName(tag)),
        }
    }

    pub const MapContext = TypeMapContext;
};

pub const ArgType = enum {
    string,
    list_string,
    number,
    list_number,
    flag,

    pub fn typeOf(self: ArgType) Type {
        return switch (self) {
            .string => .string,
            .list_string => .{
                .list = &.string,
            },
            .number => .number,
            .list_number => .{
                .list = &.number,
            },
            .flag => .bool,
        };
    }

    pub fn format(self: ArgType, w: *std.Io.Writer) !void {
        const string = switch (self) {
            .list_string => "[]string",
            .list_number => "[]number",
            inline else => @tagName(self),
        };
        try w.writeAll(string);
    }

    pub fn isNamedOnly(self: ArgType) bool {
        return switch (self) {
            .list_string, .list_number, .flag => true,
            inline else => false,
        };
    }
};

pub const TypeExpr = union(enum) {
    concrete: Type,
    generic: []const u8,
    list: *const TypeExpr,
    lambda: *const LambdaTypeExpr,
    result: *const TypeExpr,
};

pub const LambdaTypeExpr = struct {
    params: []const TypeExpr,
    return_type: TypeExpr,
};

/// Hash map context for types used as keys. `eql` is the strict `same`, never the wildcard-ish
/// compatibility check, so that equal keys always hash equally.
pub const TypeMapContext = struct {
    pub fn hash(_: @This(), value: Type) u64 {
        var hasher = std.hash.Wyhash.init(0);
        updateHasher(.from(&hasher), value);
        return hasher.final();
    }

    pub fn eql(_: @This(), a: Type, b: Type) bool {
        return Type.same(a, b);
    }

    pub fn updateHasher(hasher: lib.hash.Hasher, value: Type) void {
        const tag = std.meta.activeTag(value);
        hasher.update(@tagName(tag));
        switch (value) {
            .list => |list| updateHasher(hasher, list.*),
            .lambda => |lambda| hasher.update(
                std.mem.asBytes(&lambda.template.node),
            ),
            .result => |result| updateHasher(hasher, result.*),
            else => {},
        }
    }
};
