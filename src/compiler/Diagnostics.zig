const std = @import("std");

const Span = @import("Span.zig");

pub const Severity = enum {
    err,
    warn,
    hint,
    unnecessary,

    pub fn format(self: Severity, writer: *std.Io.Writer) !void {
        return switch (self) {
            .err => writer.writeAll("error"),
            .warn => writer.writeAll("warning"),
            .hint => writer.writeAll("hint"),
            .unnecessary => writer.writeAll("unnecessary"),
        };
    }
};

const RelatedData = struct {
    span: Span,
    message: []const u8,
};

const Record = struct {
    span: Span,
    severity: Severity,
    message: []const u8,
    related: []const RelatedData = &.{},
};

const Diagnostics = @This();

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
records: std.ArrayList(Record) = .empty,
related: std.ArrayList(RelatedData) = .empty,
errors_count: u32 = 0,

pub fn init(allocator: std.mem.Allocator) Diagnostics {
    return .{
        .allocator = allocator,
        .arena = .init(allocator),
    };
}

pub fn deinit(self: *Diagnostics) void {
    self.records.deinit(self.allocator);
    self.related.deinit(self.allocator);
    self.arena.deinit();
}

pub fn clear(self: *Diagnostics) void {
    self.records.clearRetainingCapacity();
    self.related.clearRetainingCapacity();
    _ = self.arena.reset(.retain_capacity);
    self.errors_count = 0;
}

pub fn append(self: *Diagnostics, severity: Severity, span: Span, comptime fmt: []const u8, args: anytype) !void {
    var arena = self.arena.allocator();

    try self.records.append(self.allocator, .{
        .span = span,
        .severity = severity,
        .message = try arena.print(fmt, args),
        .related = try arena.dupe(RelatedData, self.related.items),
    });

    if (severity == .err)
        self.errors_count += 1;
}

pub fn pushRelated(self: *Diagnostics, span: Span, comptime fmt: []const u8, args: anytype) !void {
    try self.related.append(
        self.allocator,
        .{
            .span = span,
            .message = try self.arena.allocator().print(fmt, args),
        },
    );
}

pub fn popRelated(self: *Diagnostics) void {
    _ = self.related.pop();
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

pub fn uneccesary(self: *Diagnostics, span: Span, comptime fmt: []const u8, args: anytype) !void {
    try self.append(.unnecessary, span, fmt, args);
}
