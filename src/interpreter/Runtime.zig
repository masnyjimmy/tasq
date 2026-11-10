const std = @import("std");

const conzole = @import("conzole");
const Style = conzole.terminal.Style;
const Printer = conzole.terminal.Printer;

const builtin = @import("builtin.zig");

const compiler = @import("compiler");
const ir = compiler.ir;
const Value = compiler.Value;

const lib = @import("lib");

const binary_mod = @import("binary.zig");
const TaskRunner = @import("TaskRunner.zig");
const Scope = @import("Scope.zig");

pub const Runtime = @This();

pub const Error = error{
    Abort,
    Break,
    Continue,
} || std.Io.Writer.Error || std.Io.Reader.Error || binary_mod.Error || std.mem.Allocator.Error || std.process.SpawnError || std.Io.Dir.RealPathError;

const style = struct {
    const echo: Style = .{ .bold = true, .fg = .bright_white };
    const @"error": Style = .{ .bold = true, .fg = .red };
};

allocator: std.mem.Allocator,
invokation_dir: []const u8,
io: std.Io,
printer: *Printer,
options: *const ir.Options,
status_code: u8 = 0,
cwd: std.Io.Dir,

pub fn init(
    allocator: std.mem.Allocator,
    invokation_dir: []const u8,
    io: std.Io,
    printer: *Printer,
    options: *const ir.Options,
) !Runtime {

    // TODO: read dotenv,

    const cwd = blk: {
        const cwd = std.Io.Dir.cwd();

        break :blk try cwd.openDir(io, options.working_dir orelse ".", .{});
    };

    return .{
        .allocator = allocator,
        .invokation_dir = invokation_dir,
        .io = io,
        .printer = printer,
        .options = options,
        .cwd = cwd,
    };
}

pub fn deinit(self: *Runtime) void {
    self.cwd.close(self.io);
}

