const std = @import("std");

const lib = @import("lib");

const compiler = @import("compiler");
const ir = compiler.ir;
const Value = compiler.Value;

const binary_mod = @import("binary.zig");

const Scope = @import("Scope.zig");

const conzole = @import("conzole");
const Printer = conzole.terminal.Printer;

const builtin = @import("builtin.zig");

pub const Interpreter = @This();

pub const Error = std.Io.Writer.Error || binary_mod.Error || std.mem.Allocator.Error || std.process.SpawnError || error{
    Abort,
    Break,
    Continue,
};

allocator: std.mem.Allocator,
io: std.Io,
printer: *Printer,
options: *const ir.Options,
status_code: u8 = 0,
environ: std.process.Environ.Map,
cwd: std.Io.Dir,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    printer: *Printer,
    options: *const ir.Options,
    environ: *const std.process.Environ.Map,
) !Interpreter {

    // TODO: read dotenv,

    var new_environ = try environ.clone(allocator);
    errdefer new_environ.deinit();

    const cwd = blk: {
        const cwd = std.Io.Dir.cwd();

        if (options.dotenv) |env_file| {
            try lib.dotenv.parse(io, env_file, &new_environ);
        }

        break :blk try cwd.openDir(io, options.working_dir orelse ".", .{});
    };

    return .{
        .allocator = allocator,
        .io = io,
        .printer = printer,
        .options = options,
        .environ = new_environ,
        .cwd = cwd,
    };
}

pub fn deinit(self: *Interpreter) void {
    self.environ.deinit();
    self.cwd.close(self.io);
}

fn bindArgs(scope: *Scope, args: []*ir.Argument, values: *std.array_hash_map.String(Value)) !void {
    for (args) |arg| {
        const kv = values.fetchSwapRemove(arg.name) orelse {
            std.debug.panic(
                \\internal error: missing argument '{s}';
                \\this should have been caught during IR validation
            ,
                .{arg.name},
            );
        };

        try scope.define(.{
            .name = kv.key,
            .value = try kv.value.clone(scope.arena.allocator()),
        }, false);
    }
}

pub fn run(self: *Interpreter, initial_task: *const ir.Task, values: *std.array_hash_map.String(Value)) !void {
    const root_scope = try Scope.create(null, self.allocator, initial_task.body.scope.root());
    defer root_scope.destroy();

    const group_scope: ?*Scope = blk: {
        if (initial_task.group) |group| {
            const group_scope = try Scope.create(root_scope, self.allocator, group.scope);
            errdefer group_scope.destroy();

            try bindArgs(group_scope, group.args, values);

            break :blk group_scope;
        } else {
            break :blk null;
        }
    };
    defer {
        if (group_scope) |gs| {
            gs.destroy();
        }
    }

    const task_scope = try Scope.create(
        group_scope orelse root_scope,
        self.allocator,
        initial_task.body.scope,
    );
    defer task_scope.destroy();

    try bindArgs(task_scope, initial_task.args, values);

    // apply task env

    const prev_environ = self.environ;
    self.environ = try prev_environ.clone(self.allocator);
    defer {
        self.environ.deinit();
        self.environ = prev_environ;
    }

    for (initial_task.envs) |env| {
        try self.environ.put(env.key, env.value);
    }

    try self.runBlock(task_scope, initial_task.body.statements);
}

pub fn runBlock(self: *Interpreter, scope: *Scope, statements: []const ir.Statement) Error!void {
    for (statements) |*stmt| {
        try self.main(scope, stmt);
    }
}

