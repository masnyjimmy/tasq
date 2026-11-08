//! Build helper: writes a `sha256sum`-compatible checksum file.
//!
//!   sha256sums <output-file> <input-file>...
//!
//! Each line is "<hex digest>  <basename of input>", which is the format
//! install.sh / install.ps1 expect.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 3) {
        std.debug.print("usage: sha256sums <output-file> <input-file>...\n", .{});
        std.process.exit(1);
    }

    var out: std.ArrayList(u8) = .empty;

    for (args[2..]) |path| {
        const data = try cwd.readFileAlloc(init.io, path, allocator, .unlimited);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);

        try out.print(allocator, "{s}  {s}\n", .{ &hex, std.fs.path.basename(path) });
    }

    try cwd.writeFile(init.io, .{
        .sub_path = args[1],
        .data = out.items,
    });
}
