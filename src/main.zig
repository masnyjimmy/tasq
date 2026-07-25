const std = @import("std");
const cli = @import("cli");
const lib = @import("lib");
const compiler = @import("compiler");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    try cli.run(
        init.gpa,
        init.io,
        init.environ_map,
        args,
    );
}
