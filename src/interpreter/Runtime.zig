const std = @import("std");

const conzole = @import("conzole");
const Style = conzole.terminal.Style;
const Printer = conzole.terminal.Printer;

const builtin = @import("builtin.zig");

const compiler = @import("compiler");
const ir = compiler.ir;
const Value = compiler.Value;
const fns = compiler.functions;

const lib = @import("lib");

const binary_mod = @import("binary.zig");
const TaskRunner = @import("TaskRunner.zig");
const Scope = @import("Scope.zig");
const parallelization = @import("parallelization.zig");
pub const Runtime = @This();

pub const Error = blk: {
    const SignalError = error{
        Abort,
        Break,
        Continue,
    };
    const DirError = std.Io.Dir.RealPathError || std.Io.Dir.WriteFileError;
    const RWError = std.Io.Writer.Error || std.Io.Reader.Error;
    const ProcessError = std.process.SpawnError;

    break :blk SignalError || DirError || RWError || ProcessError || binary_mod.Error || std.mem.Allocator.Error || lib.regex.Error;
};

const style = struct {
    const echo: Style = .{ .bold = true, .fg = .bright_white };
    const warning: Style = .{ .fg = .bright_yellow };
    const @"error": Style = .{ .bold = true, .fg = .red };
};

/// Per-branch evaluation context. Passed by value, derived with `withX`,
/// never mutated in place, so it is safe to hand to parallel workers.
pub const Ctx = struct {
    cwd: std.Io.Dir,
    scope: *Scope,
    stmt: ?*const ir.Statement = null,

    pub fn withCwd(self: Ctx, cwd: std.Io.Dir) Ctx {
        return lib.utils.replace(self, .{
            .cwd = cwd,
        });
    }

    pub fn withScope(self: Ctx, scope: *Scope) Ctx {
        return lib.utils.replace(self, .{
            .scope = scope,
        });
    }

    pub fn withStmt(self: Ctx, stmt: *const ir.Statement) Ctx {
        return lib.utils.replace(self, .{
            .stmt = stmt,
        });
    }

    pub fn arena(self: *const Ctx) std.mem.Allocator {
        return self.scope.arena.allocator();
    }
};

allocator: std.mem.Allocator,
invokation_dir: []const u8,
io: std.Io,
printer: *Printer,
regex_cache: *lib.regex.Cache,
// source
options: *const ir.Options,
// environment
cwd: std.Io.Dir,
root_scope: *Scope,
original_environ: *const std.process.Environ.Map,
tmpdir: []const u8,
// parallel
worker_budget: std.atomic.Value(usize),

pub fn init(
    allocator: std.mem.Allocator,
    invokation_dir: []const u8,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    printer: *Printer,
    regex_cache: *lib.regex.Cache,
    file: *const ir.File,
) !Runtime {

    // TODO: read dotenv,

    const cwd = try std.Io.Dir.cwd().openDir(
        io,
        file.options.working_dir orelse ".",
        .{},
    );
    errdefer cwd.close(io);

    const root_scope = try Scope.create(
        null,
        allocator,
        file.scope,
    );
    errdefer root_scope.destroy();

    try root_scope.environ.map.putAll(environ);

    if (file.options.dotenv) |dotenv| {
        try lib.dotenv.parse(
            io,
            dotenv,
            &root_scope.environ.map,
        );
    }

    const tmpdir = try lib.program.tempDir(allocator, environ);
    errdefer allocator.free(tmpdir);

    return .{
        .allocator = allocator,
        .invokation_dir = invokation_dir,
        .io = io,
        .printer = printer,
        .regex_cache = regex_cache,
        .options = &file.options,
        .cwd = cwd,
        .root_scope = root_scope,
        .original_environ = environ,
        .tmpdir = tmpdir,
        .worker_budget = .init(file.options.jobs - 1),
    };
}

pub fn deinit(self: *Runtime) void {
    self.allocator.free(self.tmpdir);
    self.cwd.close(self.io);
    self.root_scope.destroy();
}

