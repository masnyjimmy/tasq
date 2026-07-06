const std = @import("std");
const conzole = @import("conzole");
const lib = @import("lib");

gpa: std.mem.Allocator,
io: std.Io,
environ: *const std.process.Environ.Map,
printer: *conzole.terminal.Printer,
diagnostics: *lib.Diagnostic.List,
source_store: *lib.source_file.SourceStore,
source_file_path: []const u8 = "tasq"
