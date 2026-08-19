const std = @import("std");

const ir = @import("ir.zig");

const @"type" = @import("type.zig");
const Type = @"type".Type;

pub const Error = error{
    TypeMismatch,
};

pub fn binaryResultType(op: ir.BinaryOp, left: Type, right: Type) Error!BinaryResult {
    std.debug.assert(left != .noreturn and right != .noreturn);

    if (op == .add and left == .string and right == .string) {
        return .{ .result_type = .string };
    }

    return switch (op) {
        .add, .sub, .mul, .div => if (commonNumeric(left, right)) |cmn|
            .{
                .result_type = cmn,
                .coerce_to = cmn,
            }
        else
            Error.TypeMismatch,
        .gt, .gt_eq, .lt, .lt_eq => if (commonNumeric(left, right)) |_|
            .{ .result_type = .bool }
        else
            Error.TypeMismatch,
        .eq, .neq => if (Type.eq(left, right))
            .{ .result_type = .bool }
        else if (commonNumeric(left, right)) |cmn|
            .{ .result_type = .bool, .coerce_to = cmn }
        else
            Error.TypeMismatch,
        .and_op, .or_op => if (left == .bool and right == .bool)
            .{ .result_type = .bool }
        else
            Error.TypeMismatch,
    };
}

pub const BinaryResult = struct {
    result_type: Type,
    coerce_to: ?Type = null,
};

pub fn typesComparableForEquality(left: Type, right: Type) bool {
    if (Type.eq(left, right)) return true;
    if (commonNumeric(left, right) != null) return true;
    return false;
}

pub fn commonNumeric(a: Type, b: Type) ?Type {
    const ra = numericRank(a) orelse return null;
    const rb = numericRank(b) orelse return null;

    return if (ra >= rb) a else b;
}

fn numericRank(t: Type) ?u8 {
    return switch (t) {
        .number => 0,
        else => null,
    };
}
