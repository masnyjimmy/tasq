const std = @import("std");

const lib = @import("lib");

const compiler = @import("compiler");
const ir = compiler.ir;
const typing = compiler.typing;
const Value = compiler.Value;

const binary_mod = @import("binary.zig");

const symbol_mod = @import("symbol.zig");

const Symbol = symbol_mod.Symbol;
const Scope = symbol_mod.Scope;

const conzole = @import("conzole");
const Printer = conzole.terminal.Printer;

const builtin = @import("builtin.zig");

const CallStack = @import("call_stack.zig");

const ScopeStack = @import("scope_stack.zig");

pub const Interpreter = @This();

const InterpreterError = std.Io.Writer.Error || binary_mod.Error || std.mem.Allocator.Error;

allocator: std.mem.Allocator,
io: std.Io,
printer: *Printer,
options: *const ir.Options,
status_code: u8 = 0,

call_stack: *CallStack,
scope_stack: *ScopeStack,
environ: *const std.process.Environ.Map,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    printer: *Printer,
    options: *const ir.Options,
    call_stack: *CallStack,
    scope_stack: *ScopeStack,
    environ: *const std.process.Environ.Map,
) Interpreter {
    return .{
        .allocator = allocator,
        .io = io,
        .printer = printer,
        .options = options,

        .call_stack = call_stack,
        .scope_stack = scope_stack,

        .environ = environ,
    };
}

pub fn run(self: *Interpreter) !void {
    while (try self.call_stack.advance(self.allocator)) |res| {
        switch (res) {
            .statement => |stmt| try self.main(stmt),
            .frame_end => self.scope_stack.pop(self.allocator),
        }
    }
}
fn main(self: *Interpreter, stmt: *const ir.Statement) !void {
    const scope = self.currentScope();
    switch (stmt.*) {
        .decl => |decl| {
            _ = try self.handleDecl(scope, decl);
        },
        .process => |proc_expr| {
            const process = switch (proc_expr) {
                .lit => |lit| lit,
                .inter => |inter| try self.resolveStringInterpolation(scope, inter),
            };

            try self.handleProcess(process);
        },
        .if_stmt => |*if_stmt| {
            const cond = try self.resolveExpr(scope, &if_stmt.cond);

            if (cond.bool) {
                try self.call_stack.push(self.allocator, null, &if_stmt.then);
                try self.scope_stack.pushBlock(self.allocator, if_stmt.then.scope);
            } else if (if_stmt.else_) |*else_| {
                try self.call_stack.push(self.allocator, null, else_);
                try self.scope_stack.pushBlock(self.allocator, else_.scope);
            }
        },
        .switch_stmt => |*switch_stmt| {
            const target = try self.resolveExpr(scope, &switch_stmt.subject);

            const block = switch_stmt.cases.getPtr(target) orelse &switch_stmt.else_case;

            try self.call_stack.push(self.allocator, null, block);
            try self.scope_stack.pushBlock(self.allocator, block.scope);
        },
        else => {
            try self.printer.printStyled(self.allocator, .{ .bold = true, .fg = .bright_red }, "unsupported yet\n", .{});
        },
    }
}

fn handleDecl(self: *Interpreter, scope: *Scope, decl: *const ir.Decl) InterpreterError!Value {
    const decl_scope = scope.findByStatic(decl.scope) orelse unreachable;

    const value = try self.resolveExpr(decl_scope, &decl.value);

    try decl_scope.define(.{
        .name = decl.name,
        .value = value,
    });

    return value;
}

fn handleProcess(self: *Interpreter, process: []const u8) !void {
    const shell_len = self.options.shell.len;

    var argv = try self.allocator.alloc([]const u8, shell_len + 1);
    defer self.allocator.free(argv);

    @memcpy(argv[0..shell_len], self.options.shell);
    argv[shell_len] = process;

    try self.printer.printStyled(self.allocator, .{ .bold = true, .fg = .bright_white }, "{s}\n", .{process});
    var child = try std.process.spawn(
        self.io,
        .{ .argv = argv },
    );

    _ = try child.wait(self.io);
}

