const std = @import("std");

pub const Severity = enum {
    err,
    warning,
    hint,

    pub fn format(self: Severity, writer: *std.Io.Writer) !void {
        return switch (self) {
            .err => writer.writeAll("error"),
            .warning => writer.writeAll("warning"),
            .hint => writer.writeAll("hint"),
        };
    }
};

pub const Details = union(enum) {
    argument: ?usize,
    runtime,
};

pub const Diagnostic = struct {
    details: Details,
    message: []const u8,
    severity: Severity,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }

    pub fn Create(
        gpa: std.mem.Allocator,
        severity: Severity,
        details: Details,
        comptime fmt: []const u8,
        args: anytype,
    ) !Diagnostic {
        const msg = try std.fmt.allocPrint(gpa, fmt, args);
        return .{
            .severity = severity,
            .details = details,
            .message = msg,
        };
    }

    pub fn Err(
        gpa: std.mem.Allocator,
        details: Details,
        comptime fmt: []const u8,
        args: anytype,
    ) !Diagnostic {
        return Diagnostic.Create(gpa, .err, details, fmt, args);
    }

    pub fn Warn(
        gpa: std.mem.Allocator,
        details: Details,
        comptime fmt: []const u8,
        args: anytype,
    ) !Diagnostic {
        return Diagnostic.Create(gpa, .warning, details, fmt, args);
    }

    pub fn Hint(
        gpa: std.mem.Allocator,
        details: Details,
        comptime fmt: []const u8,
        args: anytype,
    ) !Diagnostic {
        return Diagnostic.Create(gpa, .hint, details, fmt, args);
    }

    pub const List = DiagnosticList;
};

pub const DiagnosticList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) DiagnosticList {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DiagnosticList) void {
        for (self.items.items) |*i| {
            i.deinit(self.allocator);
        }

        self.items.deinit(self.allocator);
    }

    pub fn append(self: *DiagnosticList, severity: Severity, details: Details, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(self.allocator, try .Create(self.allocator, severity, details, fmt, args));
    }

    pub fn Err(
        self: *DiagnosticList,
        details: Details,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.items.append(self.allocator, try .Err(self.allocator, details, fmt, args));
    }

    pub fn Warn(
        self: *DiagnosticList,
        details: Details,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.items.append(self.allocator, try .Warn(self.allocator, details, fmt, args));
    }

    pub fn Hint(
        self: *DiagnosticList,
        details: Details,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.items.append(self.allocator, try .Hint(self.allocator, details, fmt, args));
    }
};
