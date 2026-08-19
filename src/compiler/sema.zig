const std = @import("std");
const ast = @import("ast.zig");

const platform = @import("platform.zig");

const ir = @import("ir.zig");

const options_mod = @import("options.zig");
const funcs = @import("functions.zig");
const attrib = @import("attributes.zig");
const text = @import("text.zig");

const sym = @import("symbol.zig");
const Symbol = sym.Symbol;

const Type = @import("type.zig").Type;

const Value = @import("value.zig").Value;

const Scope = @import("scope.zig").Scope;

const TaskId = @import("taskId.zig");

const Diagnostics = @import("Diagnostics.zig");

const Span = @import("span.zig");
const NodeId = Span.Registry.NodeId;

const lib = @import("lib");
const enums = lib.enums;

const SemaError = error{
    SemanticError,
    PlatformMismatch,
} || std.mem.Allocator.Error;

pub const Sema = struct {
    arena: *std.heap.ArenaAllocator,
    span_registry: *const Span.Registry,
    diagnostics: *Diagnostics,

    loop_depth: u32 = 0,

    pub fn init(arena: *std.heap.ArenaAllocator, span_registry: *const Span.Registry, diagnostics: *Diagnostics) Sema {
        return Sema{
            .arena = arena,
            .span_registry = span_registry,
            .diagnostics = diagnostics,
        };
    }

    fn createScope(self: *Sema, parent: ?*Scope) !*Scope {
        const ptr = try self.arena.allocator().create(Scope);
        ptr.* = .init(parent);
        return ptr;
    }

    //TODO: consider taking ast_file as ptr
    pub fn analyse(self: *Sema, ast_file: *const ast.File) !ir.File {
        var file = try self.firstPass(ast_file);

        try self.secondPass(&file);

        return file;
    }

    fn firstPass(self: *Sema, file: *const ast.File) !ir.File {

        // create scope
        const root_scope = try self.createScope(null);

        const options = try self.analyseOptions(file.options);

        var decls = try std.ArrayList(*ir.Decl).initCapacity(self.arena.allocator(), file.decls.len);
        for (file.decls) |decl| try decls.append(self.arena.allocator(), try self.analyseDecl(root_scope, decl));

        var tasks = try std.ArrayList(*ir.Task).initCapacity(self.arena.allocator(), file.tasks.len);
        for (file.tasks) |*task| {
            const task_span = self.span_registry.getSpan(task.id);
            const ptr = self.collectTaskSignature(root_scope, task) catch |err| switch (err) {
                SemaError.PlatformMismatch => {
                    try self.diagnostics.hint(task_span, "skipping task, platform mismatch", .{});
                    continue;
                },
                else => return err,
            };

            try self.defineSymbol(root_scope, .{
                .name = task.name,
                .span = task_span,
                .origin = .{ .task = ptr },
            });

            try tasks.append(self.arena.allocator(), ptr);
        }

        var groups = try std.ArrayList(*ir.Group).initCapacity(self.arena.allocator(), file.groups.len);
        for (file.groups) |*group| {
            const group_span = self.span_registry.getSpan(group.id);
            const ptr = self.collectGroupSignature(root_scope, group) catch |err| switch (err) {
                SemaError.PlatformMismatch => {
                    try self.diagnostics.hint(group_span, "skipping group, platform mismatch", .{});
                    continue;
                },
                else => return err,
            };

            if (group.name) |name| {
                try self.defineSymbol(root_scope, .{
                    .name = name,
                    .span = group_span,
                    .origin = .{ .group = ptr },
                });
            }
            try groups.append(self.arena.allocator(), ptr);
        }

        return ir.File{
            .scope = root_scope,
            .options = options,
            .decls = try decls.toOwnedSlice(self.arena.allocator()),
            .tasks = try tasks.toOwnedSlice(self.arena.allocator()),
            .groups = try groups.toOwnedSlice(self.arena.allocator()),
        };
    }

    fn secondPass(self: *Sema, file: *ir.File) !void {
        // some tasks / body maybe be skipped from ir beacuse of platform attributes

        for (file.tasks) |task| {
            try self.analyseTaskBody(task, task.ast_ref.*);
        }

        for (file.groups) |group| {
            for (group.tasks) |task| {
                try self.analyseTaskBody(task, task.ast_ref.*);
            }
        }
    }

    fn analyseOptions(self: *Sema, options: []const ast.Set) !ir.Options {
        var result = try OptionResolver.resolve(self, options);

        var out: ir.Options = platform.default_options;

        var iter = result.iterator();

        while (iter.next()) |opt| switch (opt.value.*) {
            .shell => |shell| out.shell = shell,
        };

        return out;
    }

    fn collectGroupSignature(self: *Sema, scope: *Scope, group: *const ast.Group) !*ir.Group {
        const groupScope = try self.createScope(scope);

        const args = try self.analyseArgs(groupScope, group.args, true);

        var decls = try std.ArrayList(*ir.Decl).initCapacity(self.arena.allocator(), group.decls.len);
        for (group.decls) |decl| try decls.append(self.arena.allocator(), try self.analyseDecl(groupScope, decl));

        const ptr = try self.arena.allocator().create(ir.Group);

        ptr.* = .{
            .name = group.name,
            .args = args,
            .decls = try decls.toOwnedSlice(self.arena.allocator()),
            .tasks = undefined, // yet
            .scope = groupScope,
            .desc = "<not supported yet>", // TODO: add support
        };

        const tasks_target_scope = if (group.name) |_| groupScope else scope;

        var tasks = try std.ArrayList(*ir.Task).initCapacity(self.arena.allocator(), group.tasks.len);
        for (group.tasks) |*task| {
            const task_span = self.span_registry.getSpan(task.id);

            const task_ptr = self.collectTaskSignature(groupScope, task) catch |err| switch (err) {
                SemaError.PlatformMismatch => {
                    try self.diagnostics.hint(task_span, "skipping task, platform mismatch", .{});
                    continue;
                },
                else => return err,
            };
            task_ptr.*.group = ptr;

            try self.defineSymbol(
                tasks_target_scope,
                .{
                    .name = task.name,
                    .span = task_span,
                    .origin = .{ .task = task_ptr },
                },
            );

            try tasks.append(
                self.arena.allocator(),
                task_ptr,
            );
        }

        ptr.*.tasks = try tasks.toOwnedSlice(self.arena.allocator());

        return ptr;
    }

    fn collectTaskSignature(self: *Sema, scope: *Scope, task: *const ast.Task) !*ir.Task {
        var attributes = try AttributesResolver.resolve(self, .task, task.attrs);
        defer attributes.deinit(self.arena.allocator());

        const task_scope = try self.createScope(scope);

        const is_private = attributes.contains(.private);
        const desc = if (attributes.getAssertOne(.desc)) |value|
            value.?.string
        else
            null;

        const args = try self.analyseArgs(task_scope, task.args, false);

        const ptr = try self.arena.allocator().create(ir.Task);

        ptr.* = .{
            .ast_ref = task,
            .name = task.name,
            .args = args,
            .private = is_private,
            .desc = desc,
            .body = .{
                .scope = task_scope,
                .statements = undefined,
            },
        };

        return ptr;
    }

    fn analyseArgs(self: *Sema, scope: *Scope, args: []ast.Argument, group: bool) ![]*ir.Argument {
        var out = try std.ArrayList(*ir.Argument).initCapacity(
            self.arena.allocator(),
            args.len,
        );

        // implicitly named when:
        //      any previous is named,
        //      default value provided,
        var phase: ArgPhase = .positional;

        for (args) |*arg| {
            const span_node = self.span_registry.get(arg.id);

            var attributes = AttributesResolver.resolve(
                self,
                .{ .argument = arg.type },
                arg.attrs,
            ) catch |err| switch (err) {
                SemaError.PlatformMismatch => unreachable,
                else => return err,
            };
            defer attributes.deinit(self.arena.allocator());

            const name_required = group or arg.type.isNamedOnly();

            // get default value,

            const default: ?Value, const implicit_default: bool = blk: {
                if (arg.type == .flag) {
                    if (arg.default) |_| {
                        try self.diagnostics.err(
                            self.span_registry.getSpan(arg.id),
                            "flag value have implicit default value",
                            .{},
                        );
                        return SemaError.SemanticError;
                    }
                    break :blk .{
                        .{ .bool = false },
                        true,
                    };
                }

                if (arg.default) |def| {
                    const expr_node_id = span_node.details.argument.default.?;

                    break :blk .{
                        try self.assertLiteral(
                            arg.type.typeOf(),
                            def,
                            expr_node_id,
                        ),
                        false,
                    };
                }

                break :blk .{ null, false };
            };

            const implicit_names = default != null or name_required;

            // TODO: verify if unicode char, (if meta value will hold other)
            const short = blk: {
                const default_value = arg.name[0];

                const attr = attributes.getAssertOne(.short) orelse
                    break :blk if (implicit_names) default_value else null;

                const value = attr orelse break :blk default_value;

                break :blk switch (value) {
                    .char => |ch| ch,
                    .null => null,
                    else => unreachable,
                };
            };

            const long = blk: {
                const default_value = arg.name;

                const attr = attributes.getAssertOne(.long) orelse
                    break :blk if (implicit_names) default_value else null;

                const value = attr orelse break :blk default_value;

                break :blk switch (value) {
                    .string => |str| str,
                    .null => null,
                    else => unreachable,
                };
            };

            const desc = if (attributes.getAssertOne(.desc)) |value|
                value.?.string
            else
                null;

            const pattern = if (attributes.getAssertOne(.pattern)) |value|
                value.?.string
            else
                null;

            const int = attributes.contains(.int);

            const min = if (attributes.getAssertOne(.min)) |value|
                value.?.number
            else
                null;

            const max = if (attributes.getAssertOne(.max)) |value|
                value.?.number
            else
                null;

            const min_items: ?i64 = if (attributes.getAssertOne(.min_items)) |value|
                @intFromFloat(value.?.number)
            else
                null;

            const max_items: ?i64 = if (attributes.getAssertOne(.max_items)) |value|
                @intFromFloat(value.?.number)
            else
                null;

            // check if named
            const has_name = blk: {
                const has_name = long != null or short != null;

                if (!has_name) {
                    if (group) {
                        try self.diagnostics.err(
                            span_node.span,
                            "group arguments must be named",
                            .{},
                        );
                        return SemaError.SemanticError;
                    }

                    if (name_required) {
                        try self.diagnostics.err(
                            span_node.span,
                            "'{f}' type expect long or/and short attribute",
                            .{arg.type},
                        );
                        return SemaError.SemanticError;
                    }
                }

                break :blk has_name;
            };

            //validate arg order
            try self.validateArgOrder(
                arg,
                &phase,
                has_name,
                default != null,
            );
            // validate agains attributes
            if (default) |def| blk: {
                if (implicit_default) break :blk; // FIX: implicit default does not have span and no specific attributes
                const span = self.span_registry.getSpan(span_node.details.argument.default.?);

                switch (def) {
                    .number => |v| {
                        if (min) |m| if (v < m) {
                            try self.diagnostics.warn(span, "Default value is less than min", .{});
                        };
                        if (max) |m| if (v > m) {
                            try self.diagnostics.warn(span, "Default value is greater than max", .{});
                        };
                    },
                    .list => |list| {
                        if (min_items) |m| if (list.items.len < m) {
                            try self.diagnostics.warn(span, "Default value list items count is less than min_items", .{});
                        };

                        if (max_items) |m| if (list.items.len > m) {
                            try self.diagnostics.warn(span, "Default value list items count is greater than max_items", .{});
                        };
                    },
                    else => {},
                }
            }

            const ptr = try self.arena.allocator().create(ir.Argument);
            ptr.* = .{
                .name = arg.name,
                .type = arg.type,
                .default = default,
                .is_positional = !has_name,

                .short = short,
                .long = long,
                .desc = desc,

                .pattern = pattern,
                .int = int,
            };

            try self.defineSymbol(
                scope,
                .{
                    .name = arg.name,
                    .span = span_node.span,
                    .origin = .{ .argument = ptr },
                },
            );

            try out.append(
                self.arena.allocator(),
                ptr,
            );
        }
        return out.toOwnedSlice(self.arena.allocator());
    }

    const ArgPhase = enum {
        positional,
        named_required,
        named_optional,
    };
    // order positional > named-required > named-optional
    fn validateArgOrder(self: *Sema, arg: *const ast.Argument, phase: *ArgPhase, named: bool, optional: bool) !void {
        const arg_span = self.span_registry.getSpan(arg.id);

        const class = blk: {
            if (named == false) {
                if (optional) {
                    try self.diagnostics.err(arg_span, "positional arguments cannot have default values", .{});
                    return SemaError.SemanticError;
                }
                break :blk ArgPhase.positional;
            }

            if (optional) {
                break :blk ArgPhase.named_optional;
            } else {
                break :blk ArgPhase.named_required;
            }
        };

        switch (phase.*) {
            .positional => {},
            .named_required => switch (class) {
                .positional => {
                    try self.diagnostics.err(arg_span, "positional argument cannot follow a named argument", .{});
                    return SemaError.SemanticError;
                },
                else => {},
            },
            .named_optional => switch (class) {
                .positional => {
                    try self.diagnostics.err(arg_span, "positional argument cannot follow a named argument", .{});
                    return SemaError.SemanticError;
                },
                .named_required => {
                    try self.diagnostics.err(arg_span, "required argument cannot follow a optional argument", .{});
                    return SemaError.SemanticError;
                },
                else => {},
            },
        }
        phase.* = class;
    }

    fn analyseTaskBody(self: *Sema, target: *ir.Task, task: ast.Task) !void {
        const node = self.span_registry.get(task.id);
        target.body.statements = try self.analyseStatements(target.body.scope, task.body, node.details.task.body);
    }

    //=============== statements =================

    fn analyseStatementBlock(self: *Sema, parent_scope: *Scope, block: ast.StatementBlock, span_node_id: NodeId) !ir.StatementBlock {
        const block_scope = try self.createScope(parent_scope);

        const stmts = try self.analyseStatements(block_scope, block, span_node_id);

        return .{
            .scope = block_scope,
            .statements = stmts,
        };
    }

    fn analyseStatements(self: *Sema, scope: *Scope, stmts: []ast.Statement, block_id: NodeId) SemaError![]ir.Statement {
        var out = try std.ArrayList(ir.Statement).initCapacity(self.arena.allocator(), stmts.len);

        const block_spans = self.span_registry.get(block_id).details.block;

        for (stmts, block_spans.stmts) |stmt, stmt_id| {
            const result = self.analyseStatement(scope, stmt, stmt_id) catch |err| switch (err) {
                SemaError.SemanticError => continue,
                else => return err,
            };
            try out.append(
                self.arena.allocator(),
                result,
            );
        }

        return try out.toOwnedSlice(self.arena.allocator());
    }

    fn analyseStatement(self: *Sema, scope: *Scope, stmt: ast.Statement, node_id: NodeId) SemaError!ir.Statement {
        return switch (stmt) {
            .decl => |d| .{ .decl = try self.analyseDecl(scope, d) },
            .process => |p| .{ .process = try self.analyzeProcess(scope, p, node_id) },
            .task_call => |c| .{ .task_call = try self.analyseTaskCall(scope, c) },
            .for_stmt => |f| {
                self.loop_depth += 1;
                defer self.loop_depth -= 1;

                return .{ .for_stmt = try self.analyseForStmt(scope, f) };
            },
            .switch_stmt => |s| .{ .switch_stmt = try self.analyseSwitchStmt(scope, s) },
            .if_stmt => |s| .{ .if_stmt = try self.analyseIfStmt(scope, s) },
            .expr => |e| {
                const res = try self.analyseExpr(scope, e, node_id);

                return .{
                    .expr = res.expr,
                };
            },
        };
    }

    fn analyseDecl(self: *Sema, scope: *Scope, decl: ast.Decl) !*ir.Decl {
        const node = self.span_registry.get(decl.id);

        const result = try self.analyseExpr(
            scope,
            decl.value,
            node.details.decl.value,
        );

        const ptr = try self.arena.allocator().create(ir.Decl);

        ptr.* = .{
            .name = decl.name,
            .value = result.expr,
            .type = result.type,
            .scope = scope,
            .is_static = result.is_static,
        };

        try self.defineSymbol(scope, .{
            .name = decl.name,
            .span = node.details.decl.name,
            .origin = .{ .binding = ptr },
        });

        return ptr;
    }

    fn analyzeProcess(self: *Sema, scope: *Scope, raw: ast.ProcessStmt, node_id: NodeId) !ir.ProcessStmt {
        const segments = try self.analyseString(
            scope,
            raw,
            node_id,
        );

        return segments.string;
    }

    fn analyseTaskCall(self: *Sema, scope: *Scope, call: ast.TaskCall) SemaError!ir.TaskCall {
        const node = self.span_registry.get(call.id);
        const target_task_name = call.task;

        // resolve task from scope
        const task: *ir.Task = blk: {
            switch (call.scope) {
                .closest => {
                    if (scope.resolve(target_task_name, .task)) |symbol| {
                        std.debug.assert(symbol.origin == .task);
                        break :blk symbol.origin.task;
                    } else {
                        try self.diagnostics.err(node.details.task_call.task, "unknown task '{s}'", .{target_task_name});
                        return SemaError.SemanticError;
                    }
                },
                .root => {
                    if (scope.root().resolve(target_task_name, .task)) |symbol| {
                        std.debug.assert(symbol.origin == .task);
                        break :blk symbol.origin.task;
                    } else {
                        try self.diagnostics.err(node.details.task_call.task, "unknown task '::{s}'", .{target_task_name});
                        return SemaError.SemanticError;
                    }
                },
                .group => |gname| {
                    const group = grp: {
                        if (scope.root().resolve(gname, .group)) |symbol| {
                            std.debug.assert(symbol.origin == .group);
                            break :grp symbol.origin.group;
                        } else {
                            try self.diagnostics.err(node.details.task_call.group.?, "unknown group '{s}'", .{gname});
                            return SemaError.SemanticError;
                        }
                    };

                    const task = tsk: {
                        if (group.scope.resolveLocal(target_task_name, .task)) |symbol| {
                            std.debug.assert(symbol.origin == .task);
                            break :tsk symbol.origin.task;
                        } else {
                            try self.diagnostics.err(node.details.task_call.task, "unknown task '{s}::{s}'", .{ gname, target_task_name });
                            return SemaError.SemanticError;
                        }
                    };

                    break :blk task;
                },
            }
        };

        // A task found via `.closest` that belongs to a group can only have
        // been reached by walking *up* through enclosing scopes - which means
        // `scope` is necessarily nested inside that same group's scope right
        // now. `.root` can only ever find ungrouped tasks, and `.group` is
        // always an explicit "from outside" call. So this one check fully
        // captures "am I calling a sibling task from inside my own group?".
        const is_same_group_call = call.scope == .closest and task.group != null;

        // validate args
        var args: ir.TaskCall.ArgsMap = .empty;

        // read positional
        const pos_count = blk: {
            for (call.args, 0..) |arg, idx| {
                if (arg.name != null) break :blk idx;
                const arg_span = self.span_registry.getSpan(arg.id);

                const result = try self.analyseExpr(scope, arg.value, arg.id);

                if (idx >= task.args.len) {
                    try self.diagnostics.err(arg_span, "invalid positional arguments count, got '{}', expected '{}'", .{ idx + 1, task.args.len });
                    return SemaError.SemanticError;
                }

                const t = task.args[idx];

                if (!Type.eq(t.type.typeOf(), result.type)) {
                    try self.diagnostics.err(arg_span, "invalid argument type, got '{f}', expected '{f}'", .{ result.type, t.type.typeOf() });
                    return SemaError.SemanticError;
                }

                try args.put(self.arena.allocator(), t.name, .{ .value = result.expr });
            }
            break :blk call.args.len;
        };

        // retrieve named arguments, tagging each with whether it belongs to
        // the task itself or to the enclosing group - we need that origin
        // later to decide which of the two rules applies to a missing arg.
        const NamedArgEntry = struct {
            arg: *ir.Argument,
            from_group: bool,
        };

        var named_args = blk: {
            var out: std.array_hash_map.String(NamedArgEntry) = .empty;
            try out.ensureTotalCapacity(
                self.arena.allocator(),
                (task.args.len - pos_count) + if (task.group) |g| g.args.len else 0,
            );

            // collect task's own args
            for (task.args) |arg|
                out.putAssumeCapacity(
                    arg.name,
                    .{ .arg = arg, .from_group = false },
                );

            // collect group args
            if (task.group) |g| {
                for (g.args) |arg|
                    out.putAssumeCapacity(
                        arg.name,
                        .{ .arg = arg, .from_group = true },
                    );
            }

            break :blk out;
        };

        for (call.args[pos_count..]) |arg| {
            const arg_span = self.span_registry.getSpan(arg.id);
            const arg_name = arg.name.?; //TODO: assertion can be wrong here, as it can be user error propably, check it

            if (args.contains(arg_name)) {
                try self.diagnostics.err(
                    arg_span,
                    "duplicate argument '{s}'",
                    .{arg_name},
                );
                continue;
            }

            const target_arg = if (named_args.fetchSwapRemove(arg_name)) |target|
                target.value.arg
            else {
                try self.diagnostics.err(
                    arg_span,
                    "unknown argument '{s}'",
                    .{arg_name},
                );
                continue;
            };

            const value = try self.analyseExpr(
                scope,
                arg.value,
                arg.id,
            );

            if (value.type.eq(target_arg.type.typeOf()) == false) {
                try self.diagnostics.err(
                    arg_span,
                    "invalid argument value type, got '{f}', expected '{f}'",
                    .{
                        value.type,
                        target_arg.type.typeOf(),
                    },
                );
            }

            try args.put(
                self.arena.allocator(),
                arg_name,
                .{ .value = value.expr },
            );
        }

        // Anything left in named_args wasn't explicitly passed by the caller.
        var it = named_args.iterator();

        while (it.next()) |kv| {
            const arg_name, const entry = .{ kv.key_ptr.*, kv.value_ptr.* };

            // if its same group task call, then value is already provided in scope, it can be omited
            if (entry.from_group and is_same_group_call) {
                continue;
            }

            if (entry.arg.default) |def| {
                try args.put(self.arena.allocator(), arg_name, .{ .default = def });
            } else {
                try self.diagnostics.err(
                    self.span_registry.getSpan(call.id),
                    "missing argument: '{s}'",
                    .{arg_name},
                );
            }
        }

        return .{
            .task = task,
            .args = args,
        };
    }

    fn analyseForStmt(self: *Sema, scope: *Scope, for_stmt: ast.ForStmt) !ir.ForStmt {
        const for_spans = self.span_registry.get(for_stmt.id).details.@"for";
        const captures_span: Span = .between(for_spans.captures[0], for_spans.captures[for_spans.captures.len - 1]);

        if (for_stmt.captures.len < for_stmt.subjects.len) {
            try self.diagnostics.err(
                captures_span,
                "you need to capture each passed subject, expected captures {}, got {}",
                .{
                    for_stmt.subjects.len,
                    for_stmt.captures.len,
                },
            );
            try self.diagnostics.hint(captures_span, "you can ignore value by using '_'", .{});
            return SemaError.SemanticError;
        }

        const for_scope = try self.createScope(scope);

        var subjects: std.ArrayList(ir.Expr) = try .initCapacity(self.arena.allocator(), for_stmt.subjects.len);
        var captures: std.ArrayList(?*ir.Capture) = try .initCapacity(self.arena.allocator(), for_stmt.captures.len);

        for (
            for_stmt.subjects,
            for_stmt.captures[0..for_stmt.subjects.len],
            for_spans.subjects,
        ) |sub, capt, subject_span| {
            const result = try self.analyseExpr(scope, sub, subject_span);

            if (result.type != .list) {
                try self.diagnostics.err(
                    self.span_registry.getSpan(subject_span),
                    "for can be used on list or list like items only, got '{f}'",
                    .{result.type},
                );
                continue;
            }

            if (capt) |c| {
                const ptr = try self.arena.allocator().create(ir.Capture);
                ptr.* = .{
                    .name = c,
                    .type = result.type.list.*,
                };
                captures.appendAssumeCapacity(ptr);

                try self.defineSymbol(for_scope, .{
                    .name = c,
                    .span = self.span_registry.getSpan(subject_span),
                    .origin = .{ .capture = ptr },
                });
            }

            subjects.appendAssumeCapacity(result.expr);
        }

        if (for_stmt.captures.len == for_stmt.subjects.len + 1) {
            const index_capture = for_stmt.captures[for_stmt.captures.len - 1];

            if (index_capture) |ic| {
                const ptr = try self.arena.allocator().create(ir.Capture);
                ptr.* = .{
                    .name = ic,
                    .type = .number,
                };
                captures.appendAssumeCapacity(ptr);

                try self.defineSymbol(
                    for_scope,
                    .{
                        .name = ic,
                        .span = for_spans.captures[for_spans.captures.len - 1],
                        .origin = .{ .capture = ptr },
                    },
                );
            }

            if (for_stmt.captures.len > for_stmt.subjects.len + 1) {
                try self.diagnostics.err(captures_span, "too many captures, expected {} or {} for index capture, got {}", .{
                    for_stmt.subjects.len,
                    for_stmt.subjects.len + 1,
                    for_stmt.captures.len,
                });
            }
        }

        const body: ir.StatementBlock = .{
            .scope = for_scope,
            .statements = try self.analyseStatements(for_scope, for_stmt.body, for_spans.body),
        };

        return .{
            .subjects = try subjects.toOwnedSlice(self.arena.allocator()),
            .captures = try captures.toOwnedSlice(self.arena.allocator()),
            .body = body,
        };
    }

    fn analyseSwitchStmt(self: *Sema, scope: *Scope, switch_stmt: ast.SwitchStmt) !ir.SwitchStmt {
        const switch_spans = self.span_registry.get(switch_stmt.id).details.@"switch";

        const subject = try self.analyseExpr(
            scope,
            switch_stmt.subject,
            switch_spans.subject,
        );

        var cases: ir.SwitchStmt.CasesStorage = .empty;
        try cases.ensureTotalCapacity(self.arena.allocator(), @intCast(switch_stmt.cases.len));

        var else_case: ?ir.StatementBlock = null;

        for (switch_stmt.cases) |case| {
            const case_spans = self.span_registry.get(case.id).details.switch_case;
            switch (case.pattern) {
                .expr => |expr| {
                    const body = try self.analyseStatementBlock(scope, case.body, case_spans.body);

                    for (expr, case_spans.patterns) |e, e_span| {
                        const pattern = try self.assertLiteral(
                            subject.type,
                            e,
                            e_span,
                        );

                        if (SwitchPatternValidator.validate(pattern) == false) {
                            try self.diagnostics.err(
                                self.span_registry.getSpan(e_span),
                                "incompatible case literal value: '{f}'",
                                .{pattern},
                            );
                            continue;
                        }

                        if (cases.contains(pattern)) {
                            try self.diagnostics.err(
                                self.span_registry.getSpan(e_span),
                                "duplicate pattern",
                                .{},
                            );
                            continue;
                        }

                        try cases.put(
                            self.arena.allocator(),
                            pattern,
                            body,
                        );
                    }
                },
                .@"else" => {
                    if (else_case) |_| {
                        try self.diagnostics.err(self.span_registry.getSpan(case.id), "Duplicate else case", .{});
                        continue;
                    }

                    else_case = try self.analyseStatementBlock(
                        scope,
                        case.body,
                        case_spans.body,
                    );
                },
            }
        }

        return .{
            .subject = subject.expr,
            .cases = cases,
            .else_case = else_case,
        };
    }

    fn analyseIfStmt(self: *Sema, scope: *Scope, stmt: ast.IfStmt) SemaError!ir.IfStmt {
        const if_spans = self.span_registry.get(stmt.id).details.@"if";

        const cond = try self.analyseExpr(scope, stmt.cond, if_spans.cond);
        const then = try self.analyseStatementBlock(scope, stmt.then, if_spans.then);

        const else_ = if (stmt.@"else") |block|
            try self.analyseStatementBlock(scope, block, if_spans.else_.?)
        else
            null;

        return .{
            .cond = cond.expr,
            .then = then,
            .else_ = else_,
        };
    }

    //================== expressions ========================

    fn ExprResult(comptime ExprT: type) type {
        return struct {
            expr: ExprT,
            type: Type,
            is_static: bool,
        };
    }

    fn analyseExpr(self: *Sema, scope: *Scope, expr: ast.Expr, node_id: NodeId) SemaError!ExprResult(ir.Expr) {
        //TODO: improve span handling
        const span_node = self.span_registry.get(node_id);

        return switch (expr) {
            .number_lit => |v| .{
                .expr = .{ .number_lit = v },
                .type = .number,
                .is_static = true,
            },
            .bool_lit => |v| .{
                .expr = .{ .bool_lit = v },
                .type = .bool,
                .is_static = true,
            },
            .string => |s| {
                const res = try self.analyseString(scope, s, node_id);

                return .{
                    .expr = .{
                        .string = res.string,
                    },
                    .type = .string,
                    .is_static = res.is_static,
                };
            },
            .list => |l| {
                var list = l;

                if (list.len == 0) {
                    try self.diagnostics.err(
                        span_node.span,
                        "empty list is not allowed",
                        .{},
                    );
                    return SemaError.SemanticError;
                }

                const ItemsHelper = struct {
                    const Result = struct {
                        item: ir.Expr.List.Item,
                        type: Type,
                        is_static: bool,
                    };
                    pub fn analyseItem(sema: *Sema, s: *Scope, n: NodeId, item: ast.Expr.ListItem) !Result {
                        const result = try sema.analyseExpr(s, item.expr.*, n);

                        if (result.type == .noreturn) {
                            try sema.diagnostics.err(
                                sema.span_registry.getSpan(n),
                                "noreturn type is not accepted as list item",
                                .{},
                            );
                            return SemaError.SemanticError;
                        }

                        if (item.is_spread and result.type != .list) {
                            try sema.diagnostics.err(
                                sema.span_registry.getSpan(n),
                                "cannot spread value of type '{f}'; expected a list",
                                .{result.type},
                            );
                            try sema.diagnostics.hint(
                                sema.span_registry.getSpan(n),
                                "remove '...' operator to put item",
                                .{},
                            );
                            // pretend there was no spread operator to be able to continue
                            const expr_ptr = try sema.arena.allocator().create(ir.Expr);
                            expr_ptr.* = result.expr;
                            return .{
                                .item = .{
                                    .expr = expr_ptr,
                                    .is_spread = item.is_spread,
                                },
                                .type = result.type,
                                .is_static = result.is_static,
                            };
                        }

                        const expr_ptr = try sema.arena.allocator().create(ir.Expr);
                        expr_ptr.* = result.expr;

                        return .{
                            .item = .{
                                .expr = expr_ptr,
                                .is_spread = item.is_spread,
                            },
                            .type = if (item.is_spread)
                                result.type.list.*
                            else
                                result.type,
                            .is_static = result.is_static,
                        };
                    }
                };

                var out = try std.ArrayList(ir.Expr.List.Item).initCapacity(self.arena.allocator(), list.len);

                var list_spans = span_node.details.expr.list;

                var is_static: bool = true;

                const list_type = try self.arena.allocator().create(Type);
                errdefer self.arena.allocator().destroy(list_type);

                list_type.* = blk: while (list.len != 0) {
                    const first = ItemsHelper.analyseItem(
                        self,
                        scope,
                        list_spans[0],
                        list[0],
                    ) catch |err| switch (err) {
                        SemaError.SemanticError => {
                            list = list[1..];
                            list_spans = list_spans[1..];
                            continue :blk;
                        },
                        else => return err,
                    };

                    if (!first.is_static) is_static = false;
                    try out.append(self.arena.allocator(), first.item);
                    break :blk first.type;
                } else return SemaError.SemanticError; // we cannot ignore this error if theres no elemets left to infer type

                for (list[1..], list_spans[1..]) |item, item_span_id| {
                    const result = ItemsHelper.analyseItem(self, scope, item_span_id, item) catch |err| switch (err) {
                        SemaError.SemanticError => continue,
                        else => return err,
                    };

                    if (!result.is_static) is_static = false;

                    if (list_type.eq(result.type) == false) {
                        try self.diagnostics.err(
                            self.span_registry.getSpan(item_span_id),
                            "Invalid item type. All list items must be same type, expected {f} got {f}",
                            .{ list_type.*, result.type },
                        );
                    }

                    try out.append(self.arena.allocator(), result.item);
                }

                return .{
                    .expr = .{
                        .list = .{
                            .items_type = list_type.*,
                            .items = out.items, // not using 'toOwnedSlice' as its allocated by arena and it will waste more memory
                        },
                    },
                    .type = .{ .list = list_type },
                    .is_static = is_static,
                };
            },
            .builtin_call => |v| {
                const res = try self.analyseBuiltinCall(scope, v);
                return .{
                    .expr = .{ .builtin_call = res.builtin_call },
                    .is_static = false,
                    .type = res.type,
                };
            },
            .ident => |name| {
                const symbol = scope.resolve(name, .variable) orelse {
                    //TODO: omfg
                    try self.diagnostics.err(
                        span_node.span,
                        "undefined variable '{s}'",
                        .{name},
                    );
                    return SemaError.SemanticError;
                };
                const details: struct {
                    static: bool,
                    type: Type,
                } = switch (symbol.origin) {
                    .binding => |decl| .{
                        .static = decl.is_static,
                        .type = decl.type,
                    },
                    .argument => |arg| .{
                        .static = false,
                        .type = arg.type.typeOf(),
                    },
                    .capture => |cap| .{
                        .static = false,
                        .type = cap.type,
                    },
                    else => unreachable,
                };

                return .{
                    .expr = .{
                        .ident = .{
                            .name = name,
                            .symbol = symbol,
                        },
                    },
                    .type = details.type,
                    .is_static = details.static,
                };
            },
            .binary => |b| {
                const binary_spans = span_node.details.expr.binary;

                const left = try self.analyseExpr(scope, b.left, binary_spans.left);

                if (left.type == .noreturn) {
                    try self.diagnostics.err(
                        self.span_registry.getSpan(binary_spans.left),
                        "noreturn type is not allowed in binary expression",
                        .{},
                    );
                    return SemaError.SemanticError;
                }

                const right = try self.analyseExpr(scope, b.right, binary_spans.right);

                if (right.type == .noreturn) {
                    try self.diagnostics.err(
                        self.span_registry.getSpan(binary_spans.right),
                        "noreturn type is not allowed in binary expression",
                        .{},
                    );
                    return SemaError.SemanticError;
                }

                const binary = @import("binary.zig");

                const binary_result = binary.binaryResultType(
                    b.op,
                    left.type,
                    right.type,
                ) catch |err| {
                    switch (err) {
                        binary.Error.TypeMismatch => {
                            try self.diagnostics.err(
                                span_node.span,
                                "invalid operator '{f}' for types: {f} and {f}",
                                .{ b.op, left.type, right.type },
                            );
                            return SemaError.SemanticError;
                        },
                    }
                    return err;
                };

                const node = try self.arena.allocator().create(ir.BinaryExpr);

                node.* = .{
                    .op = b.op,
                    .left = left.expr,
                    .right = right.expr,
                    .type = binary_result.result_type,
                };

                return .{
                    .expr = .{ .binary = node },
                    .type = binary_result.result_type,
                    .is_static = left.is_static and right.is_static,
                };
            },
            .unary => |u| {
                const unary_spans = span_node.details.expr.unary;
                const operand = try self.analyseExpr(scope, u.operand, unary_spans.operand);

                if (operand.type == .noreturn) {
                    try self.diagnostics.err(
                        self.span_registry.getSpan(unary_spans.operand),
                        "noreturn type is not allowed in unary expression",
                        .{},
                    );
                    return SemaError.SemanticError;
                }

                const result_type: Type = switch (u.op) {
                    .not_op => blk: {
                        if (operand.type != .bool) {
                            try self.diagnostics.err(
                                span_node.span,
                                "'not' requires a bool or flag",
                                .{},
                            );
                        }
                        break :blk .bool;
                    },
                    .negate => blk: {
                        if (operand.type != .number) {
                            try self.diagnostics.err(
                                span_node.span,
                                "unary '-' requires number",
                                .{},
                            );
                        }
                        break :blk operand.type;
                    },
                };

                const node = try self.arena.allocator().create(ir.UnaryExpr);
                node.* = .{
                    .op = @as(ir.UnaryOp, u.op),
                    .operand = operand.expr,
                    .type = result_type,
                };
                return .{
                    .expr = .{ .unary = node },
                    .type = result_type,
                    .is_static = operand.is_static,
                };
            },
            .if_expr => |if_expr| {
                const result = try self.analyseIfExpr(scope, if_expr);

                const ptr = try self.arena.allocator().create(ir.IfExpr);
                ptr.* = result.expr;

                return .{
                    .expr = .{ .if_expr = ptr },
                    .type = result.type,
                    .is_static = result.is_static,
                };
            },
            .switch_expr => |switch_expr| {
                const result = try self.analyseSwitchExpr(scope, switch_expr);

                const ptr = try self.arena.allocator().create(ir.SwitchExpr);
                ptr.* = result.expr;

                return .{
                    .expr = .{ .switch_expr = ptr },
                    .type = result.type,
                    .is_static = result.is_static,
                };
            },
            .for_expr => |for_expr| {
                const result = try self.analyseForExpr(scope, for_expr);

                const ptr = try self.arena.allocator().create(ir.ForExpr);
                ptr.* = result.expr;

                return .{
                    .expr = .{ .for_expr = ptr },
                    .type = result.type,
                    .is_static = result.is_static,
                };
            },
            .lambda => |lambda| {
                try self.diagnostics.err(
                    self.span_registry.getSpan(lambda.id),
                    "lambda allowed only as function argument",
                    .{},
                );
                return SemaError.SemanticError;
            },
            .@"continue" => {
                if (self.loop_depth == 0) {
                    try self.diagnostics.err(
                        self.span_registry.getSpan(node_id),
                        "'continue' is only allowed inside for loop",
                        .{},
                    );
                    return SemaError.SemanticError;
                }
                return .{
                    .expr = .@"continue",
                    .type = .noreturn,
                    .is_static = true,
                };
            },
            .@"break" => {
                if (self.loop_depth == 0) {
                    try self.diagnostics.err(
                        self.span_registry.getSpan(node_id),
                        "'break' is only allowed inside for loop",
                        .{},
                    );
                    return SemaError.SemanticError;
                }
                return .{
                    .expr = .@"break",
                    .type = .noreturn,
                    .is_static = true,
                };
            },
        };
    }

    fn analyseIfExpr(self: *Sema, scope: *Scope, if_expr: *const ast.IfExpr) SemaError!ExprResult(ir.IfExpr) {
        const if_spans = self.span_registry.get(if_expr.id).details.@"if";

        const cond = try self.analyseExpr(scope, if_expr.cond, if_spans.cond);

        if (cond.type != .bool) {
            try self.diagnostics.err(
                self.span_registry.getSpan(if_spans.cond),
                "if condition must be a bool or flag, got {f}",
                .{cond.type},
            );
        }

        const then = try self.analyseExpr(scope, if_expr.then, if_spans.then);
        const @"else" = if (if_expr.@"else") |@"else"|
            try self.analyseExpr(scope, @"else", if_spans.else_.?)
        else {
            try self.diagnostics.err(
                self.span_registry.getSpan(if_expr.id),
                "if expression requires else branch",
                .{},
            );
            return SemaError.SemanticError;
        };

        const result_type = Type.unify(then.type, @"else".type) orelse blk: {
            try self.diagnostics.err(
                self.span_registry.getSpan(if_expr.id),
                "if branches must have the same type: got {f} and {f}",
                .{ then.type, @"else".type },
            );
            break :blk then.type;
        };

        return .{
            .expr = .{
                .cond = cond.expr,
                .then = then.expr,
                .@"else" = @"else".expr,
                .type = result_type,
            },
            .type = result_type,
            .is_static = cond.is_static and then.is_static and @"else".is_static,
        };
    }

    fn analyseSwitchExpr(self: *Sema, scope: *Scope, switch_expr: *const ast.SwitchExpr) SemaError!ExprResult(ir.SwitchExpr) {
        const switch_spans = self.span_registry.get(switch_expr.id).details.@"switch";

        const subject = try self.analyseExpr(
            scope,
            switch_expr.subject,
            switch_spans.subject,
        );

        if (subject.type == .noreturn) {
            try self.diagnostics.err(
                self.span_registry.getSpan(switch_spans.subject),
                "noreturn is not allowed in switch subject",
                .{},
            );
        }

        var cases: ir.SwitchExpr.CasesStorage = .empty;
        try cases.ensureTotalCapacity(self.arena.allocator(), blk: {
            var sum: u32 = 0;
            for (switch_expr.cases) |case| {
                switch (case.pattern) {
                    .expr => |expr| {
                        sum += @intCast(expr.len);
                    },
                    else => {},
                }
            }
            break :blk sum;
        });

        var else_case: ?ir.Expr = null;

        var is_static: bool = subject.is_static;

        var result_type: Type = .noreturn;

        for (switch_expr.cases) |case| {
            const case_spans = self.span_registry.get(case.id).details.switch_case;

            const body = try self.analyseExpr(
                scope,
                case.body,
                case_spans.body,
            );

            if (body.is_static == false)
                is_static = false;

            result_type = Type.unify(result_type, body.type) orelse blk: {
                try self.diagnostics.err(
                    self.span_registry.getSpan(case.id),
                    "each switch branch is required to have the same result type, expected '{}' got '{}'",
                    .{ result_type, body.type },
                );

                break :blk result_type;
            };

            switch (case.pattern) {
                .expr => |patterns| {
                    for (patterns, case_spans.patterns) |p, p_span| {
                        const pattern = try self.assertLiteral(subject.type, p, p_span);

                        if (cases.contains(pattern)) {
                            try self.diagnostics.err(
                                self.span_registry.getSpan(p_span),
                                "duplicate pattern: '{f}'",
                                .{pattern},
                            );
                            continue;
                        }

                        cases.putAssumeCapacityNoClobber(pattern, body.expr);
                    }
                },
                .@"else" => {
                    if (else_case) |_| {
                        try self.diagnostics.err(
                            self.span_registry.getSpan(case_spans.patterns[0]),
                            "duplicate else branch",
                            .{},
                        );
                    }

                    else_case = body.expr;
                },
            }
        }

        const final_else_case = if (else_case) |e|
            e
        else {
            try self.diagnostics.err(
                self.span_registry.getSpan(switch_expr.id),
                "else branch is required in switch expr",
                .{},
            );
            return SemaError.SemanticError;
        };

        return .{
            .expr = .{
                .subject = subject.expr,
                .cases = cases,
                .else_case = final_else_case,
                .type = result_type,
            },
            .is_static = is_static,
            .type = result_type,
        };
    }

    fn analyseForExpr(self: *Sema, scope: *Scope, for_expr: *const ast.ForExpr) SemaError!ExprResult(ir.ForExpr) {
        self.loop_depth += 1;
        defer self.loop_depth -= 1;

        const for_spans = self.span_registry.get(for_expr.id).details.@"for";

        const for_scope = try self.createScope(scope);

        var subjects: std.ArrayList(ir.Expr) = try .initCapacity(self.arena.allocator(), for_expr.subjects.len);
        var captures: std.ArrayList(?*ir.Capture) = try .initCapacity(self.arena.allocator(), for_expr.captures.len);

        var is_static: bool = true;

        for (for_expr.subjects, for_expr.captures[0..for_expr.subjects.len], 0..) |s, c, idx| {
            const result = try self.analyseExpr(scope, s, for_spans.subjects[idx]);

            if (result.is_static == false)
                is_static = false;

            if (result.type != .list) {
                try self.diagnostics.err(
                    self.span_registry.getSpan(for_spans.subjects[idx]),
                    "for can be used on list or list like items only, got {f}",
                    .{result.type},
                );
                continue;
            }

            if (c) |capture_ident| {
                const ptr = try self.arena.allocator().create(ir.Capture);
                ptr.* = .{
                    .name = capture_ident,
                    .type = result.type.list.*,
                };
                captures.appendAssumeCapacity(ptr);

                try self.defineSymbol(
                    for_scope,
                    .{
                        .name = capture_ident,
                        .span = for_spans.captures[idx],
                        .origin = .{ .capture = ptr },
                    },
                );
            } else {
                captures.appendAssumeCapacity(null);
            }
            subjects.appendAssumeCapacity(result.expr);
        }

        if (for_expr.captures.len == for_expr.subjects.len + 1) {
            const index = for_expr.captures.len - 1;
            const index_capture = for_expr.captures[index];

            if (index_capture) |capture_ident| {
                const ptr = try self.arena.allocator().create(ir.Capture);
                ptr.* = .{
                    .name = capture_ident,
                    .type = .number,
                };
                captures.appendAssumeCapacity(ptr);

                try self.defineSymbol(for_scope, .{
                    .name = capture_ident,
                    .span = for_spans.captures[index],
                    .origin = .{ .capture = ptr },
                });
            } else {
                captures.appendAssumeCapacity(null);
            }
        }

        const body = try self.analyseExpr(
            for_scope,
            for_expr.body,
            for_spans.body,
        );

        if (body.is_static == false)
            is_static = false;

        return .{
            .expr = .{
                .subjects = try subjects.toOwnedSlice(self.arena.allocator()),
                .captures = try captures.toOwnedSlice(self.arena.allocator()),
                .scope = for_scope,
                .body = body.expr,
                .type = body.type,
            },
            .is_static = is_static,
            .type = body.type,
        };
    }

    const StringResult = struct {
        string: ir.String,
        is_static: bool,
    };

    fn analyseString(self: *Sema, scope: *Scope, string: ast.String, node_id: NodeId) SemaError!StringResult {
        var parts: std.ArrayList(ir.StringPart) = try .initCapacity(self.arena.allocator(), string.len);
        const parts_spans = self.span_registry.get(node_id).details.expr.list;

        var is_static: bool = true;

        for (string, parts_spans) |part, part_span| {
            switch (part) {
                .lit => |lit| {
                    try parts.append(
                        self.arena.allocator(),
                        .{
                            .lit = text.processString(self.arena.allocator(), lit) catch {
                                try self.diagnostics.err(
                                    self.span_registry.getSpan(part_span),
                                    "Invalid string escape sequence: {s}",
                                    .{lit},
                                );
                                return SemaError.SemanticError;
                            },
                        },
                    );
                },
                .expr => |expr| {
                    const result = try self.analyseExpr(scope, expr, part_span);

                    if (result.is_static == false)
                        is_static = false;

                    try parts.append(self.arena.allocator(), .{ .expr = result.expr });
                },
            }
        }

        return .{
            .is_static = is_static,
            .string = try parts.toOwnedSlice(
                self.arena.allocator(),
            ),
        };
    }

    const BuiltinCallResult = struct {
        builtin_call: ir.BuiltinCall,
        type: Type,
    };

    fn analyseBuiltinCall(self: *Sema, scope: *Scope, call: ast.BuiltInCall) SemaError!BuiltinCallResult {
        const call_spans = self.span_registry.get(call.id).details.builtin_call;

        var args: std.ArrayList(ir.Expr) = try .initCapacity(self.arena.allocator(), call.args.len);
        var args_types: std.ArrayList(funcs.InArg) = try .initCapacity(self.arena.allocator(), call.args.len);

        var is_static: bool = true;

        // collect arguments, when possible, otherwise leave for second pass
        for (call.args, call_spans.args) |arg, arg_span| {
            if (arg == .lambda) {
                args.appendAssumeCapacity(undefined); // it will be resolved in later pass
                args_types.appendAssumeCapacity(
                    .{
                        .lambda = .{
                            .params = arg.lambda.params.len,
                        },
                    },
                );
                continue;
            }

            const result = try self.analyseExpr(scope, arg, arg_span);

            if (result.is_static == false)
                is_static = false;

            args.appendAssumeCapacity(result.expr);
            args_types.appendAssumeCapacity(
                .{
                    .value = .{
                        .type = result.type,
                    },
                },
            );
        }

        const result = funcs.definitions.resolve(
            self.arena.allocator(),
            call.name,
            args_types.items,
        ) catch |err| switch (err) {
            funcs.Error.UnknownFunction => {
                try self.diagnostics.err(
                    self.span_registry.getSpan(call.id),
                    "unknown function '{s}'",
                    .{call.name},
                );
                return SemaError.SemanticError;
            },
            funcs.Error.InvalidArguments => {
                try self.diagnostics.err(
                    self.span_registry.getSpan(call.id),
                    "invalid arguments",
                    .{},
                );
                return SemaError.SemanticError;
            },
            funcs.Error.OutOfMemory => return SemaError.OutOfMemory,
        };
        // second pass, resolve type inferention
        for (call.args, result.params, 0..) |expr, param, idx| {
            switch (param) {
                .lambda => |l| {
                    const lambda_spans = self.span_registry.get(call_spans.args[idx]).details.lambda;

                    const lambda = expr.lambda;

                    const lambda_scope = try self.createScope(scope);

                    const captures = try self.arena.allocator().alloc(ir.Capture, l.params.len);

                    for (lambda.params, l.params, captures, lambda_spans.params) |ident, in, *out, param_span| {
                        out.* = .{
                            .name = ident,
                            .type = in,
                        };

                        try self.defineSymbol(lambda_scope, .{
                            .name = ident,
                            .span = param_span,
                            .origin = .{
                                .capture = out,
                            },
                        });
                    }

                    const body = try self.analyseExpr(lambda_scope, lambda.body, lambda_spans.body);

                    if (body.is_static == false)
                        is_static = false;

                    if (body.type.eq(l.return_type) == false) {
                        try self.diagnostics.err(
                            self.span_registry.getSpan(lambda_spans.body),
                            "invalid lambda result type, expected '{f}' got '{f}'",
                            .{ l.return_type, body.type },
                        );
                    }

                    const lambda_ptr = try self.arena.allocator().create(ir.Lambda);
                    lambda_ptr.* = .{
                        .captures = captures,
                        .body = body.expr,
                        .scope = lambda_scope,
                    };

                    args.items[idx] = .{
                        .lambda = lambda_ptr,
                    };
                },
                else => {},
            }
        }

        return .{
            .builtin_call = .{
                .function = result,
                .args = args.items,
            },
            .type = result.return_type,
        };
    }

    //================ private helpers ==================

    fn assertLiteral(
        self: *Sema,
        expected_type: Type,
        expr: ast.Expr,
        node_id: NodeId,
    ) !Value {
        const span_node = self.span_registry.get(node_id);

        const expr_type: std.meta.Tag(Type) = switch (expr) {
            .bool_lit => .bool,
            .number_lit => .number,
            .string => |str| if (str.len == 1) .string else {
                try self.diagnostics.err(span_node.span, "invalid type, expected '{f}' literal, found string interpolation expr", .{expected_type});
                return SemaError.SemanticError;
            },
            .list => .list,
            else => {
                try self.diagnostics.err(span_node.span, "invalid value type, default value must be literal", .{});
                return SemaError.SemanticError;
            },
        };

        if (expr_type != expected_type) {
            try self.diagnostics.err(span_node.span, "invalid value type, expected '{f}' literal, found {s}", .{ expected_type, @tagName(expr_type) });
            return SemaError.SemanticError;
        }

        return switch (expected_type) {
            .bool => .{ .bool = expr.bool_lit },
            .number => .{ .number = expr.number_lit },
            .string => .{ .string = expr.string[0].lit },
            .list => |items_type| {
                var out: std.ArrayList(Value) = try .initCapacity(self.arena.allocator(), expr.list.len);
                const spans = span_node.details.expr.list;
                for (expr.list, spans) |v, item_node_id| {
                    if (v.is_spread) {
                        try self.diagnostics.err(span_node.span, "list spread is not literal", .{});
                        return SemaError.SemanticError;
                    }

                    const lit = self.assertLiteral(
                        items_type.*,
                        v.expr.*,
                        item_node_id,
                    ) catch |err| {
                        try self.diagnostics.err(span_node.span, "invalid list items type", .{});
                        return err;
                    };
                    out.appendAssumeCapacity(lit);
                }

                return .{
                    .list = .{
                        .items_type = items_type,
                        .items = out.toOwnedSliceAssert(),
                    },
                };
            },
            else => unreachable,
            // .noreturn => {
            //     try self.diagnostics.err(span_node.span, "noreturn is not literal", .{});
            //     return SemaError.SemanticError;
            // },
            // .void => unreachable,
        };
    }

    //TODO: not used anywhere, remove?
    // fn checkBinaryTypes(self: *Sema, op: ast.BinaryOp, left: ir.Type, right: ir.Type) !ir.Type {
    //     return switch (op) {
    //         .add => switch (left) {
    //             .number => if (right == .number) ir.Type.number else self.typeMismatch(.Unknown, "number", right),
    //             .string => if (right == .string) ir.Type.string else self.typeMismatch(.Unknown, "string", right),
    //             else => {
    //                 try self.diagnostics.err(.{ .span = .Unknown }, "'+' not supported for type {s}", .{@tagName(left)});
    //                 return SemaError.SemanticError;
    //             },
    //         },
    //         .sub, .mul, .div => switch (left) {
    //             .number => if (right == .number) ir.Type.number else self.typeMismatch(.Unknown, "number", right),
    //             else => {
    //                 try self.diagnostics.err(.{ .span = .Unknown }, "arithmetic not supported for type {s}", .{@tagName(left)});
    //                 return SemaError.SemanticError;
    //             },
    //         },
    //         .eq, .neq => blk: {
    //             if (!typing.Type.eq(left, right)) {
    //                 try self.diagnostics.err(.{ .span = .Unknown }, "cannot compare {s} and {s}", .{ @tagName(left), @tagName(right) });
    //                 return SemaError.SemanticError;
    //             }
    //             break :blk .bool;
    //         },
    //         .lt, .gt, .lt_eq, .gt_eq => blk: {
    //             if (left != .number) {
    //                 try self.diagnostics.err(.{ .span = .Unknown }, "comparison requires int or number", .{});
    //                 return SemaError.SemanticError;
    //             }
    //             break :blk .bool;
    //         },
    //         // logical — always returns bool
    //         .and_op, .or_op => blk: {
    //             if ((left != .bool) or (right != .bool)) {
    //                 try self.diagnostics.err(.{ .span = .Unknown }, "'and'/'or' require bool or flag operands", .{});
    //             }
    //             break :blk .bool;
    //         },
    //     };
    // }

    fn typeMismatch(self: *Sema, span: Span, expected: []const u8, got: ir.Type) !ir.Type {
        try self.diagnostics.err(
            span,
            "type mismatch: expected {s}, got {s}",
            .{ expected, @tagName(got) },
        );
        return SemaError.SemanticError;
    }

    fn alreadyDefined(self: *Sema, span: Span, name: []const u8) !void {
        try self.diagnostics.err(span, "'{s} already defined'", .{name});
        return SemaError.SemanticError;
    }
    // decl type | can be found in  | conflicts with
    // binding  - root, group, task - binding, argument
    // argument - task              - binding, argument
    // task     - root, group       - task
    // group    - root              - group

    // fn assertSymbolNameAvailable(
    //     self: *Sema,
    //     scope: *Scope,
    //     span: lib.Span,
    //     name: []const u8,
    //     kind: sym.Kind,
    // ) !void {}

    fn defineSymbol(self: *Sema, scope: *Scope, symbol: sym.Symbol) !void {
        const symbol_type = symbol.typeOf();

        const previous_symbol = switch (symbol_type) {
            .variable, .group => scope.resolve(symbol.name, symbol_type),
            .task => scope.resolveLocal(symbol.name, symbol_type),
        };

        if (previous_symbol) |prev| {
            try self.diagnostics.err(symbol.span, "'{s}' {s} already defined", .{ symbol.name, @tagName(symbol_type) });
            try self.diagnostics.hint(prev.span, "{s} defined already here", .{@tagName(symbol_type)});
            return SemaError.SemanticError;
        }

        try scope.define(self.arena.allocator(), symbol);
    }

    const SwitchPatternValidator = struct {
        fn validateNumber(number: f64) bool {
            return number == 0 or std.math.isNormal(number);
        }

        fn validate(v: Value) bool {
            return switch (v) {
                .number => |n| validateNumber(n),
                .list => |l| for (l.items) |item| {
                    if (validate(item) == false)
                        return false;
                } else true,
                else => true,
            };
        }
    };
};

