const std = @import("std");

const Runtime = @import("Runtime.zig");

const Error = Runtime.Error;

/// Runs `func(ctx, i)` for every `i` in `0..count`, with at most `limit` running at once
/// (and never more threads than the runtime-wide budget allows).
///
/// - The calling thread is one of the workers, so this never waits for a free thread.
/// - On the first failure no new indices are started; running ones finish (drain).
/// - Returns the error of the lowest failing index, so the result is deterministic.
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
                    s.errors[i] = err; // only this worker writes slot i
                    s.failed.store(true, .release);
                };
            }
        }
    };

    var shared: Shared = .{
        .ctx = ctx,
        .errors = errors,
    };

    // The caller is worker number one, so ask for `wanted - 1` extra threads.
    const wanted = std.math.clamp(limit, 1, count);
    const granted = runtime.acquireWorkers(wanted - 1);

    // Tokens are held only for threads that actually exist.
    var spawned: usize = 0;
    defer runtime.releaseWorkers(spawned);

    // Declared after the release above, so it runs first: workers are stopped and joined
    // before their tokens are returned (and before `shared` and `errors` go away).
    var group: std.Io.Group = .init;
    defer group.cancel(runtime.io);

    for (0..granted) |_| {
        group.concurrent(runtime.io, Shared.worker, .{&shared}) catch break;
        spawned += 1;
    }
    // tokens that never became threads go back to the pool right away
    runtime.releaseWorkers(granted - spawned);

    shared.worker(); // the calling thread works too

    group.await(runtime.io) catch return Error.Abort;

    for (errors) |m_err| if (m_err) |err| return err;
}
