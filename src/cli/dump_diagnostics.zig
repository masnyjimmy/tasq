const std = @import("std");

const lib = @import("lib");
const compiler = @import("compiler");
const Diagnostics = compiler.Diagnostics;
const Span = compiler.Span;

const conzole = @import("conzole");

pub fn dump_diagnostics(
    allocator: std.mem.Allocator,
    source: []const u8,
    uri: []const u8,
    diagnostics: *const Diagnostics,
    printer: *conzole.terminal.Printer,
) !void {
    for (diagnostics.records.items) |record| {
        try printLocation(allocator, source, uri, record.span, printer, "");

        const severity_color: conzole.terminal.Color = switch (record.severity) {
            .err => .bright_red,
            .hint => .bright_green,
            .warn => .yellow,
            .unnecessary => .bright_black,
        };

        try printer.printStyled(
            allocator,
            .{ .bold = true, .fg = severity_color },
            "{f}: ",
            .{record.severity},
        );

        try printer.printStyled(
            allocator,
            .{ .fg = .bright_white },
            "{s}\n",
            .{record.message},
        );

        for (record.related) |rel| {
            try printLocation(allocator, source, uri, rel.span, printer, "  ");

            try printer.printStyled(
                allocator,
                .{ .bold = true, .fg = .bright_cyan },
                "note: ",
                .{},
            );

            try printer.printStyled(
                allocator,
                .{ .fg = .bright_black },
                "{s}\n",
                .{rel.message},
            );
        }
    }

    try printer.flush();
}

fn printLocation(
    allocator: std.mem.Allocator,
    source: []const u8,
    uri: []const u8,
    span: Span,
    printer: *conzole.terminal.Printer,
    indent: []const u8,
) !void {
    const lc = try lib.debug.lineColFromIndex(source, span.start);

    try printer.printStyled(
        allocator,
        .{ .fg = .white },
        "{[file]s}:{[line]}:{[column]}: {[indent]s}",
        .{ .indent = indent, .file = uri, .line = lc.line, .column = lc.column },
    );
}
