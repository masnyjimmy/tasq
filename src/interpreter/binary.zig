const std = @import("std");

const compiler = @import("compiler");
const Type = compiler.Type;
const Value = compiler.Value;
const ir = compiler.ir;
const binary = compiler.binary;

pub const Error = binary.Error;

pub fn evalBinary(allocator: std.mem.Allocator, op: ir.BinaryOp, left: Value, right: Value) !Value {
    // The type check is the single source of truth for what is allowed; everything below
    // can rely on it and only asserts.
    const result_type = try binary.binaryResultType(op, left.typeOf(), right.typeOf());

    return switch (op) {
        .add => if (result_type == .string)
            try evalConcat(allocator, left, right)
        else
            evalArithmetic(op, left, right),
        .sub, .mul, .div, .mod => evalArithmetic(op, left, right),
        .gt, .gt_eq, .lt, .lt_eq => evalOrdering(op, left, right),
        .eq, .neq => evalEquality(op, left, right),
        .and_op, .or_op => evalLogical(op, left, right),
    };
}

fn evalConcat(allocator: std.mem.Allocator, left: Value, right: Value) !Value {
    std.debug.assert(left == .string and right == .string);

    const result = try std.mem.concat(allocator, u8, &.{ left.string, right.string });

    return .{ .string = result };
}

fn evalArithmetic(op: ir.BinaryOp, left: Value, right: Value) Value {
    std.debug.assert(left == .number and right == .number);

    const l = left.number;
    const r = right.number;

    const result = switch (op) {
        .add => l + r,
        .sub => l - r,
        .mul => l * r,
        .div => l / r,
        .mod => @rem(l, r),
        else => unreachable,
    };

    return .{ .number = result };
}

fn evalOrdering(op: ir.BinaryOp, left: Value, right: Value) Value {
    const result = switch (left) {
        .number => |l| blk: {
            const r = right.number;
            break :blk switch (op) {
                .gt => l > r,
                .gt_eq => l >= r,
                .lt => l < r,
                .lt_eq => l <= r,
                else => unreachable,
            };
        },
        // Lexical, byte-wise comparison.
        .string => |l| blk: {
            const order = std.mem.order(u8, l, right.string);
            break :blk switch (op) {
                .gt => order == .gt,
                .gt_eq => order != .lt,
                .lt => order == .lt,
                .lt_eq => order != .gt,
                else => unreachable,
            };
        },
        else => unreachable,
    };

    return .{ .bool = result };
}

fn evalEquality(op: ir.BinaryOp, left: Value, right: Value) Value {
    const equal = valuesEqual(left, right);

    const result = switch (op) {
        .eq => equal,
        .neq => !equal,
        else => unreachable,
    };

    return .{ .bool = result };
}

fn valuesEqual(left: Value, right: Value) bool {
    const T = left.typeOf();

    // `eq`, not `same`: `[]unknown` (an empty list literal) must be comparable with `[]number`.
    std.debug.assert(T.eq(right.typeOf()));

    switch (T) {
        .string => return std.mem.eql(u8, left.string, right.string),
        .list => {
            if (left.list.items.len != right.list.items.len) return false;

            for (left.list.items, right.list.items) |l, r| {
                if (!valuesEqual(l, r)) return false;
            }

            return true;
        },
        .tuple => {
            if (left.tuple.elements.len != right.tuple.elements.len) return false;

            for (left.tuple.elements, right.tuple.elements) |l, r| {
                if (!valuesEqual(l, r)) return false;
            }

            return true;
        },
        .noreturn, .result, .lambda, .unknown => unreachable,
        inline else => |_, tag| {
            const left_value = @field(left, @tagName(tag));
            const right_value = @field(right, @tagName(tag));

            return left_value == right_value;
        },
    }
}

fn evalLogical(op: ir.BinaryOp, left: Value, right: Value) Value {
    std.debug.assert(left == .bool and right == .bool);

    const result = switch (op) {
        .and_op => left.bool and right.bool,
        .or_op => left.bool or right.bool,
        else => unreachable,
    };

    return .{ .bool = result };
}
