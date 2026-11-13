// text_block.zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig"); // needs: unescapeInto(dst: []u8, src: []const u8) !usize

pub const Escapes = enum { none, cooked };
pub const Shape = enum { single_line_only, block_allowed };

pub const Problem = struct {
    kind: Kind,
    /// Slice of the ORIGINAL source: offset = @intFromPtr(at.ptr) - @intFromPtr(source.ptr)
    at: []const u8,

    pub const Kind = enum {
        break_in_single_line,
        text_on_opener_line,
        text_on_closer_line,
        invalid_escape,
        invalid_utf8,
    };

    pub fn message(p: Problem) []const u8 {
        return switch (p.kind) {
            .break_in_single_line => "line break in a single-line string",
            .text_on_opener_line => "a multiline string must start on the line after the opening quote",
            .text_on_closer_line => "the closing quote of a multiline string must be on its own line",
            .invalid_escape => "invalid escape sequence",
            .invalid_utf8 => "invalid UTF-8",
        };
    }
};

/// What pass 1 learned; input of pass 2.
pub const Block = struct {
    is_block: bool,
    indent: []const u8, // slice of the source, never allocated
    parts: usize,
    cap: usize, // exact upper bound of buffer bytes needed (0 = nothing to copy)
};

pub const Result = union(enum) { ok: Block, bad: Problem };

// ───────────────────────── pass 1 ─────────────────────────

pub const Measure = struct {
    shape: Shape,
    parts: usize = 0,
    cap: usize = 0,
    is_block: bool = false,
    line_start: bool = true,
    common: ?[]const u8 = null,
    pending: ?[]const u8 = null, // whitespace-only line start, decided by what follows
    closer_ok: bool = false,
    last_line: []const u8 = "",
    first_break: ?[]const u8 = null,

    pub fn init(shape: Shape) Measure {
        return .{ .shape = shape };
    }

    pub fn hole(m: *Measure) void {
        m.parts += 1;
        if (!m.is_block) return;
        if (m.pending) |ws| m.common = commonPrefix(m.common, ws);
        m.pending = null;
        m.line_start = false;
        m.closer_ok = false;
    }

    pub fn lit(m: *Measure, src: []const u8, escapes: Escapes) void {
        const is_first = m.parts == 0;
        m.parts += 1;

        var rest = src;
        if (is_first and m.shape == .block_allowed) {
            if (cutBreak(src)) |after| {
                m.is_block = true;
                rest = after;
            }
        }

        if (!m.is_block) {
            if (escapes == .cooked and findByte(src, '\\') != null) m.cap += src.len;
            if (m.first_break == null) {
                if (findByte(src, '\n')) |i| m.first_break = src[i .. i + 1];
            }
            return;
        }

        m.cap += src.len;
        var line_start = m.line_start;
        var line: []const u8 = "";
        while (true) {
            const nl = findByte(rest, '\n');
            line = if (nl) |i| stripCr(rest[0..i]) else rest;
            if (line_start) {
                const ws = leadingWs(line);
                if (ws.len != line.len) {
                    m.common = commonPrefix(m.common, ws); // content line
                } else if (nl == null) {
                    m.pending = ws; // blank so far: a hole may follow
                }
            }
            const i = nl orelse break;
            rest = rest[i + 1 ..];
            line_start = true;
        }
        m.closer_ok = line_start and isBlank(line);
        m.line_start = line_start and line.len == 0;
        m.last_line = line;
    }

    pub fn finish(m: *const Measure) Result {
        if (!m.is_block) {
            if (m.first_break) |at| return .{ .bad = .{
                .kind = if (m.shape == .single_line_only) .break_in_single_line else .text_on_opener_line,
                .at = at,
            } };
            return .{ .ok = .{ .is_block = false, .indent = "", .parts = m.parts, .cap = m.cap } };
        }
        if (!m.closer_ok) return .{ .bad = .{ .kind = .text_on_closer_line, .at = m.last_line } };
        return .{ .ok = .{ .is_block = true, .indent = m.common orelse "", .parts = m.parts, .cap = m.cap } };
    }
};

// ───────────────────────── pass 2 ─────────────────────────

