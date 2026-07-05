const std = @import("std");

const TaskId = @This();

name: []const u8,
groupName: ?[]const u8,

pub fn parse(id: []const u8) TaskId {
    const cut = blk: {
        if (std.mem.cut(u8, id, ".")) |cut|
            break :blk cut;

        return .{
            .name = id,
            .groupName = null,
        };
    };

    return .{
        .groupName = cut[0],
        .name = cut[1],
    };
}
