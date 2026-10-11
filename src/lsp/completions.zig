const std = @import("std");
const compiler = @import("compiler");
const ast = compiler.ast;
const attributes = compiler.attributes;
const options = compiler.options;
const cst = compiler.cst;
const ts = compiler.type;
const Span = compiler.Span;
const Scope = compiler.scope.Scope;
const Workspace = compiler.Workspace;
const FileState = Workspace.FileState;

const lib = @import("lib");
const ct = lib.@"comptime";
const lsp = @import("lsp_kit");

// ── Types ────────────────────────────────────────────────────────────────

pub const Range = struct {
    start: u32,
    end: u32,

    fn fromSpan(span: Span) Range {
        return .{
            .start = span.start,
            .end = span.end(),
        };
    }
};

pub const Completion = struct {
    label: []const u8,
    labelDetail: ?struct {
        detail: []const u8,
        description: []const u8,
    } = null,
    detail: ?[]const u8 = null,

    new_text: []const u8,
    snippet: ?[]const u8 = null,
    filter_text: ?[]const u8 = null,
    kind: lsp.types.completion.Item.Kind,
};

pub const Result = struct {
    completions: []const Completion,
    range: Range,
};

/// What kind of thing the cursor position is asking for.
const Want = union(enum) {
    const Attribute = union(enum) {
        task,
        group,
        setting,
        parameter: ?ts.ArgType,
    };
    nothing,
    type: struct {
        list: bool = false,
    },
    group_task: struct { group: ?[]const u8 },
    arg,
    attribute: Attribute,
    setting,
};

// ── Entry point ──────────────────────────────────────────────────────────

pub fn getCompletions(arena: std.mem.Allocator, file: *const FileState, pos: u32) !Result {
    const cc = try buildCursorContext(
        arena,
        file.tree.?,
        file.ir.?.scope,
        pos,
    );

    const range = wordRange(&cc, pos);

    std.log.debug("completion cursor token: {s}", .{
        if (cc.exact) |exact| @tagName(exact.kind) else "none",
    });

    const completions: []const Completion = switch (try analyse(arena, file.source, range)) {
        .setting => getSettingCompletions(),
        .group_task => |group_task| try getTasksCompletions(arena, cc.scope, group_task.group),
        .attribute => |attr| try getAttributeCompletions(arena, attr),
        else => try std.mem.concat(arena, Completion, &.{
            getKeywordCompletions(),
            getBuiltinCompletions(),
            try getSymbolsCompletions(arena, cc.scope, pos),
        }),
    };

    return .{
        .completions = completions,
        .range = range,
    };
}

// ── Cursor context ───────────────────────────────────────────────────────

const CursorContext = struct {
    /// The token under the cursor, if any.
    exact: ?*const cst.Token,
    scope: *const Scope,
    /// Nodes enclosing the cursor, outermost first.
    stack: []const *const cst.Node,

    pub fn deinit(self: *const CursorContext, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);
    }

    pub fn lastNode(self: *const CursorContext) ?*const cst.Node {
        return if (self.stack.len != 0) self.stack[self.stack.len - 1] else null;
    }

    /// True if the innermost node around the cursor is of `kind`.
    ///
    /// Use this (not `exact.kind`) to ask "is the cursor on a name?":
    /// `name` is a node kind, the token inside it is an identifier.
    pub fn atNode(self: *const CursorContext, kind: cst.NodeKind) bool {
        const node = self.lastNode() orelse return false;
        return node.kind == kind;
    }

    /// True if any enclosing node is of `kind`.
    pub fn isNode(self: *const CursorContext, kind: cst.NodeKind) bool {
        for (self.stack) |node| {
            if (node.kind == kind) return true;
        }
        return false;
    }

    /// Nearest enclosing node whose kind is in `significant`. Gives up
    /// (returns null) if a node of kind `limiter` is hit first.
    pub fn significantParent(
        self: *const CursorContext,
        comptime significant: []const cst.NodeKind,
        comptime limiter: ?cst.NodeKind,
    ) ?*const cst.Node {
        const set: std.EnumSet(cst.NodeKind) = comptime .initMany(significant);
        if (comptime limiter) |l| {
            if (comptime set.contains(l))
                @compileError("significant set shouldn't contain the limiter");
        }

        var it = std.mem.reverseIterator(self.stack);
        while (it.next()) |node| {
            if (limiter == node.kind) return null;
            if (set.contains(node.kind)) return node;
        }
        return null;
    }
};

