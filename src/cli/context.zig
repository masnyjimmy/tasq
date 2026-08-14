const std = @import("std");
const conzole = @import("conzole");
const compiler = @import("compiler");

allocator: std.mem.Allocator,
io: std.Io,
environ: *const std.process.Environ.Map,
printer: *conzole.terminal.Printer,
workspace: *compiler.Workspace,
