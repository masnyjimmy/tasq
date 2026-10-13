const std = @import("std");

const lib = @import("lib");

const ast = @import("ast.zig");

const cst = @import("cst.zig");
const ir = @import("ir.zig");
const @"type" = @import("type.zig");
const Type = @"type".Type;
const runtime = @import("runtime.zig");
const meta = @import("meta.zig");
const text = @import("text.zig");

const binary = @import("binary.zig");

const Span = @import("Span.zig");

const Symbol = @import("symbol.zig").Symbol;
const Scope = @import("scope.zig").Scope;

const attrib = @import("attributes.zig");
const functions = @import("functions.zig");

const options = @import("options.zig").options;
const platform = @import("platform.zig");

const Diagnostics = @import("Diagnostics.zig");

const Error = error{
    Incomplete,
} || std.mem.Allocator.Error || text.Error || std.Io.Writer.Error;

pub const Sema = struct {
    arena: *std.heap.ArenaAllocator,
    diagnostics: *Diagnostics,
    loop_depth: usize = 0,

    pub fn init(arena: *std.heap.ArenaAllocator, diagnostics: *Diagnostics) Sema {
        return .{
            .arena = arena,
            .diagnostics = diagnostics,
        };
    }

    // Results in partially analysed file, all symbols collected but elements which can contain reference to some can be missing
    pub fn firstPhase(self: *Sema, file: ast.File) Error!ir.File {
        const root_scope = try self.createScope(null, file.node);

        var options_resolver: OptionsResolver = .init(self);

        var tasks: std.ArrayList(*ir.Task) = .empty;
        var groups: std.ArrayList(*ir.Group) = .empty;
        var decls: std.ArrayList(*ir.Decl) = .empty;

        var it = file.iter();

        while (it.next()) |elem| {
            switch (elem) {
                .set => |set| options_resolver.resolveSet(set) catch |err| switch (err) {
                    Error.Incomplete => continue,
                    else => return err,
                },
                .binding => |binding| {
                    try decls.append(
                        self.arena.allocator(),
                        self.analyseBindingDecl(
                            binding,
                            root_scope,
                        ) catch |err| switch (err) {
                            Error.Incomplete => continue,
                            else => return err,
                        },
                    );
                },
                .task => |task| {
                    try tasks.append(
                        self.arena.allocator(),
                        self.analyseTask(
                            task,
                            root_scope,
                            root_scope,
                        ) catch |err| switch (err) {
                            Error.Incomplete => continue,
                            else => return err,
                        },
                    );
                },
                .group => |group| {
                    try groups.append(
                        self.arena.allocator(),
                        self.analyseGroup(
                            group,
                            root_scope,
                        ) catch |err| switch (err) {
                            Error.Incomplete => continue,
                            else => return err,
                        },
                    );
                },
            }
        }

        return .{
            .scope = root_scope,
            .decls = try decls.toOwnedSlice(self.arena.allocator()),
            .tasks = try tasks.toOwnedSlice(self.arena.allocator()),
            .groups = try groups.toOwnedSlice(self.arena.allocator()),
            .options = options_resolver.final(),
        };
    }

    pub fn secondPhase(self: *Sema, file: *ir.File) Error!void {
        for (file.tasks) |task|
            try self.analyseTaskBody(task);

        for (file.groups) |group| for (group.tasks) |task|
            try self.analyseTaskBody(task);
    }

    pub fn analyseFile(self: *Sema, file: *const cst.Node) Error!ir.File {
        std.debug.assert(file.kind == .source_file);
        var result = try self.firstPhase(.from(file));

        try self.secondPhase(&result);

        return result;
    }

    fn analyseTask(self: *Sema, task: ast.Task, read_scope: *Scope, write_scope: *Scope) Error!*ir.Task {
        var attributes_result = try AttributesResolver.resolve(self, .task, task.attributes);
        defer attributes_result.deinit(self.arena.allocator());

        const task_scope = try self.createScope(read_scope, task.node);

        const name = task.name.string() orelse return Error.Incomplete;

        const args: []*ir.Argument = if (task.params) |params|
            try self.analyseParams(params, task_scope, false)
        else
            &.{};

        const is_private = attributes_result.attributes.contains(.private);

        const desc = if (attributes_result.attributes.getAssertOne(.desc)) |value|
            value.?.string
        else
            null;

        const envs = blk: {
            var envs: std.ArrayList(ir.Env) = .empty;

            if (attributes_result.attributes.get(.env)) |attrs| {
                for (attrs) |attr| {
                    const kv = attr.?.tuple;
                    const key = kv[0].string;
                    const value = kv[1].string;

                    try envs.append(self.arena.allocator(), .{
                        .key = key,
                        .value = value,
                    });
                }
            }

            break :blk try envs.toOwnedSlice(self.arena.allocator());
        };

        const ptr = try self.create(ir.Task, .{
            .st_ref = task,
            .name = name,
            .args = args,
            .private = is_private,
            .desc = desc,
            .envs = envs,
            .scope = task_scope,
            // rest needs to be filled up after all symbols are recognized
            .dependecies = undefined,
            .body = undefined,
        });

        if (attributes_result.matchesPlatform()) {
            try self.defineSymbol(write_scope, .{
                .name = name,
                .span = task.node.trimmedSpan(),
                .origin = .{
                    .task = ptr,
                },
            });
        } else {
            try self.diagnostics.uneccesary(
                task.node.span,
                "inactive: only on {s} (current: {t})",
                .{
                    try attributes_result.platformsString(self.arena.allocator()),
                    platform.tag,
                },
            );
        }

        return ptr;
    }

    fn analyseTaskBody(self: *Sema, target: *ir.Task) Error!void {
        const dependencies = blk: {
            const in_deps = target.st_ref.dependencies orelse break :blk &.{};
            var dependencies: std.ArrayList(ir.TaskCall) = .empty;

            var it = in_deps.iter();

            while (it.next()) |dep|
                try dependencies.append(
                    self.arena.allocator(),
                    self.analyseTaskCall(dep, target.scope) catch |err| switch (err) {
                        Error.Incomplete => continue,
                        else => return err,
                    },
                );

            break :blk try dependencies.toOwnedSlice(self.arena.allocator());
        };

        const body_scope = try self.createScope(
            target.scope,
            target.st_ref.body.node,
        );

        const body = try self.analyseStatements(target.st_ref.body, body_scope);

        target.dependecies = dependencies;
        target.body = .{
            .scope = body_scope,
            .statements = body,
        };
    }

    fn analyseGroup(self: *Sema, group: ast.Group, scope: *Scope) Error!*ir.Group {
        var attributes_result = try AttributesResolver.resolve(self, .group, group.attributes);
        defer attributes_result.deinit(self.arena.allocator());

        const desc = if (attributes_result.attributes.getAssertOne(.desc)) |value|
            value.?.string
        else
            null;

        const group_scope = try self.createScope(scope, group.node);

        const name = if (group.name) |name|
            name.string().?
        else
            null;

        const args = if (group.params) |params|
            try self.analyseParams(params, group_scope, true)
        else
            &.{};

        var decls: std.ArrayList(*ir.Decl) = .empty;
        var tasks: std.ArrayList(*ir.Task) = .empty;

        const tasks_scope = if (group.name) |_| group_scope else scope;

        var it = group.body.iter();
        while (it.next()) |elem| {
            switch (elem) {
                .task => |task| try tasks.append(
                    self.arena.allocator(),
                    self.analyseTask(
                        task,
                        group_scope,
                        tasks_scope,
                    ) catch |err| switch (err) {
                        Error.Incomplete => continue,
                        else => return err,
                    },
                ),
                .binding => |binding| try decls.append(
                    self.arena.allocator(),
                    self.analyseBindingDecl(
                        binding,
                        group_scope,
                    ) catch |err| switch (err) {
                        Error.Incomplete => continue,
                        else => return err,
                    },
                ),
            }
        }

        const ptr = try self.create(ir.Group, .{
            .name = name,
            .args = args,
            .decls = try decls.toOwnedSlice(self.arena.allocator()),
            .tasks = try tasks.toOwnedSlice(self.arena.allocator()),
            .scope = group_scope,
            .desc = desc,
        });

        if (attributes_result.matchesPlatform()) {
            if (name) |n| {
                try self.defineSymbol(scope, .{
                    .name = n,
                    .span = group.node.trimmedSpan(),
                    .origin = .{
                        .group = ptr,
                    },
                });
            }
        } else {
            try self.diagnostics.uneccesary(
                group.node.span,
                "inactive: only on {s} (current: {t})",
                .{
                    try attributes_result.platformsString(self.arena.allocator()),
                    platform.tag,
                },
            );
        }

        return ptr;
    }

    fn analyseParams(self: *Sema, params: ast.Parameters, scope: *Scope, group: bool) Error![]*ir.Argument {
        const ArgPhase = enum {
            const Self = @This();
            positional,
            named_required,
            named_optional,

            fn validate(sema: *Sema, span: Span, phase: *Self, named: bool, optional: bool) !bool {
                const class = blk: {
                    if (named == false) {
                        if (optional) {
                            try sema.diagnostics.err(span, "positional parameters cannot have default values", .{});
                            return false;
                        }
                        break :blk Self.positional;
                    }
                    break :blk if (optional)
                        Self.named_optional
                    else
                        Self.named_required;
                };

                switch (phase.*) {
                    .positional => {},
                    .named_required => switch (class) {
                        .positional => {
                            try sema.diagnostics.err(span, "positional parameter cannot follow a named parameter", .{});
                            return false;
                        },
                        else => {},
                    },
                    .named_optional => switch (class) {
                        .positional => {
                            try sema.diagnostics.err(span, "positional parameter cannot follow a named parameter", .{});
                            return false;
                        },
                        .named_required => {
                            try sema.diagnostics.err(span, "required parameter cannot follow a optional parameter", .{});
                            return false;
                        },
                        else => {},
                    },
                }
                phase.* = class;
                return true;
            }
        };

        var phase: ArgPhase = .positional;

        var out: std.ArrayList(*ir.Argument) = .empty;

        var it = params.iter();

        while (it.next()) |param| {
            const name = param.name.string() orelse continue;

            const param_type: @"type".ArgType = blk: {
                // TODO: clean it
                if (param.type.type) |token| {
                    break :blk if (param.type.is_list)
                        switch (token.kind) {
                            .number_type => .list_number,
                            .string_type => .list_string,
                            else => unreachable,
                        }
                    else switch (token.kind) {
                        .flag_type => .flag,
                        .number_type => .number,
                        .string_type => .string,
                        else => unreachable,
                    };
                }
                continue;
            };

            var attributes = blk: {
                const attributes_result = try AttributesResolver.resolve(
                    self,
                    .{ .argument = param_type },
                    param.attributes,
                );

                std.debug.assert(attributes_result.platforms.count() == 0);
                break :blk attributes_result.attributes;
            };
            defer attributes.deinit(self.arena.allocator());

            const name_required = group or param_type.isNamedOnly();

            const default: ?runtime.Value, const implicit_default: bool = blk: {
                if (param_type == .flag) {
                    if (param.default) |def| {
                        try self.diagnostics.err(
                            def.node.trimmedSpan(),
                            "flag value have implicit default value",
                            .{},
                        );
                    }
                    break :blk .{
                        .{ .bool = false },
                        true,
                    };
                }

                if (param.default) |def| {
                    break :blk .{
                        try self.assertLiteral(def, param_type.typeOf()),
                        false,
                    };
                }

                break :blk .{ null, false };
            };
            _ = implicit_default;

            const implicit_names = default != null or name_required;

            const short = blk: {
                const default_value = name[0];

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
                const default_value = name;

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

            // const min = if (attributes.getAssertOne(.min)) |value|
            //     value.?.number
            // else
            //     null;

            // const max = if (attributes.getAssertOne(.max)) |value|
            //     value.?.number
            // else
            //     null;

            // const min_items: ?i64 = if (attributes.getAssertOne(.min_items)) |value|
            //     @intFromFloat(value.?.number)
            // else
            //     null;

            // const max_items: ?i64 = if (attributes.getAssertOne(.max_items)) |value|
            //     @intFromFloat(value.?.number)
            // else
            //     null;

            const has_name = blk: {
                const has_name = long != null or short != null;

                if (!has_name) {
                    if (group) {
                        try self.diagnostics.err(
                            param.node.trimmedSpan(),
                            "group arguments must be name",
                            .{},
                        );
                        continue;
                    }

                    if (name_required) {
                        try self.diagnostics.err(
                            param.node.trimmedSpan(),
                            "'{f}' type expect long or/and short attribute",
                            .{param_type},
                        );
                        continue; // TODO: consider if continue is best way to handle it
                    }
                }

                break :blk has_name;
            };

            //TODO: consider error handling here
            if (try ArgPhase.validate(
                self,
                param.node.trimmedSpan(),
                &phase,
                has_name,
                default != null,
            ) == false)
                break;

            //TODO: validate default values against attributes

            const ptr = try self.create(ir.Argument, .{
                .name = name,
                .type = param_type,
                .default = default,
                .is_positional = !has_name,

                .short = short,
                .long = long,
                .desc = desc,

                .pattern = pattern,
                .int = int,
            });

            try self.defineSymbol(scope, .{
                .name = name,
                .span = param.node.trimmedSpan(),
                .origin = .{ .argument = ptr },
            });

            try out.append(self.arena.allocator(), ptr);
        }

        return try out.toOwnedSlice(self.arena.allocator());
    }

    fn assertLiteral(self: *Sema, expr: ast.Expr, expected_type: Type) Error!runtime.Value {
        const class = expr.classify();

        const actual_type: std.meta.Tag(Type) = switch (class) {
            .literal => |literal| if (literal) |token|
                switch (token.kind) {
                    .true_kw, .false_kw => .bool,
                    .number => .number,
                    else => unreachable,
                }
            else
                return Error.Incomplete,
            .string => .string,
            .list => .list,
            .paren => |inner| return if (inner) |e|
                try self.assertLiteral(e, expected_type)
            else
                Error.Incomplete,
            else => |tag| {
                try self.diagnostics.err(
                    expr.node.trimmedSpan(),
                    "expected '{f}' literal, found '{t}'",
                    .{ expected_type, tag },
                );
                return Error.Incomplete;
            },
        };

        if (expected_type != actual_type) {
            try self.diagnostics.err(
                expr.node.trimmedSpan(),
                "invalid value type, expected '{f}' literal, got '{t}'",
                .{ expected_type, actual_type },
            );
            return Error.Incomplete;
        }

        return switch (class) {
            .literal => |literal| if (literal) |token|
                switch (token.kind) {
                    .true_kw => .{ .bool = true },
                    .false_kw => .{ .bool = false },
                    .number => .{ .number = std.fmt.parseFloat(f64, token.lexeme) catch unreachable },
                    else => unreachable,
                }
            else
                return Error.Incomplete,
            .list => |list| {
                if (expected_type != .list) {}

                var items: std.ArrayList(runtime.Value) = .empty;

                var it = list.iter();
                while (it.next()) |item| {
                    const result = self.assertLiteral(
                        item,
                        expected_type.list.*,
                    ) catch |err| {
                        try self.diagnostics.err(
                            item.node.trimmedSpan(),
                            "invalid list item type",
                            .{},
                        );
                        return err;
                    };
                    try items.append(self.arena.allocator(), result);
                }

                return .{
                    .list = .{
                        .items = try items.toOwnedSlice(self.arena.allocator()),
                        .items_type = try self.create(Type, expected_type),
                    },
                };
            },
            .string => |str| if (str.lit) |token|
                .{
                    .string = token.lexeme,
                }
            else
                Error.Incomplete,
            else => unreachable,
        };
    }

    fn analyseBindingDecl(self: *Sema, binding: ast.BindingDecl, scope: *Scope) Error!*ir.Decl {
        if (binding.attributes) |attrs| {
            try self.diagnostics.err(attrs.node.trimmedSpan(), "bindings doesn't support attributes", .{});
        }

        const name = binding.name.string() orelse unreachable;

        const value = if (binding.value) |value|
            try self.analyseExpr(value, scope)
        else
            return Error.Incomplete;

        const ptr = try self.create(ir.Decl, .{
            .name = name,
            .value = value.expr,
            .type = value.type,
            .scope = scope,
            .is_static = value.is_static,
        });

        try self.defineSymbol(scope, .{
            .name = name,
            .span = binding.node.trimmedSpan(),
            .origin = .{
                .binding = ptr,
            },
        });

        return ptr;
    }

    fn analyseStatements(self: *Sema, stmts: ast.Statements, scope: *Scope) Error![]ir.Statement {
        var out: std.ArrayList(ir.Statement) = .empty;

        var it = stmts.iter();

        while (it.next()) |stmt| {
            try out.append(
                self.arena.allocator(),
                self.analyseStatement(
                    stmt,
                    scope,
                ) catch |err| switch (err) {
                    Error.Incomplete => continue,
                    else => return err,
                },
            );
        }

        return try out.toOwnedSlice(self.arena.allocator());
    }

    fn analyseStatement(self: *Sema, stmt: ast.Statement, scope: *Scope) Error!ir.Statement {
        return switch (stmt.classify()) {
            .binding => |binding| .{
                .decl = try self.analyseBindingDecl(binding, scope),
            },
            .process => |proc| {
                const attributes_result = try AttributesResolver.resolve(self, .process_stmt, proc.attributes);
                std.debug.assert(attributes_result.platforms.count() == 0);

                const nofail = attributes_result.attributes.contains(.nofail);
                const noecho = if (attributes_result.attributes.getAssertOne(.noecho)) |noecho|
                    if (noecho) |value|
                        value.bool
                    else
                        true
                else
                    null;

                const result = try self.analyseStringExpr(proc.string, scope);

                return .{
                    .process = .{
                        .nofail = nofail,
                        .noecho = noecho,
                        .command = result.expr,
                    },
                };
            },
            .task_call => |task_call| .{
                .task_call = try self.analyseTaskCall(task_call, scope),
            },
            .@"for" => |for_stmt| {
                const result = try self.analyseForStmt(for_stmt, scope);

                return .{ .for_stmt = result };
            },
            .@"if" => |if_stmt| {
                const result = try self.analyseIfStmt(if_stmt, scope);

                return .{ .if_stmt = result };
            },
            .@"switch" => |switch_stmt| {
                const result = try self.analyseSwitchStmt(switch_stmt, scope);

                return .{ .switch_stmt = result };
            },
            .expr => |inner| if (inner) |expr| {
                const result = try self.analyseExpr(expr, scope);

                if (result.type != .void and result.type != .noreturn) {
                    try self.diagnostics.warn(
                        expr.node.trimmedSpan(),
                        "discarded value",
                        .{},
                    );
                }

                return .{ .expr = result.expr };
            } else Error.Incomplete,
        };
    }

    fn analyseSwitchStmt(self: *Sema, switch_stmt: ast.SwitchStmt, scope: *Scope) Error!ir.SwitchStmt {
        const subject = try self.analyseExpr(
            switch_stmt.subject orelse return Error.Incomplete,
            scope,
        );

        var cases: ir.SwitchStmt.CasesStorage = .empty;
        var else_case: ?ir.StatementBlock = null;

        var cases_it = switch_stmt.body.iter();
        while (cases_it.next()) |case| {
            const case_scope = try self.createScope(scope, case.node);

            const case_result = try self.analyseStatements(case.body, case_scope);

            switch (case.pattern.classify()) {
                .expr => |exprs| {
                    var it = exprs.iter();
                    while (it.next()) |expr| {
                        const value = self.assertLiteral(
                            expr,
                            subject.type,
                        ) catch |err| switch (err) {
                            Error.Incomplete => continue,
                            else => return err,
                        };

                        if (cases.contains(value)) {
                            try self.diagnostics.err(
                                expr.node.trimmedSpan(),
                                "duplicate pattern",
                                .{},
                            );
                            continue;
                        }

                        try cases.putNoClobber(
                            self.arena.allocator(),
                            value,
                            .{
                                .scope = case_scope,
                                .statements = case_result,
                            },
                        );
                    }
                },
                .@"else" => |token| {
                    if (else_case) |_| {
                        try self.diagnostics.err(
                            token.span,
                            "duplicate else case",
                            .{},
                        );
                        continue;
                    }

                    else_case = .{
                        .scope = case_scope,
                        .statements = case_result,
                    };
                },
            }
        }

        return .{
            .subject = subject.expr,
            .cases = cases,
            .else_case = else_case,
        };
    }

    fn analyseIfStmt(self: *Sema, if_stmt: ast.IfStmt, scope: *Scope) Error!ir.IfStmt {
        const cond = try self.analyseExpr(
            if_stmt.cond orelse return Error.Incomplete,
            scope,
        );

        if (cond.type != .bool) {
            try self.diagnostics.err(
                if_stmt.cond.?.node.trimmedSpan(),
                "condition must be of boolean type",
                .{},
            );
        }

        const then_block: ir.StatementBlock = blk: {
            const then_scope = try self.createScope(scope, if_stmt.then.node);

            const then = try self.analyseStatements(if_stmt.then, then_scope);
            break :blk .{
                .scope = then_scope,
                .statements = then,
            };
        };

        const else_block: ?ir.StatementBlock = blk: {
            const in_else = if_stmt.@"else" orelse break :blk null;

            const else_scope = try self.createScope(scope, in_else.node);
            const @"else" = try self.analyseStatements(in_else, else_scope);

            break :blk .{
                .scope = else_scope,
                .statements = @"else",
            };
        };

        return .{
            .cond = cond.expr,
            .then = then_block,
            .else_ = else_block,
        };
    }

    fn analyseForStmt(self: *Sema, for_stmt: ast.ForStmt, scope: *Scope) Error!ir.ForStmt {
        self.loop_depth += 1;
        defer self.loop_depth -= 1;

        const in_subjects = try for_stmt.subjects.collect(self.arena.allocator());
        const in_captures = try for_stmt.captures.collect(self.arena.allocator());

        if (in_subjects.len != in_captures.len and in_subjects.len + 1 != in_captures.len) {
            try self.diagnostics.err(
                for_stmt.captures.node.trimmedSpan(),
                "captures number must be equal to subjects number, or subject number + 1 if iteration index is needed",
                .{},
            );
        }

        var subjects: std.ArrayList(ir.Expr) = try .initCapacity(self.arena.allocator(), in_subjects.len);
        var captures: std.ArrayList(?*ir.Capture) = try .initCapacity(self.arena.allocator(), in_captures.len);

        const for_scope = try self.createScope(scope, for_stmt.node);

        for (in_subjects, in_captures[0..in_subjects.len]) |s, c| {
            const subject = s.unwrap() orelse continue;
            const capture = c.unwrap() orelse continue;

            const result = self.analyseExpr(
                subject,
                scope,
            ) catch |err| switch (err) {
                Error.Incomplete => continue,
                else => return err,
            };

            if (result.type != .list) {
                try self.diagnostics.err(
                    subject.node.trimmedSpan(),
                    "'{f}' type is not iterable",
                    .{result.type},
                );
                continue;
            }

            switch (capture) {
                .name => |name| {
                    const capture_ident = name.string() orelse continue;
                    const ptr = try self.create(ir.Capture, .{
                        .name = capture_ident,
                        .type = result.type.list.*,
                    });
                    captures.appendAssumeCapacity(ptr);
                    try self.defineSymbol(for_scope, .{
                        .name = capture_ident,
                        .span = name.node.trimmedSpan(),
                        .origin = .{
                            .capture = ptr,
                        },
                    });
                },
                .none => {
                    captures.appendAssumeCapacity(null);
                },
            }
            subjects.appendAssumeCapacity(result.expr);
        }

        if (in_captures.len == in_subjects.len + 1) {
            const index = in_captures.len - 1;
            if (in_captures[index].unwrap()) |index_capture| {
                switch (index_capture) {
                    .name => |name| {
                        const capture_name = name.string() orelse return Error.Incomplete;
                        const ptr = try self.create(ir.Capture, .{
                            .name = capture_name,
                            .type = .number,
                        });
                        captures.appendAssumeCapacity(ptr);

                        try self.defineSymbol(for_scope, .{
                            .name = capture_name,
                            .span = name.node.trimmedSpan(),
                            .origin = .{ .capture = ptr },
                        });
                    },
                    .none => |token| {
                        //TODO: consider making it error?
                        try self.diagnostics.warn(
                            token.span,
                            "useles anonymous capture, you can just skip index capture",
                            .{},
                        );
                        captures.appendAssumeCapacity(null);
                    },
                }
            }
        }

        const body = try self.analyseStatements(for_stmt.body, for_scope);

        return .{
            .subjects = try subjects.toOwnedSlice(self.arena.allocator()),
            .captures = try captures.toOwnedSlice(self.arena.allocator()),
            .body = .{
                .scope = for_scope,
                .statements = body,
            },
        };
    }

    fn ExprResult(comptime ExprT: type) type {
        return struct {
            expr: ExprT,
            type: Type,
            is_static: bool,
        };
    }

    fn analyseExpr(self: *Sema, expr: ast.Expr, scope: *Scope) Error!ExprResult(ir.Expr) {
        return switch (expr.classify()) {
            .literal => |literal| if (literal) |token|
                switch (token.kind) {
                    .true_kw => .{
                        .expr = .{ .bool_lit = true },
                        .type = .bool,
                        .is_static = true,
                    },
                    .false_kw => .{
                        .expr = .{ .bool_lit = false },
                        .type = .bool,
                        .is_static = true,
                    },
                    .number => .{
                        .expr = .{
                            .number_lit = std.fmt.parseFloat(f64, token.lexeme) catch unreachable,
                        },
                        .type = .number,
                        .is_static = true,
                    },
                    else => unreachable,
                }
            else
                Error.Incomplete,
            .name_ref => |name_ref| if (name_ref) |token| {
                const symbol = scope.resolve(token.lexeme, .variable) orelse {
                    // unknown reference,
                    try self.diagnostics.err(
                        token.span,
                        "unknown value: '{s}'",
                        .{token.lexeme},
                    );
                    return Error.Incomplete;
                };

                const symbol_type = switch (symbol.origin) {
                    .capture => |capture| capture.type,
                    .binding => |binding| binding.type,
                    .argument => |argument| argument.type.typeOf(),
                    else => unreachable,
                };

                return .{
                    .expr = .{
                        .ident = .{
                            .name = symbol.name,
                            .symbol = symbol,
                        },
                    },
                    .type = symbol_type,
                    .is_static = false,
                };
            } else Error.Incomplete,
            .list => |list| {
                var it = list.iter();

                var items: std.ArrayList(ir.Expr.List.Item) = .empty;

                var is_static = true;
                var items_type: ?*Type = null;

                while (it.next()) |item| {
                    const result = self.analyseExpr(
                        item,
                        scope,
                    ) catch |err| switch (err) {
                        Error.Incomplete => continue,
                        else => return err,
                    };
                    if (items_type) |t| {
                        if (t.eq(result.type) == false) {
                            // BUG: multiple diagnostics
                            try self.diagnostics.err(
                                it.lastSpan(),
                                "All list items must be of the same type, expected '{f}', got '{f}'",
                                .{ t.*, result.type },
                            );
                        }
                    } else {
                        items_type = try self.create(Type, result.type);
                    }

                    if (result.is_static == false)
                        is_static = false;

                    try items.append(self.arena.allocator(), .{
                        .expr = try self.create(ir.Expr, result.expr),
                        .is_spread = false,
                    });
                }

                const final_type = items_type orelse {
                    try self.diagnostics.err(
                        expr.node.trimmedSpan(),
                        "unable to infer list type",
                        .{},
                    );
                    return Error.Incomplete;
                };

                return .{
                    .expr = .{
                        .list = .{
                            .items = try items.toOwnedSlice(self.arena.allocator()),
                            .items_type = final_type.*,
                        },
                    },
                    .type = .{ .list = final_type },
                    .is_static = is_static,
                };
            },
            .string => |string| {
                const parts = try self.arena.allocator().alloc(ir.StringPart, 1);
                parts[0] = .{
                    .lit = if (string.lit) |token|
                        try text.processString(self.arena.allocator(), token.lexeme)
                    else
                        "",
                };

                return .{
                    .expr = .{ .string = parts },
                    .type = .string,
                    .is_static = true,
                };
            },
            .string_expr => |string| {
                const result = try self.analyseStringExpr(string, scope);

                return .{
                    .expr = .{
                        .string = result.expr,
                    },
                    .is_static = result.is_static,
                    .type = result.type,
                };
            },
            .paren => |inner| if (inner) |node|
                try self.analyseExpr(node, scope)
            else
                Error.Incomplete,
            .binary => |binary_expr| {
                const left = if (binary_expr.left) |left|
                    try self.analyseExpr(left, scope)
                else
                    return Error.Incomplete;

                const right = if (binary_expr.right) |right|
                    try self.analyseExpr(right, scope)
                else
                    return Error.Incomplete;

                const op: ir.BinaryOp = if (binary_expr.op) |op|
                    switch (op.kind) {
                        .plus => .add,
                        .minus => .sub,
                        .star => .mul,
                        .slash => .div,
                        .eq_eq => .eq,
                        .bang_eq => .neq,
                        .lt => .lt,
                        .gt => .gt,
                        .lt_eq => .lt_eq,
                        .gt_eq => .gt_eq,
                        .and_kw => .and_op,
                        .or_kw => .or_op,
                        .percent => .mod,
                        else => unreachable,
                    }
                else
                    return Error.Incomplete;

                const binary_result = binary.binaryResultType(op, left.type, right.type) catch |err| {
                    switch (err) {
                        error.TypeMismatch => {
                            try self.diagnostics.err(expr.node.trimmedSpan(), "type mismatch", .{});
                        },
                    }
                    return Error.Incomplete;
                };

                const ptr = try self.create(ir.BinaryExpr, .{
                    .left = left.expr,
                    .right = right.expr,
                    .op = op,
                    .type = binary_result.result_type,
                });

                return .{
                    .expr = .{
                        .binary = ptr,
                    },
                    .is_static = left.is_static and right.is_static,
                    .type = binary_result.result_type,
                };
            },
            .unary => |unary_expr| {
                const operand = if (unary_expr.operand) |operand|
                    try self.analyseExpr(operand, scope)
                else
                    return Error.Incomplete;

                const op: ir.UnaryOp = if (unary_expr.op) |op|
                    switch (op.kind) {
                        .not_kw => .not_op,
                        .minus => .negate,
                        else => unreachable,
                    }
                else
                    return Error.Incomplete;

                if (operand.type == .noreturn) {
                    try self.diagnostics.err(
                        expr.node.trimmedSpan(),
                        "noreturn type is not allowed in unary expression",
                        .{},
                    );
                    return Error.Incomplete;
                }

                const result_type: Type = switch (op) {
                    .not_op => blk: {
                        if (operand.type != .bool) {
                            try self.diagnostics.err(
                                expr.node.trimmedSpan(),
                                "'not' requires a bool or flag",
                                .{},
                            );
                        }
                        break :blk .bool;
                    },
                    .negate => blk: {
                        if (operand.type != .number) {
                            try self.diagnostics.err(
                                expr.node.trimmedSpan(),
                                "unary '-' requires number",
                                .{},
                            );
                        }
                        break :blk operand.type;
                    },
                };

                const ptr = try self.create(ir.UnaryExpr, .{
                    .op = op,
                    .operand = operand.expr,
                    .type = result_type,
                });

                return .{
                    .expr = .{
                        .unary = ptr,
                    },
                    .is_static = operand.is_static,
                    .type = result_type,
                };
            },
            .builtin_call => |builtin_call| {
                const result = try self.analyseBuiltinCall(builtin_call, scope);

                const ptr = try self.create(ir.BuiltinCall, result.expr);

                return .{
                    .expr = .{
                        .builtin_call = ptr,
                    },
                    .type = result.type,
                    .is_static = result.is_static,
                };
            },
            .lambda => |lambda| {
                try self.diagnostics.err(
                    lambda.node.trimmedSpan(),
                    "lambda only allowed as function argument",
                    .{},
                );
                return Error.Incomplete;
            },
            .@"switch" => |@"switch"| {
                const result = try self.analyseSwitchExpr(@"switch", scope);

                const ptr = try self.create(ir.SwitchExpr, result.expr);
                return .{
                    .expr = .{ .switch_expr = ptr },
                    .type = result.type,
                    .is_static = result.is_static,
                };
            },
            .@"if" => |@"if"| {
                const result = try self.analyseIfExpr(@"if", scope);

                const ptr = try self.create(ir.IfExpr, result.expr);
                return .{
                    .expr = .{ .if_expr = ptr },
                    .type = result.type,
                    .is_static = result.is_static,
                };
            },
            .@"for" => |@"for"| {
                const result = try self.analyseForExpr(@"for", scope);

                const ptr = try self.create(ir.ForExpr, result.expr);
                return .{
                    .expr = .{ .for_expr = ptr },
                    .type = result.type,
                    .is_static = result.is_static,
                };
            },
            .process => |process| {
                const attributes = try AttributesResolver.resolveAssertNoPlatform(self, .process_expr, process.attributes);

                const result = try self.analyseStringExpr(process.string, scope);

                var result_type: Type = .string;

                const nofail = attributes.contains(.nofail);

                const fallback: ?ir.Expr = blk: {
                    const fallback = process.fallback orelse break :blk null;

                    if (nofail) {
                        try self.diagnostics.err(
                            process.fallback.?.node.span,
                            "fallback with nofail not supported",
                            .{},
                        );
                    }

                    const fallback_expr = try self.analyseExpr(
                        fallback.expr orelse return Error.Incomplete,
                        scope,
                    );
                    result_type = Type.unify(result_type, fallback_expr.type) orelse rt: {
                        try self.diagnostics.err(
                            fallback.expr.?.node.span,
                            "invalid fallback expression value type, expected 'string', got '{f}'",
                            .{fallback_expr.type},
                        );
                        break :rt result_type;
                    };

                    break :blk fallback_expr.expr;
                };

                const ptr = try self.create(ir.ProcessExpr, .{
                    .nofail = nofail,
                    .command = result.expr,
                    .fallback = fallback,
                });

                return .{
                    .expr = .{ .process = ptr },
                    .type = result.type,
                    .is_static = false,
                };
            },
            inline .@"continue", .@"break" => |token, tag| {
                if (self.loop_depth == 0) {
                    try self.diagnostics.err(
                        token.span,
                        "'{t}' outside loop",
                        .{tag},
                    );
                }

                return .{
                    .expr = @unionInit(ir.Expr, @tagName(tag), {}),
                    .type = .noreturn,
                    .is_static = true,
                };
            },
        };
    }

    fn analyseForExpr(self: *Sema, for_expr: ast.ForExpr, scope: *Scope) Error!ExprResult(ir.ForExpr) {
        self.loop_depth += 1;
        defer self.loop_depth -= 1;

        const in_subjects = try for_expr.subjects.collect(self.arena.allocator());
        const in_captures = try for_expr.captures.collect(self.arena.allocator());

        if (in_subjects.len != in_captures.len and in_subjects.len + 1 != in_captures.len) {
            try self.diagnostics.err(
                for_expr.captures.node.trimmedSpan(),
                "captures num must be equal to subjects num or subject num + 1 if iteration index is needed",
                .{},
            );
        }

        var subjects: std.ArrayList(ir.Expr) = try .initCapacity(self.arena.allocator(), in_subjects.len);
        var captures: std.ArrayList(?*ir.Capture) = try .initCapacity(self.arena.allocator(), in_captures.len);

        var is_static = true;

        const for_scope = try self.createScope(scope, for_expr.node);

        for (in_subjects, in_captures[0..in_subjects.len]) |s, c| {
            const subject = s.unwrap() orelse continue;
            const capture = c.unwrap() orelse continue;

            const result = self.analyseExpr(
                subject,
                scope,
            ) catch |err| switch (err) {
                Error.Incomplete => continue,
                else => return err,
            };

            if (result.is_static == false)
                is_static = false;

            if (result.type != .list) {
                try self.diagnostics.err(
                    subject.node.trimmedSpan(),
                    "'{f}' type is not iterable",
                    .{result.type},
                );
                continue;
            }

            switch (capture) {
                .name => |name| {
                    const capture_ident = name.string() orelse continue;
                    const ptr = try self.create(ir.Capture, .{
                        .name = capture_ident,
                        .type = result.type.list.*,
                    });
                    captures.appendAssumeCapacity(ptr);
                    try self.defineSymbol(for_scope, .{
                        .name = capture_ident,
                        .span = name.node.trimmedSpan(),
                        .origin = .{
                            .capture = ptr,
                        },
                    });
                },
                .none => {
                    captures.appendAssumeCapacity(null);
                },
            }
            subjects.appendAssumeCapacity(result.expr);
        }

        if (in_captures.len == in_subjects.len + 1) {
            const index = in_captures.len - 1;
            if (in_captures[index].unwrap()) |index_capture| {
                switch (index_capture) {
                    .name => |name| {
                        const capture_name = name.string() orelse return Error.Incomplete;
                        const ptr = try self.create(ir.Capture, .{
                            .name = capture_name,
                            .type = .number,
                        });
                        captures.appendAssumeCapacity(ptr);

                        try self.defineSymbol(for_scope, .{
                            .name = capture_name,
                            .span = name.node.trimmedSpan(),
                            .origin = .{ .capture = ptr },
                        });
                    },
                    .none => |token| {
                        //TODO: consider making it error?
                        try self.diagnostics.warn(
                            token.span,
                            "useles anonymous capture, you can just skip index capture",
                            .{},
                        );
                        captures.appendAssumeCapacity(null);
                    },
                }
            }
        }

        const body = try self.analyseExpr(
            for_expr.body orelse return Error.Incomplete,
            for_scope,
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

    fn analyseIfExpr(self: *Sema, if_expr: ast.IfExpr, scope: *Scope) Error!ExprResult(ir.IfExpr) {
        const cond = try self.analyseExpr(
            if_expr.cond orelse return Error.Incomplete,
            scope,
        );

        if (cond.type != .bool) {
            try self.diagnostics.err(
                if_expr.cond.?.node.trimmedSpan(),
                "invalid condition type, expected '{f}', got '{f}'",
                .{ @as(Type, .bool), cond.type },
            );
        }

        const then = try self.analyseExpr(
            if_expr.then orelse return Error.Incomplete,
            scope,
        );

        const @"else" = try self.analyseExpr(
            if_expr.@"else" orelse return Error.Incomplete,
            scope,
        );

        const result_type = Type.unify(then.type, @"else".type) orelse {
            try self.diagnostics.err(
                if_expr.@"else".?.node.trimmedSpan(),
                "all branches must be of the same type",
                .{},
            );
            return Error.Incomplete;
        };

        return .{
            .expr = .{
                .cond = cond.expr,
                .then = then.expr,
                .@"else" = @"else".expr,
                .type = result_type,
            },
            .type = result_type,
            .is_static = then.is_static and @"else".is_static,
        };
    }

    fn analyseSwitchExpr(self: *Sema, switch_expr: ast.SwitchExpr, scope: *Scope) Error!ExprResult(ir.SwitchExpr) {
        const subject = try self.analyseExpr(
            switch_expr.subject orelse return Error.Incomplete,
            scope,
        );

        var is_static = subject.is_static;

        var cases: ir.SwitchExpr.CasesStorage = .empty;
        var else_case: ?ir.Expr = null;
        var result_type: Type = .noreturn;

        var b_it = switch_expr.body.iter();
        while (b_it.next()) |case| {
            const case_result = try self.analyseExpr(
                case.expr orelse return Error.Incomplete,
                scope,
            );

            if (case_result.is_static == false)
                is_static = false;

            result_type = Type.unify(result_type, case_result.type) orelse blk: {
                try self.diagnostics.err(
                    case.expr.?.node.trimmedSpan(),
                    "each switch branch is required to have the same result type, expected '{f}', got '{f}'",
                    .{ result_type, case_result.type },
                );

                break :blk result_type;
            };

            switch (case.pattern.classify()) {
                .expr => |patterns| {
                    var it = patterns.iter();
                    while (it.next()) |expr| {
                        const value = try self.assertLiteral(expr, subject.type);

                        if (cases.contains(value)) {
                            try self.diagnostics.err(
                                expr.node.trimmedSpan(),
                                "duplicate case: '{f}'",
                                .{value},
                            );
                            continue;
                        }

                        try cases.put(
                            self.arena.allocator(),
                            value,
                            case_result.expr,
                        );
                    }
                },
                .@"else" => {
                    if (else_case != null) {
                        try self.diagnostics.err(case.node.trimmedSpan(), "duplicate else case", .{});
                        continue;
                    }
                    else_case = case_result.expr;
                },
            }
        }

        const final_else_case = else_case orelse {
            try self.diagnostics.err(
                switch_expr.body.node.trimmedSpan(),
                "missing else case",
                .{},
            );
            return Error.Incomplete;
        };

        return .{
            .expr = .{
                .subject = subject.expr,
                .cases = cases,
                .else_case = final_else_case,
                .type = result_type, //TODO: finish
            },
            .is_static = is_static,
            .type = result_type,
        };
    }

    fn analyseBuiltinCall(self: *Sema, builtin_call: ast.BuiltinCall, scope: *Scope) Error!ExprResult(ir.BuiltinCall) {
        const builtin_call_name = if (builtin_call.name) |name|
            name.lexeme
        else
            return Error.Incomplete;

        const in_args = try builtin_call.args.collect(self.arena.allocator());

        var args: std.ArrayList(ir.Expr) = .empty;
        var args_types: std.ArrayList(functions.InArg) = .empty;

        var is_static = true;

        for (in_args) |arg_result| switch (arg_result) {
            .value => |arg| {
                if (arg.node.kind == .lambda) {
                    try args.append(self.arena.allocator(), undefined);
                    try args_types.append(self.arena.allocator(), .{ .lambda = .{
                        .params = blk: {
                            const lambda = arg.classify().lambda;
                            var params = lambda.params.iter();
                            var count: usize = 0;
                            while (params.next()) |_| count += 1;
                            break :blk count;
                        },
                    } });
                    continue;
                }

                const result = try self.analyseExpr(arg, scope);
                try args.append(self.arena.allocator(), result.expr);
                try args_types.append(self.arena.allocator(), .{
                    .value = .{
                        .type = result.type,
                    },
                });
            },
            else => continue,
        };

        const result = functions.definitions.resolve(
            self.arena.allocator(),
            builtin_call_name,
            args_types.items,
        ) catch |err| switch (err) {
            functions.Error.UnknownFunction => {
                try self.diagnostics.err(
                    builtin_call.node.trimmedSpan(),
                    "unknown function '{s}'",
                    .{builtin_call_name},
                );
                return Error.Incomplete;
            },
            functions.Error.InvalidArguments => {
                try self.diagnostics.err(
                    builtin_call.args.node.trimmedSpan(),
                    "invalid arguments",
                    .{},
                );
                return Error.Incomplete;
            },
            inline else => |tag| return @errorCast(tag),
        };

        for (in_args, result.params, 0..) |in_arg, param, idx| {
            const expr = in_arg.unwrap() orelse continue;
            switch (param) {
                .lambda => |l| {
                    const lambda = expr.classify().lambda;
                    const lambda_in_params = try lambda.params.collect(self.arena.allocator());

                    const lambda_scope = try self.createScope(scope, lambda.node);

                    const captures = try self.arena.allocator().alloc(ir.Capture, l.params.len);

                    for (lambda_in_params, l.params, captures) |in_param, in, *out| {
                        const lambda_param = in_param.unwrap() orelse continue;

                        const name = switch (lambda_param) {
                            .name => |name| name,
                            else => continue,
                        };
                        const ident = name.string() orelse return Error.Incomplete;
                        out.* = .{
                            .name = ident,
                            .type = in,
                        };

                        try self.defineSymbol(lambda_scope, .{
                            .name = ident,
                            .span = name.node.trimmedSpan(),
                            .origin = .{
                                .capture = out,
                            },
                        });
                    }

                    const body = try self.analyseExpr(
                        lambda.body orelse return Error.Incomplete,
                        lambda_scope,
                    );

                    if (body.is_static == false)
                        is_static = false;

                    if (body.type.eq(l.return_type) == false) {
                        try self.diagnostics.err(
                            lambda.node.trimmedSpan(),
                            "invalid lambda result type, expected '{f}', got '{f}'",
                            .{ l.return_type, body.type },
                        );
                    }

                    const ptr = try self.create(ir.Lambda, .{
                        .captures = captures,
                        .body = body.expr,
                        .scope = lambda_scope,
                    });

                    args.items[idx] = .{
                        .lambda = ptr,
                    };
                },
                else => {},
            }
        }

        var result_type = result.return_type;

        var fallback: ?ir.Expr = null;
        fb: {
            if (builtin_call.fallback) |fb| {
                const fb_expr = fb.expr orelse return Error.Incomplete;

                if (result.return_type != .result) {
                    try self.diagnostics.err(
                        fb.node.trimmedSpan(),
                        "fallback can be only used on errorable functions",
                        .{},
                    );
                    break :fb;
                }

                const fb_result = try self.analyseExpr(fb_expr, scope);
                result_type = Type.unify(result_type.result.*, fb_result.type) orelse blk: {
                    try self.diagnostics.err(
                        fb_expr.node.trimmedSpan(),
                        "invalid fallback result type",
                        .{},
                    );
                    break :blk result_type;
                };
                fallback = fb_result.expr;
            } else if (result_type == .result) {
                try self.diagnostics.err(
                    builtin_call.node.trimmedSpan(),
                    "'{s}' requires fallback expression",
                    .{builtin_call_name},
                );
            }
        }

        return .{
            .expr = .{
                .function = result,
                .args = args.items,
                .fallback = fallback,
            },
            .type = result_type,
            .is_static = false,
        };
    }

    fn analyseStringExpr(self: *Sema, string: ast.StringExpr, scope: *Scope) Error!ExprResult(ir.String) {
        var out: std.ArrayList(ir.StringPart) = .empty;

        var is_static = true;

        var it = string.iter();

        while (it.next()) |part| {
            switch (part) {
                .expr => |expr| {
                    const result = try self.analyseExpr(expr, scope);

                    if (result.is_static == false)
                        is_static = false;
                    //TODO: validate type here
                    try out.append(
                        self.arena.allocator(),
                        .{ .expr = result.expr },
                    );
                },
                .lit => |lit| {
                    try out.append(
                        self.arena.allocator(),
                        .{
                            .lit = try text.processString(
                                self.arena.allocator(),
                                lit.lexeme,
                            ),
                        },
                    );
                },
            }
        }

        return .{
            .expr = try out.toOwnedSlice(self.arena.allocator()),
            .type = .string,
            .is_static = is_static,
        };
    }

    fn lowerMetaValue(self: *Sema, value: ast.Meta) !meta.Value {
        return switch (value.classify()) {
            .literal => |literal| if (literal) |token|
                switch (token.kind) {
                    .null_kw => .null,
                    .false_kw => .{ .bool = false },
                    .true_kw => .{ .bool = true },
                    .number => .{ .number = std.fmt.parseFloat(f64, token.lexeme) catch unreachable },
                    else => unreachable,
                }
            else
                return Error.Incomplete,
            .list => |list| {
                //TODO: ensure single type

                var items: std.ArrayList(meta.Value) = .empty;

                var it = list.iter();

                while (it.next()) |item| {
                    try items.append(
                        self.arena.allocator(),
                        try self.lowerMetaValue(item),
                    );
                }

                return .{ .list = try items.toOwnedSlice(self.arena.allocator()) };
            },
            .char => |char| if (char) |token| .{
                .char = token.lexeme[0],
            } else return Error.Incomplete,
            .string => |str| .{
                .string = if (str) |token| token.lexeme else "",
            },
            .tuple => |tuple| {
                var elems: std.ArrayList(meta.Value) = .empty;

                var it = tuple.iter();
                while (it.next()) |elem| {
                    try elems.append(
                        self.arena.allocator(),
                        try self.lowerMetaValue(elem),
                    );
                }

                return .{ .tuple = try elems.toOwnedSlice(self.arena.allocator()) };
            },
        };
    }

    /// Resolves which task a call refers to. Flat early-returns instead of nested labeled blocks.
    fn resolveCallee(self: *Sema, task_call: ast.TaskCall, scope: *Scope) Error!*ir.Task {
        const task_name = task_call.task.string() orelse return Error.Incomplete;

        switch (task_call.scope) {
            .closest => {
                const symbol = scope.resolve(task_name, .task) orelse {
                    try self.diagnostics.err(
                        task_call.node.trimmedSpan(),
                        "unknown task '{s}'",
                        .{task_name},
                    );
                    return Error.Incomplete;
                };
                return symbol.origin.task;
            },
            .root => {
                const symbol = scope.root().resolve(task_name, .task) orelse {
                    try self.diagnostics.err(
                        task_call.node.trimmedSpan(),
                        "unknown task '::{s}'",
                        .{task_name},
                    );
                    return Error.Incomplete;
                };
                return symbol.origin.task;
            },
            .group => |group_name| {
                const group_name_str = group_name.string() orelse return Error.Incomplete;

                const group_symbol = scope.root().resolve(group_name_str, .group) orelse {
                    try self.diagnostics.err(
                        group_name.node.trimmedSpan(),
                        "unknown group '{s}'",
                        .{group_name_str},
                    );
                    return Error.Incomplete;
                };

                const symbol = group_symbol.origin.group.scope.resolveLocal(task_name, .task) orelse {
                    try self.diagnostics.err(
                        task_call.task.node.trimmedSpan(),
                        "unknown task '{s}::{s}'",
                        .{ group_name_str, task_name },
                    );
                    return Error.Incomplete;
                };
                return symbol.origin.task;
            },
        }
    }

    /// Finds a parameter by identifier: the task's own arguments first, then its group's shared ones.
    fn findParam(task: *const ir.Task, name: []const u8) ?*ir.Argument {
        for (task.args) |arg| if (std.mem.eql(u8, arg.name, name)) return arg;
        if (task.group) |g| for (g.args) |arg| if (std.mem.eql(u8, arg.name, name)) return arg;
        return null;
    }

    /// For a parameter the call did not supply: use its default, or report it as missing.
    fn fillMissing(
        self: *Sema,
        args: *ir.TaskCall.ArgsMap,
        arg: *ir.Argument,
        task_call: ast.TaskCall,
    ) Error!void {
        if (args.contains(arg.name)) return;

        if (arg.default) |def| {
            try args.put(self.arena.allocator(), arg.name, .{ .default = def });
        } else {
            try self.diagnostics.err(
                task_call.node.trimmedSpan(),
                "missing argument: '{s}'",
                .{arg.name},
            );
        }
    }

    fn analyseTaskCall(self: *Sema, task_call: ast.TaskCall, scope: *Scope) Error!ir.TaskCall {
        const task = try self.resolveCallee(task_call, scope);
        const alloc = self.arena.allocator();

        // A call to a task of the same group from inside that group already has
        // the group's shared arguments in scope, so they may be omitted.
        const is_same_group_call = task_call.scope == .closest and task.group != null;

        var args: ir.TaskCall.ArgsMap = .empty;
        var next_positional: usize = 0;
        var seen_named = false;

        // One pass over the call's arguments. Each one is mapped to a parameter,
        // either by name or, if it has no name, by its position.
        for (try task_call.args.collect(alloc)) |in_arg| {
            const arg = in_arg.unwrap() orelse continue;
            const span = arg.node.trimmedSpan();
            const value_node = arg.value orelse return Error.Incomplete;

            const param: *ir.Argument = if (arg.name) |name_node| blk: {
                seen_named = true;
                const name = name_node.string() orelse return Error.Incomplete;
                break :blk findParam(task, name) orelse {
                    try self.diagnostics.err(span, "unknown argument '{s}'", .{name});
                    continue;
                };
            } else blk: {
                if (seen_named) {
                    try self.diagnostics.err(span, "positional argument cannot follow a named argument", .{});
                    continue;
                }

                const idx = next_positional;
                next_positional += 1;

                if (idx >= task.args.len) {
                    try self.diagnostics.err(
                        span,
                        "invalid positional arguments count, got '{}', expected at most '{}'",
                        .{ idx + 1, task.args.len },
                    );
                    continue;
                }
                break :blk task.args[idx];
            };

            if (args.contains(param.name)) {
                try self.diagnostics.err(span, "duplicate argument '{s}'", .{param.name});
                continue;
            }

            const value = try self.analyseExpr(value_node, scope);
            const expected = param.type.typeOf();

            // Report the mismatch but still record the argument, so it is not
            // additionally reported as "missing".
            if (!value.type.eq(expected)) {
                try self.diagnostics.err(
                    value_node.node.trimmedSpan(),
                    "invalid argument type for '{s}', got '{f}', expected '{f}'",
                    .{ param.name, value.type, expected },
                );
            }

            try args.put(alloc, param.name, .{ .value = value.expr });
        }

        // Whatever the call did not supply: default or "missing".
        for (task.args) |param| try self.fillMissing(&args, param, task_call);

        if (!is_same_group_call) {
            if (task.group) |g| {
                for (g.args) |param| try self.fillMissing(&args, param, task_call);
            }
        }

        return .{
            .task = task,
            .args = args,
            .same_group = is_same_group_call,
        };
    }

    fn defineSymbol(self: *Sema, scope: *Scope, symbol: Symbol) !void {
        const symbol_type = symbol.typeOf();

        const previous_symbol = switch (symbol_type) {
            .variable, .group => scope.resolve(symbol.name, symbol_type),
            .task => scope.resolveLocal(symbol.name, symbol_type),
        };

        if (previous_symbol) |prev| {
            try self.diagnostics.err(
                symbol.span,
                "'{s}' {t} already defined",
                .{ symbol.name, symbol_type },
            );
            try self.diagnostics.err(
                prev.span,
                "'{t}' defined here",
                .{symbol_type},
            );
            return;
        }

        try scope.define(self.arena.allocator(), symbol);
    }

    fn createScope(self: *Sema, parent: ?*Scope, node: ?*const cst.Node) !*Scope {
        const ptr = try self.arena.allocator().create(Scope);
        ptr.* = .init(parent);

        if (node) |n| if (parent) |p|
            try p.put_child(self.arena.allocator(), n, ptr);

        return ptr;
    }

    fn create(self: *Sema, comptime T: type, value: T) !*T {
        const ptr = try self.arena.allocator().create(T);
        ptr.* = value;
        return ptr;
    }
};

const AttributesResolver = struct {
    const ResolvedAttributes = lib.enums.EnumMultimap(attrib.definitions.Type, ?meta.Value);

    sema: *Sema,
    attributes: ResolvedAttributes,
    platforms: std.EnumSet(platform.Tag),

    const Result = struct {
        attributes: ResolvedAttributes,
        platforms: std.EnumSet(platform.Tag),

        fn matchesPlatform(self: *const Result) bool {
            return self.platforms.count() == 0 or self.platforms.contains(platform.tag);
        }

        fn platformsString(self: *const Result, allocator: std.mem.Allocator) ![]const u8 {
            var w: std.Io.Writer.Allocating = .init(allocator);
            const last = self.platforms.count() - 1;

            var i: usize = 0;
            var it = self.platforms.iterator();

            while (it.next()) |item| : (i += 1) {
                try w.writer.print("{t}", .{item});
                if (i != last) try w.writer.writeAll(", ");
            }

            return try w.toOwnedSlice();
        }

        fn deinit(self: *Result, allocator: std.mem.Allocator) void {
            self.attributes.deinit(allocator);
        }
    };

    fn resolveAssertNoPlatform(sema: *Sema, target: attrib.definitions.Target, attributes: ?ast.Attributes) !ResolvedAttributes {
        const result = try resolve(sema, target, attributes);
        std.debug.assert(result.platforms.count() == 0);
        return result.attributes;
    }

    fn resolve(sema: *Sema, target: attrib.definitions.Target, attributes: ?ast.Attributes) !Result {
        var resolver: AttributesResolver = .{
            .sema = sema,
            .attributes = .empty,
            .platforms = .empty,
        };

        if (attributes) |attrs| {
            try resolver.resolveAttributes(attrs, target);
        }

        return .{
            .attributes = resolver.attributes,
            .platforms = resolver.platforms,
        };
    }

    fn resolveAttributes(
        self: *AttributesResolver,
        attributes: ast.Attributes,
        target: attrib.definitions.Target,
    ) !void {
        var it = attributes.iter();
        while (it.next()) |attr| {
            try self.resolveAttribute(attr, target);
        }
    }

    fn resolveAttribute(
        self: *AttributesResolver,
        attribute: ast.Attribute,
        target: attrib.definitions.Target,
    ) !void {
        const name = attribute.name.string() orelse return;

        const value = if (attribute.value) |value|
            try self.sema.lowerMetaValue(value)
        else
            null;

        const def = attrib.definitions.get(name, target) orelse {
            try self.sema.diagnostics.err(
                attribute.node.trimmedSpan(),
                "'{s}' is not valid attribute for this element",
                .{name},
            );
            return;
        };

        switch (def.kind) {
            .platform => {
                const pt = lib.enums.castEnum(def.type, platform.Tag) orelse unreachable;
                std.debug.assert(def.unique);

                if (value != null) {
                    try self.sema.diagnostics.err(
                        attribute.node.trimmedSpan(),
                        "platform attributes does not take value",
                        .{},
                    );
                    return;
                }

                if (self.platforms.contains(pt)) {
                    try self.sema.diagnostics.err(
                        attribute.node.trimmedSpan(),
                        "'{s}' platform attribute duplicate",
                        .{name},
                    );
                    return;
                }

                self.platforms.insert(pt);
            },
            else => {
                if (def.unique and self.attributes.contains(def.type)) {
                    try self.sema.diagnostics.err(
                        attribute.node.trimmedSpan(),
                        "'{s}' attribute duplicate",
                        .{name},
                    );
                    return;
                }

                if (value) |v| {
                    for (def.value_types) |vt| {
                        if (v.validateType(vt)) break;
                    } else {
                        const expected = try attrib.typesListToString(self.sema.arena.allocator(), def.value_types, def.allow_default);
                        try self.sema.diagnostics.err(
                            attribute.node.trimmedSpan(),
                            "invalid '{s}' attribute value, expected '{s}'",
                            .{ name, expected },
                        );
                        return;
                    }
                } else if (def.allow_default == false) {
                    const expected = try attrib.typesListToString(self.sema.arena.allocator(), def.value_types, def.allow_default);
                    try self.sema.diagnostics.err(
                        attribute.node.trimmedSpan(),
                        "'{s}' attribute doesn't support default value, expected '{s}'",
                        .{ name, expected },
                    );
                    return;
                }
                try self.attributes.add(
                    self.sema.arena.allocator(),
                    def.type,
                    value,
                );
            },
        }
    }
};

const OptionsResolver = struct {
    const OptionValue = union(options.Type) {
        shell: []const []const u8,
        dotenv: ?[]const u8,
        working_dir: []const u8,
    };

    const ResolvedOptions = std.EnumMap(options.Type, OptionValue);

    sema: *Sema,
    resolved: ResolvedOptions = .init(.{}),

    pub fn init(sema: *Sema) OptionsResolver {
        return .{ .sema = sema };
    }

    fn final(self: *OptionsResolver) ir.Options {
        var out: ir.Options = platform.default_options;

        var it = self.resolved.iterator();

        while (it.next()) |opt| switch (opt.value.*) {
            .shell => |shell| out.shell = shell,
            .dotenv => |dotenv| out.dotenv = dotenv,
            .working_dir => |wd| out.working_dir = wd,
        };

        return out;
    }

    fn resolveSet(self: *OptionsResolver, set: ast.Set) Error!void {
        var attributes_result = try AttributesResolver.resolve(self.sema, .setting, set.attributes);
        defer attributes_result.deinit(self.sema.arena.allocator());

        if (attributes_result.matchesPlatform() == false) {
            try self.sema.diagnostics.uneccesary(
                set.node.span,
                "inactive: only on {s} (current: {t})",
                .{
                    try attributes_result.platformsString(self.sema.arena.allocator()),
                    platform.tag,
                },
            );
            return;
        }

        var it = set.body.iter();

        while (it.next()) |decl| {
            self.resolveDecl(decl) catch |err| switch (err) {
                Error.Incomplete => continue,
                else => return err,
            };
        }
    }

    fn resolveDecl(self: *OptionsResolver, decl: ast.SetDecl) Error!void {
        const decl_name = decl.name.string() orelse return Error.Incomplete;
        const def = options.get(decl_name) orelse {
            try self.sema.diagnostics.err(
                decl.name.node.trimmedSpan(),
                "unknown option '{s}'",
                .{decl_name},
            );
            return Error.Incomplete;
        };

        if (self.resolved.contains(def.id)) {
            try self.sema.diagnostics.err(
                decl.node.trimmedSpan(),
                "duplicate setting '{s}'",
                .{decl_name},
            );
            return Error.Incomplete;
        }

        const value: meta.Value = if (decl.value) |value|
            try self.sema.lowerMetaValue(value)
        else
            .{ .bool = true };

        for (def.value_types) |vt| {
            if (value.validateType(vt)) break;
        } else {
            const expected = try attrib.typesListToString(self.sema.arena.allocator(), def.value_types, false);
            try self.sema.diagnostics.err(
                decl.node.trimmedSpan(),
                "invalid '{s}' option value type, expected '{s}'",
                .{ decl_name, expected },
            );
            return Error.Incomplete;
        }

        self.resolved.put(
            def.id,
            try self.getOptionValue(
                def.id,
                value,
            ),
        );
    }

    fn getOptionValue(self: *OptionsResolver, id: options.Type, value: meta.Value) !OptionValue {
        return switch (id) {
            .shell => {
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

                return .{
                    .shell = try out.toOwnedSlice(self.sema.arena.allocator()),
                };
            },
            .dotenv => switch (value) {
                .bool => |b| {
                    return .{ .dotenv = if (b) ".env" else null };
                },
                .string => |str| {
                    return .{ .dotenv = str };
                },
                else => unreachable,
            },
            .working_dir => .{ .working_dir = value.string },
        };
    }
};

// fn castError(in: anytype) Error {
//     const T = @TypeOf(in);

//     const error_set = blk: {
//         const ti = @typeInfo(T);

//         if (ti != .error_set)
//             @compileError("error set expected, got " ++ @tagName(ti));

//         break :blk ti.error_set.?;
//     };

//     inline for(error_set) |err| {
//         @err
//     }
// }
