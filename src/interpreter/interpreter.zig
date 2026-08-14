const std = @import("std");

const lib = @import("lib");

const compiler = @import("compiler");
const ir = compiler.ir;
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

const InterpreterError = std.Io.Writer.Error || binary_mod.Error || std.mem.Allocator.Error || std.process.SpawnError || error{
    Abort,
    Break,
    Continue,
};

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

pub fn run(self: *Interpreter) InterpreterError!void {
    const target_depth = self.call_stack.stack.items.len;
    while (try self.call_stack.advance(self.allocator)) |res| {
        switch (res) {
            .statement => |stmt| self.main(stmt) catch |err| switch (err) {
                InterpreterError.Abort => return,
                else => return err,
            },
            .frame_end => {
                self.scope_stack.pop(self.allocator);
                if (self.call_stack.stack.items.len < target_depth) return;
            },
        }
    }
}

fn main(self: *Interpreter, stmt: *const ir.Statement) InterpreterError!void {
    const scope = self.currentScope();
    switch (stmt.*) {
        .decl => |decl| {
            _ = try self.handleDecl(scope, decl);
        },
        .process => |proc_expr| {
            const process = try self.resolveString(scope, proc_expr);

            try self.handleProcess(process);
        },
        .if_stmt => |*if_stmt| {
            const cond = try self.resolveExpr(scope, &if_stmt.cond);

            if (cond.bool) {
                try self.pushBlock(&if_stmt.then);
            } else if (if_stmt.else_) |*else_| {
                try self.pushBlock(else_);
            }
        },
        .switch_stmt => |*switch_stmt| {
            const target = try self.resolveExpr(scope, &switch_stmt.subject);

            const block: ?*const ir.StatementBlock = switch_stmt.cases.getPtr(target) orelse if (switch_stmt.else_case) |*e| e else null;

            if (block) |b|
                try self.pushBlock(b);
        },
        .for_stmt => |*for_stmt| {
            const values = try scope.arena.allocator().alloc(Value, for_stmt.subjects.len);

            for (values, for_stmt.subjects) |*out, in| {
                out.* = try self.resolveExpr(scope, &in);
            }

            const max_length = blk: {
                var out: usize = values[0].list.items.len;

                for (values[1..]) |val|
                    out = @min(out, val.list.items.len);

                break :blk out;
            };

            for (0..max_length) |idx| {
                try self.pushBlock(&for_stmt.body);

                const iter_scope = self.currentScope();

                for (for_stmt.captures[0 .. for_stmt.captures.len - 1], 0..) |maybe_cap, j| {
                    if (maybe_cap) |cap| {
                        try iter_scope.define(.{
                            .name = cap.name,
                            .value = values[j].list.items[idx],
                        });
                    }
                }
                if (for_stmt.captures.len == for_stmt.subjects.len + 1) {
                    if (for_stmt.captures[for_stmt.captures.len - 1]) |idx_cap| {
                        try iter_scope.define(.{
                            .name = idx_cap.name,
                            .value = .{ .number = @floatFromInt(idx) },
                        });
                    }
                }

                // run till this level again
                self.run() catch |err| switch (err) {
                    InterpreterError.Break => {
                        try self.popBlockTarget(&for_stmt.body);
                        break;
                    },
                    InterpreterError.Continue => {
                        try self.popBlockTarget(&for_stmt.body);
                        continue;
                    },
                    else => return err,
                };
            }
        },
        .expr => |*expr| {
            _ = try self.resolveExpr(scope, expr);
        },
        else => {
            try self.printer.printStyled(self.allocator, .{ .bold = true, .fg = .bright_red }, "unsupported yet\n", .{});
            try self.printer.flush();
        },
    }
}

fn pushBlock(self: *Interpreter, block: *const ir.StatementBlock) InterpreterError!void {
    try self.call_stack.push(self.allocator, null, block);
    try self.scope_stack.pushBlock(self.allocator, block.scope);
}
fn popBlock(self: *Interpreter) void {
    self.call_stack.pop(self.allocator);
    self.scope_stack.pop(self.allocator);
}

fn popBlockTarget(self: *Interpreter, block: *const ir.StatementBlock) InterpreterError!void {
    while (self.call_stack.current) |state| {
        const is_current = state.block == block;

        self.popBlock();

        if (is_current)
            break;
    } else unreachable;
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

fn handleProcess(self: *Interpreter, process: []const u8) InterpreterError!void {
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
        .string => |str| .{ .string = try self.resolveString(scope, str) },
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
            return switch (id.symbol.origin) {
                .binding => |decl| try self.handleDecl(scope, decl),
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
                try self.resolveExpr(scope, &if_expr.@"else");
        },
        .switch_expr => |switch_expr| {
            const target = try self.resolveExpr(scope, &switch_expr.subject);

            const value = switch_expr.cases.get(target) orelse switch_expr.else_case;

            return try self.resolveExpr(scope, &value);
        },
        .for_expr => |for_expr| {
            const subjects = try scope.arena.allocator().alloc(Value, for_expr.subjects.len);

            for (subjects, for_expr.subjects) |*out, in| {
                out.* = try self.resolveExpr(scope, &in);
            }

            const max_length = blk: {
                var out: usize = subjects[0].list.items.len;

                for (subjects[1..]) |val|
                    out = @min(out, val.list.items.len);

                break :blk out;
            };

            var result: std.ArrayList(Value) = .empty;

            for (0..max_length) |idx| {
                try self.scope_stack.pushBlock(self.allocator, for_expr.scope);
                defer self.scope_stack.pop(self.allocator);

                const iter_scope = self.currentScope();

                for (for_expr.captures[0 .. for_expr.captures.len - 1], 0..) |maybe_cap, j| {
                    if (maybe_cap) |cap| {
                        try iter_scope.define(.{
                            .name = cap.name,
                            .value = subjects[j].list.items[idx],
                        });
                    }
                }

                if (for_expr.captures.len == for_expr.subjects.len + 1) {
                    if (for_expr.captures[for_expr.captures.len - 1]) |idx_cap| {
                        try iter_scope.define(.{
                            .name = idx_cap.name,
                            .value = .{ .number = @floatFromInt(idx) },
                        });
                    }
                }

                const item = self.resolveExpr(iter_scope, &for_expr.body) catch |err| switch (err) {
                    InterpreterError.Continue => continue,
                    InterpreterError.Break => break,
                    else => return err,
                };

                try result.append(
                    scope.arena.allocator(),
                    try item.clone(scope.arena.allocator()),
                );
            }

            return .{
                .list = .{
                    .items_type = &for_expr.type,
                    .items = try result.toOwnedSlice(scope.arena.allocator()),
                },
            };
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

            return builtin.callFunction(self, call.id, args) catch |err| return switch (err) {
                builtin.Error.Abort => InterpreterError.Abort,
                else => unreachable,
            };
        },
        .@"continue" => InterpreterError.Continue,
        .@"break" => InterpreterError.Break,
    };
}

fn resolveString(self: *Interpreter, scope: *Scope, string: ir.String) InterpreterError![]const u8 {
    var aw = std.Io.Writer.Allocating.init(scope.arena.allocator());
    const writer = &aw.writer;
    errdefer aw.deinit();

    for (string) |part| {
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
