const std = @import("std");
const Span = @import("Span.zig");
const Token = @import("Token.zig");
const Lexer = @import("lexer.zig").Lexer;
const Diagnostics = @import("Diagnostics.zig");

pub const Cursor = struct {
    events: []const TreeReader.Event,
    pos: usize,
    depth: usize,

    pub fn init(tt_events: []const TreeReader.Event) Cursor {
        return .{
            .events = tt_events,
            .pos = 0,
            .depth = 0,
        };
    }

    pub fn advance(self: *Cursor) ?Token {
        if (self.pos >= self.events.len) return null;

        const evt = self.events[self.pos];
        self.pos += 1;

        switch (evt) {
            .open => self.depth += 1,
            .close => self.depth -= 1,
            .token => {},
        }

        return eventToken(evt);
    }

    pub fn retreat(self: *Cursor) void {
        std.debug.assert(self.pos != 0);
        self.pos -= 1;
        switch (self.events[self.pos]) {
            .open => self.depth -= 1,
            .close => self.depth += 1,
            .token => {},
        }
    }

    pub fn atEnd(self: *Cursor) bool {
        return self.peek() == .eof;
    }

    pub fn peek(self: *Cursor) Token.Kind {
        return self.kindAt(self.pos);
    }

    pub fn kindAt(self: *Cursor, pos: usize) Token.Kind {
        if (self.pos >= self.events.len) return .eof;

        return eventKind(self.events[pos]);
    }

    pub fn atOwnClose(self: *Cursor, depth: usize) bool {
        if (self.pos >= self.events.len) return true;
        return self.depth == depth and self.events[self.pos] == .close;
    }

    pub fn atClose(self: *Cursor) bool {
        if (self.pos >= self.events.len) return true;
        return self.events[self.pos] == .close;
    }

    pub fn spanAt(self: *Cursor, pos: usize) Span {
        if (pos < self.events.len) {
            if (eventSpan(self.events[pos])) |span| return span;
        }
        return self.insertionPoint(pos);
    }

    /// Zero-width span placed right after the nearest real event strictly
    /// before `pos` (searching backward). Used when `pos` itself has no
    /// real span — a poisoned close, or true eof past the last event.
    /// Returns {0,0} if nothing real precedes it (e.g. the very first
    /// event in the file is already broken).
    fn insertionPoint(self: *Cursor, pos: usize) Span {
        var idx = @min(pos, self.events.len);
        while (idx > 0) {
            idx -= 1;
            if (eventSpan(self.events[idx])) |span|
                return span.insertionPoint();
        }
        return .{ .start = 0, .len = 0 };
    }

    fn eventSpan(evt: TreeReader.Event) ?Span {
        return switch (evt) {
            .token => |t| t.span,
            .open => |open| open.token.span,
            .close => |close| if (close.token) |t|
                t.span
            else
                null,
        };
    }

    fn eventKind(evt: TreeReader.Event) Token.Kind {
        return switch (evt) {
            .token => |t| t.kind,
            .open => |o| o.token.kind,
            .close => |c| if (c.token) |t| t.kind else Delims.closing(c.delim),
        };
    }

    fn eventToken(evt: TreeReader.Event) ?Token {
        return switch (evt) {
            .token => |t| t,
            .open => |o| o.token,
            .close => |c| c.token,
        };
    }
};