pub fn run(
    self: *Runtime,
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

pub fn runTask(self: *Runtime, scope: *Scope, task: *const ir.Task, values: std.array_hash_map.String(Value), same_group: bool) !void {
    var runner: TaskRunner = .init(self);
    defer runner.deinit();

    try runner.run(
        scope,
        task,
        values,
        same_group,
        false,
    );
}

pub fn runBlock(self: *Runtime, cwd: std.Io.Dir, scope: *Scope, statements: []const ir.Statement) Error!void {
    for (statements) |*stmt| {
        try self.main(cwd, scope, stmt);
    }
}

fn main(self: *Runtime, cwd: std.Io.Dir, scope: *Scope, stmt: *const ir.Statement) Error!void {
    switch (stmt.*) {
        .decl => |decl| {
            _ = try self.handleDecl(cwd, scope, decl, null);
        },
        .process => |proc_expr| {
            const process = try self.resolveString(cwd, scope, proc_expr.command);

            const noecho = if (proc_expr.noecho) |value|
                value
            else
                false;

            self.status_code = try self.handleProcess(cwd, scope, .{
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
            const cond = try self.evaluateExpr(cwd, scope, &if_stmt.cond);

            if (cond.bool) {
                const then_scope = try Scope.create(scope, self.allocator, if_stmt.then.scope);
                defer then_scope.destroy();

                try self.runBlock(cwd, then_scope, if_stmt.then.statements);
            } else if (if_stmt.else_) |*else_| {
                const else_scope = try Scope.create(scope, self.allocator, else_.scope);
                defer else_scope.destroy();

                try self.runBlock(cwd, else_scope, else_.statements);
            }
        },
        .switch_stmt => |*switch_stmt| {
            const target = try self.evaluateExpr(cwd, scope, &switch_stmt.subject);

            const block: ?*const ir.StatementBlock = switch_stmt.cases.getPtr(target) orelse if (switch_stmt.else_case) |*e| e else null;

            if (block) |b| {
                const case_scope = try Scope.create(scope, self.allocator, b.scope);
                defer case_scope.destroy();

                try self.runBlock(cwd, case_scope, b.statements);
            }
        },
        .for_stmt => |*for_stmt| {
            const ranges = try self.allocator.alloc(Range, for_stmt.subjects.len);
            defer self.allocator.free(ranges);

            const values = try self.allocator.alloc(?Value, for_stmt.subjects.len);
            defer self.allocator.free(values);

            for (for_stmt.subjects, 0..) |in, idx| {
                switch (in) {
                    .range => |*range| {
                        ranges[idx] = try self.evaluateRange(cwd, scope, range);
                        values[idx] = null;
                    },
                    .expr => |*list_expr| {
                        const value = try self.evaluateExpr(cwd, scope, list_expr);
                        ranges[idx] = .{
                            .left = 0,
                            .right = @intCast(value.list.items.len),
                        };
                        values[idx] = value;
                    },
                }
            }

            const final_range = clampRanges(ranges);

            if (final_range.right) |right| {
                const iterations_count: usize = @intCast(right - final_range.left);

                if (for_stmt.parallel) |*p| {
                    const jobs_count: usize = try self.evaluateParallelJobsCount(
                        cwd,
                        scope,
                        p,
                    );
                    var threaded: std.Io.Threaded = .init(self.allocator, .{
                        .async_limit = .limited(jobs_count),
                    });
                    defer threaded.deinit();

                    const threaded_io = threaded.io();

                    const Job = struct {
                        iter_scope: *Scope,

                        fn deinit(s: *@This()) void {
                            s.iter_scope.destroy();
                        }

                        fn process(runtime: *Runtime, dir: std.Io.Dir, iter_scope: *Scope, statements: []const ir.Statement) Error!void {
                            try runtime.runBlock(dir, iter_scope, statements);
                        }
                    };

                    const jobs = try self.allocator.alloc(Job, iterations_count);
                    defer self.allocator.free(jobs);

                    const results = try self.allocator.alloc(std.Io.Future(Error!void), iterations_count);
                    defer self.allocator.free(results);

                    for (0..iterations_count) |i| {
                        const item_index = @as(usize, @intCast(final_range.left)) + i;
                        const iter_scope = try Scope.create(
                            scope,
                            self.allocator,
                            for_stmt.body.scope,
                        );
                        for (for_stmt.captures, 0..) |capture, j| {
                            const value: Value = if (values[j]) |value|
                                value.list.items[@intCast(item_index)]
                            else
                                .{ .number = @floatFromInt(item_index) };

                            _ = try self.destructure(
                                ir.Capture,
                                cwd,
                                iter_scope,
                                capture.target,
                                value,
                                null,
                            );

                            jobs[i] = .{ .iter_scope = iter_scope };
                            results[i] = threaded_io.async(
                                Job.process,
                                .{
                                    self,
                                    cwd,
                                    iter_scope,
                                    for_stmt.body.statements,
                                },
                            );
                        }
                    }
                    defer for (jobs) |*j| j.deinit();

                    for (results) |*r| {
                        r.await(threaded_io) catch |err| switch (err) {
                            Error.Break => continue,
                            Error.Continue => unreachable,
                            else => return err,
                        };
                    }
                } else {
                    const for_scope = try Scope.create(scope, self.allocator, for_stmt.body.scope);
                    defer for_scope.destroy();

                    for (0..iterations_count) |i| {
                        const item_index = @as(usize, @intCast(final_range.left)) + i;
                        defer for_scope.clearSymbols();

                        for (for_stmt.captures, 0..) |capture, j| {
                            const value: Value = if (values[j]) |value|
                                value.list.items[item_index]
                            else
                                .{ .number = @floatFromInt(item_index) };

                            _ = try self.destructure(
                                ir.Capture,
                                cwd,
                                for_scope,
                                capture.target,
                                value,
                                null,
                            );
                        }
                        self.runBlock(cwd, for_scope, for_stmt.body.statements) catch |err| switch (err) {
                            Error.Continue => continue,
                            Error.Break => break,
                            else => return err,
                        };
                    }
                }
            }
        },
        .task_call => |*task_call| {
            try self.handleTaskCall(cwd, scope, task_call);
        },
        .in_stmt => |*in_stmt| {
            const subject = try self.evaluateExpr(
                cwd,
                scope,
                &in_stmt.subject,
            );

            const path = subject.string;

            const in_dir = cwd.openDir(
                self.io,
                path,
                .{},
            ) catch {
                if (in_stmt.@"else") |@"else"| {
                    var in_scope = try Scope.create(scope, self.allocator, @"else".scope);
                    defer in_scope.destroy();

                    try self.runBlock(cwd, in_scope, @"else".statements);
                }
                return;
            };
            defer in_dir.close(self.io);

            var in_scope = try Scope.create(scope, self.allocator, in_stmt.body.scope);
            defer in_scope.destroy();

            try self.runBlock(
                in_dir,
                in_scope,
                in_stmt.body.statements,
            );
        },
        .parallel_block => |parallel_block| {
            const jobs_count: usize = try self.evaluateParallelJobsCount(
                cwd,
                scope,
                &parallel_block.parallel,
            );

            var threaded: std.Io.Threaded = .init(self.allocator, .{
                .async_limit = .limited(jobs_count),
            });
            defer threaded.deinit();

            const threaded_io = threaded.io();

            const Job = struct {
                stmt_scope: *Scope,

                fn deinit(s: *@This()) void {
                    s.stmt_scope.destroy();
                }

                fn process(runtime: *Runtime, dir: std.Io.Dir, stmt_scope: *Scope, target_stmt: *const ir.Statement) Error!void {
                    try runtime.main(
                        dir,
                        stmt_scope,
                        target_stmt,
                    );
                }
            };
            const jobs = try self.allocator.alloc(Job, parallel_block.statements.len);
            defer self.allocator.free(jobs);

            const results = try self.allocator.alloc(std.Io.Future(Error!void), parallel_block.statements.len);
            defer self.allocator.free(results);

            for (parallel_block.statements, 0..) |*parallel_stmt, idx| {
                const stmt_scope = try Scope.create(
                    scope,
                    self.allocator,
                    parallel_stmt.scope,
                );

                results[idx] = threaded_io.async(Job.process, .{
                    self,
                    cwd,
                    stmt_scope,
                    &parallel_stmt.statement,
                });

                jobs[idx] = .{ .stmt_scope = stmt_scope };
            }
            defer for (jobs) |*j| j.deinit();

            for (results) |*r| {
                try r.await(threaded_io);
            }
        },
        .expr => |*expr| {
            _ = try self.evaluateExpr(cwd, scope, expr);
        },
    }
}

fn evaluateParallelJobsCount(self: *Runtime, cwd: std.Io.Dir, scope: *Scope, parallel: *const ir.Parallel) Error!usize {
    if (parallel.jobs) |*jobs_expr| {
        const value = try self.evaluateExpr(cwd, scope, jobs_expr);
        return @intCast(integerize(value.number));
    }

    return self.options.jobs;
}

fn handleTaskCall(self: *Runtime, cwd: std.Io.Dir, scope: *Scope, task_call: *const ir.TaskCall) Error!void {
    const task = task_call.task;

    var values: std.array_hash_map.String(Value) = .empty;
    defer values.deinit(self.allocator);
    var it = task_call.args.iterator();

    while (it.next()) |kv| {
        switch (kv.value_ptr.*) {
            .default => |def| try values.put(self.allocator, kv.key_ptr.*, def),
            .value => |expr| try values.put(self.allocator, kv.key_ptr.*, try self.evaluateExpr(cwd, scope, &expr)),
        }
    }

    try self.runTask(scope, task, values, task_call.same_group);
}

fn handleDecl(
    self: *Runtime,
    cwd: std.Io.Dir,
    scope: *Scope,
    decl: *const ir.Decl,
    needed: ?*ir.Target(ir.Decl).Leaf,
) Error!?Value {
    const decl_scope = scope.findByStatic(decl.scope) orelse unreachable;

    const value = try self.evaluateExpr(cwd, decl_scope, &decl.value);

    return try self.destructure(
        ir.Decl,
        cwd,
        scope,
        decl.targets,
        value,
        needed,
    );
}

pub fn destructure(
    self: *Runtime,
    comptime T: type,
    cwd: std.Io.Dir,
    scope: *Scope,
    targets: ir.Target(T),
    value: Value,
    needed: ?*ir.Target(T).Leaf,
) Error!?Value {
    switch (targets) {
        .exact => |target| {
            if (target.name) |name| {
                try scope.define(target, .{
                    .name = name,
                    .value = value,
                }, false);
            }

            if (target == needed)
                return value;

            return null;
        },
        .destructure => |ts| {
            const values = value.tuple.elements;
            var needed_value: ?Value = null;

            for (ts, values) |t, v| {
                if (try self.destructure(T, cwd, scope, t, v, needed)) |ev|
                    needed_value = ev;
            }

            return needed_value;
        },
    }
}

const ProcessOptions = struct {
    process: []const u8,
    echo: bool,
    allow_input: bool,
    out: ?*std.Io.Writer = null,
};

fn handleProcess(self: *Runtime, cwd: std.Io.Dir, scope: *Scope, options: ProcessOptions) Error!u8 {
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
            .cwd = .{ .dir = cwd },
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

pub fn evaluateExpr(self: *Runtime, cwd: std.Io.Dir, scope: *Scope, expr: *const ir.Expr) Error!Value {
    return switch (expr.*) {
        .bool_lit => |lit| .{ .bool = lit },
        .number_lit => |lit| .{ .number = lit },
        .string => |str| .{ .string = try self.resolveString(cwd, scope, str) },
        .list => |*list| {
            var result: std.ArrayList(Value) = try .initCapacity(scope.arena.allocator(), list.items.len);
            errdefer result.deinit(scope.arena.allocator());

            for (list.items) |item| {
                if (item.is_spread) {
                    const spread = try self.evaluateExpr(cwd, scope, item.expr);
                    try result.appendSlice(scope.arena.allocator(), spread.list.items);
                } else {
                    try result.append(scope.arena.allocator(), try self.evaluateExpr(cwd, scope, item.expr));
                }
            }

            return .{
                .list = .{
                    .items_type = &list.items_type,
                    .items = try result.toOwnedSlice(scope.arena.allocator()),
                },
            };
        },
        .tuple => |tuple| {
            const result = try scope.arena.allocator().alloc(Value, tuple.elements.len);

            for (tuple.elements, result) |*element, *out| {
                out.* = try self.evaluateExpr(cwd, scope, element);
            }

            return .{
                .tuple = .{
                    .types = tuple.types,
                    .elements = result,
                },
            };
        },
        .ident => |id| {
            // get resolved
            if (scope.resolve(id.symbol.identity())) |sym| {
                return sym.value;
            }
            // resolve if not already (lazy resolution)
            return switch (id.symbol.origin) {
                .decl => |target| try self.handleDecl(
                    cwd,
                    scope,
                    target.parent,
                    target,
                ) orelse unreachable,
                .capture => std.debug.panic("Capture value not resolved? The flip?", .{}),
                .argument => unreachable, // should be already resolved by runtime builder,
                else => unreachable, // group and task cannot be used in expression
            };
        },
        .if_expr => |if_expr| {
            const cond = try self.evaluateExpr(cwd, scope, &if_expr.cond);
            std.debug.assert(cond == .bool);

            return if (cond.bool)
                try self.evaluateExpr(cwd, scope, &if_expr.then)
            else
                try self.evaluateExpr(cwd, scope, &if_expr.@"else");
        },
        .switch_expr => |switch_expr| {
            const target = try self.evaluateExpr(cwd, scope, &switch_expr.subject);

            const value = switch_expr.cases.get(target) orelse switch_expr.else_case;

            return try self.evaluateExpr(cwd, scope, &value);
        },
        .for_expr => |for_expr| {
            const ranges = try self.allocator.alloc(Range, for_expr.subjects.len);
            defer self.allocator.free(ranges);

            const values = try self.allocator.alloc(?Value, for_expr.subjects.len);
            defer self.allocator.free(values);

            for (for_expr.subjects, 0..) |in, idx| {
                switch (in) {
                    .range => |*range| {
                        ranges[idx] = try self.evaluateRange(cwd, scope, range);
                        values[idx] = null;
                    },
                    .expr => |*list_expr| {
                        const value = try self.evaluateExpr(cwd, scope, list_expr);
                        ranges[idx] = .{
                            .left = 0,
                            .right = @intCast(value.list.items.len),
                        };
                        values[idx] = value;
                    },
                }
            }

            const final_range = clampRanges(ranges);

            var result: std.ArrayList(Value) = .empty;

            if (final_range.right) |right| {
                const iterations_count: usize = @intCast(right - final_range.left);

                // handle parallel for expr
                if (for_expr.parallel) |*p| {
                    const jobs_count: usize = try self.evaluateParallelJobsCount(
                        cwd,
                        scope,
                        p,
                    );
                    var threaded = std.Io.Threaded.init(self.allocator, .{
                        .async_limit = .limited(jobs_count),
                    });
                    defer threaded.deinit();

                    const threaded_io = threaded.io();

                    const Job = struct {
                        iter_scope: *Scope,

                        fn deinit(s: *@This()) void {
                            s.iter_scope.destroy();
                        }

                        fn process(runtime: *Runtime, dir: std.Io.Dir, iter_scope: *Scope, iter_expr: *const ir.Expr) Error!Value {
                            return try runtime.evaluateExpr(
                                dir,
                                iter_scope,
                                iter_expr,
                            );
                        }
                    };

                    const jobs = try self.allocator.alloc(Job, iterations_count);
                    defer self.allocator.free(jobs);

                    const results = try self.allocator.alloc(std.Io.Future(Error!Value), iterations_count);
                    defer self.allocator.free(results);

                    for (0..iterations_count) |i| {
                        const item_index = @as(usize, @intCast(final_range.left)) + i;
                        const iter_scope = try Scope.create(
                            scope,
                            self.allocator,
                            for_expr.scope,
                        );
                        for (for_expr.captures, 0..) |capture, j| {
                            const value: Value = if (values[j]) |value|
                                value.list.items[@intCast(item_index)]
                            else
                                .{ .number = @floatFromInt(item_index) };

                            _ = try self.destructure(
                                ir.Capture,
                                cwd,
                                iter_scope,
                                capture.target,
                                value,
                                null,
                            );
                        }

                        jobs[i] = .{ .iter_scope = iter_scope };
                        results[i] = threaded_io.async(
                            Job.process,
                            .{
                                self,
                                cwd,
                                iter_scope,
                                &for_expr.body,
                            },
                        );
                    }
                    defer for (jobs) |*j| j.deinit();

                    for (results) |*r| {
                        const value = r.await(threaded_io);

                        if (value) |v| {
                            try result.append(scope.arena.allocator(), v);
                        } else |err| switch (err) {
                            Error.Continue => continue,
                            Error.Break => unreachable,
                            else => return err,
                        }
                    }
                } else {
                    const for_scope = try Scope.create(scope, self.allocator, for_expr.scope);
                    defer for_scope.destroy();

                    for (0..iterations_count) |i| {
                        const item_index = @as(usize, @intCast(final_range.left)) + i;
                        defer for_scope.clearSymbols();

                        for (for_expr.captures, 0..) |capture, j| {
                            const value: Value = if (values[j]) |value|
                                value.list.items[item_index]
                            else
                                .{ .number = @floatFromInt(item_index) };

                            _ = try self.destructure(
                                ir.Capture,
                                cwd,
                                for_scope,
                                capture.target,
                                value,
                                null,
                            );
                        }

                        const item = self.evaluateExpr(
                            cwd,
                            for_scope,
                            &for_expr.body,
                        ) catch |err| switch (err) {
                            Error.Continue => continue,
                            Error.Break => break,
                            else => return err,
                        };

                        try result.append(
                            scope.arena.allocator(),
                            try item.clone(scope.arena.allocator()),
                        );
                    }
                }
            }
            return .{
                .list = .{
                    .items_type = &for_expr.type,
                    .items = try result.toOwnedSlice(scope.arena.allocator()),
                },
            };
        },
        .binary => |binary| {
            const left = try self.evaluateExpr(cwd, scope, &binary.left);
            const right = try self.evaluateExpr(cwd, scope, &binary.right);

            // add,sub,div,mul => [string,float,int,list,bool] op [string,float,int]

            return try binary_mod.evalBinary(
                scope.arena.allocator(),
                binary.op,
                left,
                right,
            );
        },
        .unary => |unary| {
            const operand = try self.evaluateExpr(cwd, scope, &unary.operand);

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
            // lib.debug.dump(call, 4);
            const args = try scope.arena.allocator().alloc(Value, call.args.len);

            for (call.args, args) |in, *out| {
                out.* = try self.evaluateExpr(cwd, scope, &in);
            }

            const value = try builtin.callFunction(self, cwd, scope, call.function.id, args);

            return switch (value) {
                .result => |r| if (r.value) |v|
                    v.*
                else
                    try self.evaluateExpr(cwd, scope, &call.fallback.?),
                else => value,
            };
        },
        .lambda => |lambda| .{
            .lambda = if (lambda.resolved) |resolved|
                .{ .instance = resolved }
            else
                .{ .template = lambda.template },
        },
        .lambda_call => |lambda_call| {
            const lambda = lambda_call.lambda;
            std.debug.assert(lambda_call.args.len == lambda.params.len);

            const frame = try Scope.create(scope, self.allocator, lambda.scope);
            defer frame.destroy();

            for (lambda_call.args, lambda.params) |*arg, *param| {
                const value = try self.evaluateExpr(cwd, scope, arg);

                _ = try self.destructure(
                    ir.Capture,
                    cwd,
                    frame,
                    param.target,
                    value,
                    null,
                );
            }

            const result = try self.evaluateExpr(
                cwd,
                frame,
                &lambda.body,
            );

            return result.clone(scope.arena.allocator());
        },
        .process => |process_expr| {
            const process = try self.resolveString(cwd, scope, process_expr.command);
            var aw: std.Io.Writer.Allocating = .init(scope.arena.allocator());

            self.status_code = try self.handleProcess(cwd, scope, .{
                .process = process,
                .echo = false,
                .allow_input = false,
                .out = &aw.writer,
            });

            if (self.status_code != 0) {
                if (process_expr.fallback) |*value| {
                    return try self.evaluateExpr(cwd, scope, value);
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
        .slice => |slice| {
            const operand = try self.evaluateExpr(cwd, scope, &slice.operand);

            const length = switch (operand) {
                .list => |list| list.items.len,
                .string => |str| str.len,
                else => unreachable,
            };

            const range = clampRange(
                try self.evaluateRange(cwd, scope, &slice.range),
                .{
                    .left = 0,
                    .right = @intCast(length),
                },
            );

            const result: Value = switch (operand) {
                .list => |list| .{
                    .list = .{
                        .items_type = list.items_type,
                        .items = list.items[@intCast(range.left)..@intCast(range.right.?)],
                    },
                },
                .string => |str| .{
                    .string = str[@intCast(range.left)..@intCast(range.right.?)],
                },
                else => unreachable,
            };

            return result.clone(scope.arena.allocator());
        },
        .with => |with| {
            const with_scope = try Scope.create(
                scope,
                self.allocator,
                with.scope,
            );
            defer with_scope.destroy();

            if (with.parallel) |p| {
                const jobs_count: usize = blk: {
                    if (p.jobs) |*jobs_expr| {
                        const jobs_value = try self.evaluateExpr(cwd, scope, jobs_expr);
                        break :blk @intCast(integerize(jobs_value.number));
                    }
                    break :blk self.options.jobs;
                };

                var threaded: std.Io.Threaded = .init(self.allocator, .{
                    .async_limit = .limited(jobs_count),
                });
                defer threaded.deinit();

                const threaded_io = threaded.io();

                const Job = struct {
                    fn process(runtime: *Runtime, dir: std.Io.Dir, s: *Scope, subject: *const ir.Expr) Error!Value {
                        return try runtime.evaluateExpr(
                            dir,
                            s,
                            subject,
                        );
                    }
                };

                const results = try self.allocator.alloc(std.Io.Future(Error!Value), with.subjects.len);
                defer self.allocator.free(results);

                for (with.subjects, 0..) |*subject, idx| {
                    results[idx] = threaded_io.async(Job.process, .{
                        self,
                        cwd,
                        scope,
                        subject,
                    });
                }

                for (results, with.captures) |*result, cap| {
                    const value = try result.await(threaded_io);

                    _ = try self.destructure(
                        ir.Capture,
                        cwd,
                        with_scope,
                        cap.target,
                        value,
                        null,
                    );
                }
            } else {
                for (with.subjects, with.captures) |*sub, cap| {
                    const value = try self.evaluateExpr(
                        cwd,
                        scope,
                        sub,
                    );

                    _ = try self.destructure(
                        ir.Capture,
                        cwd,
                        with_scope,
                        cap.target,
                        value,
                        null,
                    );
                }
            }

            const result = try self.evaluateExpr(cwd, with_scope, &with.expr);

            return try result.clone(scope.arena.allocator());
        },
        .in => |in| {
            const subject = try self.evaluateExpr(
                cwd,
                scope,
                &in.subject,
            );

            const path = subject.string;

            const in_dir = cwd.openDir(
                self.io,
                path,
                .{},
            ) catch {
                return try self.evaluateExpr(cwd, scope, &in.@"else");
            };
            defer in_dir.close(self.io);

            return try self.evaluateExpr(in_dir, scope, &in.body);
        },
        .@"continue" => Error.Continue,
        .@"break" => Error.Break,
        .unknown => unreachable,
    };
}

fn clampRanges(ranges: []const Range) Range {
    std.debug.assert(ranges.len != 0);
    var range = ranges[0];

    for (ranges[1..]) |r| {
        range = clampRange(range, r);
    }

    return range;
}

fn clampRange(a: Range, b: Range) Range {
    var left = @max(a.left, b.left);

    const right = if (a.right == null)
        b.right
    else if (b.right == null)
        a.right
    else
        @min(a.right.?, b.right.?);

    if (right) |r| left = @min(left, r);

    return .{
        .left = left,
        .right = right,
    };
}

const Range = struct {
    left: i64,
    right: ?i64,
};

pub fn integerize(value: f64) i64 {
    return @ceil(value);
}

fn evaluateRange(self: *Runtime, cwd: std.Io.Dir, scope: *Scope, range: *const ir.Range) Error!Range {
    const left: i64 = blk: {
        const value = try self.evaluateExpr(
            cwd,
            scope,
            &range.left,
        );

        break :blk integerize(value.number);
    };

    const right: ?i64 = blk: {
        const right = range.right orelse break :blk null;

        const value = try self.evaluateExpr(
            cwd,
            scope,
            &right,
        );

        break :blk @max(integerize(value.number), left);
    };

    return .{
        .left = left,
        .right = right,
    };
}

fn resolveString(self: *Runtime, cwd: std.Io.Dir, scope: *Scope, string: ir.String) Error![]const u8 {
    var aw = std.Io.Writer.Allocating.init(scope.arena.allocator());
    const writer = &aw.writer;
    errdefer aw.deinit();

    for (string) |part| {
        switch (part) {
            .lit => |lit| {
                try writer.writeAll(lit);
            },
            .expr => |expr| {
                const value = try self.evaluateExpr(cwd, scope, &expr);
                try writer.print("{f}", .{value});
            },
        }
    }

    return try aw.toOwnedSlice();
}