fn buildCursorContext(
    allocator: std.mem.Allocator,
    root_node: *const cst.Node,
    root_scope: *const Scope,
    pos: u32,
) !CursorContext {
    const Walker = struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        stack: std.ArrayList(*const cst.Node),
        scope: *const Scope,
        pos: u32,

        /// Descends into whichever element contains `pos`, recording the
        /// nodes (and scopes) passed on the way. Returns the token hit.
        fn descend(self: *Self, items: []const cst.Element) !?*const cst.Token {
            for (items) |*item| {
                if (!item.span().contains(self.pos)) continue;

                switch (item.*) {
                    .node => |node| {
                        if (self.scope.child(node)) |child_scope|
                            self.scope = child_scope;

                        try self.stack.append(self.allocator, node);

                        if (try self.descend(node.children)) |token|
                            return token;
                    },
                    .token => |*token| return token,
                    .missing => {},
                }
            }
            return null;
        }
    };

    var walker: Walker = .{
        .allocator = allocator,
        .stack = .empty,
        .scope = root_scope,
        .pos = pos,
    };

    const exact = try walker.descend(root_node.children);

    return .{
        .exact = exact,
        .scope = walker.scope,
        .stack = try walker.stack.toOwnedSlice(allocator),
    };
}

/// The range that a completion should replace: the word under the cursor,
/// or an empty range at `pos` if there isn't one.
pub fn wordRange(cc: *const CursorContext, pos: u32) Range {
    const empty: Range = .{ .start = pos, .end = pos };

    const exact = cc.exact orelse return empty;
    if (exact.kind != .ident) return empty;

    // Include the `@` of a builtin call so `@fo|` replaces the whole thing.
    if (cc.significantParent(&.{.builtin_call}, null)) |call| {
        if (call.childToken(.at)) |at| {
            return .fromSpan(.between(at.span, exact.span));
        }
    }

    return .fromSpan(exact.span);
}

// ── Analysis: what does the cursor want? ─────────────────────────────────

const PatchResult = struct {
    node: *const cst.Node,
    patch_pos: u32,
};

/// Re-parses the source with the word under the cursor replaced by a
/// placeholder identifier, so the cursor always sits on a real token.
fn patchAndParse(arena: std.mem.Allocator, source: []const u8, range: Range) !PatchResult {
    const PATCH = "__cursor__";
    const patched_source = try std.mem.concat(arena, u8, &.{
        source[0..range.start],
        PATCH,
        source[range.end..],
    });

    var diag: compiler.Diagnostics = .init(arena);
    var lexer: compiler.Lexer = .init(arena, patched_source);

    const tree = try compiler.token_tree.TreeReader.read(
        arena,
        &lexer,
        &diag,
    );

    var cursor: compiler.token_tree.Cursor = .init(tree);
    var parser: compiler.Parser = try .init(arena, &cursor, &diag);

    return .{
        .node = try parser.parseFile(),
        .patch_pos = range.start + @as(u32, @intCast(PATCH.len)),
    };
}

fn analyse(arena: std.mem.Allocator, source: []const u8, range: Range) !Want {
    const patched = try patchAndParse(arena, source, range);
    const pcc = try buildCursorContext(
        arena,
        patched.node,
        &Scope.empty,
        patched.patch_pos,
    );
    std.log.debug(
        "pcc: {s}",
        .{
            if (pcc.exact) |e|
                @tagName(e.kind)
            else
                "none",
        },
    );

    const owner = pcc.significantParent(&.{
        .set,
        .set_decl,
        .task,
        .group,
        .parameter,
        .task_call,
    }, null) orelse return .nothing;

    return switch (owner.kind) {
        .set_decl => .setting,
        .set => {
            if (pcc.exact == null or pcc.atNode(.name) == false) return .nothing;
            return attributeWant(&pcc, .set, .setting);
        },
        .task => {
            if (pcc.exact == null or pcc.atNode(.name) == false) return .nothing;
            return attributeWant(&pcc, .task, .task);
        },
        .group => {
            if (pcc.exact == null or pcc.atNode(.name) == false) return .nothing;
            return attributeWant(&pcc, .group, .group);
        },
        .parameter => {
            if (pcc.exact == null or pcc.atNode(.name) == false) return .nothing;
            return attributeWant(&pcc, .parameter, .{
                .parameter = argTypeOf(.from(owner)),
            });
        },
        .task_call => {
            const task_call: ast.TaskCall = .from(owner);

            if (task_call.task.node.span.contains(patched.patch_pos) == false)
                return .nothing;
            std.log.debug("task_call", .{});
            return .{
                .group_task = .{
                    .group = switch (task_call.scope) {
                        .group => |name| name.string(),
                        else => null,
                    },
                },
            };
        },
        else => unreachable, // significantParent only returns the kinds above
    };
}

/// The cursor is in an attribute name that belongs to `owner`.
fn attributeWant(
    cc: *const CursorContext,
    comptime owner: cst.NodeKind,
    attribute: Want.Attribute,
) Want {
    // Stops at `owner` so we don't pick up attributes of an outer item.
    _ = cc.significantParent(&.{.attribute}, owner) orelse return .nothing;
    return .{ .attribute = attribute };
}

