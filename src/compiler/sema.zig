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
const Span = Diagnostics.Span;

const lib = @import("lib");
const enums = lib.enums;

const SemaError = error{
    SemanticError,
    PlatformMismatch,
} || std.mem.Allocator.Error;

pub const Sema = struct {
    arena: *std.heap.ArenaAllocator,
    diagnostics: *Diagnostics,

    pub fn init(arena: *std.heap.ArenaAllocator, diagnostics: *Diagnostics) Sema {
        return Sema{
            .arena = arena,
            .diagnostics = diagnostics,
        };
    }

    fn createScope(self: *Sema, parent: ?*Scope) !*Scope {
        const ptr = try self.arena.allocator().create(Scope);
        ptr.* = .init(parent);
        return ptr;
    }

    fn firstPass(self: *Sema, file: ast.File) !ir.File {

        // create scope
        const root_scope = try self.createScope(null);

        const options = try self.analyseOptions(file.options);

        var decls = try std.ArrayList(*ir.Decl).initCapacity(self.arena.allocator(), file.decls.len);
        for (file.decls) |decl| try decls.append(self.arena.allocator(), try self.analyseDecl(root_scope, decl));

        var tasks = try std.ArrayList(*ir.Task).initCapacity(self.arena.allocator(), file.tasks.len);
        for (file.tasks) |task| {
            const ptr = self.collectTaskSignature(root_scope, task) catch |err| switch (err) {
                SemaError.PlatformMismatch => {
                    try self.diagnostics.hint(.{ .span = task.span }, "skipping task, platform mismatch", .{});
                    continue;
                },
                else => return err,
            };

            try self.defineSymbol(root_scope, .{
                .name = task.name,
                .span = task.span,
                .details = .{ .task = .{
                    .origin = ptr,
                } },
            });

            try tasks.append(self.arena.allocator(), ptr);
        }

        var groups = try std.ArrayList(*ir.Group).initCapacity(self.arena.allocator(), file.groups.len);
        for (file.groups) |group| {
            const ptr = self.collectGroupSignature(root_scope, group) catch |err| switch (err) {
                SemaError.PlatformMismatch => {
                    try self.diagnostics.hint(.{ .span = group.span }, "skipping group, platform mismatch", .{});
                    continue;
                },
                else => return err,
            };

            if (group.name) |name| {
                try self.defineSymbol(root_scope, .{
                    .name = name,
                    .span = group.span,
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

    fn secondPass(self: *Sema, outFile: *ir.File, inFile: ast.File) !void {
        for (outFile.tasks, inFile.tasks) |out, in| {
            try self.analyseTaskBody(out, in);
        }

        for (outFile.groups, inFile.groups) |outGroup, inGroup| {
            for (outGroup.tasks, inGroup.tasks) |out, in| {
                try self.analyseTaskBody(out, in);
            }
        }
    }

    pub fn analyse(self: *Sema, ast_file: ast.File) !ir.File {
        var file = try self.firstPass(ast_file);

        try self.secondPass(&file, ast_file);

        return file;
    }

    fn analyseOptions(self: *Sema, options: []const ast.Set) !ir.Options {
        var result = try OptionResolver.resolve(self, options);

        var out: ir.Options = platform.default_options;

        var iter = result.iterator();

        while (iter.next()) |opt| switch (opt.value.*) {
            .shell => |shell| out.shell = shell,
            .script => |script| out.script = script,
        };

        return out;
    }

    const OptionResolver = struct {
        const options = options_mod.options;

        const OptionValue = union(options.Type) {
            shell: []const []const u8,
            script: []const []const u8,
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
                var attributes = AttributesResolver.resolve(self.sema, .setting, set.attrs) catch |err| switch (err) {
                    SemaError.PlatformMismatch => {
                        try self.sema.diagnostics.hint(set.span, "skipping settings, platform mismatch", .{});
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
                const def = options.get(decl.name.value) orelse {
                    try self.sema.diagnostics.err(decl.span, "unknown option '{s}'", .{decl.name.value});
                    return SemaError.SemanticError;
                };

                if (self.storage.contains(def.id)) {
                    try self.sema.diagnostics.err(decl.span, "duplicate option '{s}'", .{decl.name.value});
                    return SemaError.SemanticError;
                }

                const value: ast.MetaValue = decl.value orelse .{ .bool = true };

                if (value.validateType(def.value_type) == false) {
                    try self.sema.diagnostics.err(decl.span, "invalid '{s}' option value type, expected '{f}'", .{ decl.name.value, def.value_type });
                    return SemaError.SemanticError;
                }

                self.storage.put(def.id, try self.getOptionValue(def.id, value));
            }
        }

        fn getOptionValue(self: *OptionResolver, id: options.Type, value: ast.MetaValue) !OptionValue {
            switch (id) {
                inline .shell, .script => |tag| {
                    var out: std.ArrayList([]const u8) = try .initCapacity(self.sema.arena.allocator(), value.list.len);

                    for (value.list) |val| {
                        const string = try text.processString(self.sema.arena.allocator(), val.string);
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
        const result = try self.analyseExpr(scope, decl.value);

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
            .span = decl.span,
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
                const def = attrib.definitions.get(attr.name, target) orelse {
                    try self.sema.diagnostics.err(attr.span, "'{s}' is not valid attribute for this element", .{attr.name});
                    return SemaError.SemanticError;
                };

                switch (def.kind) {
                    .platform => {
                        const pt = lib.enums.castEnum(def.type, platform.Tag) orelse unreachable;
                        // platforms are always unique attributes
                        std.debug.assert(def.unique == true);

                        if (self.platforms.contains(pt)) {
                            try self.sema.diagnostics.err(attr.span, "'{s}' platform attribute duplicate", .{attr.name});
                            return SemaError.SemanticError;
                        }

                        self.platforms.insert(pt);
                    },
                    else => {
                        // validate uniqueness
                        if (def.unique and self.attributes.contains(def.type)) {
                            try self.sema.diagnostics.err(attr.span, "'{s}' attribute duplicate", .{attr.name});
                            return SemaError.SemanticError;
                        }

                        // validate value
                        if (attr.value) |val| {
                            for (def.value_types) |vt| {
                                if (val.validateType(vt)) break;
                            } else {
                                const expected = try attrib.typesListToString(self.sema.arena.allocator(), def.value_types, def.allow_default);
                                try self.sema.diagnostics.err(attr.span, "invalid '{s}' attribute value type, expected '{s}'", .{ attr.name, expected });
                                return SemaError.SemanticError;
                            }
                        } else if (def.allow_default == false) {
                            const expected = try attrib.typesListToString(self.sema.arena.allocator(), def.value_types, def.allow_default);
                            try self.sema.diagnostics.err(attr.span, "'{s}' attribute doesn't support default value, expected '{s}'", .{ attr.name, expected });
                            return SemaError.SemanticError;
                        }
                        try self.attributes.add(self.sema.arena.allocator(), def.type, attr.value);
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
        var out = try std.ArrayList(*ir.Argument).initCapacity(self.arena.allocator(), args.len);

        // implicitly named when:
        //      any previous is named,
        //      default value provided,
        var phase: ArgPhase = .positional;

        for (args) |*arg| {
            var attributes = AttributesResolver.resolve(self, .{ .argument = arg.type }, arg.attrs) catch |err| switch (err) {
                SemaError.PlatformMismatch => unreachable,
                else => return err,
            };
            defer attributes.deinit(self.arena.allocator());

            const name_required = group or arg.type.isNamedOnly();

            // get default value,
            const default: ?typing.Value = blk: {
                if (arg.type == .flag) {
                    if (arg.default) |def| {
                        try self.diagnostics.err(.{ .span = def.span() }, "flag value have implicit default value", .{});
                        return SemaError.SemanticError;
                    }
                    break :blk .{ .bool = false };
                }

                if (arg.default) |def| {
                    break :blk try self.assertLiteral(arg.type.typeOf(), def);
                }

                break :blk null;
            };

            const implicit_names = default != null or name_required;

            // TODO: verify if unicode char, (if meta value will hold other)
            const short = blk: {
                if (attributes.getAssertOne(.short)) |attr| if (attr) |value| {
                    break :blk switch (value) {
                        .char => |ch| ch,
                        .null => null,
                        else => unreachable,
                    };
                };

                if (implicit_names) {
                    break :blk arg.name[0];
                }

                break :blk null;
            };

            const long = blk: {
                if (attributes.getAssertOne(.long)) |attr| if (attr) |value| {
                    break :blk switch (value) {
                        .string => |str| str,
                        .null => null,
                        else => unreachable,
                    };
                };

                if (implicit_names) {
                    break :blk arg.name;
                }

                break :blk null;
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

            // check if named
            const has_name = blk: {
                const has_name = long != null or short != null;

                if (!has_name) {
                    if (group) {
                        try self.diagnostics.err(.{ .span = arg.span }, "group arguments must be named", .{});
                        return SemaError.SemanticError;
                    }

                    if (name_required) {
                        try self.diagnostics.err(.{ .span = arg.span }, "'{f}' type expect long or/and short attribute", .{arg.type});
                        return SemaError.SemanticError;
                    }
                }

                break :blk has_name;
            };

            //validate arg order
            try self.validateArgOrder(arg, &phase, has_name, default != null);

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
                    .span = arg.span,
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
        const class = blk: {
            if (named == false) {
                if (optional) {
                    try self.diagnostics.err(.{ .span = arg.span }, "positional arguments cannot have default values", .{});
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
                    try self.diagnostics.err(.{ .span = arg.span }, "positional argument cannot follow a named argument", .{});
                    return SemaError.SemanticError;
                },
                else => {},
            },
            .named_optional => switch (class) {
                .positional => {
                    try self.diagnostics.err(.{ .span = arg.span }, "positional argument cannot follow a named argument", .{});
                    return SemaError.SemanticError;
                },
                .named_required => {
                    try self.diagnostics.err(.{ .span = arg.span }, "required argument cannot follow a optional argument", .{});
                    return SemaError.SemanticError;
                },
                else => {},
            },
        }
        phase.* = class;
    }

    fn assertLiteral(self: *Sema, expected_type: typing.Type, expr: ast.Expr) !typing.Value {
        const expr_type: typing.TypeTag = switch (expr) {
            .bool_lit => .bool,
            .number_lit => .number,
            .char_lit => .char,
            .string => |str| switch (str.value) {
                .lit => .string,
                .inter => {
                    try self.diagnostics.err(.{ .span = expr.span() }, "invalid type, expected '{f}' literal, found string interpolation expr", .{expected_type});
                    return SemaError.SemanticError;
                },
            },
            .list => .list,
            else => {
                try self.diagnostics.err(.{ .span = expr.span() }, "invalid value type, default value must be literal", .{});
                return SemaError.SemanticError;
            },
        };

        if (expr_type != expected_type) {
            try self.diagnostics.err(.{ .span = expr.span() }, "invalid value type, expected '{f}' literal, found {s}", .{ expected_type, @tagName(expr_type) });
            return SemaError.SemanticError;
        }

        return switch (expected_type) {
            .bool => .{ .bool = expr.bool_lit.value },
            .number => .{ .number = expr.number_lit.value },
            .char => .{ .char = expr.char_lit.value },
            .string => .{ .string = expr.string.value.lit },
            .list => |items_type| {
                var out: std.ArrayList(typing.Value) = try .initCapacity(self.arena.allocator(), expr.list.value.len);

                for (expr.list.value) |v| {
                    const lit = self.assertLiteral(items_type.*, v) catch |err| {
                        try self.diagnostics.err(.{ .span = expr.span() }, "invalid list items type", .{});
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
        };
    }

    fn collectGroupSignature(self: *Sema, scope: *Scope, group: ast.Group) !*ir.Group {
        const groupScope = try self.createScope(scope);

        const args = try self.analyseArgs(groupScope, group.args, true);

        var decls = try std.ArrayList(*ir.Decl).initCapacity(self.arena.allocator(), group.decls.len);
        for (group.decls) |decl| try decls.append(self.arena.allocator(), try self.analyseDecl(groupScope, decl));

        const ptr = try self.arena.allocator().create(ir.Group);

        ptr.* = .{
            .scope = groupScope,
            .name = group.name,
            .args = args,
            .decls = try decls.toOwnedSlice(self.arena.allocator()),
            .tasks = undefined, // yet
            .desc = "<not supported yet>", // TODO: add support
        };

        const tasks_target_scope = if (group.name) |_| groupScope else scope;

        var tasks = try std.ArrayList(*ir.Task).initCapacity(self.arena.allocator(), group.tasks.len);
        for (group.tasks) |task| {
            const task_ptr = self.collectTaskSignature(groupScope, task) catch |err| switch (err) {
                SemaError.PlatformMismatch => {
                    try self.diagnostics.hint(.{ .span = task.span }, "skipping task, platform mismatch", .{});
                    continue;
                },
                else => return err,
            };
            task_ptr.*.group = ptr;

            try self.defineSymbol(
                tasks_target_scope,
                .{
                    .name = task.name,
                    .span = task.span,
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
        target.body.statements = try self.analyseStatements(target.body.scope, task.body);
    }

    fn collectTaskSignature(self: *Sema, scope: *Scope, task: ast.Task) !*ir.Task {
        var attributes = try AttributesResolver.resolve(self, .task, task.attrs);
        defer attributes.deinit(self.arena.allocator());

        const taskScope = try self.createScope(scope);

        const is_script = attributes.contains(.script);
        const is_private = attributes.contains(.private);
        const desc = if (attributes.getAssertOne(.desc)) |value|
            value.?.string
        else
            null;

        const args = try self.analyseArgs(taskScope, task.args, false);

        const ptr = try self.arena.allocator().create(ir.Task);

        ptr.* = .{
            .name = task.name,
            .args = args,
            .script = is_script,
            .private = is_private,
            .desc = desc,
            .body = .{
                .scope = taskScope,
                .statements = undefined,
            },
        };

        return ptr;
    }

    //========= statemets ==============
    fn analyseStatementBlock(self: *Sema, scope: *Scope, block: ast.StatementBlock) !ir.StatementBlock {
        const block_scope = try self.createScope(scope);

        const stmts = try self.analyseStatements(block_scope, block);

        return .{
            .scope = block_scope,
            .statements = stmts,
        };
    }

    fn analyseStatements(self: *Sema, scope: *Scope, stmts: []ast.Statement) ![]ir.Statement {
        var out = try std.ArrayList(ir.Statement).initCapacity(self.arena.allocator(), stmts.len);

        for (stmts) |stmt| {
            try out.append(
                self.arena.allocator(),
                try self.analyseStatement(scope, stmt),
            );
        }

        return try out.toOwnedSlice(self.arena.allocator());
    }

    fn analyseStatement(self: *Sema, scope: *Scope, stmt: ast.Statement) !ir.Statement {
        return switch (stmt) {
            .decl => |d| .{ .decl = try self.analyseDecl(scope, d) },
            .process => |p| .{ .process = try self.analyzeProcess(scope, p) },
            .task_call => |c| .{ .task_call = try self.analyseTaskCall(scope, c) },
            .if_stmt => |s| .{ .if_stmt = try self.analyseIfStmt(scope, s) },
        };
    }

    fn analyseTaskCall(self: *Sema, scope: *Scope, call: ast.TaskCall) !ir.TaskCall {
        const target_task_name = call.task;

        // resolve task from scope
        const task: *ir.Task = blk: {
            switch (call.scope) {
                .closest => {
                    if (scope.resolve(target_task_name, .task)) |symbol| {
                        std.debug.assert(symbol.details == .task);
                        break :blk symbol.details.task.origin;
                    } else {
                        try self.diagnostics.err(.{ .span = call.span }, "unknown task '{s}'", .{target_task_name});
                        return SemaError.SemanticError;
                    }
                },
                .root => {
                    if (scope.root().resolve(target_task_name, .task)) |symbol| {
                        std.debug.assert(symbol.details == .task);
                        break :blk symbol.details.task.origin;
                    } else {
                        try self.diagnostics.err(.{ .span = call.span }, "unknown task '::{s}'", .{target_task_name});
                        return SemaError.SemanticError;
                    }
                },
                .group => |gname| {
                    const group = grp: {
                        if (scope.root().resolve(gname, .group)) |symbol| {
                            std.debug.assert(symbol.details == .group);
                            break :grp symbol.details.group.origin;
                        } else {
                            try self.diagnostics.err(.{ .span = call.span }, "unknown group '{s}'", .{gname});
                            return SemaError.SemanticError;
                        }
                    };

                    const task = tsk: {
                        if (group.scope.resolveLocal(target_task_name, .task)) |symbol| {
                            std.debug.assert(symbol.details == .task);
                            break :tsk symbol.details.task.origin;
                        } else {
                            try self.diagnostics.err(.{ .span = call.span }, "unknown task '{s}::{s}'", .{ gname, target_task_name });
                            return SemaError.SemanticError;
                        }
                    };

                    break :blk task;
                },
            }
        };

        // validate args
        var outArgs = ir.TaskCallArgs.init(self.arena.allocator());

        // read positional
        const positionalCount = blk: {
            for (call.args, 0..) |arg, idx| {
                if (arg.name != null) break :blk idx;

                const result = try self.analyseExpr(scope, arg.value);

                if (idx >= task.args.len) {
                    try self.diagnostics.err(.{ .span = arg.span }, "invalid positional arguments count, got '{}', expected {}", .{ idx + 1, task.args.len });
                    return SemaError.SemanticError;
                }

                const t = task.args[idx];

                if (!typing.Type.eq(t.type.typeOf(), result.type)) {
                    try self.diagnostics.err(.{ .span = arg.span }, "invalid type", .{});
                    return SemaError.SemanticError;
                }

                try outArgs.put(t.name, result.expr);
            }
            break :blk call.args.len;
        };

        // get rest of parameters from group and task
        const restArgs = totalArgs: {
            var out = try std.ArrayList(*ir.Argument).initCapacity(self.arena.allocator(), task.args.len + if (task.group) |g| g.args.len else 0);
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
                if (out.contains(arg.name.?)) {
                    try self.diagnostics.err(.{ .span = arg.span }, "duplicate argument '{s}'", .{arg.name.?});
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
                const inArg = in.value;
                const result = try self.analyseExpr(scope, inArg.value);
                if (!typing.Type.eq(result.type, arg.type.typeOf())) {
                    try self.diagnostics.err(
                        .{ .span = inArg.span },
                        "invalid argument type, got '{s}', expected '{s}'",
                        .{
                            @tagName(result.type),
                            @tagName(arg.type),
                        },
                    );
                    return SemaError.SemanticError;
                }
                try outArgs.put(arg.name, result.expr);
            } else if (arg.default == null) {
                try self.diagnostics.err(.{ .span = call.span }, "missing argument '{s}'", .{arg.name});
                return SemaError.SemanticError;
            }
        }

        // bind positional arguments to group arguments
        if (task.group) |g| {
            for (g.args) |arg| {
                if (restCallArgs.fetchRemove(arg.name)) |in| {
                    const inArg = in.value;
                    const result = try self.analyseExpr(scope, inArg.value);
                    if (!typing.Type.eq(result.type, arg.type.typeOf())) {
                        try self.diagnostics.err(
                            .{ .span = inArg.span },
                            "invalid argument type, got '{s}', expected '{s}'",
                            .{
                                @tagName(result.type),
                                @tagName(arg.type),
                            },
                        );
                        return SemaError.SemanticError;
                    }
                } else if (arg.default == null) {
                    try self.diagnostics.err(.{ .span = call.span }, "missing group argument '{s}'", .{arg.name});
                    return SemaError.SemanticError;
                }
            }
        }

        if (restCallArgs.unmanaged.size != 0) {
            var iter = restCallArgs.iterator();
            while (iter.next()) |v| {
                try self.diagnostics.err(.{ .span = v.value_ptr.span }, "invalid argument '{s}'", .{v.key_ptr.*});
            }
            return SemaError.SemanticError;
        }

        return .{
            .task = task,
            .args = outArgs,
        };
    }

    fn analyzeProcess(self: *Sema, scope: *Scope, raw: ast.ProcessStmt) !ir.ProcessStmt {
        const segments = try self.analyseString(scope, raw);
        return segments.string;
    }

    fn analyseIfStmt(self: *Sema, scope: *Scope, stmt: ast.IfStmt) SemaError!ir.IfStmt {
        const cond = try self.analyseExpr(scope, stmt.cond);
        const then = try self.analyseStatementBlock(scope, stmt.then);

        const else_ = if (stmt.else_) |block| try self.analyseStatementBlock(scope, block) else null;

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

    fn analyseString(self: *Sema, scope: *Scope, string: ast.StringExpr) SemaError!StringResult {
        switch (string) {
            .lit => |str| {
                //TODO: add Span to ast.String.lit
                return .{
                    .is_static = true,
                    .string = .{
                        .lit = text.processString(self.arena.allocator(), str) catch {
                            try self.diagnostics.err(.unknown, "Invalid string escape sequence: {s}", .{str});
                            return SemaError.SemanticError;
                        },
                    },
                };
            },
            .inter => |segs| {
                var segments = try std.ArrayList(ir.InterStringSeg).initCapacity(self.arena.allocator(), segs.len);

                var is_static: bool = true;
                for (segs) |seg| {
                    switch (seg) {
                        .lit => |str| {
                            try segments.append(self.arena.allocator(), .{ .lit = text.processString(self.arena.allocator(), str) catch {
                                try self.diagnostics.err(
                                    .unknown,
                                    "Invalid string escape sequence: {s}",
                                    .{str},
                                );
                                return SemaError.SemanticError;
                            } });
                        },
                        .expr => |expr| {
                            const res = try self.analyseExpr(scope, expr);

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
        const functions = @import("functions.zig");

        const def = functions.getFunctionDef(call.name, call.args.len) catch |err| switch (err) {
            error.UnknownFunction => {
                try self.diagnostics.err(call.span, "unknown function '{s}'", .{call.name});
                return SemaError.SemanticError;
            },
            error.InvalidArguments => {
                try self.diagnostics.err(call.span, "invalid arguments num", .{});
                return SemaError.SemanticError;
            },
        };

        var args = try std.ArrayList(ir.Expr).initCapacity(self.arena.allocator(), call.args.len);

        for (call.args, def.args) |expr, arg_def| {
            const arg = try self.analyseExpr(scope, expr);

            if (arg.type.eq(arg_def[1]) == false) {
                try self.diagnostics.err(expr.span(), "invalid argument type, got '{f}' expected '{f}'", .{ arg.type, arg_def[1] });
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

    fn analyseExpr(self: *Sema, scope: *Scope, expr: ast.Expr) SemaError!ExprResult {
        return switch (expr) {
            .number_lit => |v| ExprResult{
                .expr = .{ .number_lit = v.value },
                .type = .number,
                .is_static = true,
            },
            .bool_lit => |v| ExprResult{
                .expr = .{ .bool_lit = v.value },
                .type = .bool,
                .is_static = true,
            },
            .char_lit => |ch| {
                const out = ch.value;

                return ExprResult{
                    .is_static = true,
                    .expr = .{ .char_lit = out },
                    .type = .char,
                };
            },
            .string => |s| {
                const res = try self.analyseString(scope, s.value);

                return .{
                    .expr = .{
                        .string = res.string,
                    },
                    .type = .string,
                    .is_static = res.is_static,
                };
            },
            .list => |list| {
                std.debug.assert(list.value.len != 0);
                var out = try std.ArrayList(ir.Expr).initCapacity(self.arena.allocator(), list.value.len);

                var is_static: bool = false;

                const list_type = try self.arena.allocator().create(typing.Type);
                errdefer self.arena.allocator().destroy(list_type);

                list_type.* = blk: {
                    const first = try self.analyseExpr(scope, list.value[0]);
                    if (first.is_static) is_static = true;
                    out.appendAssumeCapacity(first.expr);
                    break :blk first.type;
                };

                for (list.value[1..]) |i| {
                    const curr = try self.analyseExpr(scope, i);
                    if (list_type.eq(curr.type) == false) {
                        try self.diagnostics.err(expr.span(), "All list elements must be of same type", .{});
                        return SemaError.SemanticError;
                    }
                    if (curr.is_static) is_static = true;
                    out.appendAssumeCapacity(curr.expr);
                }

                return .{
                    .expr = .{
                        .list = .{
                            .items_type = list_type.*,
                            .items = try out.toOwnedSlice(self.arena.allocator()),
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
                const symbol = scope.resolve(name.value, .variable) orelse {
                    try self.diagnostics.err(name.span, "undefined variable '{s}'", .{name.value});
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
                            .name = name.value,
                            .symbol = symbol,
                        },
                    },
                    .type = details.type,
                    .is_static = details.static,
                };
            },
            .binary => |b| {
                const left = try self.analyseExpr(scope, b.left);
                const right = try self.analyseExpr(scope, b.right);

                const binary = @import("binary.zig");

                const binary_result = binary.binaryResultType(b.op, left.type, right.type) catch |err| {
                    switch (err) {
                        binary.Error.TypeMismatch => {
                            try self.diagnostics.err(.{ .span = b.span }, "invalid operator '{f}' for types: {f} and {f}", .{ b.op, left.type, right.type });
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
                const operand = try self.analyseExpr(scope, u.operand);
                const result_type: ir.Type = switch (u.op) {
                    .not_op => blk: {
                        if (operand.type != .bool) {
                            try self.diagnostics.err(.{ .span = u.span }, "'not' requires a bool or flag", .{});
                        }
                        break :blk .bool;
                    },
                    .negate => blk: {
                        if (operand.type != .number) {
                            try self.diagnostics.err(.{ .span = u.span }, "unary '-' requires number", .{});
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
                const cond = try self.analyseExpr(scope, i.cond);
                const then = try self.analyseExpr(scope, i.then);
                const else_ = try self.analyseExpr(scope, i.else_);

                if (cond.type != .bool) {
                    try self.diagnostics.err(.{ .span = i.span }, "if condition must be a bool or flag", .{});
                }
                if (!typing.Type.eq(then.type, else_.type)) {
                    try self.diagnostics.err(
                        .{ .span = i.span },
                        "if branches must have the same type: got {s} and {s}",
                        .{
                            @tagName(then.type),
                            @tagName(else_.type),
                        },
                    );
                }

                const node = try self.arena.allocator().create(ir.IfExpr);
                node.* = .{
                    .cond = cond.expr,
                    .then = then.expr,
                    .else_ = else_.expr,
                    .type = then.type,
                };
                return .{
                    .expr = .{ .if_expr = node },
                    .type = then.type,
                    .is_static = cond.is_static and then.is_static and else_.is_static,
                };
            },
        };
    }

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

    fn typeMismatch(self: *Sema, span: lib.Span, expected: []const u8, got: ir.Type) !ir.Type {
        try self.diagnostics.err(
            .{ .span = span },
            "type mismatch: expected {s}, got {s}",
            .{ expected, @tagName(got) },
        );
        return SemaError.SemanticError;
    }

    fn alreadyDefined(self: *Sema, span: lib.Span, name: []const u8) !void {
        try self.diagnostics.err(.{ .span = span }, "'{s} already defined'", .{name});
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
            try self.diagnostics.err(.{ .span = symbol.span }, "'{s}' {s} already defined", .{ symbol.name, @tagName(symbol_type) });
            try self.diagnostics.hint(.{ .span = prev.span }, "{s} defined already here", .{@tagName(symbol_type)});
            return SemaError.SemanticError;
        }

        try scope.define(self.arena.allocator(), symbol);
    }
};