pub const Writer = struct {
    block: Block,
    buf: []u8, // at least block.cap bytes
    used: usize = 0,
    index: usize = 0,
    line_start: bool = true,

    problem: Problem = .{ .kind = .invalid_escape, .at = "" },

    pub fn init(block: Block, buf: []u8) Writer {
        std.debug.assert(buf.len >= block.cap);
        return .{ .block = block, .buf = buf };
    }

    pub fn hole(w: *Writer) void {
        w.index += 1;
        w.line_start = false;
    }

    /// Final text of one piece: a slice of the source (nothing to change) or of `buf`.
    /// Pass the same `escapes` as in pass 1. May return "": skip empty pieces.
    pub fn lit(w: *Writer, src: []const u8, escapes: Escapes) error{InvalidText}![]const u8 {
        const is_first = w.index == 0;
        const is_last = w.index + 1 == w.block.parts;
        w.index += 1;
        const start = w.used;

        if (!w.block.is_block) {
            if (escapes == .none or findByte(src, '\\') == null) return src;
            try w.put(src, escapes);
            return w.buf[start..w.used];
        }

        var rest = if (is_first) cutBreak(src).? else src; // pass 1 guarantees the break
        var line_start = w.line_start;
        var wrote_break = false;
        while (true) {
            const nl = findByte(rest, '\n');
            const raw = if (nl) |i| stripCr(rest[0..i]) else rest;

            if (nl == null and is_last) { // closer line: drop it and the break before it
                if (wrote_break) w.used -= 1;
                break;
            }

            const line = if (!line_start)
                raw
            else if (nl != null and isBlank(raw))
                raw[0..0]
            else
                raw[w.block.indent.len..];
            try w.put(line, escapes);

            const i = nl orelse {
                w.line_start = line_start and raw.len == 0;
                break;
            };
            w.buf[w.used] = '\n';
            w.used += 1;
            wrote_break = true;
            rest = rest[i + 1 ..];
            line_start = true;
        }
        return w.buf[start..w.used];
    }

    fn put(w: *Writer, src: []const u8, escapes: Escapes) error{InvalidText}!void {
        switch (escapes) {
            .none => {
                @memcpy(w.buf[w.used..][0..src.len], src);
                w.used += src.len;
            },
            .cooked => {
                var diag: text.Diag = .{};
                const n = text.unescape(w.buf[w.used..], src, &diag) catch |err| {
                    w.problem = .{
                        .kind = switch (err) {
                            text.Error.InvalidEscape => .invalid_escape,
                            text.Error.InvalidUtf8 => .invalid_utf8,
                        },
                        .at = src[diag.offset..][0..diag.len],
                    };
                    return error.InvalidText;
                };
                w.used += n;
            },
        }
    }
};

// ───────────────────────── one-part shortcut ─────────────────────────

pub const Whole = union(enum) { ok: []const u8, bad: Problem };

pub fn whole(arena: Allocator, src: []const u8, shape: Shape, escapes: Escapes) Allocator.Error!Whole {
    var m = Measure.init(shape);
    m.lit(src, escapes);
    const block = switch (m.finish()) {
        .ok => |b| b,
        .bad => |p| return .{ .bad = p },
    };
    var w = Writer.init(block, try arena.alloc(u8, block.cap)); // cap 0: no allocation
    const s = w.lit(src, escapes) catch return .{ .bad = w.problem };
    return .{ .ok = s };
}

// ───────────────────────── helpers ─────────────────────────

fn findByte(s: []const u8, b: u8) ?usize {
    return std.mem.findScalar(u8, s, b); // one place to fix if std renames again
}
fn isBlank(s: []const u8) bool {
    for (s) |c| if (c != ' ' and c != '\t') return false;
    return true;
}
fn leadingWs(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[0..i];
}
fn stripCr(s: []const u8) []const u8 {
    return if (s.len > 0 and s[s.len - 1] == '\r') s[0 .. s.len - 1] else s;
}
fn cutBreak(s: []const u8) ?[]const u8 {
    if (s.len >= 2 and s[0] == '\r' and s[1] == '\n') return s[2..];
    if (s.len >= 1 and s[0] == '\n') return s[1..];
    return null;
}
fn commonPrefix(common: ?[]const u8, ws: []const u8) []const u8 {
    const c = common orelse return ws;
    var i: usize = 0;
    const n = @min(c.len, ws.len);
    while (i < n and c[i] == ws[i]) i += 1;
    return c[0..i];
}
