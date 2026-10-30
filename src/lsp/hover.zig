const std = @import("std");

const CursorContext = @import("CursorContext.zig");
const compiler = @import("compiler");
const Workspace = compiler.Workspace;
const FileState = Workspace.FileState;
const cst = compiler.cst;

pub fn getSymbolType(allocator: std.mem.Allocator, file: *const FileState, pos: u32) !?compiler.Type {
    const cc = try CursorContext.build(
        allocator,
        file.tree.?,
        file.ir.?.scope,
        pos,
    );

    const target = cc.exact orelse return null;

    if (cc.significantParent(&.{ .name_ref, .name }, null) == null)
        return null;

    const symbol = cc.scope.resolve(target.lexeme, .variable) orelse return null;

    return symbol.origin.assertValueType();
}
