const std = @import("std");

pub const Error = error{
    OsError,
} || std.mem.Allocator.Error;

pub const windows = struct {
    const native = std.os.windows;

    extern "kernel32" fn GetTempPathW(
        nBufferLength: native.DWORD,
        lpBuffer: native.LPWSTR,
    ) callconv(.winapi) native.DWORD;

    pub fn getTempPath(allocator: std.mem.Allocator) Error![]const u8 {
        var buffer: [1024:0]u16 = undefined;

        const length = GetTempPathW(buffer.len, &buffer);

        if (length == 0 or length >= buffer.len)
            return Error.OsError;

        return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..length]);
    }
};
