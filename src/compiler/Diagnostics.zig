const std = @import("std");

const Span = @import("span.zig");

pub const Severity = enum {
    err,
    warn,
    hint,

    pub fn format(self: Severity, writer: *std.Io.Writer) !void {
        return switch (self) {
            .err => writer.writeAll("error"),
            .warn => writer.writeAll("warning"),
            .hint => writer.writeAll("hint"),
        };
    }
};

const Record = struct {
    span: Span,
    severity: Severity,
    message: []const u8,
};

const Diagnostics = @This();

allocator: std.mem.Allocator,
records: std.ArrayList(Record) = .empty,

pub fn init(allocator: std.mem.Allocator) Diagnostics {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Diagnostics) void {
    for (self.records.items) |*rec| {
        self.allocator.free(rec.message);
    }

    self.records.deinit(self.allocator);
}

pub fn clear(self: *Diagnostics) void {
    self.records.clearRetainingCapacity();
}

pub fn append(self: *Diagnostics, severity: Severity, span: Span, comptime fmt: []const u8, args: anytype) !void {
    try self.records.append(self.allocator, .{
        .span = span,
        .severity = severity,
        .message = try std.fmt.allocPrint(self.allocator, fmt, args),
    });
}

pub fn err(self: *Diagnostics, span: Span, comptime fmt: []const u8, args: anytype) !void {
    try self.append(.err, span, fmt, args);
}

pub fn warn(self: *Diagnostics, span: Span, comptime fmt: []const u8, args: anytype) !void {
    try self.append(.warn, span, fmt, args);
}

pub fn hint(self: *Diagnostics, span: Span, comptime fmt: []const u8, args: anytype) !void {
    try self.append(.hint, span, fmt, args);
}
