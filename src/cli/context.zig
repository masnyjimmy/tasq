const std = @import("std");
const conzole = @import("conzole");
const lib = @import("lib");
const compiler = @import("compiler");

gpa: std.mem.Allocator,
io: std.Io,
environ: *const std.process.Environ.Map,
printer: *conzole.terminal.Printer,
diagnostics: *lib.Diagnostic.List,
workspace: *compiler.Workspace,
source_file_path: []const u8 = "tasq"