fn resolveExpr(self: *Interpreter, scope: *Scope, expr: *const ir.Expr) InterpreterError!Value {
    return switch (expr.*) {
        .bool_lit => |lit| .{ .bool = lit },
        .char_lit => |lit| .{ .char = lit },
        .number_lit => |lit| .{ .number = lit },
        .string => |str| switch (str) {
            .lit => |lit| .{ .string = lit },
            .inter => |inter| .{ .string = try self.resolveStringInterpolation(scope, inter) },
        },
        .list => |list| {
            var result: std.ArrayList(Value) = try .initCapacity(scope.arena.allocator(), list.items.len);
            errdefer result.deinit(scope.arena.allocator());

            for (list.items) |item| {
                if (item.is_spread) {
                    const spread = try self.resolveExpr(scope, item.expr);
                    try result.appendSlice(scope.arena.allocator(), spread.list.items);
                } else {
                    try result.append(scope.arena.allocator(), try self.resolveExpr(scope, item.expr));
                }
            }

            return .{
                .list = .{
                    .items_type = &list.items_type,
                    .items = try result.toOwnedSlice(scope.arena.allocator()),
                },
            };
        },

        .ident => |id| {
            // get resolved
            if (self.getSymbol(id.name)) |sym| {
                return sym.value;
            }
            // resolve if not already (lazy resolution)
            return switch (id.symbol.details) {
                .binding => |b| try self.handleDecl(scope, b.origin),
                .argument => unreachable, // should be already resolved by runtime builder,
                else => unreachable, // group and task cannot be used in expression
            };
        },
        .if_expr => |if_expr| {
            const cond = try self.resolveExpr(scope, &if_expr.cond);
            std.debug.assert(cond == .bool);

            return if (cond.bool)
                try self.resolveExpr(scope, &if_expr.then)
            else
                try self.resolveExpr(scope, &if_expr.else_);
        },
        .binary => |binary| {
            const left = try self.resolveExpr(scope, &binary.left);
            const right = try self.resolveExpr(scope, &binary.right);

            // add,sub,div,mul => [string,float,int,list,bool] op [string,float,int]

            return try binary_mod.evalBinary(
                scope.arena.allocator(),
                binary.op,
                left,
                right,
            );
        },
        .unary => |unary| {
            const operand = try self.resolveExpr(scope, &unary.operand);
            std.debug.assert(operand.typeOf() == .bool);

            switch (unary.op) {
                .not_op => {
                    return .{ .bool = !operand.bool };
                },
                .negate => {
                    switch (operand) {
                        inline .number => |v, tag| {
                            return @unionInit(Value, @tagName(tag), -v);
                        },
                        else => unreachable,
                    }
                },
            }

            return .{ .bool = !operand.bool };
        },
        .builtin_call => |call| {
            const args = try scope.arena.allocator().alloc(Value, call.args.len);

            for (call.args, args) |in, *out| {
                out.* = try self.resolveExpr(scope, &in);
            }
            // should't ever error
            return builtin.callFunction(self, call.id, args) catch unreachable;
        },
    };
}

fn resolveStringInterpolation(self: *Interpreter, scope: *Scope, inter: []const ir.InterStringSeg) InterpreterError![]const u8 {
    var aw = std.Io.Writer.Allocating.init(scope.arena.allocator());
    const writer = &aw.writer;
    errdefer aw.deinit();

    for (inter) |part| {
        switch (part) {
            .lit => |lit| {
                try writer.writeAll(lit);
            },
            .expr => |expr| {
                const value = try self.resolveExpr(scope, &expr);
                try writer.print("{f}", .{value});
            },
        }
    }

    return try aw.toOwnedSlice();
}

fn currentScope(self: *Interpreter) *Scope {
    return self.scope_stack.assertCurrentScope();
}

fn getSymbol(self: *Interpreter, name: []const u8) ?*Symbol {
    return self.currentScope().resolve(name);
}
