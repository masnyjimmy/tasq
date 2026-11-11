const std = @import("std");

const Runtime = @import("Runtime.zig");

const Error = Runtime.Error;

pub fn runIndexed(
    runtime: *Runtime,
    count: usize,
    limit: usize,
    ctx: anytype,
    comptime func: fn (ctx: @TypeOf(ctx), idx: usize) Error!void,
) Error!void {
    if (count == 0) return;

    const errors = try runtime.allocator.alloc(?Error, count);
    defer runtime.allocator.free(errors);
    @memset(errors, null);

    const Shared = struct {
        const Self = @This();
        ctx: @TypeOf(ctx),
        errors: []?Error,
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),

        fn worker(s: *Self) void {
            while (!s.failed.load(.acquire)) {
                const i = s.next.fetchAdd(1, .monotonic);
                if (i >= s.errors.len) return;
                func(s.ctx, i) catch |err| {
                    s.errors[i] = err;
                    s.failed.store(true, .release);
                };
            }
        }
    };
    var shared: Shared = .{
        .ctx = ctx,
        .errors = errors,
    };

    var group: std.Io.Group = .init;
    defer group.cancel(runtime.io);

    for (0..std.math.clamp(limit, 1, count)) |_| {
        group.concurrent(
            runtime.io,
            Shared.worker,
            .{&shared},
        ) catch Shared.worker(&shared);
    }
    group.await(runtime.io) catch return Error.Abort;

    for (errors) |m_err| if (m_err) |err| return err;
}
