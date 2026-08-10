const std = @import("std");
const ast = @import("ast.zig");

const platform = @import("platform.zig");

const ir = @import("ir.zig");

const options_mod = @import("options.zig");
const funcs = @import("functions.zig");
const attrib = @import("attributes.zig");
const text = @import("text.zig");

const typing = @import("typing.zig");

const sym = @import("symbol.zig");
const Symbol = sym.Symbol;

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
                .details = .{ .task = .{
                    .origin = ptr,
                } },
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
                    .details = .{
                        .group = .{
                            .origin = ptr,
                        },
                    },
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
    //TODO: consider taking ast_file as ptr
    pub fn analyse(self: *Sema, ast_file: ast.File) !ir.File {
        var file = try self.firstPass(&ast_file);

        try self.secondPass(&file);

        return file;
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

    fn analyseDecl(self: *Sema, scope: *Scope, decl: ast.Decl) !*ir.Decl {
        const node = self.span_registry.get(decl.id);

        const result = try self.analyseExpr(
            scope,
            decl.value,
            node.details.decl.value,
        );

        //TODO: copy pattern in other origins
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
            .details = .{
                .binding = .{
                    .static = result.is_static,
                    .type = result.type,
                    .origin = ptr,
                },
            },
        });

        return ptr;
    }

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

            const default: ?typing.Value, const implicit_default: bool = blk: {
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
                    .details = .{
                        .argument = .{
                            .type = arg.type.typeOf(),
                            .origin = ptr,
                        },
                    },
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

    fn assertLiteral(
        self: *Sema,
        expected_type: typing.Type,
        expr: ast.Expr,
        node_id: NodeId,
    ) !typing.Value {
        const span_node = self.span_registry.get(node_id);

        const expr_type: typing.TypeTag = switch (expr) {
            .bool_lit => .bool,
            .number_lit => .number,
            .char_lit => .char,
            .string => |str| switch (str) {
                .lit => .string,
                .inter => {
                    try self.diagnostics.err(span_node.span, "invalid type, expected '{f}' literal, found string interpolation expr", .{expected_type});
                    return SemaError.SemanticError;
                },
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
            .char => .{ .char = expr.char_lit },
            .string => .{ .string = expr.string.lit },
            .list => |items_type| {
                var out: std.ArrayList(typing.Value) = try .initCapacity(self.arena.allocator(), expr.list.len);
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
            .noreturn => {
                try self.diagnostics.err(span_node.span, "noreturn is not literal", .{});
                return SemaError.SemanticError;
            },
        };
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
                    .details = .{
                        .task = .{
                            .origin = task_ptr,
                        },
                    },
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

    fn analyseTaskBody(self: *Sema, target: *ir.Task, task: ast.Task) !void {
        const node = self.span_registry.get(task.id);
        target.body.statements = try self.analyseStatements(target.body.scope, task.body, node.details.task.body);
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

    //========= statemets ==============
    fn analyseStatementBlock(self: *Sema, scope: *Scope, block: ast.StatementBlock, span_node_id: NodeId) !ir.StatementBlock {
        const block_scope = try self.createScope(scope);

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
            .if_stmt => |s| .{ .if_stmt = try self.analyseIfStmt(scope, s) },
            .switch_stmt => |s| .{ .switch_stmt = try self.analyseSwitchStmt(scope, s) },
            .expr => |e| {
                const res = try self.analyseExpr(scope, e, node_id);

                return .{
                    .expr = res.expr,
                };
            },
        };
    }

    fn analyseSwitchStmt(self: *Sema, scope: *Scope, switch_stmt: ast.SwitchStmt) !ir.SwitchStmt {
        const span_node = self.span_registry.get(switch_stmt.id).details.switch_stmt;

        const subject = try self.analyseExpr(
            scope,
            switch_stmt.subject,
            span_node.subject,
        );

        var cases: ir.SwitchStmt.CasesStorage = .empty;
        try cases.ensureTotalCapacity(self.arena.allocator(), @intCast(switch_stmt.cases.len));

        var else_case: ?ir.StatementBlock = null;

        for (switch_stmt.cases) |case| {
            const case_node = self.span_registry.get(case.id).details.switch_case;
            switch (case.pattern) {
                .expr => |expr| {
                    const pattern = try self.assertLiteral(
                        subject.type,
                        expr,
                        case_node.pattern,
                    );
                    if (SwitchPatternValidator.validate(pattern) == false) {
                        try self.diagnostics.err(
                            self.span_registry.getSpan(case_node.pattern),
                            "incompatible case literal value: '{f}'",
                            .{pattern},
                        );
                        continue;
                    }
                    if (cases.contains(pattern)) {
                        try self.diagnostics.err(
                            self.span_registry.getSpan(case_node.pattern),
                            "duplicate pattern",
                            .{},
                        );
                        continue;
                    }
                    try cases.put(
                        self.arena.allocator(),
                        pattern,
                        try self.analyseStatementBlock(scope, case.body, case_node.body),
                    );
                },
                .else_ => {
                    if (else_case) |_| {
                        try self.diagnostics.err(self.span_registry.getSpan(case.id), "Duplicate else case", .{});
                        continue;
                    }

                    else_case = try self.analyseStatementBlock(
                        scope,
                        case.body,
                        case_node.body,
                    );
                },
            }
        }

        return .{
            .subject = subject.expr,
            .cases = cases,
            .else_case = else_case orelse {
                try self.diagnostics.err(self.span_registry.getSpan(switch_stmt.id), "Missing else case", .{});
                return SemaError.SemanticError;
            },
        };
    }

    fn analyseTaskCall(self: *Sema, scope: *Scope, call: ast.TaskCall) SemaError!ir.TaskCall {
        const node = self.span_registry.get(call.id);
        const target_task_name = call.task;

        // resolve task from scope
        const task: *ir.Task = blk: {
            switch (call.scope) {
                .closest => {
                    if (scope.resolve(target_task_name, .task)) |symbol| {
                        std.debug.assert(symbol.details == .task);
                        break :blk symbol.details.task.origin;
                    } else {
                        try self.diagnostics.err(node.details.task_call.task, "unknown task '{s}'", .{target_task_name});
                        return SemaError.SemanticError;
                    }
                },
                .root => {
                    if (scope.root().resolve(target_task_name, .task)) |symbol| {
                        std.debug.assert(symbol.details == .task);
                        break :blk symbol.details.task.origin;
                    } else {
                        try self.diagnostics.err(node.details.task_call.task, "unknown task '::{s}'", .{target_task_name});
                        return SemaError.SemanticError;
                    }
                },
                .group => |gname| {
                    const group = grp: {
                        if (scope.root().resolve(gname, .group)) |symbol| {
                            std.debug.assert(symbol.details == .group);
                            break :grp symbol.details.group.origin;
                        } else {
                            try self.diagnostics.err(node.details.task_call.group.?, "unknown group '{s}'", .{gname});
                            return SemaError.SemanticError;
                        }
                    };

                    const task = tsk: {
                        if (group.scope.resolveLocal(target_task_name, .task)) |symbol| {
                            std.debug.assert(symbol.details == .task);
                            break :tsk symbol.details.task.origin;
                        } else {
                            try self.diagnostics.err(node.details.task_call.task, "unknown task '{s}::{s}'", .{ gname, target_task_name });
                            return SemaError.SemanticError;
                        }
                    };

                    break :blk task;
                },
            }
        };

        // validate args
        var out_args = ir.TaskCallArgs.init(self.arena.allocator());

        // read positional
        const positionalCount = blk: {
            for (call.args, 0..) |arg, idx| {
                if (arg.name != null) break :blk idx;
                const arg_span = self.span_registry.getSpan(arg.id);

                const result = try self.analyseExpr(scope, arg.value, arg.id);

                if (idx >= task.args.len) {
                    try self.diagnostics.err(arg_span, "invalid positional arguments count, got '{}', expected {}", .{ idx + 1, task.args.len });
                    return SemaError.SemanticError;
                }

                const t = task.args[idx];

                if (!typing.Type.eq(t.type.typeOf(), result.type)) {
                    try self.diagnostics.err(arg_span, "invalid type", .{});
                    return SemaError.SemanticError;
                }

                try out_args.put(t.name, result.expr);
            }
            break :blk call.args.len;
        };

        // get rest of parameters from group and task
        const restArgs = totalArgs: {
            var out = try std.ArrayList(*ir.Argument).initCapacity(
                self.arena.allocator(),
                task.args.len + if (task.group) |g| g.args.len else 0,
            );
            for (task.args[positionalCount..]) |arg| {
                try out.append(self.arena.allocator(), arg);
            }
            if (task.group) |g| {
                for (g.args) |arg| {
                    try out.append(self.arena.allocator(), arg);
                }
            }
            break :totalArgs try out.toOwnedSlice(self.arena.allocator());
        };
        defer self.arena.allocator().free(restArgs);

        // get positional parameters from call as map {name => arg}
        var restCallArgs = blk: {
            var out = std.StringHashMap(ast.TaskCallArg).init(self.arena.allocator());
            for (call.args[positionalCount..]) |arg| {
                const arg_span = self.span_registry.getSpan(arg.id);
                if (out.contains(arg.name.?)) {
                    try self.diagnostics.err(arg_span, "duplicate argument '{s}'", .{arg.name.?});
                    return SemaError.SemanticError;
                }

                try out.put(arg.name.?, arg);
            }
            break :blk out;
        };
        defer restCallArgs.deinit();

        // bind positional arguments to task argument
        for (restArgs) |arg| {
            if (restCallArgs.fetchRemove(arg.name)) |in| {
                const in_arg = in.value;
                const in_arg_span = self.span_registry.getSpan(in_arg.id);

                const result = try self.analyseExpr(scope, in_arg.value, in_arg.id);
                if (!typing.Type.eq(result.type, arg.type.typeOf())) {
                    try self.diagnostics.err(
                        in_arg_span,
                        "invalid argument type, got '{s}', expected '{s}'",
                        .{
                            @tagName(result.type),
                            @tagName(arg.type),
                        },
                    );
                    return SemaError.SemanticError;
                }
                try out_args.put(arg.name, result.expr);
            } else if (arg.default == null) {
                try self.diagnostics.err(node.details.task_call.args, "missing argument '{s}'", .{arg.name});
                return SemaError.SemanticError;
            }
        }

        // bind positional arguments to group arguments
        if (task.group) |g| {
            for (g.args) |arg| {
                if (restCallArgs.fetchRemove(arg.name)) |in| {
                    const in_arg = in.value;
                    const arg_span = self.span_registry.getSpan(in_arg.id);

                    const result = try self.analyseExpr(scope, in_arg.value, in_arg.id);
                    if (!typing.Type.eq(result.type, arg.type.typeOf())) {
                        try self.diagnostics.err(
                            arg_span,
                            "invalid argument type, got '{s}', expected '{s}'",
                            .{
                                @tagName(result.type),
                                @tagName(arg.type),
                            },
                        );
                        return SemaError.SemanticError;
                    }
                } else if (arg.default == null) {
                    try self.diagnostics.err(node.details.task_call.args, "missing group argument '{s}'", .{arg.name});
                    return SemaError.SemanticError;
                }
            }
        }

        if (restCallArgs.unmanaged.size != 0) {
            var iter = restCallArgs.iterator();
            while (iter.next()) |v| {
                try self.diagnostics.err(
                    self.span_registry.getSpan(
                        v.value_ptr.id,
                    ),
                    "invalid argument '{s}'",
                    .{v.key_ptr.*},
                );
            }
            return SemaError.SemanticError;
        }

        return .{
            .task = task,
            .args = out_args,
        };
    }

    fn analyzeProcess(self: *Sema, scope: *Scope, raw: ast.ProcessStmt, node_id: NodeId) !ir.ProcessStmt {
        const segments = try self.analyseString(
            scope,
            raw,
            node_id,
        );
        return segments.string;
    }

    fn analyseIfStmt(self: *Sema, scope: *Scope, stmt: ast.IfStmt) SemaError!ir.IfStmt {
        const span_node = self.span_registry.get(stmt.id);
        const if_span_node = span_node.details.if_stmt;

        const cond = try self.analyseExpr(scope, stmt.cond, if_span_node.cond);
        const then = try self.analyseStatementBlock(scope, stmt.then, if_span_node.then);

        const else_ = if (stmt.else_) |block|
            try self.analyseStatementBlock(scope, block, if_span_node.else_.?)
        else
            null;

        return .{
            .cond = cond.expr,
            .then = then,
            .else_ = else_,
        };
    }

    const StringResult = struct {
        string: ir.String,
        is_static: bool,
    };

    fn analyseString(self: *Sema, scope: *Scope, string: ast.StringExpr, node_id: NodeId) SemaError!StringResult {
        switch (string) {
            .lit => |str| {
                //TODO: improve span hanlding in strings
                const span = self.span_registry.getSpan(node_id);

                return .{
                    .is_static = true,
                    .string = .{
                        .lit = text.processString(self.arena.allocator(), str) catch {
                            try self.diagnostics.err(
                                span,
                                "Invalid string escape sequence: {s}",
                                .{str},
                            );
                            return SemaError.SemanticError;
                        },
                    },
                };
            },
            .inter => |segs| {
                var segments = try std.ArrayList(ir.InterStringSeg).initCapacity(self.arena.allocator(), segs.len);
                const spans_ids = self.span_registry.get(node_id).details.expr.list;

                var is_static: bool = true;
                for (segs, spans_ids) |seg, span_id| {
                    switch (seg) {
                        .lit => |str| {
                            try segments.append(self.arena.allocator(), .{ .lit = text.processString(self.arena.allocator(), str) catch {
                                try self.diagnostics.err(
                                    self.span_registry.getSpan(span_id),
                                    "Invalid string escape sequence: {s}",
                                    .{str},
                                );
                                return SemaError.SemanticError;
                            } });
                        },
                        .expr => |expr| {
                            const res = try self.analyseExpr(scope, expr, span_id);

                            if (res.is_static == false) {
                                is_static = false;
                            }

                            try segments.append(
                                self.arena.allocator(),
                                .{
                                    .expr = res.expr,
                                },
                            );
                        },
                    }
                }
                return .{
                    .is_static = is_static,
                    .string = .{
                        .inter = try segments.toOwnedSlice(self.arena.allocator()),
                    },
                };
            },
        }
    }

    const BuiltinCallResult = struct {
        builtin_call: ir.BuiltinCall,
        type: ir.Type,
    };

    fn analyseBuiltinCall(self: *Sema, scope: *Scope, call: ast.BuiltInCall) SemaError!BuiltinCallResult {
        const call_spans = self.span_registry.get(call.id);

        const def = funcs.definitions.get(call.name, call.args.len) catch |err| switch (err) {
            funcs.definitions.Error.UnknownFunction => {
                try self.diagnostics.err(
                    call_spans.span,
                    "Unknown builtin function '{s}'",
                    .{call.name},
                );
                return SemaError.SemanticError;
            },
            funcs.definitions.Error.InvalidArguments => {
                try self.diagnostics.err(
                    self.span_registry.getSpan(call.id),
                    "Invalid arguments number ({}) for '{s}' function",
                    .{ call.args.len, call.name },
                );
                return SemaError.SemanticError;
            },
        };

        var args = try std.ArrayList(ir.Expr).initCapacity(self.arena.allocator(), call.args.len);

        for (call.args, def.args, call_spans.details.builtin_call.args) |arg_expr, arg_def, arg_span| {
            const arg = try self.analyseExpr(
                scope,
                arg_expr,
                arg_span, //TODO: implement handling span
            );

            if (arg.type.eq(arg_def.type) == false) {
                try self.diagnostics.err(
                    self.span_registry.getSpan(arg_span),
                    "invalid argument type, got '{f}' expected '{f}'",
                    .{ arg.type, arg_def.type },
                );
                return SemaError.SemanticError;
            }

            args.appendAssumeCapacity(arg.expr);
        }

        return .{
            .builtin_call = .{
                .id = def.id,
                .args = args.toOwnedSliceAssert(),
            },
            .type = def.return_type,
        };
    }

    const ExprResult = struct {
        expr: ir.Expr,
        type: ir.Type,
        is_static: bool,
    };

    fn analyseExpr(self: *Sema, scope: *Scope, expr: ast.Expr, node_id: NodeId) SemaError!ExprResult {
        //TODO: improve span handling
        const span_node = self.span_registry.get(node_id);

        return switch (expr) {
            .number_lit => |v| ExprResult{
                .expr = .{ .number_lit = v },
                .type = .number,
                .is_static = true,
            },
            .bool_lit => |v| ExprResult{
                .expr = .{ .bool_lit = v },
                .type = .bool,
                .is_static = true,
            },
            .char_lit => |ch| {
                const out = ch;

                return ExprResult{
                    .is_static = true,
                    .expr = .{ .char_lit = out },
                    .type = .char,
                };
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

                std.debug.assert(list.len != 0);

                const ItemsHelper = struct {
                    const Result = struct {
                        item: ir.Expr.List.Item,
                        type: ir.Type,
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

                const list_type = try self.arena.allocator().create(typing.Type);
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
                    const result = ItemsHelper.analyseItem(self, scope, node_id, item) catch |err| switch (err) {
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
                    type: ir.Type,
                } = switch (symbol.details) {
                    .binding => |binding| .{
                        .static = binding.static,
                        .type = binding.type,
                    },
                    .argument => |arg| .{
                        .static = false,
                        .type = arg.type,
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

                const result_type: ir.Type = switch (u.op) {
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
            .if_expr => |i| {
                const if_spans = span_node.details.expr.if_expr;

                const cond = try self.analyseExpr(scope, i.cond, if_spans.cond);

                if (cond.type == .noreturn) {
                    try self.diagnostics.err(
                        self.span_registry.getSpan(if_spans.cond),
                        "noreturn not allowed in if condition",
                        .{},
                    );
                }

                if (cond.type != .bool) {
                    try self.diagnostics.err(
                        self.span_registry.getSpan(if_spans.cond),
                        "if condition must be a bool or flag",
                        .{},
                    );
                }

                const then = try self.analyseExpr(scope, i.then, if_spans.then);
                const else_ = try self.analyseExpr(scope, i.else_, if_spans.else_);

                const result_type = typing.Type.unify(then.type, else_.type) orelse blk: {
                    try self.diagnostics.err(
                        span_node.span,
                        "if branches must have the same type: got {f} and {f}",
                        .{ then.type, else_.type },
                    );
                    break :blk then.type; // TODO: (consider) give it whatever type so it can continue collecting errors
                };

                const node = try self.arena.allocator().create(ir.IfExpr);
                node.* = .{ .cond = cond.expr, .then = then.expr, .else_ = else_.expr, .type = result_type };
                return .{
                    .expr = .{ .if_expr = node },
                    .type = result_type,
                    .is_static = cond.is_static and then.is_static and else_.is_static,
                };
            },
            .switch_expr => |switch_expr| {
                const switch_spans = self.span_registry.get(node_id);

                const subject = try self.analyseExpr(scope, switch_expr.subject, switch_spans.details.switch_stmt.subject);

                if (subject.type == .noreturn) {
                    try self.diagnostics.err(
                        self.span_registry.getSpan(switch_spans.details.switch_stmt.subject),
                        "noreturn is not allow in switch subject",
                        .{},
                    );
                }

                var is_static = subject.is_static;

                var cases: ir.SwitchExpr.CasesStorage = .empty;
                try cases.ensureTotalCapacity(self.arena.allocator(), @intCast(switch_expr.cases.len));

                var else_case: ?ir.Expr = null;

                var result_type: typing.Type = .noreturn;

                for (switch_expr.cases) |case| {
                    const case_spans = self.span_registry.get(case.id).details.switch_case;
                    switch (case.pattern) {
                        .expr => |e| {
                            const pattern = try self.assertLiteral(subject.type, e, case_spans.pattern);

                            if (cases.contains(pattern)) {
                                try self.diagnostics.err(
                                    self.span_registry.getSpan(case_spans.pattern),
                                    "Duplicate switch case pattern '{f}'",
                                    .{pattern},
                                );
                                continue;
                            }
                            const value = try self.analyseExpr(scope, case.value, case_spans.body);

                            result_type = typing.Type.unify(result_type, value.type) orelse {
                                try self.diagnostics.err(
                                    self.span_registry.getSpan(case_spans.body),
                                    "Invalid result type. Each case must result in the same type, expected {f} got {f}",
                                    .{ result_type, value.type },
                                );
                                continue;
                            };

                            if (value.is_static == false) is_static = false;
                            cases.putAssumeCapacityNoClobber(pattern, value.expr);
                        },
                        .else_ => {
                            if (else_case) |_| {
                                try self.diagnostics.err(
                                    self.span_registry.getSpan(case_spans.pattern),
                                    "Duplicate switch else case",
                                    .{},
                                );
                                continue;
                            }
                            const value = try self.analyseExpr(scope, case.value, case_spans.body);
                            result_type = typing.Type.unify(result_type, value.type) orelse {
                                try self.diagnostics.err(
                                    self.span_registry.getSpan(case_spans.body),
                                    "Invalid result type. Each case must result in the same type, expected {f} got {f}",
                                    .{ result_type, value.type },
                                );
                                continue;
                            };

                            if (value.is_static == false) is_static = false;
                            else_case = value.expr;
                        },
                    }
                }

                const ptr = try self.arena.allocator().create(ir.SwitchExpr);
                ptr.* = .{
                    .subject = subject.expr,
                    .cases = cases,
                    .else_case = else_case orelse {
                        try self.diagnostics.err(
                            self.span_registry.getSpan(node_id),
                            "Missing else case",
                            .{},
                        );
                        return SemaError.SemanticError;
                    },
                };
                return .{
                    .expr = .{
                        .switch_expr = ptr,
                    },
                    .type = result_type,
                    .is_static = is_static,
                };
            },
        };
    }

    //TODO: not used anywhere, remove?
    fn checkBinaryTypes(self: *Sema, op: ast.BinaryOp, left: ir.Type, right: ir.Type) !ir.Type {
        return switch (op) {
            .add => switch (left) {
                .number => if (right == .number) ir.Type.number else self.typeMismatch(.Unknown, "number", right),
                .string => if (right == .string) ir.Type.string else self.typeMismatch(.Unknown, "string", right),
                else => {
                    try self.diagnostics.err(.{ .span = .Unknown }, "'+' not supported for type {s}", .{@tagName(left)});
                    return SemaError.SemanticError;
                },
            },
            .sub, .mul, .div => switch (left) {
                .number => if (right == .number) ir.Type.number else self.typeMismatch(.Unknown, "number", right),
                else => {
                    try self.diagnostics.err(.{ .span = .Unknown }, "arithmetic not supported for type {s}", .{@tagName(left)});
                    return SemaError.SemanticError;
                },
            },
            .eq, .neq => blk: {
                if (!typing.Type.eq(left, right)) {
                    try self.diagnostics.err(.{ .span = .Unknown }, "cannot compare {s} and {s}", .{ @tagName(left), @tagName(right) });
                    return SemaError.SemanticError;
                }
                break :blk .bool;
            },
            .lt, .gt, .lt_eq, .gt_eq => blk: {
                if (left != .number) {
                    try self.diagnostics.err(.{ .span = .Unknown }, "comparison requires int or number", .{});
                    return SemaError.SemanticError;
                }
                break :blk .bool;
            },
            // logical — always returns bool
            .and_op, .or_op => blk: {
                if ((left != .bool) or (right != .bool)) {
                    try self.diagnostics.err(.{ .span = .Unknown }, "'and'/'or' require bool or flag operands", .{});
                }
                break :blk .bool;
            },
        };
    }

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

        fn validate(v: typing.Value) bool {
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
