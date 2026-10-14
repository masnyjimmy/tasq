const std = @import("std");

const lib = @import("lib");

const compiler = @import("compiler");
const ir = compiler.ir;
const Value = compiler.Value;

const binary_mod = @import("binary.zig");

const Scope = @import("Scope.zig");

const conzole = @import("conzole");
const Style = conzole.terminal.Style;
const Printer = conzole.terminal.Printer;

const builtin = @import("builtin.zig");

pub const Interpreter = @This();

pub const Error = std.Io.Writer.Error || std.Io.Reader.Error || binary_mod.Error || std.mem.Allocator.Error || std.process.SpawnError || error{
    Abort,
    Break,
    Continue,
};

const style = struct {
    const echo: Style = .{ .bold = true, .fg = .bright_white };
    const @"error": Style = .{ .bold = true, .fg = .red };
};

allocator: std.mem.Allocator,
io: std.Io,
printer: *Printer,
options: *const ir.Options,
status_code: u8 = 0,
cwd: std.Io.Dir,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    printer: *Printer,
    options: *const ir.Options,
) !Interpreter {

    // TODO: read dotenv,

    const cwd = blk: {
        const cwd = std.Io.Dir.cwd();

        break :blk try cwd.openDir(io, options.working_dir orelse ".", .{});
    };

    return .{
        .allocator = allocator,
        .io = io,
        .printer = printer,
        .options = options,
        .cwd = cwd,
    };
}

pub fn deinit(self: *Interpreter) void {
    self.cwd.close(self.io);
}

pub fn run(
    self: *Interpreter,
    initial_task: *const ir.Task,
    environ: *const std.process.Environ.Map,
    values: std.array_hash_map.String(Value),
) !void {
    const root_scope = try Scope.create(null, self.allocator, initial_task.body.scope.root());
    defer root_scope.destroy();

    var it = environ.iterator();

    while (it.next()) |kv| {
        try root_scope.environ.put(
            kv.key_ptr.*,
            kv.value_ptr.*,
        );
    }

    if (self.options.dotenv) |dotenv| {
        try lib.dotenv.parse(
            self.io,
            dotenv,
            &root_scope.environ,
        );
    }

    try self.runTask(
        root_scope,
        initial_task,
        values,
        false,
    );
}

pub fn runTask(self: *Interpreter, scope: *Scope, task: *const ir.Task, values: std.array_hash_map.String(Value), same_group: bool) !void {
    const group_scope: ?*Scope = blk: {
        if (task.group) |group| {

            // if another group call => find by static group scope parent
            // if same group => find by static group scope,
            const actual_parent = p: {
                if (same_group) {
                    break :p scope.findByStatic(group.scope).?;
                }

                break :p if (group.scope.parent) |p| scope.findByStatic(p).? else scope.root();
            };
            const group_scope = try Scope.create(actual_parent, self.allocator, group.scope);
            errdefer group_scope.destroy();

            for (group.args) |arg| {
                // if same group and group arguments are optional
                const value = values.get(arg.name) orelse {
                    if (same_group == false) {
                        std.debug.panic(
                            \\internal error: missing argument '{s}';
                            \\this should have been caught during IR validation.
                        ,
                            .{arg.name},
                        );
                    }
                    continue;
                };
                try group_scope.define(.{
                    .name = arg.name,
                    .value = try value.clone(group_scope.arena.allocator()),
                }, same_group);
            }

            break :blk group_scope;
        }

        break :blk null;
    };
    defer {
        if (group_scope) |gs|
            gs.destroy();
    }

    const task_scope = try Scope.create(
        group_scope orelse scope,
        self.allocator,
        task.scope,
    );
    defer task_scope.destroy();

    for (task.args) |arg| {
        const value = values.get(arg.name) orelse {
            std.debug.panic(
                \\internal error: missing argument '{s}';
                \\this should have been caught during IR validation.
            ,
                .{arg.name},
            );
        };
        try task_scope.define(.{
            .name = arg.name,
            .value = try value.clone(task_scope.arena.allocator()),
        }, false);
    }

    for (task.envs) |env| {
        try task_scope.environ.put(
            env.key,
            env.value,
        );
    }

    for (task.dependecies) |*dep| {
        try self.handleTaskCall(task_scope, dep);
    }

    const task_body_scope = try Scope.create(task_scope, self.allocator, task.body.scope);
    defer task_body_scope.destroy();

    try self.runBlock(task_body_scope, task.body.statements);
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
            const process = try self.resolveString(scope, proc_expr.command);

            const noecho = if (proc_expr.noecho) |value|
                value
            else
                false;

            self.status_code = try self.handleProcess(scope, .{
                .process = process,
                .echo = !noecho,
                .allow_input = true,
            });

            if (self.status_code != 0 and proc_expr.nofail == false) {
                try self.printer.printStyled(
                    self.allocator,
                    style.@"error",
                    \\tasq: error: command failed with exit code {}
                    \\  on '{s}'
                    \\
                ,
                    .{ self.status_code, process },
                );
                return Error.Abort;
            }
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
            try self.handleTaskCall(scope, task_call);
        },
        .expr => |*expr| {
            _ = try self.evaluateExpr(scope, expr);
        },
    }
}

