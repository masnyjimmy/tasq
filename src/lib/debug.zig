const std = @import("std");

pub const LineCol = struct {
    line: usize,
    column: usize,
};

pub fn lineColFromIndex(text: []const u8, index: usize) !LineCol {
    if (index > text.len) return error.IndexOutOfBounds;

    var line: usize = 1;
    var col: usize = 1;

    var i: usize = 0;
    while (i < index) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }

    return .{ .line = line, .column = col };
}

fn isSimpleType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => true,
        else => false,
    };
}

// FIX: use `gpa` consistently everywhere — original code mixed in std.heap.page_allocator
// FIX: deinit/toOwnedSlice now take an allocator in Zig 0.15+ (unmanaged-by-default migration)
// FIX: removed the trailing null byte — you're printing with {s} on a Zig slice, not a C string
fn visualizeString(gpa: std.mem.Allocator, in: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(gpa, in.len * 2);
    errdefer out.deinit(gpa);

    for (in) |ch| {
        switch (ch) {
            '\t' => try out.appendSlice(gpa, "\\t"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '"' => try out.appendSlice(gpa, "\\\""),
            else => try out.append(gpa, ch),
        }
    }

    return out.toOwnedSlice(gpa);
}

fn isBuiltIn(t: anytype) bool {
    const typeName = @typeName(t);
    if (std.mem.indexOf(u8, typeName, "HashMap") != null) {
        return true;
    }
    return false;
}

fn isIterable(comptime t: type) bool {
    return @hasDecl(t, "iterator");
}

pub fn dump(
    value: anytype,
    comptime indent_width: usize,
) void {
    const Dumper = struct {
        allocator: std.heap.DebugAllocator(.{}),
        visited_ptrs: std.AutoHashMap(usize, usize),
        next_id: usize = 0,

        pub fn deinit(self: *@This()) void {
            self.visited_ptrs.deinit();
        }

        fn indent(n: usize) void {
            for (0..n) |_| std.debug.print(" ", .{});
        }

        pub fn print(comptime fmt: []const u8, args: anytype) void {
            std.debug.print(fmt, args);
        }

        // FIX: removed all `try` — this function returns void, errors are silently dropped
        // with `catch return` at each callsite that can fail

        const C_RESET = "\x1b[0m";
        const C_DIM = "\x1b[2;37m"; // grey   — null, empty
        const C_KEY = "\x1b[1;37m"; // bold white — field names
        const C_STR = "\x1b[32m"; // green  — strings
        const C_REF = "\x1b[36m"; // cyan   — #N anchor / → #N back-ref
        const C_ENUM = "\x1b[33m"; // yellow — enum / union tags
        const C_NUM = "\x1b[35m"; // magenta — numbers / bools

        pub fn dump(self: *@This(), value_: anytype, depth: usize) void {
            const T = @TypeOf(value_);
            const ti = @typeInfo(T);
            const pad = indent_width * depth;
            const child_pad = indent_width * (depth + 1);

            switch (ti) {
                .int, .float, .bool => {
                    print(C_NUM ++ "{any}" ++ C_RESET, .{value_});
                },

                .@"enum" => |e| {
                    // FIX: handle id like enums
                    const has_field = inline for (e.fields) |field| {
                        if (field.value == @intFromEnum(value_))
                            break true;
                    } else false;

                    if (has_field) {
                        print(C_ENUM ++ ".{s}" ++ C_RESET, .{@tagName(value_)});
                    } else {
                        print(C_ENUM ++ "{}" ++ C_RESET, .{@intFromEnum(value_)});
                    }
                },

                .optional => {
                    if (value_) |v| {
                        self.dump(v, depth);
                    } else {
                        print(C_DIM ++ "null" ++ C_RESET, .{});
                    }
                },

                .pointer => |p| {
                    switch (@typeInfo(p.child)) {
                        .@"fn", .@"opaque" => return,
                        else => {},
                    }

                    // ── String slice ──────────────────────────────────────
                    if (p.size == .slice and p.child == u8) {
                        // FIX: was passing std.heap.page_allocator; use self.allocator.allocator()
                        const str = visualizeString(self.allocator.allocator(), value_) catch return;
                        defer self.allocator.allocator().free(str);
                        print(C_STR ++ "\"{s}\"" ++ C_RESET, .{str});
                        return;
                    }

                    // ── Empty slice → [] ──────────────────────────────────
                    if (p.size == .slice and value_.len == 0) {
                        print(C_DIM ++ "[]" ++ C_RESET, .{});
                        return;
                    }

                    const addr = if (p.size == .slice)
                        @intFromPtr(value_.ptr)
                    else
                        @intFromPtr(value_);

                    // ── Null-ish pointer ──────────────────────────────────
                    if (addr < 4096) {
                        print(C_DIM ++ "null" ++ C_RESET, .{});
                        return;
                    }

                    // ── Cycle detection ───────────────────────────────────
                    const gop = self.visited_ptrs.getOrPut(addr) catch |err| {
                        std.debug.print("<<error: {s}>>", .{@errorName(err)});
                        return;
                    };
                    if (gop.found_existing) {
                        print(
                            C_REF ++ "-> #{d}" ++ C_RESET,
                            .{gop.value_ptr.*},
                        );
                        return;
                    }

                    const id = self.next_id;
                    gop.value_ptr.* = id;
                    self.next_id += 1;

                    print(C_REF ++ "[#{d}]" ++ C_RESET ++ " ", .{id});

                    if (p.size == .slice) {
                        print("[\n", .{});
                        for (value_, 0..) |item, i| {
                            indent(child_pad);
                            self.dump(item, depth + 1);
                            if (i + 1 < value_.len) print(",", .{});
                            print("\n", .{});
                        }
                        indent(pad);
                        print("]", .{});
                    } else {
                        self.dump(value_.*, depth);
                    }
                },

                .array => |a| {
                    if (a.child == u8) {
                        // FIX: was passing self.allocator (the struct) instead of .allocator()
                        // FIX: removed `try` — dump returns void
                        const str = visualizeString(self.allocator.allocator(), &value_) catch return;
                        defer self.allocator.allocator().free(str);
                        print(C_STR ++ "\"{s}\"" ++ C_RESET, .{str});
                    } else if (value_.len == 0) {
                        print(C_DIM ++ "[]" ++ C_RESET, .{});
                    } else {
                        print("[\n", .{});
                        for (value_, 0..) |item, i| {
                            indent(child_pad);
                            self.dump(item, depth + 1); // FIX: removed `try`
                            if (i + 1 < value_.len) print(",", .{});
                            print("\n", .{});
                        }
                        indent(pad);
                        print("]", .{});
                    }
                },

                .@"struct" => {
                    // ── debugDump hook ────────────────────────────────────
                    if (@hasDecl(T, "debugDump")) {
                        self.dump(value_.debugDump(), depth + 1); // FIX: removed `try`
                        return;
                    }

                    // ── Iterator (HashMap etc.) ───────────────────────────
                    if (comptime isIterable(T)) {
                        var iter = @constCast(&value_).iterator();
                        const first = iter.next();
                        if (first == null) {
                            print(C_DIM ++ "{{}}" ++ C_RESET, .{});
                            return;
                        }
                        print("{{\n", .{});
                        var entry = first;
                        while (entry) |v| : (entry = iter.next()) {
                            indent(child_pad);
                            const vT = @TypeOf(v);
                            const vTi = @typeInfo(vT);
                            if (vTi == .@"struct" and vTi.@"struct".fields.len == 2) {
                                self.dump(@field(v, vTi.@"struct".fields[0].name), depth + 1); // FIX: removed `try`
                                print(": ", .{});
                                self.dump(@field(v, vTi.@"struct".fields[1].name), depth + 1); // FIX: removed `try`
                            } else {
                                self.dump(v, depth + 1); // FIX: removed `try`
                            }
                            print(",\n", .{});
                        }
                        indent(pad);
                        print("}}", .{});
                        return;
                    }

                    const fields = ti.@"struct".fields;
                    if (fields.len == 0) {
                        print(C_DIM ++ "{}" ++ C_RESET, .{});
                        return;
                    }

                    print("{{\n", .{});
                    inline for (fields, 0..) |field, i| {
                        indent(child_pad);
                        print(C_KEY ++ "{s}" ++ C_RESET ++ ": ", .{field.name});
                        self.dump(@field(value_, field.name), depth + 1);
                        if (i + 1 < fields.len) print(",", .{});
                        print("\n", .{});
                    }
                    indent(pad);
                    print("}}", .{});
                },

                .@"union" => {
                    print(C_ENUM ++ ".{s}" ++ C_RESET ++ " = ", .{@tagName(value_)});
                    switch (value_) {
                        inline else => |payload| self.dump(payload, depth), // FIX: removed `try`
                    }
                },

                else => print(C_DIM ++ "<{s}>" ++ C_RESET, .{@tagName(ti)}),
            }
        }
    };

    var dumper = Dumper{
        .allocator = .init,
        .visited_ptrs = undefined,
        .next_id = 0,
    };
    dumper.visited_ptrs = .init(dumper.allocator.allocator());
    defer dumper.deinit();

    dumper.dump(value, 0);
    Dumper.print("\n", .{});
}
