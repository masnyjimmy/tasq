const std = @import("std");

const compiler = @import("compiler");
const Type = compiler.Type;
const ArgType = compiler.ArgType;
const Value = compiler.Value;
const ir = compiler.ir;
const binary = compiler.binary;

pub const Error = binary.Error;

pub fn evalBinary(allocator: std.mem.Allocator, op: ir.BinaryOp, left: Value, right: Value) !Value {
    // string coersion

    const binary_result = try binary.binaryResultType(op, left.typeOf(), right.typeOf());

    if (op == .add and binary_result.result_type == .string) {
        return try evalConcat(allocator, left, right);
    }

    const l, const r = blk: {
        if (binary_result.coerce_to) |to|
            break :blk .{ coerce(left, to), coerce(right, to) };

        break :blk .{ left, right };
    };
    return switch (op) {
        .add, .sub, .mul, .div => evalArithmetic(op, l, r),
        .gt, .gt_eq, .lt, .lt_eq => evalOrdering(op, l, r),
        .eq, .neq => evalEquality(op, l, r),
        .and_op, .or_op => evalLogical(op, l, r),
    };
}

fn evalConcat(allocator: std.mem.Allocator, left: Value, right: Value) !Value {
    std.debug.assert(left == .string and right == .string);

    const result = try std.mem.concat(allocator, u8, &.{ left.string, right.string });

    return .{ .string = result };
}

fn evalArithmetic(op: ir.BinaryOp, left: Value, right: Value) Value {
    const T = blk: {
        const left_type = left.typeOf();
        const right_type = right.typeOf();
        std.debug.assert(Type.eq(left_type, right_type));

        break :blk left_type;
    };

    switch (T) {
        inline .number => |_, tag| {
            const left_value = @field(left, @tagName(tag));
            const right_value = @field(right, @tagName(tag));

            const result = switch (op) {
                .add => left_value + right_value,
                .sub => left_value - right_value,
                .div => left_value / right_value,
                .mul => left_value * right_value,
                else => unreachable,
            };

            return @unionInit(Value, @tagName(tag), result);
        },
        else => unreachable,
    }
}

fn evalOrdering(op: ir.BinaryOp, left: Value, right: Value) Value {
    const T = blk: {
        const left_type = left.typeOf();

        std.debug.assert(left_type.eq(right.typeOf()));

        break :blk left_type;
    };

    switch (T) {
        inline .number => |_, tag| {
            const left_value = @field(left, @tagName(tag));
            const right_value = @field(right, @tagName(tag));

            const result = switch (op) {
                .gt => left_value > right_value,
                .gt_eq => left_value >= right_value,
                .lt => left_value < right_value,
                .lt_eq => left_value <= right_value,
                else => unreachable,
            };

            return .{ .bool = result };
        },
        else => unreachable,
    }
}

fn evalEquality(op: ir.BinaryOp, left: Value, right: Value) Value {
    const T = blk: {
        const left_type = left.typeOf();

        std.debug.assert(left_type.eq(right.typeOf()));

        break :blk left_type;
    };

    const equal = blk: {
        break :blk switch (T) {
            .string => std.mem.eql(u8, left.string, right.string),
            .list => {
                if (left.list.items.len != right.list.items.len)
                    break :blk false;

                for (left.list.items, right.list.items) |l, r| {
                    if (evalEquality(.eq, l, r).bool == false)
                        break :blk false;
                }

                break :blk true;
            },
            .noreturn => unreachable,
            inline else => |_, tag| {
                const left_value = @field(left, @tagName(tag));
                const right_value = @field(right, @tagName(tag));

                break :blk left_value == right_value;
            },
        };
    };

    const result = switch (op) {
        .eq => equal,
        .neq => !equal,
        else => unreachable,
    };

    return .{ .bool = result };
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

fn coerce(v: Value, target: std.meta.Tag(Type)) Value {
    const v_type = v.typeOf();
    if (v_type == target) return v;

    unreachable; //TODO: implement later if other numeric types added,
}