const OptionResolver = struct {
    const options = options_mod.options;

    const OptionValue = union(options.Type) {
        shell: []const []const u8,
    };

    const Storage = std.EnumMap(options.Type, OptionValue);

    sema: *Sema,
    sets: []const ast.Set,

    storage: Storage = .init(.{}),

    pub fn init(sema: *Sema, sets: []const ast.Set) OptionResolver {
        return .{
            .sema = sema,
            .sets = sets,
        };
    }

    pub fn resolve(sema: *Sema, sets: []const ast.Set) !Storage {
        var resolver: OptionResolver = .init(sema, sets);

        try resolver.resolveOptions();

        return resolver.storage;
    }

    fn resolveOptions(self: *OptionResolver) !void {
        for (self.sets) |set| {
            const set_span = self.sema.span_registry.get(set.id).span;

            var attributes = AttributesResolver.resolve(self.sema, .setting, set.attrs) catch |err| switch (err) {
                SemaError.PlatformMismatch => {
                    try self.sema.diagnostics.hint(
                        set_span,
                        "skipping settings, platform mismatch",
                        .{},
                    );
                    continue;
                },
                else => return err,
            };
            std.debug.assert(attributes.count() == 0);
            defer attributes.deinit(self.sema.arena.allocator());

            try self.resolveOption(set.body);
        }
    }

    fn resolveOption(self: *OptionResolver, decls: []const ast.Set.SetDecl) !void {
        for (decls) |decl| {
            const decl_span = self.sema.span_registry.get(decl.id).span;
            const def = options.get(decl.name) orelse {
                try self.sema.diagnostics.err(
                    decl_span,
                    "unknown option '{s}'",
                    .{decl.name},
                );
                return SemaError.SemanticError;
            };

            if (self.storage.contains(def.id)) {
                try self.sema.diagnostics.err(
                    decl_span,
                    "duplicate option '{s}'",
                    .{decl.name},
                );
                return SemaError.SemanticError;
            }

            const value: ast.MetaValue = decl.value orelse .{ .bool = true };

            if (value.validateType(def.value_type) == false) {
                try self.sema.diagnostics.err(
                    decl_span,
                    "invalid '{s}' option value type, expected '{f}'",
                    .{ decl.name, def.value_type },
                );
                return SemaError.SemanticError;
            }

            self.storage.put(def.id, try self.getOptionValue(def.id, value));
        }
    }

    fn getOptionValue(self: *OptionResolver, id: options.Type, value: ast.MetaValue) !OptionValue {
        switch (id) {
            inline .shell => |tag| {
                var out: std.ArrayList([]const u8) = try .initCapacity(
                    self.sema.arena.allocator(),
                    value.list.len,
                );

                for (value.list) |val| {
                    const string = try text.processString(
                        self.sema.arena.allocator(),
                        val.string,
                    );
                    out.appendAssumeCapacity(string);
                }
                return @unionInit(
                    OptionValue,
                    @tagName(tag),
                    out.toOwnedSliceAssert(),
                );
            },
        }
    }
};

