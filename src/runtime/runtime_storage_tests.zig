//! Allocation discipline of the runtime's on-demand storage outside the
//! views: the automation snapshot buffers.

const std = @import("std");
const geometry = @import("geometry");
const core = @import("core.zig");
const runtime_automation_snapshot = @import("automation_snapshot.zig");
const support = @import("test_support.zig");

const platform = support.platform;
const automation = support.automation;
const App = support.App;
const TestHarness = support.TestHarness;

const automation_bytes = @sizeOf(runtime_automation_snapshot.AutomationSnapshotStorage);

const StorageApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "runtime-storage", .source = platform.WebViewSource.html("<h1>Storage</h1>") };
    }
};

fn harnessWithRuntimeAllocator(runtime_allocator: std.mem.Allocator) !*TestHarness() {
    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 140) });
    errdefer harness.destroy(std.testing.allocator);
    core.Runtime.initAt(&harness.runtime, .{
        .platform = harness.null_platform.platform(),
        .trace_sink = harness.trace_sink.sink(),
        .allocator = runtime_allocator,
        .environ = std.testing.environ,
    });
    harness.runtime.dispatch_error_policy = .propagate;
    return harness;
}

test "the automation snapshot buffers exist from the first snapshot until deinit" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const harness = try harnessWithRuntimeAllocator(counting.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: StorageApp = .{};
    try harness.start(app_state.app());

    // A runtime that is never snapshotted never allocates them.
    try std.testing.expectEqual(@as(usize, 0), counting.allocations);
    try std.testing.expect(harness.runtime.automation_storage == null);

    // The first snapshot allocates exactly one block; later snapshots
    // reuse it.
    const first = harness.runtime.automationSnapshot("Storage");
    try std.testing.expect(first.windows.len > 0);
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);
    try std.testing.expectEqual(automation_bytes, counting.allocated_bytes);
    _ = harness.runtime.automationSnapshot("Storage");
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);

    harness.runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
    try std.testing.expectEqual(automation_bytes, counting.freed_bytes);
    try std.testing.expect(harness.runtime.automation_storage == null);
}

test "a session fingerprint without snapshot buffers reports no fingerprint" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const harness = try harnessWithRuntimeAllocator(failing.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: StorageApp = .{};
    try harness.start(app_state.app());

    // The refusal is reported as the "no fingerprint" value, never a
    // crash or a fingerprint of nothing.
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.sessionStateFingerprint());
    try std.testing.expect(harness.runtime.automation_storage == null);

    // Once memory is available the fingerprint is real.
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(harness.runtime.sessionStateFingerprint() != 0);
    try std.testing.expect(harness.runtime.automation_storage != null);
}

test "publishing to the automation server reports a refused snapshot allocation as an error" {
    var dir_buffer: [256]u8 = undefined;
    const automation_dir = try automation.watcher.testDirectory(&dir_buffer, ".zig-cache/test-automation-runtime-storage");
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(std.testing.io, automation_dir) catch {};
    try cwd.createDirPath(std.testing.io, automation_dir);
    defer cwd.deleteTree(std.testing.io, automation_dir) catch {};

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const harness = try harnessWithRuntimeAllocator(failing.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: StorageApp = .{};
    const app = app_state.app();
    try harness.start(app);
    harness.runtime.options.automation = automation.Server.init(std.testing.io, automation_dir, "Storage");

    // The frame that publishes cannot get the snapshot buffers: the
    // refusal surfaces as the frame's error, and nothing is half-built.
    failing.fail_index = failing.alloc_index;
    harness.runtime.invalidate();
    try std.testing.expectError(error.OutOfMemory, harness.runtime.frame(app));
    try std.testing.expect(harness.runtime.automation_storage == null);

    // Once memory is available the next frame publishes normally.
    failing.fail_index = std.math.maxInt(usize);
    harness.runtime.invalidate();
    try harness.runtime.frame(app);
    try std.testing.expect(harness.runtime.automation_storage != null);
}