fn main(self: *Interpreter, scope: *Scope, stmt: *const ir.Statement) Error!void {
    switch (stmt.*) {
        .decl => |decl| {
            _ = try self.handleDecl(scope, decl);
        },
        .process => |proc_expr| {
            const process = try self.resolveString(scope, proc_expr);

            try self.handleProcess(process);
        },
        .if_stmt => |*if_stmt| {
            const cond = try self.evaluateExpr(scope, &if_stmt.cond);

            if (cond.bool) {
                const then_scope = try Scope.create(scope, self.allocator, if_stmt.then.scope);
                defer then_scope.destroy();

                try self.runBlock(then_scope, if_stmt.then.statements);
            } else if (if_stmt.else_) |*else_| {
                const else_scope = try Scope.create(scope, self.allocator, else_.scope);
                defer else_scope.destroy();

                try self.runBlock(else_scope, else_.statements);
            }
        },
        .switch_stmt => |*switch_stmt| {
            const target = try self.evaluateExpr(scope, &switch_stmt.subject);

            const block: ?*const ir.StatementBlock = switch_stmt.cases.getPtr(target) orelse if (switch_stmt.else_case) |*e| e else null;

            if (block) |b| {
                const case_scope = try Scope.create(scope, self.allocator, b.scope);
                defer case_scope.destroy();

                try self.runBlock(case_scope, b.statements);
            }
        },
        .for_stmt => |*for_stmt| {
            const values = try self.allocator.alloc(Value, for_stmt.subjects.len);
            defer self.allocator.free(values);

            for (values, for_stmt.subjects) |*out, in| {
                out.* = try self.evaluateExpr(scope, &in);
            }

            const max_length = blk: {
                var out: usize = values[0].list.items.len;

                for (values[1..]) |val|
                    out = @min(out, val.list.items.len);

                break :blk out;
            };

            for (0..max_length) |idx| {
                const for_scope = try Scope.create(scope, self.allocator, for_stmt.body.scope);
                defer for_scope.destroy();

                for (for_stmt.captures[0..for_stmt.subjects.len], 0..) |maybe_cap, j| {
                    if (maybe_cap) |cap| {
                        try for_scope.define(.{
                            .name = cap.name,
                            .value = values[j].list.items[idx],
                        }, false);
                    }
                }

                if (for_stmt.captures.len == for_stmt.subjects.len + 1) {
                    if (for_stmt.captures[for_stmt.captures.len - 1]) |idx_cap| {
                        try for_scope.define(.{
                            .name = idx_cap.name,
                            .value = .{ .number = @floatFromInt(idx) },
                        }, false);
                    }
                }

                self.runBlock(for_scope, for_stmt.body.statements) catch |err| switch (err) {
                    Error.Continue => continue,
                    Error.Break => break,
                    else => return err,
                };
            }
        },
        .task_call => |*task_call| {
            const task = task_call.task;

            const group_scope: ?*Scope = blk: {
                if (task.group) |group| {
                    const group_scope = try Scope.create(scope, self.allocator, group.scope);
                    errdefer group_scope.destroy();

                    for (group.args) |arg| {
                        if (task_call.args.get(arg.name)) |in| {
                            const value = switch (in) {
                                .default => |def| def,
                                .value => |*expr| try self.evaluateExpr(scope, expr),
                            };
                            try group_scope.define(.{
                                .name = arg.name,
                                .value = value,
                            }, true);
                        }
                    }

                    break :blk group_scope;
                }

                break :blk null;
            };
            defer {
                if (group_scope) |gs| {
                    gs.destroy();
                }
            }

            const task_scope = try Scope.create(group_scope orelse scope, self.allocator, task.body.scope);
            defer task_scope.destroy();

            for (task.args) |arg| {
                const in = task_call.args.get(arg.name) orelse {
                    std.debug.panic(
                        \\internal error: mssing '{s}' task argument
                        \\this should have been caught during IR validation
                    ,
                        .{arg.name},
                    );
                };
                const value = switch (in) {
                    .default => |def| def,
                    .value => |*expr| try self.evaluateExpr(scope, expr),
                };
                try task_scope.define(.{
                    .name = arg.name,
                    .value = value,
                }, false);
            }

            // apply task environ
            const prev_environ = self.environ;
            self.environ = try prev_environ.clone(self.allocator);
            defer {
                self.environ.deinit();
                self.environ = prev_environ;
            }

            for (task.envs) |env| {
                try self.environ.put(env.key, env.value);
            }

            try self.runBlock(task_scope, task.body.statements);
        },
        .expr => |*expr| {
            _ = try self.evaluateExpr(scope, expr);
        },
    }
}

fn handleDecl(self: *Interpreter, scope: *Scope, decl: *const ir.Decl) Error!Value {
    const decl_scope = scope.findByStatic(decl.scope) orelse unreachable;

    const value = try self.evaluateExpr(decl_scope, &decl.value);

    try decl_scope.define(.{
        .name = decl.name,
        .value = value,
    }, false);

    return value;
}

fn handleProcess(self: *Interpreter, process: []const u8) Error!void {
    const shell_len = self.options.shell.len;

    var argv = try self.allocator.alloc([]const u8, shell_len + 1);
    defer self.allocator.free(argv);

    @memcpy(argv[0..shell_len], self.options.shell);
    argv[shell_len] = process;

    try self.printer.printStyled(self.allocator, .{ .bold = true, .fg = .bright_white }, "{s}\n", .{process});

    var child = try std.process.spawn(
        self.io,
        .{
            .argv = argv,
            .cwd = .{ .dir = self.cwd },
            .environ_map = &self.environ,
        },
    );

    _ = try child.wait(self.io);
}