const AttributesResolver = struct {
    const ResolvedAttributes = enums.EnumMultimap(attrib.definitions.Type, ?ast.MetaValue);

    sema: *Sema,
    attributes: ResolvedAttributes,
    platforms: std.EnumSet(platform.Tag),

    fn resolveAttributes(self: *AttributesResolver, attributes: []const ast.Attribute, target: attrib.definitions.Target) !void {
        for (attributes) |attr| {
            const attr_span = self.sema.span_registry.get(attr.id).span;

            const def = attrib.definitions.get(attr.name, target) orelse {
                try self.sema.diagnostics.err(
                    attr_span,
                    "'{s}' is not valid attribute for this element",
                    .{attr.name},
                );
                continue;
            };
            // TODO: improve flow
            switch (def.kind) {
                .platform => {
                    const pt = lib.enums.castEnum(def.type, platform.Tag) orelse unreachable;
                    // platforms are always unique attributes
                    std.debug.assert(def.unique == true);

                    if (attr.value != null) {
                        try self.sema.diagnostics.err(attr_span, "platform attributes does not take value", .{});
                        // dont skip cuz value can be just ignored
                        // TODO: consider it warning instead
                    }

                    if (self.platforms.contains(pt)) {
                        try self.sema.diagnostics.err(
                            attr_span,
                            "'{s}' platform attribute duplicate",
                            .{attr.name},
                        );
                        continue;
                    }

                    self.platforms.insert(pt);
                },
                else => {
                    // validate uniqueness
                    if (def.unique and self.attributes.contains(def.type)) {
                        try self.sema.diagnostics.err(
                            attr_span,
                            "'{s}' attribute duplicate",
                            .{attr.name},
                        );
                        continue;
                    }

                    // validate value
                    if (attr.value) |val| {
                        for (def.value_types) |vt| {
                            if (val.validateType(vt)) break;
                        } else {
                            const expected = try attrib.typesListToString(self.sema.arena.allocator(), def.value_types, def.allow_default);
                            try self.sema.diagnostics.err(
                                attr_span,
                                "invalid '{s}' attribute value type, expected '{s}'",
                                .{ attr.name, expected },
                            );
                            continue;
                        }
                    } else if (def.allow_default == false) {
                        const expected = try attrib.typesListToString(self.sema.arena.allocator(), def.value_types, def.allow_default);
                        try self.sema.diagnostics.err(
                            attr_span,
                            "'{s}' attribute doesn't support default value, expected '{s}'",
                            .{ attr.name, expected },
                        );
                        continue;
                    }
                    try self.attributes.add(
                        self.sema.arena.allocator(),
                        def.type,
                        attr.value,
                    );
                },
            }
        }
    }

    fn resolve(sema: *Sema, target: attrib.definitions.Target, attributes: []const ast.Attribute) !ResolvedAttributes {
        var resolver: AttributesResolver = .{
            .sema = sema,
            .attributes = .empty,
            .platforms = .empty,
        };

        try resolver.resolveAttributes(attributes, target);

        const valid_platform = resolver.platforms.count() == 0 or resolver.platforms.contains(platform.tag);

        if (valid_platform == false) {
            return SemaError.PlatformMismatch;
        }

        return resolver.attributes;
    }
};
