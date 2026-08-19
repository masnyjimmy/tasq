const std = @import("std");

const lib = @import("lib");
const compiler = @import("compiler");
const Diagnostics = compiler.Diagnostics;

const conzole = @import("conzole");

pub fn dump_diagnostics(
    allocator: std.mem.Allocator,
    source: []const u8,
    uri: []const u8,
    diagnostics: *const Diagnostics,
    printer: *conzole.terminal.Printer,
) !void {
    const records = diagnostics.records.items;

    for (records) |record| {
        const lc = try lib.debug.lineColFromIndex(source, record.span.start);

        try printer.printStyled(
            allocator,
            .{ .fg = .white },
            "{[file]s}:{[line]}:{[col]}",
            .{ .file = uri, .line = lc.line, .col = lc.column },
        );

        const severity_color: conzole.terminal.Color = switch (record.severity) {
            .err => .bright_red,
            .hint => .bright_green,
            .warn => .yellow,
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
    }

    try printer.flush();
}