pub fn evaluateExpr(self: *Interpreter, scope: *Scope, expr: *const ir.Expr) Error!Value {
    return switch (expr.*) {
        .bool_lit => |lit| .{ .bool = lit },
        .number_lit => |lit| .{ .number = lit },
        .string => |str| .{ .string = try self.resolveString(scope, str) },
        .list => |list| {
            var result: std.ArrayList(Value) = try .initCapacity(scope.arena.allocator(), list.items.len);
            errdefer result.deinit(scope.arena.allocator());

            for (list.items) |item| {
                if (item.is_spread) {
                    const spread = try self.evaluateExpr(scope, item.expr);
                    try result.appendSlice(scope.arena.allocator(), spread.list.items);
                } else {
                    try result.append(scope.arena.allocator(), try self.evaluateExpr(scope, item.expr));
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
            if (scope.resolve(id.name)) |sym| {
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
            const cond = try self.evaluateExpr(scope, &if_expr.cond);
            std.debug.assert(cond == .bool);

            return if (cond.bool)
                try self.evaluateExpr(scope, &if_expr.then)
            else
                try self.evaluateExpr(scope, &if_expr.@"else");
        },
        .switch_expr => |switch_expr| {
            const target = try self.evaluateExpr(scope, &switch_expr.subject);

            const value = switch_expr.cases.get(target) orelse switch_expr.else_case;

            return try self.evaluateExpr(scope, &value);
        },
        .for_expr => |for_expr| {
            const values = try self.allocator.alloc(Value, for_expr.subjects.len);
            defer self.allocator.free(values);

            for (values, for_expr.subjects) |*out, in| {
                out.* = try self.evaluateExpr(scope, &in);
            }

            const max_length = blk: {
                var out: usize = values[0].list.items.len;

                for (values[1..]) |val|
                    out = @min(out, val.list.items.len);

                break :blk out;
            };

            var result: std.ArrayList(Value) = .empty;

            for (0..max_length) |idx| {
                const for_scope = try Scope.create(scope, self.allocator, for_expr.scope);
                defer for_scope.destroy();

                for (for_expr.captures[0..for_expr.subjects.len], 0..) |maybe_cap, j| {
                    if (maybe_cap) |cap| {
                        try for_scope.define(.{
                            .name = cap.name,
                            .value = values[j].list.items[idx],
                        }, false);
                    }
                }

                if (for_expr.captures.len == for_expr.subjects.len + 1) {
                    if (for_expr.captures[for_expr.captures.len - 1]) |idx_cap| {
                        try for_scope.define(.{
                            .name = idx_cap.name,
                            .value = .{ .number = @floatFromInt(idx) },
                        }, false);
                    }
                }

                const item = self.evaluateExpr(for_scope, &for_expr.body) catch |err| switch (err) {
                    Error.Continue => continue,
                    Error.Break => break,
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
            const left = try self.evaluateExpr(scope, &binary.left);
            const right = try self.evaluateExpr(scope, &binary.right);

            // add,sub,div,mul => [string,float,int,list,bool] op [string,float,int]

            return try binary_mod.evalBinary(
                scope.arena.allocator(),
                binary.op,
                left,
                right,
            );
        },
        .unary => |unary| {
            const operand = try self.evaluateExpr(scope, &unary.operand);
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
                out.* = try self.evaluateExpr(scope, &in);
            }

            const value = try builtin.callFunction(self, scope, call.function.id, args);

            return switch (value) {
                .result => |r| if (r.value) |v|
                    v.*
                else
                    try self.evaluateExpr(scope, &call.fallback.?),
                else => value,
            };
        },
        .lambda => |lambda| .{ .lambda = lambda },
        .@"continue" => Error.Continue,
        .@"break" => Error.Break,
    };
}

fn resolveString(self: *Interpreter, scope: *Scope, string: ir.String) Error![]const u8 {
    var aw = std.Io.Writer.Allocating.init(scope.arena.allocator());
    const writer = &aw.writer;
    errdefer aw.deinit();

    for (string) |part| {
        switch (part) {
            .lit => |lit| {
                try writer.writeAll(lit);
            },
            .expr => |expr| {
                const value = try self.evaluateExpr(scope, &expr);
                try writer.print("{f}", .{value});
            },
        }
    }

    return try aw.toOwnedSlice();
}
