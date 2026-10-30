const std = @import("std");

const compiler = @import("compiler");
const cst = compiler.cst;
const Scope = compiler.scope.Scope;

const CursorContext = @This();

exact: ?*const cst.Token,
scope: *const Scope,
stack: []const *const cst.Node,

pub fn deinit(self: *const CursorContext, allocator: std.mem.Allocator) void {
    allocator.free(self.stack);
}

pub fn lastNode(self: *const CursorContext) ?*const cst.Node {
    return if (self.stack.len != 0)
        self.stack[self.stack.len - 1]
    else
        null;
}

pub fn atNode(self: *const CursorContext, kind: cst.NodeKind) bool {
    const node = self.lastNode() orelse return false;
    return node.kind == kind;
}

pub fn isNode(self: *const CursorContext, kind: cst.NodeKind) bool {
    for (self.stack) |node|
        if (node.kind == kind)
            return true;

    return false;
}

pub fn significantParent(
    self: *const CursorContext,
    comptime significant: []const cst.NodeKind,
    comptime limiter: ?cst.NodeKind,
) ?*const cst.Node {
    const set: std.EnumSet(cst.NodeKind) = comptime .initMany(significant);
    if (comptime limiter) |l| {
        if (comptime set.contains(l))
            @compileError("significant set shouldn't contain the limiter");
    }

    var it = std.mem.reverseIterator(self.stack);
    while (it.next()) |node| {
        if (limiter == node.kind) return null;
        if (set.contains(node.kind)) return node;
    }
    return null;
}

pub fn build(
    allocator: std.mem.Allocator,
    root_node: *const cst.Node,
    root_scope: *const Scope,
    pos: u32,
) !CursorContext {
    const Walker = struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        stack: std.ArrayList(*const cst.Node),
        scope: *const Scope,
        pos: u32,

        fn descend(self: *Self, items: []const cst.Element) !?*const cst.Token {
            for (items) |*item| {
                if (!item.trimmedSpan().contains(self.pos)) continue;

                switch (item.*) {
                    .node => |node| {
                        if (self.scope.child(node)) |child_scope|
                            self.scope = child_scope;

                        try self.stack.append(self.allocator, node);

                        if (try self.descend(node.children)) |token|
                            return token;
                    },
                    .token => |*token| return token,
                    .missing => {},
                }
            }
            return null;
        }
    };

    var walker: Walker = .{
        .allocator = allocator,
        .stack = .empty,
        .scope = root_scope,
        .pos = pos,
    };

    const exact = try walker.descend(root_node.children);

    return .{
        .exact = exact,
        .scope = walker.scope,
        .stack = try walker.stack.toOwnedSlice(allocator),
    };
}
