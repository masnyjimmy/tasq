const std = @import("std");

const Span = @This();

start: u32,
len: u32,

pub fn end(self: @This()) u32 {
    return self.start + self.len;
}

pub const Registry = struct {
    pub const SpanId = enum(u32) { _ };
    const Index = usize;

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

    const Node = struct {
        object: Span,
        name: ?Span,
        value: ?Span,
        extra: ?Span, // TaskCallScope => group, Argument => type
    };
    const IndexMap = std.hash_map.AutoHashMapUnmanaged(SpanId, Node);

    allocator: std.mem.Allocator,
    spans: std.ArrayList(Item) = .empty,
    nodes: std.hash_map.AutoHashMapUnmanaged(SpanId, Node),
    next_id: u32 = 0,

    fn getNextId(self: *Registry) SpanId {
        defer self.next_id += 1;
        return @enumFromInt(self.next_id);
    }
    pub fn put(self: *Registry, st: Type, span: Span) !void {
        std.debug.assert(st != .node);

        try self.spans.append(self.allocator, span);
    }

    // task,group,set,
    pub fn putNode(self: *Registry, span: Span, name: ?Span, value: ?Span, extra: ?Span) !SpanId {
        const id = self.getNextId();

        try self.nodes.put(self.allocator, .{
            .object = span,
            .name = name,
            .value = value,
            .extra = extra,
        });

        try self.nodes.put(self.allocator, id, .{
            .object = span,
            .name = name,
            .value = value,
        });

        return id;
    }

    // bellow functions asserts that those exists
    // it will be known from either ast or ir,

    pub fn fullSpan(self: *Registry, id: SpanId) Span {
        return self.nodes.get(id).?.object;
    }
    pub fn nameSpan(self: *Registry, id: SpanId) Span {
        return self.nodes.get(id).?.name.?;
    }

    pub fn valueSpan(self: *Registry, id: SpanId) Span {
        return self.nodes.get(id).?.value.?;
    }

    pub fn extraSpan(self: *Registry, id: SpanId) Span {
        return self.nodes.get(id).?.extra.?;
    }
};