fn argTypeOf(parameter: ast.Parameter) ?ts.ArgType {
    const token = parameter.type.type orelse return null;

    // Return null rather than panicking: the file is mid-edit and may be
    // malformed.
    return if (parameter.type.is_list) switch (token.kind) {
        .number_type => .list_number,
        .string_type => .list_string,
        else => null,
    } else switch (token.kind) {
        .number_type => .number,
        .string_type => .string,
        .flag_type => .flag,
        else => null,
    };
}

// ── Completion sources ───────────────────────────────────────────────────

// Keywords

const KeywordSpec = struct {
    label: []const u8,
    new_text: []const u8,
    filter_text: ?[]const u8 = null,
    snippet: ?[]const u8 = null,
};

const keyword_specs: []const KeywordSpec = &.{
    .{
        .label = "for",
        .new_text = "for",
        .snippet = "for(${1}) |${2}| ${0}",
    },
    .{
        .label = "switch",
        .new_text = "switch",
        .snippet =
        \\switch(${1}) {
        \\  ${2:else} => ${0},
        \\}
        ,
    },
    .{
        .label = "if",
        .new_text = "if",
        .snippet = "if(${1}) ${0}",
    },
    .{
        .label = "task",
        .new_text = "task",
        .snippet = "task ${1:name} ${0:body}",
    },
    .{
        .label = "group",
        .new_text = "group",
        .snippet =
        \\group ${1:name}(${2:args}) {
        \\  ${0}
        \\}
        ,
    },
    .{
        .label = "anonymous group",
        .filter_text = "agroup",
        .new_text = "group",
        .snippet =
        \\group (${2:args}) {
        \\  ${0}
        \\}
        ,
    },
    .{
        .label = "set",
        .new_text = "set",
    },
};

pub fn getKeywordCompletions() []const Completion {
    const result = comptime blk: {
        var out: [keyword_specs.len]Completion = undefined;

        for (keyword_specs, &out) |spec, *completion| {
            completion.* = .{
                .label = spec.label,
                .new_text = spec.new_text,
                .filter_text = spec.filter_text, // was being dropped before
                .snippet = spec.snippet,
                .kind = .Keyword,
            };
        }
        break :blk out;
    };

    return &result;
}

// Builtins

pub fn getBuiltinCompletions() []const Completion {
    @setEvalBranchQuota(100_000);
    const functions = compiler.functions;

    const result = comptime blk: {
        var out: [functions.definitions.items.len]Completion = undefined;

        for (functions.definitions.items, &out) |def, *completion| {
            completion.* = .{
                .label = "@" ++ @tagName(def.ident),
                .labelDetail = .{
                    .detail = Signature.params(def.args),
                    .description = Signature.typeExpr(def.return_type),
                },
                .new_text = "@" ++ @tagName(def.ident),
                .detail = Signature.detail(def),
                .snippet = Signature.snippet(def),
                .kind = .Function,
            };
        }
        break :blk out;
    };

    return &result;
}

