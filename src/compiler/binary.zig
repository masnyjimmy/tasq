const std = @import("std");

const ir = @import("ir.zig");
const typing = @import("typing.zig");

pub const Error = error{
    TypeMismatch,
};

pub fn binaryResultType(op: ir.BinaryOp, left: typing.Type, right: typing.Type) Error!BinaryResult {
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
        .eq, .neq => if (typing.Type.eq(left, right))
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
    result_type: typing.Type,
    coerce_to: ?typing.Type = null,
};

pub fn typesComparableForEquality(left: typing.Type, right: typing.Type) bool {
    if (typing.Type.eq(left, right)) return true;
    if (commonNumeric(left, right) != null) return true;
    return false;
}

pub fn commonNumeric(a: typing.Type, b: typing.Type) ?typing.Type {
    const ra = numericRank(a) orelse return null;
    const rb = numericRank(b) orelse return null;

    return if (ra >= rb) a else b;
}

fn numericRank(t: typing.Type) ?u8 {
    return switch (t) {
        .number => 0,
        else => null,
    };
}
