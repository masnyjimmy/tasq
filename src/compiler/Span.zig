const std = @import("std");
const lib = @import("lib");

const Span = @This();

start: u32,
len: u32,

pub fn end(self: @This()) u32 {
    return self.start + self.len;
}

pub fn insertionPoint(self: Span) Span {
    return .{ .start = self.start + self.len, .len = 0 };
}

pub fn between(left: Span, right: Span) Span {
    return .{
        .start = left.start,
        .len = right.end() - left.start,
    };
}

pub fn contains(self: Span, pos: u32) bool {
    return pos >= self.start and pos <= self.end();
}

pub fn after(self: Span, pos: u32) bool {
    return pos > self.end();
}

pub fn before(self: Span, pos: u32) bool {
    return pos < self.start;
}