pub fn getTasksCompletions(allocator: std.mem.Allocator, scope: *const Scope, group_name: ?[]const u8) ![]const Completion {
    const target_scope: *const Scope = if (group_name) |gn|
        if (scope.resolve(gn, .group)) |group|
            group.origin.group.scope
        else
            return &.{}
    else
        scope.rootConst();

    var out: std.ArrayList(Completion) = .empty;

    for (target_scope.symbols.items) |symbol| {
        _ = switch (symbol.origin) {
            .task => |task| task,
            else => continue,
        };

        const item: Completion = .{
            .label = symbol.name,
            .new_text = symbol.name,
            .kind = .Function,
        };

        try out.append(allocator, item);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn getSymbolsCompletions(allocator: std.mem.Allocator, scope: *const Scope, pos: u32) ![]const Completion {
    var out: std.ArrayList(Completion) = .empty;

    var current: ?*const Scope = scope;

    while (current) |curr| {
        for (curr.symbols.items) |symbol| {
            if (curr == scope and symbol.span.before(pos))
                continue;

            const item: Completion = .{
                .label = symbol.name,
                .kind = switch (symbol.origin) {
                    .argument, .capture, .binding => .Variable,
                    .group => .Module,
                    .task => .Function,
                },
                .new_text = symbol.name,
                .detail = switch (symbol.origin) {
                    .argument => |arg| try std.fmt.allocPrint(allocator, "{f}", .{arg.type.typeOf()}),
                    .binding => |binding| try std.fmt.allocPrint(allocator, "{f}", .{binding.type}),
                    .capture => |capture| try std.fmt.allocPrint(allocator, "{f}", .{capture.type}),
                    else => null,
                },
                .snippet = switch (symbol.origin) {
                    .group => |group| try std.fmt.allocPrint(allocator, "{s}::${{1}}", .{group.name.?}),
                    else => null,
                },
            };

            try out.append(allocator, item);
        }
        current = curr.parent;
    }

    return try out.toOwnedSlice(allocator);
}

/// Comptime rendering of builtin function signatures.
const Signature = struct {
    const functions = compiler.functions;

    /// `@name(${1:a: T},${2:b: U})`, plus a fallback tab stop for fallible builtins.
    fn snippet(comptime def: functions.definitions.DefinitionT) []const u8 {
        comptime {
            var builder: ct.StringBuilder = .init("@" ++ @tagName(def.ident) ++ "(");

            for (def.args, 0..) |arg, idx| {
                if (idx != 0) builder.appendRaw(",");
                builder.append("${{{}:{s}}}", .{ idx + 1, param(arg) });
            }

            builder.appendRaw(")");

            if (def.return_type == .result) {
                builder.append(" fallback ${{{}}}", .{def.args.len + 1});
            }

            return builder.buffer;
        }
    }

    /// `@name((a: T, b: U)) -> R`
    fn detail(comptime def: functions.definitions.DefinitionT) []const u8 {
        return std.fmt.comptimePrint("{s}({s}) -> {s}", .{
            "@" ++ @tagName(def.ident),
            params(def.args),
            typeExpr(def.return_type),
        });
    }

    /// `(a: T, b: U)`
    fn params(comptime list: []const functions.Spec.Param) []const u8 {
        comptime {
            var builder: ct.StringBuilder = .init("(");

            for (list, 0..) |p, idx| {
                if (idx != 0) builder.appendRaw(",");
                builder.appendRaw(param(p));
            }

            builder.appendRaw(")");
            return builder.buffer;
        }
    }

    /// `a: T`
    fn param(comptime p: functions.Spec.Param) []const u8 {
        return std.fmt.comptimePrint("{s}: {s}", .{ p.name, typeExpr(p.type) });
    }

    fn typeExpr(comptime type_expr: ts.TypeExpr) []const u8 {
        return switch (type_expr) {
            .concrete => |concrete| std.fmt.comptimePrint("{f}", .{concrete}),
            .generic => |generic| generic,
            .list => |list| std.fmt.comptimePrint("[]{s}", .{typeExpr(list.*)}),
            .lambda => |lambda| lambdaExpr(lambda.*),
            .result => |result| std.fmt.comptimePrint("!{s}", .{typeExpr(result.*)}),
        };
    }

    /// `|A,B| -> R`
    fn lambdaExpr(comptime lambda: ts.LambdaTypeExpr) []const u8 {
        comptime {
            var builder: ct.StringBuilder = .init("|");

            for (lambda.params, 0..) |p, idx| {
                if (idx != 0) builder.appendRaw(",");
                builder.append("{s}", .{typeExpr(p)});
            }

            builder.append("| -> {s}", .{typeExpr(lambda.return_type)});
            return builder.buffer;
        }
    }
};

fn getSettingCompletions() []const Completion {
    @setEvalBranchQuota(100_000);

    const result = comptime blk: {
        var out: [options.options.raw.len]Completion = undefined;

        for (options.options.raw, &out) |def, *completion| {
            completion.* = .{
                .label = @tagName(def.id),
                .new_text = @tagName(def.id),
                .kind = .Property,
            };
        }

        break :blk out;
    };

    return &result;
}

// Attributes

pub fn getAttributeCompletions(allocator: std.mem.Allocator, want: Want.Attribute) ![]const Completion {
    var out: std.ArrayList(Completion) = .empty;

    for (attributes.definitions.raw) |attr| {
        std.log.debug("want: {any}, vf: {any}", .{ want, attr.valid_for });
        for (attr.valid_for) |vf| {
            const valid = switch (vf) {
                .argument => |arg| want == .parameter and if (want.parameter) |t|
                    (arg.count() == 0 or arg.contains(t))
                else
                    false,
                .group => want == .group,
                .setting => want == .setting,
                .task => want == .task,
            };
            if (valid)
                break;
        } else continue;

        try out.append(allocator, .{
            .kind = .Property,
            .label = @tagName(attr.type),
            .new_text = @tagName(attr.type),
        });
    }
    std.log.debug("attrs: {}", .{out.items.len});
    return try out.toOwnedSlice(allocator);
}

fn attributeApplies(attr: anytype, want: Want.Attribute) bool {
    for (attr.valid_for) |target| {
        const applies = switch (target) {
            .argument => |arg_types| switch (want) {
                // Parameter type unknown (e.g. still being typed): offer all.
                .parameter => |arg_type| if (arg_type) |t| arg_types.contains(t) else true,
                else => false,
            },
            .group => want == .group,
            .task => want == .task,
            .setting => want == .setting,
        };

        if (applies) return true;
    }
    return false;
}