pub fn run(
    self: *Runtime,
    initial_task: *const ir.Task,
    values: std.array_hash_map.String(Value),
) !void {
    try self.runTask(
        self.root_scope,
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

pub fn runBlock(self: *Runtime, ctx: Ctx, statements: []const ir.Statement) Error!void {
    for (statements) |*stmt| {
        try self.main(ctx.withStmt(stmt), stmt);
    }
}

fn main(self: *Runtime, ctx: Ctx, stmt: *const ir.Statement) Error!void {
    switch (stmt.*) {
        .decl => |decl| {
            _ = try self.handleDecl(ctx, decl, null);
        },
        .process => |*proc_expr| {
            const process = try self.evaluateExpr(ctx, &proc_expr.command);

            const status_code = blk: {
                if (proc_expr.script) {
                    const noecho = proc_expr.noecho orelse true;

                    break :blk try self.executeScript(ctx, .{
                        .process = process.string,
                        .echo = !noecho,
                        .allow_input = true,
                    });
                } else {
                    const noecho = proc_expr.noecho orelse false;

                    break :blk try self.executeProcess(ctx, .{
                        .process = process.string,
                        .echo = !noecho,
                        .allow_input = true,
                    });
                }
            };

            ctx.scope.setStatusCode(status_code);

            if (status_code != 0 and proc_expr.nofail == false) {
                try self.printer.printStyled(
                    self.allocator,
                    style.@"error",
                    \\tasq: error: command failed with exit code {}
                    \\  on '{s}'
                    \\
                ,
                    .{ status_code, process.string },
                );
                return Error.Abort;
            }
        },
        .if_stmt => |*if_stmt| {
            const cond = try self.evaluateExpr(ctx, &if_stmt.cond);

            if (cond.bool) {
                const then_scope = try Scope.create(ctx.scope, self.allocator, if_stmt.then.scope);
                defer then_scope.destroy();

                try self.runBlock(ctx.withScope(then_scope), if_stmt.then.statements);
            } else if (if_stmt.else_) |*else_| {
                const else_scope = try Scope.create(ctx.scope, self.allocator, else_.scope);
                defer else_scope.destroy();

                try self.runBlock(ctx.withScope(else_scope), else_.statements);
            }
        },
        .switch_stmt => |*switch_stmt| {
            const target = try self.evaluateExpr(ctx, &switch_stmt.subject);

            const block: ?*const ir.StatementBlock = switch_stmt.cases.getPtr(target) orelse if (switch_stmt.else_case) |*e| e else null;

            if (block) |b| {
                const case_scope = try Scope.create(ctx.scope, self.allocator, b.scope);
                defer case_scope.destroy();

                try self.runBlock(ctx.withScope(case_scope), b.statements);
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
                        ranges[idx] = try self.evaluateRange(ctx, range);
                        values[idx] = null;
                    },
                    .expr => |*list_expr| {
                        const value = try self.evaluateExpr(ctx, list_expr);
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
                    const jobs_limit: usize = try self.evaluateParallelJobsLimit(ctx, p);

                    const ItCtx = struct {
                        const Self = @This();
                        runtime: *Runtime,
                        ctx: Ctx,
                        target: *const ir.ForStmt,
                        values: []?Value,
                        left: i64,

                        fn iteration(it: *Self, idx: usize) Error!void {
                            const item_index = lib.math.op(i64, it.left, idx, .add);

                            const iter_scope = try Scope.create(
                                it.ctx.scope,
                                it.runtime.allocator,
                                it.target.body.scope,
                            );
                            defer iter_scope.destroy();

                            const iter_ctx = it.ctx.withScope(iter_scope);

                            for (it.target.captures, 0..) |capture, j| {
                                const value: Value = if (it.values[j]) |value|
                                    value.list.items[@intCast(item_index)]
                                else
                                    .{ .number = @floatFromInt(item_index) };
                                _ = try it.runtime.destructure(
                                    ir.Capture,
                                    iter_ctx,
                                    capture.target,
                                    value,
                                    null,
                                );
                            }

                            it.runtime.runBlock(
                                iter_ctx,
                                it.target.body.statements,
                            ) catch |err| switch (err) {
                                Error.Continue => return,
                                Error.Break => unreachable,
                                else => return err,
                            };
                        }
                    };

                    var context: ItCtx = .{
                        .runtime = self,
                        .ctx = ctx,
                        .target = for_stmt,
                        .values = values,
                        .left = final_range.left,
                    };

                    try parallelization.runIndexed(
                        self,
                        iterations_count,
                        jobs_limit,
                        &context,
                        ItCtx.iteration,
                    );
                } else {
                    const for_scope = try Scope.create(ctx.scope, self.allocator, for_stmt.body.scope);
                    defer for_scope.destroy();

                    const body_ctx = ctx.withScope(for_scope);

                    for (0..iterations_count) |i| {
                        const item_index = lib.math.op(i64, final_range.left, i, .add);
                        defer for_scope.clearSymbols(self.io);

                        for (for_stmt.captures, 0..) |capture, j| {
                            const value: Value = if (values[j]) |value|
                                value.list.items[@intCast(item_index)]
                            else
                                .{ .number = @floatFromInt(item_index) };

                            _ = try self.destructure(
                                ir.Capture,
                                body_ctx,
                                capture.target,
                                value,
                                null,
                            );
                        }
                        self.runBlock(body_ctx, for_stmt.body.statements) catch |err| switch (err) {
                            Error.Continue => continue,
                            Error.Break => break,
                            else => return err,
                        };
                    }
                }
            }
        },
        .task_call => |*task_call| {
            try self.handleTaskCall(ctx, task_call);
        },
        .in_stmt => |*in_stmt| {
            const subject = try self.evaluateExpr(ctx, &in_stmt.subject);

            const path = subject.string;

            const in_dir = ctx.cwd.openDir(
                self.io,
                path,
                .{},
            ) catch {
                if (in_stmt.@"else") |@"else"| {
                    const else_scope = try Scope.create(ctx.scope, self.allocator, @"else".scope);
                    defer else_scope.destroy();

                    try self.runBlock(ctx.withScope(else_scope), @"else".statements);
                }
                return;
            };
            defer in_dir.close(self.io);

            const in_scope = try Scope.create(ctx.scope, self.allocator, in_stmt.body.scope);
            defer in_scope.destroy();

            try self.runBlock(
                ctx.withCwd(in_dir).withScope(in_scope),
                in_stmt.body.statements,
            );
        },
        .parallel_block => |*parallel_block| {
            const jobs_limit: usize = try self.evaluateParallelJobsLimit(
                ctx,
                &parallel_block.parallel,
            );

            const Context = struct {
                const Self = @This();
                runtime: *Runtime,
                ctx: Ctx,
                block: *const ir.ParallelBlock,

                fn runStatement(it: *Self, idx: usize) Error!void {
                    const par_stmt = &it.block.statements[idx];
                    const stmt_scope = try Scope.create(
                        it.ctx.scope,
                        it.runtime.allocator,
                        par_stmt.scope,
                    );
                    defer stmt_scope.destroy();

                    try it.runtime.main(
                        it.ctx.withScope(stmt_scope).withStmt(&par_stmt.statement),
                        &par_stmt.statement,
                    );
                }
            };

            var context: Context = .{
                .runtime = self,
                .ctx = ctx,
                .block = parallel_block,
            };

            try parallelization.runIndexed(
                self,
                parallel_block.statements.len,
                jobs_limit,
                &context,
                Context.runStatement,
            );
        },
        .expr => |*expr| {
            _ = try self.evaluateExpr(ctx, expr);
        },
    }
}

fn evaluateParallelJobsLimit(self: *Runtime, ctx: Ctx, parallel: *const ir.Parallel) Error!usize {
    if (parallel.jobs) |*jobs_expr| {
        const value = try self.evaluateExpr(ctx, jobs_expr);
        return @intCast(integerize(value.number));
    }

    return self.options.jobs;
}

fn handleTaskCall(self: *Runtime, ctx: Ctx, task_call: *const ir.TaskCall) Error!void {
    const task = task_call.task;

    var values: std.array_hash_map.String(Value) = .empty;
    defer values.deinit(self.allocator);
    var it = task_call.args.iterator();

    while (it.next()) |kv| {
        switch (kv.value_ptr.*) {
            .default => |def| try values.put(self.allocator, kv.key_ptr.*, def),
            // capture by pointer: evaluating a copy of the Expr would leave
            // pointers into this stack frame (e.g. list `items_type`) in the result
            .value => |*expr| try values.put(
                self.allocator,
                kv.key_ptr.*,
                try self.evaluateExpr(ctx, expr),
            ),
        }
    }

    try self.runTask(ctx.scope, task, values, task_call.same_group);
}

fn handleDecl(
    self: *Runtime,
    ctx: Ctx,
    decl: *const ir.Decl,
    needed: ?*ir.Target(ir.Decl).Leaf,
) Error!?Value {
    const decl_scope = ctx.scope.findByStatic(decl.scope) orelse unreachable;

    const value = try self.evaluateExpr(ctx.withScope(decl_scope), &decl.value);

    return try self.destructure(
        ir.Decl,
        ctx,
        decl.targets,
        value,
        needed,
    );
}

pub fn destructure(
    self: *Runtime,
    comptime T: type,
    ctx: Ctx,
    targets: ir.Target(T),
    value: Value,
    needed: ?*ir.Target(T).Leaf,
) Error!?Value {
    switch (targets) {
        .exact => |target| {
            if (target.name) |name| {
                try ctx.scope.define(self.io, target, .{
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
                if (try self.destructure(T, ctx, t, v, needed)) |ev|
                    needed_value = ev;
            }

            return needed_value;
        },
    }
}

const ExecuteOptions = struct {
    process: []const u8,
    echo: bool,
    allow_input: bool,
    out: ?*std.Io.Writer = null,
};

fn executeScript(self: *Runtime, ctx: Ctx, options: ExecuteOptions) Error!u8 {
    // generate temp file name,
    var raw: [8]u8 = undefined;
    self.io.random(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);

    var name_buf: [64]u8 = undefined;

    const name = try std.mem.print(&name_buf, "tasq-{s}{s}", .{
        hex, lib.platform.Desc.current.script_extensions,
    });

    const tmp_file_path = try std.fs.path.join(self.allocator, &.{
        self.tmpdir,
        name,
    });
    defer self.allocator.free(tmp_file_path);

    try ctx.cwd.writeFile(self.io, .{
        .sub_path = tmp_file_path,
        .data = options.process,
        .flags = .{
            .exclusive = true,
            .truncate = true,
        },
    });
    defer ctx.cwd.deleteFile(self.io, tmp_file_path) catch |err| {
        self.printer.printStyled(
            self.allocator,
            style.warning,
            "warning: unable to delete '{s}' ({s}),",
            .{ tmp_file_path, @errorName(err) },
        ) catch unreachable;
    };

    const script_len = self.options.script.len;
    var argv = try self.allocator.alloc([]const u8, script_len + 1);
    defer self.allocator.free(argv);

    @memcpy(argv[0..script_len], self.options.script);
    argv[script_len] = tmp_file_path;

    if (options.echo) {
        try self.printer.printStyled(
            self.allocator,
            style.echo,
            "{s}\n",
            .{options.process},
        );
    }

    //TOOD: consider if echo, stdout, stdin etc
    return self.spawnAndWait(ctx, argv, options);
}

fn executeProcess(self: *Runtime, ctx: Ctx, options: ExecuteOptions) Error!u8 {
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

    return self.spawnAndWait(ctx, argv, options);
}

/// Spawns `argv`, optionally streams its stdout into `options.out`, and waits
/// for it. If streaming fails the child is killed so it is never left unreaped.
fn spawnAndWait(
    self: *Runtime,
    ctx: Ctx,
    argv: []const []const u8,
    options: ExecuteOptions,
) Error!u8 {
    var child = try std.process.spawn(self.io, .{
        .argv = argv,
        .cwd = .{ .dir = ctx.cwd },
        .environ_map = &ctx.scope.environ.map,
        .stdout = if (options.out == null)
            .inherit
        else
            .pipe,
        .stdin = if (options.allow_input)
            .inherit
        else
            .ignore,
    });

    if (options.out) |output| {
        errdefer child.kill(self.io);

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

pub fn evaluateExpr(self: *Runtime, ctx: Ctx, expr: *const ir.Expr) Error!Value {
    return switch (expr.*) {
        .bool_lit => |lit| .{ .bool = lit },
        .number_lit => |lit| .{ .number = lit },
        .string => |str| .{ .string = try self.resolveString(ctx, str) },
        .regex => |regex| .{ .regex = regex },
        .list => |*list| {
            var result: std.ArrayList(Value) = try .initCapacity(
                ctx.arena(),
                list.items.len,
            );
            errdefer result.deinit(ctx.arena());

            for (list.items) |item| {
                if (item.is_spread) {
                    const spread = try self.evaluateExpr(ctx, item.expr);
                    try result.appendSlice(ctx.arena(), spread.list.items);
                } else {
                    try result.append(ctx.arena(), try self.evaluateExpr(ctx, item.expr));
                }
            }

            return .{
                .list = .{
                    .items_type = &list.items_type,
                    .items = try result.toOwnedSlice(ctx.arena()),
                },
            };
        },
        .tuple => |tuple| {
            const result = try ctx.arena().alloc(Value, tuple.elements.len);

            for (tuple.elements, result) |*element, *out| {
                out.* = try self.evaluateExpr(ctx, element);
            }

            return .{
                .tuple = .{
                    .types = tuple.types,
                    .elements = result,
                },
            };
        },
        .ident => |id| {
            const identity = id.symbol.identity();
            // get resolved
            while (true) {
                if (ctx.scope.resolve(self.io, identity)) |sym| {
                    return sym.value;
                }
                // resolve if not already (lazy resolution)
                return switch (id.symbol.origin) {
                    .decl => |target| {
                        const decl = target.parent;
                        const decl_scope = ctx.scope.findByStatic(decl.scope) orelse unreachable;

                        switch (try decl_scope.beginStatic(self.io, decl, identity)) {
                            .done => continue,
                            .wait => |event| {
                                event.waitUncancelable(self.io);
                                continue;
                            },
                            .owner => {
                                defer decl_scope.endStatic(self.io, decl);
                                return try self.handleDecl(ctx, decl, target) orelse unreachable;
                            },
                        }
                    },
                    .capture => std.debug.panic("Capture value not resolved? The flip?", .{}),
                    .argument => unreachable, // should be already resolved by runtime builder,
                    else => unreachable, // group and task cannot be used in expression
                };
            }
        },
        .if_expr => |if_expr| {
            const cond = try self.evaluateExpr(ctx, &if_expr.cond);
            std.debug.assert(cond == .bool);

            return if (cond.bool)
                try self.evaluateExpr(ctx, &if_expr.then)
            else
                try self.evaluateExpr(ctx, &if_expr.@"else");
        },
        .switch_expr => |switch_expr| {
            const target = try self.evaluateExpr(ctx, &switch_expr.subject);

            // by pointer: evaluating a stack copy of the case Expr would leave
            // dangling pointers into this frame (e.g. list `items_type`)
            const value: *const ir.Expr = switch_expr.cases.getPtr(target) orelse
                if (switch_expr.else_case) |*e| e else {
                    std.debug.panic(
                        \\internal error: no matching case found
                        \\this should have been catched during ir validation
                    , .{});
                };

            return try self.evaluateExpr(ctx, value);
        },
        .for_expr => |for_expr| {
            const ranges = try self.allocator.alloc(Range, for_expr.subjects.len);
            defer self.allocator.free(ranges);

            const values = try self.allocator.alloc(?Value, for_expr.subjects.len);
            defer self.allocator.free(values);

            for (for_expr.subjects, 0..) |in, idx| {
                switch (in) {
                    .range => |*range| {
                        ranges[idx] = try self.evaluateRange(ctx, range);
                        values[idx] = null;
                    },
                    .expr => |*list_expr| {
                        const value = try self.evaluateExpr(ctx, list_expr);
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
                try result.ensureTotalCapacityPrecise(
                    ctx.arena(),
                    iterations_count,
                );
                // handle parallel for expr
                if (for_expr.parallel) |*p| {
                    const jobs_limit: usize = try self.evaluateParallelJobsLimit(ctx, p);

                    const ItCtx = struct {
                        const Self = @This();
                        runtime: *Runtime,
                        ctx: Ctx,
                        target: *const ir.ForExpr,
                        values: []?Value,
                        left: i64,
                        slots: []?Value,

                        fn iteration(it: *Self, idx: usize) Error!void {
                            const item_index = lib.math.op(i64, it.left, idx, .add);

                            const iter_scope = try Scope.create(
                                it.ctx.scope,
                                it.runtime.allocator,
                                it.target.scope,
                            );
                            defer iter_scope.destroy();

                            const iter_ctx = it.ctx.withScope(iter_scope);

                            for (it.target.captures, 0..) |capture, j| {
                                const value: Value = if (it.values[j]) |value|
                                    value.list.items[@intCast(item_index)]
                                else
                                    .{ .number = @floatFromInt(item_index) };
                                _ = try it.runtime.destructure(
                                    ir.Capture,
                                    iter_ctx,
                                    capture.target,
                                    value,
                                    null,
                                );
                            }

                            const value = it.runtime.evaluateExpr(
                                iter_ctx,
                                &it.target.body,
                            ) catch |err| switch (err) {
                                Error.Continue => return,
                                Error.Break => unreachable,
                                else => return err,
                            };
                            // clone into the parent's arena: iter_scope dies on return
                            it.slots[idx] = try value.clone(it.ctx.arena());
                        }
                    };

                    const slots = try self.allocator.alloc(?Value, iterations_count);
                    defer self.allocator.free(slots);
                    @memset(slots, null);

                    var context: ItCtx = .{
                        .runtime = self,
                        .ctx = ctx,
                        .target = for_expr,
                        .values = values,
                        .left = @intCast(final_range.left),
                        .slots = slots,
                    };

                    try parallelization.runIndexed(
                        self,
                        iterations_count,
                        jobs_limit,
                        &context,
                        ItCtx.iteration,
                    );

                    for (slots) |slot| if (slot) |v| result.appendAssumeCapacity(v);
                } else {
                    const for_scope = try Scope.create(ctx.scope, self.allocator, for_expr.scope);
                    defer for_scope.destroy();

                    const body_ctx = ctx.withScope(for_scope);

                    for (0..iterations_count) |i| {
                        const item_index = lib.math.op(i64, final_range.left, i, .add);
                        defer for_scope.clearSymbols(self.io);

                        for (for_expr.captures, 0..) |capture, j| {
                            const value: Value = if (values[j]) |value|
                                value.list.items[@intCast(item_index)]
                            else
                                .{ .number = @floatFromInt(item_index) };

                            _ = try self.destructure(
                                ir.Capture,
                                body_ctx,
                                capture.target,
                                value,
                                null,
                            );
                        }

                        const item = self.evaluateExpr(
                            body_ctx,
                            &for_expr.body,
                        ) catch |err| switch (err) {
                            Error.Continue => continue,
                            Error.Break => break,
                            else => return err,
                        };

                        try result.append(
                            ctx.arena(),
                            try item.clone(ctx.arena()),
                        );
                    }
                }
            }
            return .{
                .list = .{
                    .items_type = &for_expr.type,
                    .items = result.items,
                },
            };
        },
        .binary => |binary| {
            const left = try self.evaluateExpr(ctx, &binary.left);
            const right = try self.evaluateExpr(ctx, &binary.right);

            // add,sub,div,mul => [string,float,int,list,bool] op [string,float,int]

            return try binary_mod.evalBinary(
                ctx.arena(),
                binary.op,
                left,
                right,
            );
        },
        .unary => |unary| {
            const operand = try self.evaluateExpr(ctx, &unary.operand);

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
            const args = try ctx.arena().alloc(Value, call.args.len);

            for (call.args, args) |in, *out| {
                out.* = try self.evaluateExpr(ctx, &in);
            }

            return try builtin.callFunction(
                self,
                ctx,
                call.function.id,
                args,
                &call.function.return_type,
            );
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

            const frame = try Scope.create(ctx.scope, self.allocator, lambda.scope);
            defer frame.destroy();

            const frame_ctx = ctx.withScope(frame);

            for (lambda_call.args, lambda.params) |*arg, *param| {
                const value = try self.evaluateExpr(ctx, arg);

                _ = try self.destructure(
                    ir.Capture,
                    frame_ctx,
                    param.target,
                    value,
                    null,
                );
            }

            const result = try self.evaluateExpr(
                frame_ctx,
                &lambda.body,
            );

            return result.clone(ctx.arena());
        },
        .process => |process_expr| {
            const process = try self.evaluateExpr(ctx, &process_expr.command);
            var aw: std.Io.Writer.Allocating = .init(ctx.arena());

            const status_code = if (process_expr.script)
                try self.executeScript(ctx, .{
                    .process = process.string,
                    .allow_input = false,
                    .echo = false,
                    .out = &aw.writer,
                })
            else
                try self.executeProcess(ctx, .{
                    .process = process.string,
                    .allow_input = false,
                    .echo = false,
                    .out = &aw.writer,
                });

            ctx.scope.setStatusCode(status_code);

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

            if (process_expr.nofail)
                return .{ .string = result };

            const result_type = comptime &fns.ProcessResult.withType(&.string);

            if (status_code != 0) {
                return try fns.ProcessResult.fail(
                    ctx.arena(),
                    result_type,
                    .failed,
                    "command failed with exit code {}",
                    .{status_code},
                );
            }

            return try fns.ProcessResult.ok(
                ctx.arena(),
                result_type,
                .{ .string = result },
            );
        },
        .slice => |slice| {
            const operand = try self.evaluateExpr(ctx, &slice.operand);

            const length = switch (operand) {
                .list => |list| list.items.len,
                .string => |str| str.len,
                else => unreachable,
            };

            const range = clampRange(
                try self.evaluateRange(ctx, &slice.range),
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

            return result.clone(ctx.arena());
        },
        .in => |in| {
            const subject = try self.evaluateExpr(ctx, &in.subject);

            const path = subject.string;

            const in_dir = ctx.cwd.openDir(
                self.io,
                path,
                .{},
            ) catch {
                return try self.evaluateExpr(ctx, &in.@"else");
            };
            defer in_dir.close(self.io);

            return try self.evaluateExpr(ctx.withCwd(in_dir), &in.body);
        },
        .@"continue" => Error.Continue,
        .@"break" => Error.Break,
        .try_expr => |try_expr| {
            const value = try self.evaluateExpr(ctx, &try_expr.subject);

            return switch (value.result.payload) {
                .fail => |e| self.abortWithError(ctx, "{s}: {s}", .{
                    e.type.names[e.id],
                    e.message.?,
                }),
                .value => |v| v.*,
            };
        },
        .catch_expr => |catch_expr| {
            const value = try self.evaluateExpr(ctx, &catch_expr.subject);

            const err = switch (value.result.payload) {
                .fail => |e| e,
                .value => |v| return v.*,
            };

            const catch_scope = try Scope.create(
                ctx.scope,
                self.allocator,
                catch_expr.scope,
            );
            defer catch_scope.destroy();

            if (catch_expr.capture) |capture| {
                _ = try self.destructure(
                    ir.Capture,
                    ctx.withScope(catch_scope),
                    capture.target,
                    .{ .@"error" = err },
                    null,
                );
            }
            const result = try self.evaluateExpr(ctx.withScope(catch_scope), &catch_expr.expr);
            return try result.clone(ctx.arena());
        },
        .block_expr => |block_expr| {
            const scope = try Scope.create(
                ctx.scope,
                self.allocator,
                block_expr.scope,
            );
            defer scope.destroy();

            for (block_expr.bindings) |binding| {
                _ = try self.handleDecl(
                    ctx.withScope(scope),
                    binding,
                    null,
                );
            }

            const result = try self.evaluateExpr(ctx.withScope(scope), &block_expr.result_expr);

            return try result.clone(ctx.arena());
        },
        .parallel_block => |block_expr| {
            // must use the runtime allocator (not the parent's arena), like
            // every other Scope.create, since destroy() frees through it
            const block_scope = try Scope.create(
                ctx.scope,
                self.allocator,
                block_expr.scope,
            );
            defer block_scope.destroy();

            const jobs_limit: usize = try self.evaluateParallelJobsLimit(
                ctx,
                &block_expr.parallel,
            );

            const Context = struct {
                const Self = @This();
                runtime: *Runtime,
                ctx: Ctx,
                block: *const ir.ParallelBlockExpr,

                fn runDecl(it: *Self, idx: usize) Error!void {
                    const decl = it.block.bindings[idx];
                    _ = try it.runtime.handleDecl(
                        it.ctx,
                        decl,
                        null,
                    );
                }
            };

            var context: Context = .{
                .runtime = self,
                .ctx = ctx.withScope(block_scope),
                .block = block_expr,
            };

            try parallelization.runIndexed(
                self,
                block_expr.bindings.len,
                jobs_limit,
                &context,
                Context.runDecl,
            );

            const value = try self.evaluateExpr(
                ctx.withScope(block_scope),
                &block_expr.result_expr,
            );

            return try value.clone(ctx.arena());
        },
        .unknown => unreachable,
    };
}

fn abortWithError(self: *Runtime, _: Ctx, comptime fmt: []const u8, args: anytype) Error {
    try self.printer.printStyled(
        self.allocator,
        style.@"error",
        "tasq: error: ",
        .{},
    );
    try self.printer.printStyled(self.allocator, style.@"error", fmt, args);
    try self.printer.print(self.allocator, "\n", .{});

    return Error.Abort;
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
    return lib.math.asInt(i64, value);
}

fn evaluateRange(self: *Runtime, ctx: Ctx, range: *const ir.Range) Error!Range {
    const left: i64 = blk: {
        const value = try self.evaluateExpr(
            ctx,
            &range.left,
        );

        break :blk integerize(value.number);
    };

    const right: ?i64 = blk: {
        // by pointer, not by copy, so nothing can point into this stack frame
        const right_expr = if (range.right) |*r| r else break :blk null;

        const value = try self.evaluateExpr(
            ctx,
            right_expr,
        );

        break :blk @max(integerize(value.number), left);
    };

    return .{
        .left = left,
        .right = right,
    };
}

fn resolveString(self: *Runtime, ctx: Ctx, string: ir.String) Error![]const u8 {
    var aw = std.Io.Writer.Allocating.init(ctx.arena());
    const writer = &aw.writer;
    errdefer aw.deinit();

    for (string) |part| {
        switch (part) {
            .lit => |lit| {
                try writer.writeAll(lit);
            },
            .expr => |expr| {
                const value = try self.evaluateExpr(ctx, &expr);
                try writer.print("{f}", .{value});
            },
        }
    }

    return try aw.toOwnedSlice();
}

pub fn acquireWorkers(self: *Runtime, want: usize) usize {
    var cur = self.worker_budget.load(.monotonic);
    while (true) {
        const take = @min(cur, want);
        if (take == 0) return 0;
        cur = self.worker_budget.cmpxchgWeak(cur, cur - take, .acquire, .monotonic) orelse return take;
    }
}

pub fn releaseWorkers(self: *Runtime, n: usize) void {
    _ = self.worker_budget.fetchAdd(n, .release);
}