pub const TreeReader = struct {
    pub const Event = union(enum) {
        const Open = struct {
            delim: Delim,
            token: Token,
        };
        const Close = struct {
            delim: Delim,
            token: ?Token,
            open_idx: usize,
        };

        token: Token,
        open: Open,
        close: Close,
    };

    events: std.ArrayList(Event) = .empty,
    unclosed_indices: std.ArrayList(usize) = .empty,
    lexer: *Lexer,
    diagnostics: *Diagnostics,

    pub fn init(lexer: *Lexer, diagnostics: *Diagnostics) TreeReader {
        return .{ .lexer = lexer, .diagnostics = diagnostics };
    }

    pub fn deinit(self: *TreeReader, allocator: std.mem.Allocator) void {
        self.events.deinit(allocator);
        self.unclosed_indices.deinit(allocator);
    }

    pub fn read(allocator: std.mem.Allocator, lexer: *Lexer, diagnostics: *Diagnostics) ![]Event {
        var reader: TreeReader = .init(lexer, diagnostics);
        defer reader.deinit(allocator);

        return try reader.group(allocator);
    }

    /// Consumes the whole token stream and returns the top-level tree.
    /// Ownership of the returned slice passes to the caller.
    pub fn group(self: *TreeReader, allocator: std.mem.Allocator) ![]Event {
        var token = try self.lexer.next();
        while (token.kind != .eof) : (token = try self.lexer.next()) {
            if (Delims.delimOf(token.kind)) |d| {
                try self.handleOpen(allocator, token, d);
            } else if (Delims.isClosing(token.kind)) {
                try self.handleClose(allocator, token);
            } else {
                try self.events.append(allocator, .{ .token = token });
            }
        }

        try self.unwindUnclosed(allocator);
        std.debug.assert(self.unclosed_indices.items.len == 0);
        return self.events.toOwnedSlice(allocator);
    }

    // ── open / close handling ────────────────────────────────────────────

    fn handleOpen(self: *TreeReader, allocator: std.mem.Allocator, open: Token, delim: Delim) !void {
        const idx = self.events.items.len;

        try self.events.append(
            allocator,
            .{ .open = .{
                .token = open,
                .delim = delim,
            } },
        );

        try self.unclosed_indices.append(allocator, idx);
    }

    fn handleClose(self: *TreeReader, allocator: std.mem.Allocator, token: Token) !void {
        const unclosed = self.currentUnclosed() orelse {
            try self.diagnostics.err(token.span, "unexpected closing '{t}'", .{token.kind});
            return;
        };

        if (token.kind != Delims.closing(unclosed.delim)) {
            try self.handleMismatch(allocator, token);
            return;
        }

        const idx = self.unclosed_indices.pop() orelse unreachable;

        try self.events.append(allocator, .{ .close = .{
            .delim = unclosed.delim,
            .token = token,
            .open_idx = idx,
        } });
    }

    fn currentUnclosed(self: *TreeReader) ?Event.Open {
        const idx = self.unclosed_indices.getLastOrNull() orelse return null;

        return self.events.items[idx].open;
    }

    /// Closer doesn't match the innermost frame. Check whether some
    /// ancestor frame actually matches it — if so, the innermost frames
    /// up to that ancestor are unclosed and get poisoned; if not, this
    /// token is just garbage and gets dropped with a diagnostic.
    fn handleMismatch(self: *TreeReader, allocator: std.mem.Allocator, token: Token) !void {
        if (!self.hasAncestorMatching(token.kind)) {
            // invalid closing, skip it entirely,
            // TODO: does it leaves gap in source then? consider if its ok
            try self.events.append(allocator, .{ .token = token });
            try self.diagnostics.err(token.span, "unexpected closing '{t}'", .{token.kind});
            return;
        }

        while (self.unclosed_indices.pop()) |idx| {
            const open = self.events.items[idx].open;

            if (Delims.closing(open.delim) == token.kind) {
                try self.events.append(allocator, .{ .close = .{
                    .delim = open.delim,
                    .token = token,
                    .open_idx = idx,
                } });
                break;
            }
            try self.diagnostics.err(open.token.span, "unclosed '{t}'", .{open.token.kind});
            try self.events.append(allocator, .{ .close = .{
                .delim = open.delim,
                .token = null,
                .open_idx = idx,
            } });
        }
    }

    fn hasAncestorMatching(self: *TreeReader, closing: Token.Kind) bool {
        var it = std.mem.reverseIterator(self.unclosed_indices.items);

        while (it.next()) |idx| {
            const open = self.events.items[idx].open;

            if (Delims.closing(open.delim) == closing) return true;
        }

        return false;
    }

    /// Whatever's left open at EOF is unclosed — poison and flush each one.
    fn unwindUnclosed(self: *TreeReader, allocator: std.mem.Allocator) !void {
        while (self.unclosed_indices.pop()) |idx| {
            const open = self.events.items[idx].open;

            try self.diagnostics.err(open.token.span, "unclosed '{t}'", .{open.token.kind});
            try self.events.append(allocator, .{ .close = .{
                .delim = open.delim,
                .token = null,
                .open_idx = idx,
            } });
        }
    }
};

pub const Delim = enum { paren, bracket, brace, double_brace };

pub const Delims = struct {
    const Pair = struct { delim: Delim, open: Token.Kind, close: Token.Kind };

    // single source of truth — add a new delimiter pair here and
    // every lookup below picks it up automatically.
    const pairs = [_]Pair{
        .{ .delim = .paren, .open = .lparen, .close = .rparen },
        .{ .delim = .bracket, .open = .lbracket, .close = .rbracket },
        .{ .delim = .brace, .open = .lbrace, .close = .rbrace },
        .{ .delim = .double_brace, .open = .ldbrace, .close = .rdbrace },
    };

    const open_by_delim = blk: {
        var arr = std.EnumArray(Delim, Token.Kind).initUndefined();
        for (pairs) |p| arr.set(p.delim, p.open);
        break :blk arr;
    };

    const close_by_delim = blk: {
        var arr = std.EnumArray(Delim, Token.Kind).initUndefined();
        for (pairs) |p| arr.set(p.delim, p.close);
        break :blk arr;
    };

    const delim_by_open = blk: {
        var arr = std.EnumArray(Token.Kind, ?Delim).initFill(null);
        for (pairs) |p| arr.set(p.open, p.delim);
        break :blk arr;
    };

    const close_set = blk: {
        var set = std.EnumSet(Token.Kind).initEmpty();
        for (pairs) |p| set.insert(p.close);
        break :blk set;
    };

    pub fn opening(delim: Delim) Token.Kind {
        return open_by_delim.get(delim);
    }

    pub fn closing(delim: Delim) Token.Kind {
        return close_by_delim.get(delim);
    }

    pub fn delimOf(open_kind: Token.Kind) ?Delim {
        return delim_by_open.get(open_kind);
    }

    pub fn isClosing(kind: Token.Kind) bool {
        return close_set.contains(kind);
    }
};
