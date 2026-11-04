const std = @import("std");

const ir = @import("ir.zig");
const Type = @import("type.zig").Type;

pub const Error = error{
    TypeMismatch,
};

pub fn binaryResultType(op: ir.BinaryOp, left: Type, right: Type) Error!Type {
    //TODO: consider how to handle this
    if (left == .noreturn or right == .noreturn) unreachable;

    // Equality is the only operation that accepts structured types (lists, tuples, results),
    // so it goes through `Type.eq`, which already treats `unknown` as a wildcard at any depth
    // (`[]number == []unknown` is fine).
    if (op == .eq or op == .neq) {
        return if (Type.eq(left, right)) .bool else error.TypeMismatch;
    }

    // Everything else works on scalars only, so both sides must agree on one operand type.
    const operand = commonOperand(left, right) orelse return error.TypeMismatch;

    return switch (op) {
        // `unknown + unknown` stays unknown: it could still turn out to be a string or a number.
        .add => switch (operand) {
            .number, .string, .unknown => operand,
            else => error.TypeMismatch,
        },
        // Only numbers are valid here, so the result is known even if both sides are unknown.
        .sub, .mul, .div, .mod => switch (operand) {
            .number, .unknown => .number,
            else => error.TypeMismatch,
        },
        // Strings compare lexically.
        .gt, .gt_eq, .lt, .lt_eq => switch (operand) {
            .number, .string, .unknown => .bool,
            else => error.TypeMismatch,
        },
        .and_op, .or_op => switch (operand) {
            .bool, .unknown => .bool,
            else => error.TypeMismatch,
        },
        .eq, .neq => unreachable, // handled above
    };
}

fn commonOperand(left: Type, right: Type) ?Type {
    if (left == .unknown) return right;
    if (right == .unknown) return left;
    return if (Type.same(left, right)) left else null;
}
