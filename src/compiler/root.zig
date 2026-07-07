const std = @import("std");
const lib = @import("lib");

pub const platform = @import("platform.zig");

const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;

const parser_lib = @import("parser.zig");
pub const Parser = parser_lib.Parser;

pub const ast = @import("ast.zig");

const sema_lib = @import("sema.zig");
pub const Sema = sema_lib.Sema;

pub const ir = @import("ir.zig");

pub const typing = @import("typing.zig");

pub const Value = typing.Value;

pub const symbol = @import("symbol.zig");

pub const scope = @import("scope.zig");

pub const binary = @import("binary.zig");

pub const functions = @import("functions.zig");

pub const Workspace = @import("Workspace.zig");

pub fn parse(allocator: std.mem.Allocator, source: lib.source_file.SourceView, diagnostics: *lib.Diagnostic.List) !Parser.Result {
    var lexer = Lexer.init(source);

    var parser = try Parser.init(allocator, &lexer, diagnostics);

    return try parser.parseFile();
}

pub const Result = Sema.Result(ir.File);

pub fn compile(
    allocator: std.mem.Allocator,
    source: lib.source_file.SourceView,
    diagnostics: *lib.Diagnostic.List,
) !Result {
    const pr = try parse(allocator, source, diagnostics);

    // ir doesnt hold any reference to ast
    // it can be safely destroyed after ir is built
    defer pr.deinit();

    var sema = try Sema.init(allocator, diagnostics);

    return try sema.analyse(pr.result);
}