fn handleTaskCall(self: *Interpreter, scope: *Scope, task_call: *const ir.TaskCall) Error!void {
    const task = task_call.task;

    var values: std.array_hash_map.String(Value) = .empty;
    defer values.deinit(self.allocator);
    var it = task_call.args.iterator();

    while (it.next()) |kv| {
        switch (kv.value_ptr.*) {
            .default => |def| try values.put(self.allocator, kv.key_ptr.*, def),
            .value => |expr| try values.put(self.allocator, kv.key_ptr.*, try self.evaluateExpr(scope, &expr)),
        }
    }

    try self.runTask(scope, task, values, task_call.same_group);
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

const ProcessOptions = struct {
    process: []const u8,
    echo: bool,
    allow_input: bool,
    out: ?*std.Io.Writer = null,
};

fn handleProcess(self: *Interpreter, scope: *Scope, options: ProcessOptions) Error!u8 {
    const shell_len = self.options.shell.len;

    var argv = try self.allocator.alloc([]const u8, shell_len + 1);
    defer self.allocator.free(argv);

    @memcpy(argv[0..shell_len], self.options.shell);
    argv[shell_len] = options.process;

    if (options.echo) {
        try self.printer.printStyled(
            self.allocator,
            style.echo,
            "{s}\n",
            .{options.process},
        );
    }

    var child = try std.process.spawn(
        self.io,
        .{
            .argv = argv,
            .cwd = .{ .dir = self.cwd },
            .environ_map = &scope.environ,
            .stdout = if (options.out == null)
                .inherit
            else
                .pipe,
            .stdin = if (options.allow_input)
                .inherit
            else
                .ignore,
        },
    );

    if (options.out) |output| {
        var buffer: [4096]u8 = undefined;
        var file_reader: std.Io.File.Reader = .initStreaming(
            child.stdout.?,
            self.io,
            &buffer,
        );
        _ = try file_reader.interface.streamRemaining(output);
    }

    const result = try child.wait(self.io);

    return switch (result) {
        .exited => |code| code,
        .signal => |signal| std.debug.panic(
            \\Process killed by signal '{t}',
            \\  Not sure what to do yet :p
        ,
            .{signal},
        ),
        else => unreachable,
    };
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
        .process => |process_expr| {
            const process = try self.resolveString(scope, process_expr.command);
            var aw: std.Io.Writer.Allocating = .init(scope.arena.allocator());

            self.status_code = try self.handleProcess(scope, .{
                .process = process,
                .echo = false,
                .allow_input = false,
                .out = &aw.writer,
            });

            if (self.status_code != 0) {
                if (process_expr.fallback) |*value| {
                    return try self.evaluateExpr(scope, value);
                }

                if (process_expr.nofail == false) {
                    try self.printer.printStyled(
                        self.allocator,
                        style.@"error",
                        \\tasq: error: command failed with exit code {}
                        \\  on binding evaluation '{s}'
                    ,
                        .{ self.status_code, process },
                    );
                    return Error.Abort;
                }
            }

            const result = blk: {
                //TODO: consider future 'raw' attribute
                const result = try aw.toOwnedSlice();
                var end = result.len;
                while (end > 0 and result[end - 1] == '\n') {
                    end -= 1;
                    if (end > 0 and result[end - 1] == '\r') end -= 1;
                }
                break :blk result[0..end];
            };

            return .{ .string = result };
        },
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
