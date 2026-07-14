const std = @import("std");

const Span = @This();

start: u32,
len: u32,

pub fn end(self: @This()) u32 {
    return self.start + self.len;
}

pub const Registry = struct {
    pub const NodeType = enum {
        leaf,
        wrap,
        set,
        set_decl,
        group,
        task,
        argument,
        attribute,
        decl,
        block,
        if_stmt,
        task_call,
        task_call_arg,
        builtin_call,
        expr,
    };

    pub const SpanDetails = union(NodeType) {
        leaf,
        wrap: NodeId,

        set: struct { body: Span },
        set_decl: struct { name: Span, value: ?NodeId },

        group: struct { name: ?Span, args: ?Span, body: Span },
        task: struct { name: Span, args: ?Span, body: NodeId },

        argument: struct { name: Span, type: Span, default: ?NodeId },
        attribute: struct { name: Span, value: ?NodeId },

        decl: struct { name: Span, value: NodeId },

        block: struct { stmts: []const NodeId },
        if_stmt: struct { cond: NodeId, then: NodeId, else_: ?NodeId },

        task_call: struct { group: ?Span, task: Span, args: Span },
        task_call_arg: struct { name: ?Span, value: NodeId },

        builtin_call: struct { name: Span, args: []const NodeId },

        /// binary   -> children = .{ left, right }        (op needs no span)
        /// unary    -> children = .{ operand }
        /// if_expr  -> children = .{ cond, then, else_ }
        /// list     -> children = each item that has an id, in order
        /// inter    -> children = each {{expr}} segment's id, in order
        ///             (literal text segments go through `put`, not here)
        expr: union(enum) {
            binary: struct {
                left: NodeId,
                right: NodeId,
            },
            unary: struct {
                operand: NodeId,
            },
            if_expr: struct {
                cond: NodeId,
                then: NodeId,
                else_: NodeId,
            },
            list: []const NodeId,
        },

        pub fn span(self: SpanDetails) Span {
            return switch (self) {
                inline else => |v| if (@TypeOf(v) == Span) v else v.span,
            };
        }

        pub fn deinit(self: *SpanDetails, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .block => |v| {
                    allocator.free(v.stmts);
                },
                .builtin_call => |v| {
                    allocator.free(v.args);
                },
                .expr => |v| switch (v) {
                    .list => |list| {
                        allocator.free(list);
                    },
                    else => {},
                },
                else => {},
            }
        }
    };

    pub const SpanNode = struct {
        span: Span,
        details: SpanDetails,
    };

    pub fn Wrapped(comptime T: type) type {
        return struct {
            id: NodeId,
            payload: T,

            pub fn wrap(id: NodeId, value: T) @This() {
                return .{
                    .id = id,
                    .payload = value,
                };
            }
        };
    }

    pub const NodeId = enum(u32) {
        _,
    };

    const Type = enum {
        type,
        operator,
        keyword,
        string,
        number,
    };

    const Item = struct {
        type: Type,
        span: Span,
    };

    allocator: std.mem.Allocator,
    spans: std.ArrayList(Item) = .empty,
    nodes: std.ArrayList(SpanNode) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.spans.deinit(self.allocator);

        for (self.nodes.items) |*item| {
            item.details.deinit(self.allocator);
        }

        self.nodes.deinit(self.allocator);

        self.* = undefined;
    }
    // utility functions to get registry managed array list
    pub fn getArrayList(self: *Registry, comptime T: type, capacity: usize) !std.array_list.Managed(T) {
        return .initCapacity(self.allocator, capacity);
    }

    /// Flat, untyped/highlighting spans (strings, keywords, ...).
    pub fn put(self: *Registry, st: Type, span: Span) !void {
        try self.spans.append(self.allocator, .{ .type = st, .span = span });
    }

    pub fn addNode(self: *Registry, span: Span, details: SpanDetails) !NodeId {
        const idx = self.nodes.items.len;
        try self.nodes.append(self.allocator, .{
            .span = span,
            .details = details,
        });
        return @enumFromInt(idx);
    }

    pub fn get(self: *const Registry, id: NodeId) SpanNode {
        return self.nodes.items[@intFromEnum(id)];
    }

    pub fn getSpan(self: *const Registry, id: NodeId) Span {
        return self.get(id).span;
    }
};
