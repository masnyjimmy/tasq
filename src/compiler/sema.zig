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

const options = @import("options.zig");
const platform = @import("platform.zig");

const Diagnostics = @import("Diagnostics.zig");

const Error = error{
    Incomplete,
} || std.mem.Allocator.Error || text.Error || std.Io.Writer.Error;

/// `Error.Incomplete` means "already reported (or the syntax tree is broken), skip this element".
/// Turns it into `null` so loops can write `orelse continue` instead of a `catch |err| switch`.
/// Every other error is passed through.
fn skipIncomplete(result: anytype) Error!?@typeInfo(@TypeOf(result)).error_union.payload {
    const value = result catch |err| switch (err) {
        Error.Incomplete => return null,
        else => |e| return e,
    };
    return value;
}

pub const Sema = struct {
    arena: *std.heap.ArenaAllocator,
    diagnostics: *Diagnostics,

    lambda_instances: std.hash_map.HashMapUnmanaged(
        ir.LambdaInstance.Key,
        ir.LambdaInstance.State,
        ir.LambdaInstance.Key.MapContext,
        80,
    ) = .empty,
    loop_depth: usize = 0,

    /// True while the body of a lambda is analysed once, at its definition, with `unknown`
    /// parameters. Everything depends on `unknown` there, so incomplete types are expected and
    /// the resulting IR is thrown away.
    in_template: bool = false,

    pub fn init(arena: *std.heap.ArenaAllocator, diagnostics: *Diagnostics) Sema {
        return .{
            .arena = arena,
            .diagnostics = diagnostics,
        };
    }

    // Results in partially analysed file, all symbols collected but elements which can contain reference to some can be missing
    pub fn firstPhase(self: *Sema, file: ast.File) Error!ir.File {
        const alloc = self.arena.allocator();
        const root_scope = try self.createScope(null, file.node);

        var options_resolver: OptionsResolver = .init(self);

        var tasks: std.ArrayList(*ir.Task) = .empty;
        var groups: std.ArrayList(*ir.Group) = .empty;
        var decls: std.ArrayList(*ir.Decl) = .empty;

        var it = file.iter();

        while (it.next()) |elem| {
            switch (elem) {
                .set => |set| {
                    _ = try skipIncomplete(options_resolver.resolveSet(set));
                },
                .binding => |binding| {
                    const decl = try skipIncomplete(self.analyseBindingDecl(binding, root_scope)) orelse continue;
                    try decls.append(alloc, decl);
                },
                .task => |task| {
                    const ptr = try skipIncomplete(self.analyseTask(task, root_scope, root_scope)) orelse continue;
                    try tasks.append(alloc, ptr);
                },
                .group => |group| {
                    const ptr = try skipIncomplete(self.analyseGroup(group, root_scope)) orelse continue;
                    try groups.append(alloc, ptr);
                },
            }
        }

        return .{
            .scope = root_scope,
            .decls = try decls.toOwnedSlice(alloc),
            .tasks = try tasks.toOwnedSlice(alloc),
            .groups = try groups.toOwnedSlice(alloc),
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

        try CycleChecker.checkCycles(self, &result);

        return result;
    }

    // ------------------------------------------------------------------------------------------
    // Small shared helpers
    // ------------------------------------------------------------------------------------------

    /// Reads an attribute that carries a string value (`desc`, `cwd`, `pattern`, ...).
    fn stringAttribute(
        attributes: *const AttributesResolver.ResolvedAttributes,
        comptime kind: attrib.definitions.Type,
    ) ?[]const u8 {
        const value = attributes.getAssertOne(kind) orelse return null;
        return value.?.string;
    }

    /// Hint for elements that are disabled on the current platform (`[linux]`, `[windows]`, ...).
    fn reportInactive(self: *Sema, span: Span, attributes: *const AttributesResolver.Result) Error!void {
        try self.diagnostics.uneccesary(
            span,
            "inactive: only enabled on {s} (current platform: {t})",
            .{
                try attributes.platformsString(self.arena.allocator()),
                platform.tag,
            },
        );
    }

    fn unknownValue(self: *Sema, span: Span, name: []const u8) Error!void {
        try self.diagnostics.err(
            span,
            "cannot find value '{s}' in this scope",
            .{name},
        );
    }

    /// `noreturn` (`break`, `continue`, an `@error(..)` call, ...) is only meaningful as a branch of
    /// `if`/`switch` or as a statement. Wherever a value is *consumed* (operand, argument, condition,
    /// list item, ...) the consuming code can never run, so that is reported as unreachable code.
    ///
    /// The type becomes `unknown`, so nothing downstream reports the same problem again.
    /// Returns `true` when the expression was rejected.
    fn rejectNoreturn(
        self: *Sema,
        expr: ast.Expr,
        result: *ExprResult(ir.Expr),
        comptime role: []const u8,
        args: anytype,
    ) Error!bool {
        if (result.type != .noreturn) return false;

        try self.diagnostics.err(
            expr.node.trimmedSpan(),
            "unreachable code: this expression never produces a value, so it cannot be used as " ++ role,
            args,
        );

        result.type = .unknown;
        return true;
    }

    /// Condition of `if` (statement or expression): must be a `bool`.
    fn analyseCondition(self: *Sema, cond: ?ast.Expr, scope: *Scope) Error!ExprResult(ir.Expr) {
        const node = cond orelse return Error.Incomplete;

        var result = try self.analyseExpr(node, scope);
        _ = try self.rejectNoreturn(node, &result, "the condition of an 'if'", .{});

        if (result.type != .bool and result.type != .unknown) {
            try self.diagnostics.err(
                node.node.trimmedSpan(),
                "invalid condition type, expected '{f}', got '{f}'",
                .{ @as(Type, .bool), result.type },
            );
        }

        return result;
    }

    /// Subject of `switch` (statement or expression).
    fn analyseSwitchSubject(self: *Sema, subject: ?ast.Expr, scope: *Scope) Error!ExprResult(ir.Expr) {
        const node = subject orelse return Error.Incomplete;

        var result = try self.analyseExpr(node, scope);
        _ = try self.rejectNoreturn(node, &result, "the subject of a 'switch'", .{});

        return result;
    }

    /// A braced block of statements with a scope of its own.
    fn analyseBlock(
        self: *Sema,
        node: *const cst.Node,
        stmts: ast.Statements,
        parent: *Scope,
    ) Error!ir.StatementBlock {
        const block_scope = try self.createScope(parent, node);

        return .{
            .scope = block_scope,
            .statements = try self.analyseStatements(stmts, block_scope),
        };
    }

    /// Registers one `switch` case (statement or expression) in `cases` / `else_slot`.
    /// A pattern is a list of literals, or `else`. Bad patterns are reported and skipped.
    fn registerCase(
        self: *Sema,
        cases: anytype,
        else_slot: anytype,
        pattern: anytype,
        subject_type: Type,
        payload: anytype,
    ) Error!void {
        switch (pattern.classify()) {
            .expr => |exprs| {
                var it = exprs.iter();
                while (it.next()) |expr| {
                    const value = try skipIncomplete(self.assertLiteral(expr, subject_type)) orelse continue;

                    if (cases.contains(value)) {
                        try self.diagnostics.err(
                            expr.node.trimmedSpan(),
                            "duplicate case '{f}': an earlier case already handles this value",
                            .{value},
                        );
                        continue;
                    }

                    try cases.put(self.arena.allocator(), value, payload);
                }
            },
            .@"else" => |token| {
                if (else_slot.* != null) {
                    try self.diagnostics.err(
                        token.span,
                        "duplicate 'else' case: a switch can have only one",
                        .{},
                    );
                    return;
                }

                else_slot.* = payload;
            },
        }
    }

    // ------------------------------------------------------------------------------------------
    // Tasks and groups
    // ------------------------------------------------------------------------------------------

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
            .desc = stringAttribute(&attributes_result.attributes, .desc),
            .envs = envs,
            .cwd = stringAttribute(&attributes_result.attributes, .cwd),
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
            try self.reportInactive(task.node.trimmedSpan(), &attributes_result);
        }

        return ptr;
    }

    fn analyseTaskBody(self: *Sema, target: *ir.Task) Error!void {
        const alloc = self.arena.allocator();

        const dependencies = blk: {
            const in_deps = target.st_ref.dependencies orelse break :blk &.{};
            var dependencies: std.ArrayList(ir.TaskCall) = .empty;

            var it = in_deps.iter();

            while (it.next()) |dep| {
                const call = try skipIncomplete(self.analyseTaskCall(dep, target.scope)) orelse continue;
                try dependencies.append(alloc, call);
            }

            break :blk try dependencies.toOwnedSlice(alloc);
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
        const alloc = self.arena.allocator();

        var attributes_result = try AttributesResolver.resolve(self, .group, group.attributes);
        defer attributes_result.deinit(alloc);

        const group_scope = try self.createScope(scope, group.node);

        const name: ?[]const u8 = if (group.name) |name_node|
            name_node.string() orelse return Error.Incomplete
        else
            null;

        const args = if (group.params) |params|
            try self.analyseParams(params, group_scope, true)
        else
            &.{};

        const ptr = try self.create(ir.Group, .{
            .name = name,
            .args = args,
            .decls = undefined,
            .tasks = undefined,
            .scope = group_scope,
            .desc = stringAttribute(&attributes_result.attributes, .desc),
            .cwd = stringAttribute(&attributes_result.attributes, .cwd),
        });

        var decls: std.ArrayList(*ir.Decl) = .empty;
        var tasks: std.ArrayList(*ir.Task) = .empty;

        // tasks of an anonymous group are visible from the enclosing scope
        const tasks_scope = if (group.name) |_| group_scope else scope;

        var it = group.body.iter();
        while (it.next()) |elem| {
            switch (elem) {
                .task => |task| {
                    const task_ptr = try skipIncomplete(
                        self.analyseTask(task, group_scope, tasks_scope),
                    ) orelse continue;

                    task_ptr.group = ptr;

                    try tasks.append(alloc, task_ptr);
                },
                .binding => |binding| {
                    const decl = try skipIncomplete(
                        self.analyseBindingDecl(binding, group_scope),
                    ) orelse continue;

                    try decls.append(alloc, decl);
                },
            }
        }

        ptr.decls = try decls.toOwnedSlice(alloc);
        ptr.tasks = try tasks.toOwnedSlice(alloc);

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
            try self.reportInactive(group.node.trimmedSpan(), &attributes_result);
        }

        return ptr;
    }

    fn analyseParams(self: *Sema, params: ast.Parameters, scope: *Scope, group: bool) Error![]*ir.Argument {
        const ArgPhase = enum {
            const Self = @This();
            positional,
            named_required,
            named_optional,

            /// Parameters must come in this order: positional, named required, named optional.
            fn validate(
                sema: *Sema,
                span: Span,
                name: []const u8,
                phase: *Self,
                named: bool,
                optional: bool,
            ) !bool {
                const class: Self = blk: {
                    if (named == false) {
                        if (optional) {
                            try sema.diagnostics.err(
                                span,
                                "positional parameter '{s}' cannot have a default value: remove the default, or enable a long/short name to make it a named parameter",
                                .{name},
                            );
                            return false;
                        }
                        break :blk .positional;
                    }
                    break :blk if (optional) .named_optional else .named_required;
                };

                if (phase.* != .positional and class == .positional) {
                    try sema.diagnostics.err(
                        span,
                        "positional parameter '{s}' cannot follow a named parameter: move it before all named parameters",
                        .{name},
                    );
                    return false;
                }

                if (phase.* == .named_optional and class == .named_required) {
                    try sema.diagnostics.err(
                        span,
                        "required parameter '{s}' cannot follow an optional parameter: move it before the optional ones",
                        .{name},
                    );
                    return false;
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

            var attributes = try AttributesResolver.resolveAssertNoPlatform(
                self,
                .{ .argument = param_type },
                param.attributes,
            );
            defer attributes.deinit(self.arena.allocator());

            const name_required = group or param_type.isNamedOnly();

            const default: ?runtime.Value = blk: {
                if (param_type == .flag) {
                    if (param.default) |def| {
                        try self.diagnostics.err(
                            def.node.trimmedSpan(),
                            "flag parameter '{s}' is 'false' by default and cannot have an explicit default value",
                            .{name},
                        );
                    }
                    break :blk .{ .bool = false };
                }

                if (param.default) |def|
                    break :blk try self.assertLiteral(def, param_type.typeOf());

                break :blk null;
            };

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

            const desc = stringAttribute(&attributes, .desc);
            const pattern = stringAttribute(&attributes, .pattern);
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
                            "parameter '{s}' of a group must be named: groups pass their parameters by name, so enable a long and/or short name",
                            .{name},
                        );
                        continue;
                    }

                    if (name_required) {
                        try self.diagnostics.err(
                            param.node.trimmedSpan(),
                            "parameter '{s}' of type '{f}' must be named: enable a long and/or short name for it",
                            .{ name, param_type },
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
                name,
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

    /// Default values and `switch` patterns must be literals. `expected_type` may be `unknown`
    /// (the subject of a switch inside a lambda template), then any literal is accepted.
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
                    "expected a literal of type '{f}', found a '{t}' expression: only literals are allowed here",
                    .{ expected_type, tag },
                );
                return Error.Incomplete;
            },
        };

        // an `unknown` expectation (the subject of a switch inside a lambda template, for
        // example) accepts any literal: there is nothing to compare it with
        if (expected_type != .unknown and expected_type != actual_type) {
            try self.diagnostics.err(
                expr.node.trimmedSpan(),
                "type mismatch: expected a literal of type '{f}', got '{t}'",
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
                const item_expected: Type = if (expected_type == .list)
                    expected_type.list.*
                else
                    .unknown;

                var items: std.ArrayList(runtime.Value) = .empty;
                var failed = false;

                var it = list.iter();
                while (it.next()) |item| {
                    // a bad item has already been reported by its own check
                    const value = try skipIncomplete(self.assertLiteral(item, item_expected)) orelse {
                        failed = true;
                        continue;
                    };
                    try items.append(self.arena.allocator(), value);
                }

                if (failed) return Error.Incomplete;

                return .{
                    .list = .{
                        .items = try items.toOwnedSlice(self.arena.allocator()),
                        .items_type = try self.create(Type, expected_type),
                    },
                };
            },
            .string => |string| .{
                .string = if (string.lit) |token|
                    token.lexeme
                else
                    "",
            },
            else => unreachable,
        };
    }

    // ------------------------------------------------------------------------------------------
    // Statements
    // ------------------------------------------------------------------------------------------

    fn analyseBindingDecl(self: *Sema, binding: ast.BindingDecl, scope: *Scope) Error!*ir.Decl {
        if (binding.attributes) |attrs| {
            try self.diagnostics.err(
                attrs.node.trimmedSpan(),
                "attributes are not supported on bindings",
                .{},
            );
        }

        const name: ?[]const u8 = blk: {
            const name = binding.name.string() orelse return Error.Incomplete;
            if (std.mem.eql(u8, name, "_")) {
                break :blk null;
            }

            break :blk name;
        };

        const value_node = binding.value orelse return Error.Incomplete;

        // `analyseExpr` is the strict entry point: a value whose type is only partly known
        // (`list := []`) cannot be bound, there is nothing to give it its element type
        var value = try self.analyseExpr(value_node, scope);

        // the binding is still defined (with an `unknown` type), so its uses do not cascade
        _ = try self.rejectNoreturn(value_node, &value, "the value of a binding", .{});

        const ptr = try self.create(ir.Decl, .{
            .name = name,
            .value = value.expr,
            .type = value.type,
            .scope = scope,
            .is_static = value.is_static,
        });

        if (name) |n| {
            try self.defineSymbol(scope, .{
                .name = n,
                .span = binding.node.trimmedSpan(),
                .origin = .{
                    .binding = ptr,
                },
            });
        }

        return ptr;
    }

    fn analyseStatements(self: *Sema, stmts: ast.Statements, scope: *Scope) Error![]ir.Statement {
        var out: std.ArrayList(ir.Statement) = .empty;

        var it = stmts.iter();

        while (it.next()) |stmt| {
            const result = try skipIncomplete(self.analyseStatement(stmt, scope)) orelse continue;
            try out.append(self.arena.allocator(), result);
        }

        return try out.toOwnedSlice(self.arena.allocator());
    }

    fn analyseStatement(self: *Sema, stmt: ast.Statement, scope: *Scope) Error!ir.Statement {
        return switch (stmt.classify()) {
            .binding => |binding| .{
                .decl = try self.analyseBindingDecl(binding, scope),
            },
            .process => |proc| {
                const attributes = try AttributesResolver.resolveAssertNoPlatform(
                    self,
                    .process_stmt,
                    proc.attributes,
                );

                const nofail = attributes.contains(.nofail);
                const noecho = if (attributes.getAssertOne(.noecho)) |noecho|
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
            .@"for" => |for_stmt| .{
                .for_stmt = try self.analyseForStmt(for_stmt, scope),
            },
            .@"if" => |if_stmt| .{
                .if_stmt = try self.analyseIfStmt(if_stmt, scope),
            },
            .@"switch" => |switch_stmt| .{
                .switch_stmt = try self.analyseSwitchStmt(switch_stmt, scope),
            },
            .expr => |inner| {
                const expr = inner orelse return Error.Incomplete;
                const result = try self.analyseExpr(expr, scope);

                // `noreturn` is fine as a statement (`break`, `continue`, `@error(..)`), and
                // `unknown` says nothing about the value; whoever produced it already reported why
                if (result.type != .void and result.type != .noreturn and result.type != .unknown) {
                    try self.diagnostics.err(
                        expr.node.trimmedSpan(),
                        "unused value of type '{f}': bind it to '_' (`_ := ...`) if discarding it is intended",
                        .{result.type},
                    );
                }

                return .{ .expr = result.expr };
            },
        };
    }

    fn analyseSwitchStmt(self: *Sema, switch_stmt: ast.SwitchStmt, scope: *Scope) Error!ir.SwitchStmt {
        const subject = try self.analyseSwitchSubject(switch_stmt.subject, scope);

        var cases: ir.SwitchStmt.CasesStorage = .empty;
        var else_case: ?ir.StatementBlock = null;

        var it = switch_stmt.body.iter();
        while (it.next()) |case| {
            const block = try self.analyseBlock(case.node, case.body, scope);

            try self.registerCase(&cases, &else_case, case.pattern, subject.type, block);
        }

        return .{
            .subject = subject.expr,
            .cases = cases,
            .else_case = else_case,
        };
    }

    fn analyseIfStmt(self: *Sema, if_stmt: ast.IfStmt, scope: *Scope) Error!ir.IfStmt {
        const cond = try self.analyseCondition(if_stmt.cond, scope);

        const then_block = try self.analyseBlock(if_stmt.then.node, if_stmt.then, scope);

        const else_block: ?ir.StatementBlock = if (if_stmt.@"else") |in_else|
            try self.analyseBlock(in_else.node, in_else, scope)
        else
            null;

        return .{
            .cond = cond.expr,
            .then = then_block,
            .else_ = else_block,
        };
    }

    const ForHeader = struct {
        scope: *Scope,
        subjects: []ir.Expr,
        captures: []?*ir.Capture,
        is_static: bool,
    };

    /// The part `for (subjects) |captures|` shared by the statement and the expression form:
    /// analyses the subjects (in the enclosing scope) and defines the captures (in a new scope).
    /// Works on `ast.ForStmt` and `ast.ForExpr`.
    fn analyseForHeader(self: *Sema, for_node: anytype, scope: *Scope) Error!ForHeader {
        const alloc = self.arena.allocator();

        const in_subjects = try for_node.subjects.collect(alloc);
        const in_captures = try for_node.captures.collect(alloc);

        if (in_subjects.len != in_captures.len) {
            try self.diagnostics.err(
                for_node.captures.node.trimmedSpan(),
                "'for' needs exactly one capture per subject: got {} capture(s) for {} subject(s)",
                .{ in_captures.len, in_subjects.len },
            );
        }
        const valid_pairs_count = @min(in_subjects.len, in_captures.len);

        var subjects: std.ArrayList(ir.Expr) = try .initCapacity(alloc, valid_pairs_count);
        var captures: std.ArrayList(?*ir.Capture) = try .initCapacity(alloc, valid_pairs_count);

        var is_static = true;

        const for_scope = try self.createScope(scope, for_node.node);

        for (in_subjects[0..valid_pairs_count], in_captures[0..valid_pairs_count]) |s, c| {
            const subject = s.unwrap() orelse continue;
            const capture = c.unwrap() orelse continue;

            var result = try skipIncomplete(self.analyseExpr(subject, scope)) orelse continue;
            _ = try self.rejectNoreturn(subject, &result, "a 'for' subject", .{});

            if (result.is_static == false)
                is_static = false;

            const capture_type: Type = switch (result.type) {
                .list => |items_type| items_type.*,
                .unknown => .unknown,
                else => |t| blk: {
                    try self.diagnostics.err(
                        subject.node.trimmedSpan(),
                        "cannot iterate over a value of type '{f}': 'for' needs a list",
                        .{t},
                    );
                    break :blk .unknown;
                },
            };

            switch (capture) {
                .name => |name| {
                    const capture_ident = name.string() orelse continue;
                    const ptr = try self.create(ir.Capture, .{
                        .name = capture_ident,
                        .type = capture_type,
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
                .blank => {
                    captures.appendAssumeCapacity(null);
                },
            }
            subjects.appendAssumeCapacity(result.expr);
        }

        return .{
            .scope = for_scope,
            .subjects = try subjects.toOwnedSlice(alloc),
            .captures = try captures.toOwnedSlice(alloc),
            .is_static = is_static,
        };
    }

    fn analyseForStmt(self: *Sema, for_stmt: ast.ForStmt, scope: *Scope) Error!ir.ForStmt {
        const header = try self.analyseForHeader(for_stmt, scope);

        // only the body is inside the loop: a `break` in a subject belongs to an enclosing loop
        self.loop_depth += 1;
        defer self.loop_depth -= 1;

        const body = try self.analyseStatements(for_stmt.body, header.scope);

        return .{
            .subjects = header.subjects,
            .captures = header.captures,
            .body = .{
                .scope = header.scope,
                .statements = body,
            },
        };
    }

    // ------------------------------------------------------------------------------------------
    // Lambdas
    // ------------------------------------------------------------------------------------------

    fn getLambdaInstance(
        self: *Sema,
        template: *const @"type".LambdaTemplate,
        types: []const Type,
    ) !*const ir.LambdaInstance {
        // instances exist only for concrete types; callers skip the call when something is unknown
        for (types) |t| std.debug.assert(!t.containsUnknown());

        const key: ir.LambdaInstance.Key = .{
            .template = template,
            .params = types,
        };
        {
            const gop = try self.lambda_instances.getOrPut(self.arena.allocator(), key);

            if (gop.found_existing) {
                switch (gop.value_ptr.*) {
                    .failed => return Error.Incomplete,
                    .in_progress => {
                        try self.diagnostics.err(
                            template.template.node.trimmedSpan(),
                            "recursive lambda: this lambda is called again while it is still being analysed with the same argument types, recursion is not supported",
                            .{},
                        );
                        return Error.Incomplete;
                    },
                    .ok => |out| return out,
                }
            }
            // create instance

            gop.value_ptr.* = .in_progress;
        }
        errdefer self.lambda_instances.getPtr(key).?.* = .failed;

        const prev_loop_depth = self.loop_depth;
        self.loop_depth = 0;
        defer self.loop_depth = prev_loop_depth;

        // the body of an instance is real code (concrete parameter types), even when the instance
        // is requested from inside another lambda's template
        const prev_in_template = self.in_template;
        self.in_template = false;
        defer self.in_template = prev_in_template;

        const lambda_scope = try self.createScope(template.parent_scope, null);

        var it = template.template.params.iter();

        const captures = try self.arena.allocator().alloc(
            ir.Capture,
            types.len,
        );

        for (types, captures) |arg, *out| {
            const r_param = it.next() orelse unreachable; // should be checked already
            const param = r_param.unwrap() orelse continue;
            out.* = .{
                .name = param.name.string().?,
                .type = arg,
            };

            try lambda_scope.define(self.arena.allocator(), .{
                .name = out.name,
                .span = template.template.node.trimmedSpan(),
                .origin = .{ .capture = out },
            });
        }

        const body = try self.analyseExpr(
            template.template.body orelse return Error.Incomplete,
            lambda_scope,
        );

        if (body.type == .lambda) {
            try self.diagnostics.err(
                template.template.node.trimmedSpan(),
                "a lambda cannot return another lambda",
                .{},
            );
            return Error.Incomplete;
        }

        const instance = try self.create(ir.LambdaInstance, .{
            .template = template,
            .params = captures,
            .body = body.expr,
            .return_type = body.type,
            .scope = lambda_scope,
            .is_static = body.is_static,
        });

        self.lambda_instances.getPtr(key).?.* = .{ .ok = instance };

        return instance;
    }

    fn lambdaParamCount(template: *const @"type".LambdaTemplate) usize {
        var count: usize = 0;
        var it = template.template.params.iter();
        while (it.next()) |_| count += 1;
        return count;
    }

    fn allKnown(types: []const Type) bool {
        for (types) |t| {
            if (t.containsUnknown()) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------------------------------

    fn ExprResult(comptime ExprT: type) type {
        return struct {
            expr: ExprT,
            type: Type,
            is_static: bool,
        };
    }

    /// The result of an expression nothing is known about: a call that could not be analysed,
    /// or a lambda call inside a template. Whatever consumes it stays silent.
    fn unknownResult() ExprResult(ir.Expr) {
        return .{
            .expr = ir.Expr.unknown,
            .type = .unknown,
            .is_static = true,
        };
    }

    /// Strict entry point. Use it wherever a value is consumed (bindings, conditions, operands,
    /// arguments of lambda calls, ...): the type of what is consumed must be fully known.
    ///
    /// The only expressions that can be incomplete are those containing an empty list literal,
    /// whose element type has to come from somewhere else. Forms that can supply it (list items,
    /// if/switch branches, for bodies, builtin and task call arguments) use `analyseExprPartial`
    /// and complete the type themselves.
    fn analyseExpr(self: *Sema, expr: ast.Expr, scope: *Scope) Error!ExprResult(ir.Expr) {
        var result = try self.analyseExprPartial(expr, scope);
        try self.requireComplete(expr, &result);
        return result;
    }

    /// Fails (once) when the type is only partly known, unless we are inside a lambda template,
    /// where everything depends on `unknown` parameters. The type then becomes `unknown`, so
    /// nothing downstream reports the same problem again.
    fn requireComplete(self: *Sema, expr: ast.Expr, result: *ExprResult(ir.Expr)) Error!void {
        if (self.in_template or !result.type.isPartial()) return;

        try self.diagnostics.err(
            expr.node.trimmedSpan(),
            "cannot infer the type of this expression, '{f}' has an unknown element type (an empty list needs a context that tells its type)",
            .{result.type},
        );

        result.type = .unknown;
    }

    /// Makes `result` carry the most informative type of its own and `target`, and rewrites the
    /// IR to match (see `retypeExpr`). Meant for places where a type is learned from context:
    /// the other branch of an `if`, the parameter of a call, the other items of a list.
    fn coerce(result: *ExprResult(ir.Expr), target: Type) void {
        const unified = Type.unify(result.type, target) orelse return;
        if (Type.same(unified, result.type)) return;

        result.expr = retypeExpr(result.expr, unified);
        result.type = unified;
    }

    /// Gives the empty list literals reachable through `expr` the element type `target`
    /// prescribes, so the interpreter never sees an `unknown` type. Only forms that pass a
    /// value through can contain such a literal: a list literal, `if`, `switch` and `for`.
    /// Everything else already has a complete type.
    fn retypeExpr(expr: ir.Expr, target: Type) ir.Expr {
        switch (expr) {
            .list => |list| {
                const items_type = switch (target) {
                    .list => |t| t.*,
                    else => return expr,
                };

                for (list.items) |item| {
                    item.expr.* = retypeExpr(item.expr.*, if (item.is_spread) target else items_type);
                }

                var out = expr;
                out.list.items_type = items_type;
                return out;
            },
            .if_expr => |ptr| {
                ptr.type = target;
                ptr.then = retypeExpr(ptr.then, target);
                ptr.@"else" = retypeExpr(ptr.@"else", target);
                return expr;
            },
            .switch_expr => |ptr| {
                ptr.type = target;
                ptr.else_case = retypeExpr(ptr.else_case, target);

                var it = ptr.cases.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.* = retypeExpr(entry.value_ptr.*, target);
                }
                return expr;
            },
            .for_expr => |ptr| {
                const items_type = switch (target) {
                    .list => |t| t.*,
                    else => return expr,
                };

                ptr.type = items_type;
                ptr.body = retypeExpr(ptr.body, items_type);
                return expr;
            },
            else => return expr,
        }
    }

    /// Like `analyseExpr`, but the type may be only partly known. The caller must complete it
    /// (`coerce`) or reject it (`requireComplete`).
    fn analyseExprPartial(self: *Sema, expr: ast.Expr, scope: *Scope) Error!ExprResult(ir.Expr) {
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
                    try self.unknownValue(token.span, token.lexeme);
                    return Error.Incomplete;
                };

                const symbol_type = symbol.origin.valueType() orelse unreachable;

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
                var broken = false;

                // `[]` has no items to learn the element type from, it stays `unknown` until
                // something around the list supplies it
                var items_type: Type = .unknown;

                while (it.next()) |item| {
                    var result = try skipIncomplete(self.analyseExprPartial(item, scope)) orelse {
                        broken = true;
                        continue;
                    };

                    // `[1, break]`: the list itself could never be produced
                    if (try self.rejectNoreturn(item, &result, "a list item", .{})) {
                        broken = true;
                        continue;
                    }

                    items_type = Type.unify(items_type, result.type) orelse blk: {
                        // BUG: multiple diagnostics
                        try self.diagnostics.err(
                            it.lastSpan(),
                            "list items must all have the same type: expected '{f}', got '{f}'",
                            .{ items_type, result.type },
                        );
                        break :blk items_type;
                    };

                    if (result.is_static == false)
                        is_static = false;

                    try items.append(self.arena.allocator(), .{
                        .expr = try self.create(ir.Expr, result.expr),
                        .is_spread = false,
                    });
                }

                // an item failed and nothing else is known: do not report the missing type on top
                if (broken and items_type == .unknown)
                    return unknownResult();

                const final_items = try items.toOwnedSlice(self.arena.allocator());

                // `[[], [1]]`: the first item learns its type from the second one
                for (final_items) |item| {
                    item.expr.* = retypeExpr(item.expr.*, items_type);
                }

                return .{
                    .expr = .{
                        .list = .{
                            .items = final_items,
                            .items_type = items_type,
                        },
                    },
                    .type = .{ .list = try self.create(Type, items_type) },
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
                try self.analyseExprPartial(node, scope)
            else
                Error.Incomplete,
            .binary => |binary_expr| {
                const left_node = binary_expr.left orelse return Error.Incomplete;
                var left = try self.analyseExpr(left_node, scope);

                const right_node = binary_expr.right orelse return Error.Incomplete;
                var right = try self.analyseExpr(right_node, scope);

                const op_token = binary_expr.op orelse return Error.Incomplete;

                // `1 + break`: the operation can never be evaluated, whichever side diverges
                _ = try self.rejectNoreturn(left_node, &left, "an operand of '{s}'", .{op_token.lexeme});
                _ = try self.rejectNoreturn(right_node, &right, "an operand of '{s}'", .{op_token.lexeme});

                const op: ir.BinaryOp = switch (op_token.kind) {
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
                };

                const binary_result = binary.binaryResultType(op, left.type, right.type) catch |err| {
                    switch (err) {
                        error.TypeMismatch => {
                            try self.diagnostics.err(
                                expr.node.trimmedSpan(),
                                "cannot apply '{s}' to '{f}' and '{f}'",
                                .{ op_token.lexeme, left.type, right.type },
                            );
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
                const operand_node = unary_expr.operand orelse return Error.Incomplete;
                var operand = try self.analyseExpr(operand_node, scope);

                const op_token = unary_expr.op orelse return Error.Incomplete;

                _ = try self.rejectNoreturn(operand_node, &operand, "the operand of '{s}'", .{op_token.lexeme});

                const op: ir.UnaryOp = switch (op_token.kind) {
                    .not_kw => .not_op,
                    .minus => .negate,
                    else => unreachable,
                };

                const result_type: Type = switch (op) {
                    .not_op => switch (operand.type) {
                        inline .bool, .unknown => operand.type,
                        else => |t| err: {
                            try self.diagnostics.err(
                                expr.node.trimmedSpan(),
                                "cannot apply 'not' to '{f}', expected 'bool'",
                                .{t},
                            );
                            break :err .unknown;
                        },
                    },
                    .negate => switch (operand.type) {
                        inline .number, .unknown => operand.type,
                        else => |t| err: {
                            try self.diagnostics.err(
                                expr.node.trimmedSpan(),
                                "cannot negate '{f}', expected 'number'",
                                .{t},
                            );
                            break :err .unknown;
                        },
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
                std.debug.assert(scope.child(lambda.node) == null);
                var it = lambda.params.iter();

                const template_scope = try self.createScope(
                    scope,
                    lambda.node,
                );

                while (it.next()) |r_param| switch (r_param) {
                    .value => |param| {
                        const param_name = param.name.string() orelse continue;

                        const capture = try self.create(
                            ir.Capture,
                            .{
                                .name = param_name,
                                .type = .unknown,
                            },
                        );

                        try self.defineSymbol(
                            template_scope,
                            .{
                                .name = param_name,
                                .span = param.name.node.trimmedSpan(),
                                .origin = .{ .capture = capture },
                            },
                        );
                    },
                    else => continue,
                };

                {
                    // The body is analysed once here, with `unknown` parameters. Anything that
                    // does not depend on the parameter types is reported now; the IR is dropped.
                    const prev_in_template = self.in_template;
                    self.in_template = true;
                    defer self.in_template = prev_in_template;

                    _ = try self.analyseExprPartial(
                        lambda.body orelse return Error.Incomplete,
                        template_scope,
                    );
                }

                const template = try self.create(@"type".LambdaTemplate, .{
                    .template = lambda,
                    .parent_scope = scope,
                });

                return .{
                    .expr = .{
                        .lambda = .{
                            .template = template,
                            .resolved = null,
                        },
                    },
                    .type = .{ .lambda = template },
                    .is_static = false,
                };
            },
            .lambda_call => |lambda_call| {
                const name = lambda_call.name.string() orelse return Error.Incomplete;
                const in_args = try lambda_call.args.collect(self.arena.allocator());

                // Who is called? `null`: nothing can be known (already reported, or `unknown`).
                const callee: ?*const @"type".LambdaTemplate = blk: {
                    const symbol = scope.resolve(name, .variable) orelse {
                        try self.unknownValue(lambda_call.name.node.trimmedSpan(), name);
                        break :blk null;
                    };

                    break :blk switch (symbol.origin.assertValueType()) {
                        .lambda => |lambda| lambda,
                        .unknown => null,
                        else => |t| err: {
                            try self.diagnostics.err(
                                lambda_call.name.node.trimmedSpan(),
                                "'{s}' has type '{f}' and cannot be called: only lambdas can be called",
                                .{ name, t },
                            );
                            break :err null;
                        },
                    };
                };

                const lambda = callee orelse {
                    // there is nothing to instantiate, but the arguments are still code
                    for (in_args) |r_arg| {
                        const arg = r_arg.unwrap() orelse continue;
                        _ = try skipIncomplete(self.analyseExpr(arg, scope));
                    }
                    return unknownResult();
                };

                const params_count = lambdaParamCount(lambda);

                if (in_args.len != params_count) {
                    try self.diagnostics.err(
                        lambda_call.args.node.trimmedSpan(),
                        "lambda '{s}' takes {} argument(s), got {}",
                        .{ name, params_count, in_args.len },
                    );
                    return unknownResult();
                }

                var valid = true;
                const types = try self.arena.allocator().alloc(Type, in_args.len);
                const resolved_args = try self.arena.allocator().alloc(ir.Expr, in_args.len);

                for (in_args, 0..) |r_arg, idx| {
                    const arg = r_arg.unwrap() orelse {
                        valid = false;
                        types[idx] = .unknown;
                        resolved_args[idx] = ir.Expr.unknown; // won't be used
                        continue;
                    };

                    var result = try self.analyseExpr(arg, scope);
                    _ = try self.rejectNoreturn(arg, &result, "an argument of lambda '{s}'", .{name});

                    types[idx] = result.type;
                    resolved_args[idx] = result.expr;
                }

                if (!valid) return Error.Incomplete;

                // A lambda is only instantiated for concrete types. With an `unknown` argument
                // (inside a template, or after an error) there is no instance to analyse, and
                // the result is unknown as well.
                if (!allKnown(types)) return unknownResult();

                try self.diagnostics.pushRelated(
                    lambda_call.node.trimmedSpan(),
                    "<- from lambda call",
                    .{},
                );
                defer self.diagnostics.popRelated();

                const resolved_lambda = try self.getLambdaInstance(lambda, types);

                //TODO: adjust is_static
                const ptr = try self.create(ir.LambdaCall, .{
                    .lambda = resolved_lambda,
                    .args = resolved_args,
                });

                return .{
                    .expr = .{ .lambda_call = ptr },
                    .type = resolved_lambda.return_type,
                    .is_static = false,
                };
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
                            fallback.node.trimmedSpan(),
                            "a process with 'nofail' cannot have a fallback: failures are ignored, so the fallback would never run",
                            .{},
                        );
                    }

                    const fallback_node = fallback.expr orelse return Error.Incomplete;
                    const fallback_expr = try self.analyseExpr(fallback_node, scope);

                    result_type = Type.unify(result_type, fallback_expr.type) orelse rt: {
                        try self.diagnostics.err(
                            fallback_node.node.trimmedSpan(),
                            "invalid fallback type: a process yields 'string', got '{f}'",
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
                    .type = result_type,
                    .is_static = false,
                };
            },
            inline .@"continue", .@"break" => |token, tag| {
                if (self.loop_depth == 0) {
                    try self.diagnostics.err(
                        token.span,
                        "'{t}' outside of a loop",
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
        const header = try self.analyseForHeader(for_expr, scope);

        // only the body is inside the loop: a `break` in a subject belongs to an enclosing loop
        self.loop_depth += 1;
        defer self.loop_depth -= 1;

        // the body may be an incomplete list too (`for(xs) |x| []`), which the context of the
        // whole `for` can complete, so it is analysed as partial
        const body = try self.analyseExprPartial(
            for_expr.body orelse return Error.Incomplete,
            header.scope,
        );

        // a `for` expression produces a list of what its body produces; a diverging body
        // (`for(xs) |x| break`) says nothing about the element type
        const items_type: Type = if (body.type == .noreturn) .unknown else body.type;

        return .{
            .expr = .{
                .subjects = header.subjects,
                .captures = header.captures,
                .scope = header.scope,
                .body = body.expr,
                .type = items_type,
            },
            .is_static = header.is_static and body.is_static,
            .type = .{ .list = try self.create(Type, items_type) },
        };
    }

    fn analyseIfExpr(self: *Sema, if_expr: ast.IfExpr, scope: *Scope) Error!ExprResult(ir.IfExpr) {
        const cond = try self.analyseCondition(if_expr.cond, scope);

        // a diverging branch (`if (c) break else 1`) is fine, it just does not constrain the type
        var then = try self.analyseExprPartial(
            if_expr.then orelse return Error.Incomplete,
            scope,
        );

        const else_node = if_expr.@"else" orelse return Error.Incomplete;
        var @"else" = try self.analyseExprPartial(else_node, scope);

        const result_type = Type.unify(then.type, @"else".type) orelse {
            try self.diagnostics.err(
                else_node.node.trimmedSpan(),
                "'if' branches must have the same type: 'then' is '{f}', 'else' is '{f}'",
                .{ then.type, @"else".type },
            );
            return Error.Incomplete;
        };

        // `if (c) [1, 2] else []`: both branches end up with the type the two together describe
        coerce(&then, result_type);
        coerce(&@"else", result_type);

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
        const subject = try self.analyseSwitchSubject(switch_expr.subject, scope);

        var is_static = subject.is_static;

        var cases: ir.SwitchExpr.CasesStorage = .empty;
        var else_case: ?ir.Expr = null;
        var result_type: Type = .noreturn;

        // First pass: analyse every branch and find the type they have in common.
        var branches: std.ArrayList(ExprResult(ir.Expr)) = .empty;

        var b_it = switch_expr.body.iter();
        while (b_it.next()) |case| {
            const case_node = case.expr orelse return Error.Incomplete;
            const case_result = try self.analyseExprPartial(case_node, scope);

            if (case_result.is_static == false)
                is_static = false;

            result_type = Type.unify(result_type, case_result.type) orelse blk: {
                try self.diagnostics.err(
                    case_node.node.trimmedSpan(),
                    "switch branches must have the same type: expected '{f}', got '{f}'",
                    .{ result_type, case_result.type },
                );

                break :blk result_type;
            };

            try branches.append(self.arena.allocator(), case_result);
        }

        // Second pass: every branch takes the common type, then the patterns are registered.
        var p_it = switch_expr.body.iter();
        var idx: usize = 0;
        while (p_it.next()) |case| : (idx += 1) {
            const branch_expr = retypeExpr(branches.items[idx].expr, result_type);

            try self.registerCase(&cases, &else_case, case.pattern, subject.type, branch_expr);
        }

        const final_else_case = else_case orelse {
            try self.diagnostics.err(
                switch_expr.body.node.trimmedSpan(),
                "a switch expression needs an 'else' case: it has to produce a value for every subject",
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

    /// "int, string, list<number>": the argument types of a call, for diagnostics.
    fn describeArgTypes(allocator: std.mem.Allocator, results: []const ExprResult(ir.Expr)) ![]const u8 {
        var w: std.Io.Writer.Allocating = .init(allocator);

        for (results, 0..) |result, idx| {
            if (idx != 0) try w.writer.writeAll(", ");
            try w.writer.print("{f}", .{result.type});
        }

        return try w.toOwnedSlice();
    }

    fn analyseBuiltinCall(self: *Sema, builtin_call: ast.BuiltinCall, scope: *Scope) Error!ExprResult(ir.BuiltinCall) {
        const alloc = self.arena.allocator();

        const builtin_call_name = if (builtin_call.name) |name|
            name.lexeme
        else
            return Error.Incomplete;

        const in_args = try builtin_call.args.collect(alloc);

        const nodes = try alloc.alloc(ast.Expr, in_args.len);
        const results = try alloc.alloc(ExprResult(ir.Expr), in_args.len);
        const in_types = try alloc.alloc(functions.InArg, in_args.len);

        // Every argument is analysed exactly once, and may be incomplete (`@replace([], 1, 2)`):
        // the overload tells what it should be.
        for (in_args, 0..) |arg_result, idx| switch (arg_result) {
            .value => |arg| {
                nodes[idx] = arg;
                results[idx] = try self.analyseExprPartial(arg, scope);

                _ = try self.rejectNoreturn(arg, &results[idx], "an argument of '{s}'", .{builtin_call_name});

                in_types[idx] = switch (results[idx].type) {
                    .lambda => |lambda| .{ .lambda = .{ .params = lambdaParamCount(lambda) } },
                    else => |t| .{ .value = .{ .type = t } },
                };
            },
            .missing => |span| {
                //TODO: the parser may already report this one, drop it then
                try self.diagnostics.err(
                    span,
                    "incomplete argument in call to '{s}'",
                    .{builtin_call_name},
                );
                return Error.Incomplete;
            },
        };

        const resolved_function = functions.definitions.resolve(
            alloc,
            builtin_call_name,
            in_types,
        ) catch |err| switch (err) {
            functions.Error.UnknownFunction => {
                try self.diagnostics.err(
                    builtin_call.node.trimmedSpan(),
                    "unknown builtin function '{s}'",
                    .{builtin_call_name},
                );
                return Error.Incomplete;
            },
            functions.Error.InvalidArguments => {
                try self.diagnostics.err(
                    builtin_call.args.node.trimmedSpan(),
                    "'{s}' cannot be called with arguments ({s})",
                    .{ builtin_call_name, try describeArgTypes(alloc, results) },
                );
                return Error.Incomplete;
            },
            inline else => |tag| return @errorCast(tag),
        };

        const resolved_args = try alloc.alloc(ir.Expr, in_args.len);

        for (results, resolved_function.params, resolved_args, nodes) |*result, param, *out, node| {
            switch (param) {
                .value => |target| {
                    // the parameter says what an incomplete argument has to be
                    coerce(result, target);
                    try self.requireComplete(node, result);
                    out.* = result.expr;
                },
                .lambda => |expected| switch (result.type) {
                    .lambda => |template| {
                        var resolved: ?*const ir.LambdaInstance = null;

                        // Parameter types that nothing pinned down (an `unknown` list, inside a
                        // template) leave nothing to instantiate with
                        if (allKnown(expected.params)) {
                            try self.diagnostics.pushRelated(
                                node.node.trimmedSpan(),
                                "<- from lambda called here",
                                .{},
                            );
                            defer self.diagnostics.popRelated();

                            const instance = try self.getLambdaInstance(template, expected.params);

                            // TODO: consider if that's enough, or type compare is required too
                            if (Type.unify(instance.return_type, expected.return_type) == null) {
                                try self.diagnostics.err(
                                    template.template.body.?.node.trimmedSpan(),
                                    "invalid lambda result type for '{s}': expected '{f}', got '{f}'",
                                    .{ builtin_call_name, expected.return_type, instance.return_type },
                                );
                            }

                            resolved = instance;
                        }

                        out.* = .{
                            .lambda = .{
                                .template = template,
                                .resolved = resolved,
                            },
                        };
                    },
                    // an `unknown` value where a lambda is expected: it fits, nothing to instantiate
                    else => out.* = result.expr,
                },
            }
        }

        var result_type = resolved_function.return_type;

        var fallback: ?ir.Expr = null;

        if (builtin_call.fallback) |fb| {
            const fb_node = fb.expr orelse return Error.Incomplete;

            switch (resolved_function.return_type) {
                .result => |inner| {
                    const fb_result = try self.analyseExpr(fb_node, scope);

                    result_type = Type.unify(inner.*, fb_result.type) orelse blk: {
                        try self.diagnostics.err(
                            fb_node.node.trimmedSpan(),
                            "invalid fallback type for '{s}': expected '{f}', got '{f}'",
                            .{ builtin_call_name, inner.*, fb_result.type },
                        );
                        break :blk inner.*;
                    };
                    fallback = fb_result.expr;
                },
                // an overload that could not be told apart: nothing to check the fallback against
                .unknown => {
                    const fb_result = try self.analyseExpr(fb_node, scope);
                    fallback = fb_result.expr;
                },
                else => {
                    try self.diagnostics.err(
                        fb.node.trimmedSpan(),
                        "'{s}' cannot fail, so it does not take a fallback expression",
                        .{builtin_call_name},
                    );
                },
            }
        } else if (resolved_function.return_type == .result) {
            try self.diagnostics.err(
                builtin_call.node.trimmedSpan(),
                "'{s}' can fail and requires a fallback expression",
                .{builtin_call_name},
            );
        }

        return .{
            .expr = .{
                .function = resolved_function,
                .args = resolved_args,
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
                    var result = try self.analyseExpr(expr, scope);
                    _ = try self.rejectNoreturn(expr, &result, "an interpolated value", .{});

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

    // ------------------------------------------------------------------------------------------
    // Task calls
    // ------------------------------------------------------------------------------------------

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
        task_name: []const u8,
        task_call: ast.TaskCall,
    ) Error!void {
        if (args.contains(arg.name)) return;

        if (arg.default) |def| {
            try args.put(self.arena.allocator(), arg.name, .{ .default = def });
        } else {
            try self.diagnostics.err(
                task_call.node.trimmedSpan(),
                "missing argument for parameter '{s}' of task '{s}'",
                .{ arg.name, task_name },
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
                    try self.diagnostics.err(
                        span,
                        "task '{s}' has no parameter named '{s}'",
                        .{ task.name, name },
                    );
                    continue;
                };
            } else blk: {
                if (seen_named) {
                    try self.diagnostics.err(
                        span,
                        "positional argument cannot follow a named argument: move it before the named ones",
                        .{},
                    );
                    continue;
                }

                const idx = next_positional;
                next_positional += 1;

                if (idx >= task.args.len) {
                    try self.diagnostics.err(
                        span,
                        "too many positional arguments for task '{s}': got {}, it takes at most {}",
                        .{ task.name, idx + 1, task.args.len },
                    );
                    continue;
                }
                break :blk task.args[idx];
            };

            if (args.contains(param.name)) {
                try self.diagnostics.err(
                    span,
                    "argument '{s}' is passed more than once",
                    .{param.name},
                );
                continue;
            }

            // partial: the parameter type completes an empty list (`update([])`)
            var value = try self.analyseExprPartial(value_node, scope);
            _ = try self.rejectNoreturn(value_node, &value, "an argument of task '{s}'", .{task.name});

            const expected = param.type.typeOf();

            // Report the mismatch but still record the argument, so it is not
            // additionally reported as "missing".
            if (Type.unify(value.type, expected)) |unified| {
                coerce(&value, unified);
            } else {
                try self.diagnostics.err(
                    value_node.node.trimmedSpan(),
                    "invalid argument for parameter '{s}' of task '{s}': expected '{f}', got '{f}'",
                    .{ param.name, task.name, expected, value.type },
                );
            }

            try args.put(alloc, param.name, .{ .value = value.expr });
        }

        // Whatever the call did not supply: default or "missing".
        for (task.args) |param| try self.fillMissing(&args, param, task.name, task_call);

        if (!is_same_group_call) {
            if (task.group) |g| {
                for (g.args) |param| try self.fillMissing(&args, param, task.name, task_call);
            }
        }

        return .{
            .task = task,
            .args = args,
            .same_group = is_same_group_call,
        };
    }

    // ------------------------------------------------------------------------------------------
    // Symbols and allocation
    // ------------------------------------------------------------------------------------------

    fn defineSymbol(self: *Sema, scope: *Scope, symbol: Symbol) !void {
        const symbol_type = symbol.typeOf();

        const previous_symbol = switch (symbol_type) {
            .variable, .group => scope.resolve(symbol.name, symbol_type),
            .task => scope.resolveLocal(symbol.name, symbol_type),
        };

        if (previous_symbol) |prev| {
            try self.diagnostics.err(
                symbol.span,
                "{t} '{s}' is already defined",
                .{ symbol_type, symbol.name },
            );
            try self.diagnostics.hint(
                prev.span,
                "previous definition of {t} '{s}' is here",
                .{ symbol_type, symbol.name },
            );
            return;
        }

        try scope.define(self.arena.allocator(), symbol);
    }

    fn createScope(self: *Sema, parent: ?*Scope, node: ?*const cst.Node) !*Scope {
        const ptr = try self.arena.allocator().create(Scope);
        ptr.* = .init(parent);

        if (node) |n| if (parent) |p|
            try p.putChild(self.arena.allocator(), n, ptr);

        return ptr;
    }

    fn create(self: *Sema, comptime T: type, value: T) !*T {
        const ptr = try self.arena.allocator().create(T);
        ptr.* = value;
        return ptr;
    }
};

const CycleChecker = struct {
    const State = enum {
        unvisited,
        in_progress,
        done,
    };

    const StateMap = std.AutoHashMap(*ir.Task, State);

    fn checkCycles(self: *Sema, file: *ir.File) !void {
        var states: StateMap = .init(self.arena.allocator());
        defer states.deinit();

        var stack: std.ArrayList(*ir.Task) = .empty;
        defer stack.deinit(self.arena.allocator());

        for (file.tasks) |task| {
            const state = states.get(task) orelse .unvisited;
            if (state == .unvisited) {
                try visit(self, task, &states, &stack);
            }
        }

        for (file.groups) |group| {
            for (group.tasks) |task| {
                const state = states.get(task) orelse .unvisited;
                if (state == .unvisited) {
                    try visit(self, task, &states, &stack);
                }
            }
        }
    }

    fn visit(
        self: *Sema,
        task: *ir.Task,
        states: *StateMap,
        stack: *std.ArrayList(*ir.Task),
    ) !void {
        try states.put(task, .in_progress);
        try stack.append(self.arena.allocator(), task);

        for (task.dependecies) |dep| {
            const s = states.get(dep.task) orelse .unvisited;
            switch (s) {
                .in_progress => try reportCycle(self, task, dep.task, stack.items),
                .done => {},
                .unvisited => try visit(self, dep.task, states, stack),
            }
        }

        _ = stack.pop();
        try states.put(task, .done);
    }

    /// `task` depends on `target`, which is still being visited, so it is somewhere on `stack`:
    /// the cycle is everything from `target` to the top of the stack, and back to `target`.
    fn reportCycle(self: *Sema, task: *ir.Task, target: *ir.Task, stack: []const *ir.Task) !void {
        var w: std.Io.Writer.Allocating = .init(self.arena.allocator());

        const start = std.mem.indexOfScalar(*ir.Task, stack, target) orelse 0;
        for (stack[start..]) |member| {
            try writeTaskName(&w.writer, member);
            try w.writer.writeAll(" -> ");
        }
        try writeTaskName(&w.writer, target);

        try self.diagnostics.err(
            task.st_ref.dependencies.?.node.trimmedSpan(),
            "dependency cycle: {s}",
            .{try w.toOwnedSlice()},
        );
    }

    /// `name` or `group::name`.
    fn writeTaskName(w: *std.Io.Writer, task: *const ir.Task) !void {
        if (task.group) |g| if (g.name) |group_name|
            try w.print("{s}::", .{group_name});

        try w.writeAll(task.name);
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

        const def = attrib.definitions.get(name, target) orelse {
            try self.sema.diagnostics.err(
                attribute.node.trimmedSpan(),
                "unknown attribute '{s}', or it cannot be applied to this element",
                .{name},
            );
            return;
        };

        switch (def.kind) {
            .platform => {
                const pt = lib.enums.castEnum(def.type, platform.Tag) orelse unreachable;
                std.debug.assert(def.unique);

                if (attribute.value != null) {
                    try self.sema.diagnostics.err(
                        attribute.node.trimmedSpan(),
                        "platform attribute '{s}' does not take a value",
                        .{name},
                    );
                    return;
                }

                if (self.platforms.contains(pt)) {
                    try self.sema.diagnostics.err(
                        attribute.node.trimmedSpan(),
                        "duplicate platform attribute '{s}'",
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
                        "duplicate attribute '{s}': it can be specified only once",
                        .{name},
                    );
                    return;
                }

                const value: ?meta.Value = blk: {
                    if (attribute.value) |v| {
                        const value = try self.sema.lowerMetaValue(v);

                        // validate type
                        for (def.value_types) |vt| {
                            if (value.validateType(vt)) break;
                        } else {
                            const expected = try attrib.formatValueTypes(self.sema.arena.allocator(), &def);
                            try self.sema.diagnostics.err(
                                attribute.node.trimmedSpan(),
                                "invalid value for attribute '{s}', expected '{s}'",
                                .{ name, expected },
                            );
                            return;
                        }

                        break :blk value;
                    } else switch (def.default) {
                        .value => |value| break :blk value,
                        .none => {
                            const expected = try attrib.formatValueTypes(self.sema.arena.allocator(), &def);
                            try self.sema.diagnostics.err(
                                attribute.node.trimmedSpan(),
                                "attribute '{s}' requires a value, expected '{s}'",
                                .{ name, expected },
                            );
                            return;
                        },
                    }
                };

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
    const OptionValue = union(options.definitions.Type) {
        shell: []const []const u8,
        dotenv: ?[]const u8,
        working_dir: []const u8,
    };

    const ResolvedOptions = std.EnumMap(options.definitions.Type, OptionValue);

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
            try self.sema.reportInactive(set.node.trimmedSpan(), &attributes_result);
            return;
        }

        var it = set.body.iter();

        while (it.next()) |decl| {
            _ = try skipIncomplete(self.resolveDecl(decl));
        }
    }

    fn resolveDecl(self: *OptionsResolver, decl: ast.SetDecl) Error!void {
        const decl_name = decl.name.string() orelse return Error.Incomplete;
        const def = options.definitions.get(decl_name) orelse {
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
                "option '{s}' is set more than once",
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
            const expected = try options.formatValueTypes(self.sema.arena.allocator(), def);
            try self.sema.diagnostics.err(
                decl.node.trimmedSpan(),
                "invalid value for option '{s}', expected {{{s}}}",
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

    fn getOptionValue(self: *OptionsResolver, id: options.definitions.Type, value: meta.Value) !OptionValue {
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
