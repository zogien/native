//! Explicit native external-producer capabilities. Portable app state and
//! channel lifecycle stay in the app; `native-sdk.process.samples` owns a
//! detached OS sampler, `native-sdk.app.launches` hands the channel to
//! the single-instance listener (single_instance.zig), and
//! `native-sdk.updates` receives the updater's status records
//! (updater/engine.zig).
const std = @import("std");
const builtin = @import("builtin");
const effects = @import("effects.zig");
const clock = @import("clock.zig");
const single_instance = @import("single_instance.zig");
const update_engine = @import("../updater/engine.zig");
const sample_interval_ms = 500;
const max_line_bytes = 96;

pub fn start(name: []const u8, payload: []const u8, handle: effects.ChannelHandle) !void {
    if (std.mem.eql(u8, name, single_instance.source_name)) return single_instance.attach(payload, handle);
    if (std.mem.eql(u8, name, update_engine.channel_source)) return attachUpdates(payload, handle);
    if (!std.mem.eql(u8, name, "native-sdk.process.samples")) return error.UnknownChannelSource;
    if (payload.len != 0) return error.InvalidChannelSourceArguments;
    if (comptime builtin.single_threaded) return error.UnsupportedChannelSource;
    try startSamplerThread(handle);
}

/// The open `native-sdk.updates` channels, each the engine's sink. A slot
/// frees itself when its channel answers `.closed`.
const UpdateChannel = struct {
    handle: effects.ChannelHandle = undefined,
    used: std.atomic.Value(bool) = .init(false),

    fn post(context: *anyopaque, bytes: []const u8) update_engine.Posted {
        const self: *UpdateChannel = @ptrCast(@alignCast(context));
        return switch (self.handle.post(bytes)) {
            .accepted => .delivered,
            .dropped_full, .dropped_oversized => .dropped,
            .closed => {
                self.used.store(false, .release);
                return .closed;
            },
        };
    }
};
var update_channels: [4]UpdateChannel = .{UpdateChannel{}} ** 4;

comptime {
    // Every status record fits one post; notes travel by request.
    std.debug.assert(update_engine.max_status_bytes <= effects.max_effect_channel_bytes);
}

fn attachUpdates(payload: []const u8, handle: effects.ChannelHandle) !void {
    if (payload.len != 0) return error.InvalidChannelSourceArguments;
    for (&update_channels) |*channel| {
        if (channel.used.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            channel.handle = handle;
            update_engine.attach(.{ .context = channel, .post = UpdateChannel.post }) catch {
                channel.used.store(false, .release);
                return error.UnsupportedChannelSource;
            };
            return;
        }
    }
    return error.UnsupportedChannelSource;
}

fn startSamplerThread(handle: effects.ChannelHandle) std.Thread.SpawnError!void {
    const thread = try std.Thread.spawn(.{}, samplerMain, .{handle});
    thread.detach();
}

/// The app-owned source: real process readings on a real thread, paced
/// by its own sleep — the loop never ticks for it.
fn samplerMain(handle: effects.ChannelHandle) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const started_ms = clock.monotonicMs();
    var index: u64 = 0;
    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(sample_interval_ms), .awake) catch return;
        index += 1;
        var buffer: [max_line_bytes]u8 = undefined;
        const line = formatSample(&buffer, index, started_ms);
        // The post's answer is the worker's whole protocol — "retry
        // later" and "stop forever" are different answers on purpose.
        switch (handle.post(line)) {
            // Staged: one `.data` Msg delivers on the next drain.
            .accepted => {},
            // Transient back-pressure: THIS sample is dropped and
            // counted — the next delivered event carries the totals
            // and the status line reports them — but sampling
            // continues. A stalled drain is not a stop.
            .dropped_full => {},
            // A programming error by construction here: samples are
            // bounded at max_line_bytes, far under the channel's
            // post bound — no retry of the same bytes could ever land.
            .dropped_oversized => unreachable,
            // The occupancy is over for good — Stop closed the
            // channel, or the app tore down. Wind down.
            .closed => return,
        }
    }
}

/// One reading of this process: sample ordinal, uptime, and (where the
/// OS reports it) the peak resident set size.
fn formatSample(buffer: []u8, index: u64, started_ms: u64) []const u8 {
    const now_ms = clock.monotonicMs();
    const uptime_ms: u64 = if (now_ms > started_ms) now_ms - started_ms else 0;
    const rss_kb = currentMaxRssKb();
    if (rss_kb > 0) {
        return std.fmt.bufPrint(buffer, "sample {d}: uptime {d}.{d:0>1}s, peak rss {d} KiB", .{
            index, uptime_ms / 1000, (uptime_ms % 1000) / 100, rss_kb,
        }) catch "sample";
    }
    return std.fmt.bufPrint(buffer, "sample {d}: uptime {d}.{d:0>1}s", .{
        index, uptime_ms / 1000, (uptime_ms % 1000) / 100,
    }) catch "sample";
}

/// This process's peak resident set size in KiB, 0 where unavailable.
/// macOS reports `maxrss` in bytes, Linux in KiB — normalized here.
fn currentMaxRssKb() u64 {
    if (builtin.os.tag == .windows or !builtin.link_libc) return 0;
    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &usage) != 0) return 0;
    const raw: u64 = @intCast(@max(usage.maxrss, 0));
    return if (builtin.os.tag.isDarwin()) raw / 1024 else raw;
}
