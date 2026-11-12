//! Allocation discipline of the runtime's on-demand storage outside the
//! views: the automation snapshot buffers, each window's source copy and
//! shell layout, and each status item's menu rows.

const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const runtime_automation_snapshot = @import("automation_snapshot.zig");
const runtime_state = @import("state.zig");
const shell_layout = @import("shell_layout.zig");
const support = @import("test_support.zig");

const platform = support.platform;
const automation = support.automation;
const App = support.App;
const TestHarness = support.TestHarness;

const automation_bytes = @sizeOf(runtime_automation_snapshot.AutomationSnapshotStorage);
const source_bytes = @sizeOf(runtime_state.RuntimeSourceStorage);
const shell_layout_bytes = @sizeOf(shell_layout.RuntimeShellLayout);
const tray_items_bytes = @sizeOf(runtime_state.RuntimeTrayItems);

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
    try std.testing.expect(harness.runtime.automation_storage == null);
    const start_allocations = counting.allocations;
    const start_bytes = counting.allocated_bytes;

    // The first snapshot allocates exactly one block; later snapshots
    // reuse it.
    const first = harness.runtime.automationSnapshot("Storage");
    try std.testing.expect(first.windows.len > 0);
    try std.testing.expectEqual(start_allocations + 1, counting.allocations);
    try std.testing.expectEqual(start_bytes + automation_bytes, counting.allocated_bytes);
    _ = harness.runtime.automationSnapshot("Storage");
    try std.testing.expectEqual(start_allocations + 1, counting.allocations);

    harness.runtime.deinit();
    try std.testing.expectEqual(counting.allocations, counting.deallocations);
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
    try std.testing.expect(harness.runtime.automation_storage == null);
}

test "a session fingerprint without snapshot buffers reports no fingerprint" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const harness = try harnessWithRuntimeAllocator(failing.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: StorageApp = .{};
    try harness.start(app_state.app());

    // The refusal is reported as the "no fingerprint" value, never a
    // crash or a fingerprint of nothing.
    failing.fail_index = failing.alloc_index;
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

test "a window whose source copy cannot be allocated is refused before the platform sees it" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const harness = try harnessWithRuntimeAllocator(failing.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: StorageApp = .{};
    try harness.start(app_state.app());
    const runtime_windows = harness.runtime.window_count;
    const platform_windows = harness.null_platform.window_count;
    const options: platform.WindowCreateOptions = .{ .label = "panel", .title = "Panel", .source = platform.WebViewSource.html("<p>Panel</p>") };

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, harness.runtime.createWindow(options));
    try std.testing.expectEqual(runtime_windows, harness.runtime.window_count);
    try std.testing.expectEqual(platform_windows, harness.null_platform.window_count);

    // Nothing was half-created: the label is free and the same window is
    // created normally once memory is available.
    failing.fail_index = std.math.maxInt(usize);
    _ = try harness.runtime.createWindow(options);
    try std.testing.expectEqual(runtime_windows + 1, harness.runtime.window_count);
    try std.testing.expectEqual(platform_windows + 1, harness.null_platform.window_count);
}

test "shell views whose layout cannot be allocated are rolled back" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const harness = try harnessWithRuntimeAllocator(failing.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: StorageApp = .{};
    try harness.start(app_state.app());
    const panel = try harness.runtime.createWindow(.{ .label = "panel", .title = "Panel", .source = platform.WebViewSource.html("<p>Panel</p>") });
    const runtime_views = harness.runtime.view_count;
    const platform_views = harness.null_platform.view_count;
    const views = [_]app_manifest.ShellView{.{ .label = "panel-bar", .kind = .toolbar }};
    const bounds = geometry.RectF.init(0, 0, 240, 140);

    // The views are created before their layout binds; a refused layout
    // removes them again, here and on the platform.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, harness.runtime.createShellViews(panel.id, &views, bounds));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.shell_layout_count);
    try std.testing.expectEqual(runtime_views, harness.runtime.view_count);
    try std.testing.expectEqual(platform_views, harness.null_platform.view_count);

    failing.fail_index = std.math.maxInt(usize);
    try harness.runtime.createShellViews(panel.id, &views, bounds);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.shell_layout_count);
    try std.testing.expectEqual(runtime_views + 1, harness.runtime.view_count);
}

test "a closed window's borrowed source leaves the platform before the runtime frees it" {
    // Platform services borrow the source slices for the call. The null
    // platform keeps them for inspection while a window is open, so it
    // must drop them on close: reopening the label removes the closed
    // record, and with it the runtime's copy those slices pointed into.
    const harness = try harnessWithRuntimeAllocator(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: StorageApp = .{};
    try harness.start(app_state.app());
    const options: platform.WindowCreateOptions = .{ .label = "panel", .title = "Panel", .source = platform.WebViewSource.html("<p>Panel</p>") };
    const panel = try harness.runtime.createWindow(options);
    const slot = harness.null_platform.window_count - 1;
    try std.testing.expectEqualStrings("<p>Panel</p>", harness.null_platform.window_sources[slot].?.bytes);

    try harness.runtime.closeWindow(panel.id);
    try std.testing.expect(harness.null_platform.window_sources[slot] == null);
    _ = try harness.runtime.createWindow(options);
}

test "a window owns its shell layout while open and its source copy while its record exists" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const harness = try harnessWithRuntimeAllocator(counting.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: StorageApp = .{};
    try harness.start(app_state.app());

    // The main window took the app's source, so it owns a source copy.
    try std.testing.expect(harness.runtime.windows[0].source_storage != null);
    const start_allocations = counting.allocations;
    const start_bytes = counting.allocated_bytes;

    // A window with a source allocates its copy with it.
    const panel = try harness.runtime.createWindow(.{ .label = "panel", .title = "Panel", .source = platform.WebViewSource.html("<p>Panel</p>") });
    try std.testing.expectEqual(start_allocations + 1, counting.allocations);
    try std.testing.expectEqual(start_bytes + source_bytes, counting.allocated_bytes);

    // Its shell views bring its shell layout; the native-control views
    // themselves own no canvas storage.
    try harness.runtime.createShellViews(panel.id, &.{.{ .label = "panel-bar", .kind = .toolbar }}, geometry.RectF.init(0, 0, 240, 140));
    try std.testing.expectEqual(start_allocations + 2, counting.allocations);
    try std.testing.expectEqual(start_bytes + source_bytes + shell_layout_bytes, counting.allocated_bytes);

    // Closing the window removes its views and returns the shell layout.
    // The closed window's record (and its source copy) stays until the
    // slot is reused, so the label can reopen.
    const freed_before = counting.freed_bytes;
    try harness.runtime.closeWindow(panel.id);
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
    try std.testing.expectEqual(freed_before + shell_layout_bytes, counting.freed_bytes);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.shell_layout_count);

    // Reopening under the same label removes the closed record, returning
    // its source copy, and the new window copies its own.
    const allocations_before_reopen = counting.allocations;
    _ = try harness.runtime.createWindow(.{ .label = "panel", .title = "Panel again", .source = platform.WebViewSource.html("<p>Again</p>") });
    try std.testing.expectEqual(@as(usize, 2), counting.deallocations);
    try std.testing.expectEqual(freed_before + shell_layout_bytes + source_bytes, counting.freed_bytes);
    try std.testing.expectEqual(allocations_before_reopen + 1, counting.allocations);

    harness.runtime.deinit();
    try std.testing.expectEqual(counting.allocations, counting.deallocations);
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
}

test "a status item owns its menu rows from creation until removal" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const harness = try harnessWithRuntimeAllocator(counting.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: StorageApp = .{};
    try harness.start(app_state.app());
    const start_allocations = counting.allocations;
    const start_bytes = counting.allocated_bytes;
    const platform_items = harness.null_platform.statusItemCount();

    // An unused slot holds no menu storage; creating the status item
    // allocates exactly one block of rows, and menu updates reuse it.
    try std.testing.expect(harness.runtime.status_items[0].items == null);
    try harness.runtime.createTray(.{ .items = &.{.{ .id = 7, .label = "Refresh", .command = "app.refresh" }} });
    try std.testing.expectEqual(start_allocations + 1, counting.allocations);
    try std.testing.expectEqual(start_bytes + tray_items_bytes, counting.allocated_bytes);
    try harness.runtime.updateTrayMenu(&.{
        .{ .id = 7, .label = "Refresh", .command = "app.refresh" },
        .{ .id = 8, .label = "Quit", .command = "app.quit" },
    });
    try std.testing.expectEqual(start_allocations + 1, counting.allocations);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.status_item_count);

    // Removing it returns the block.
    const freed_before = counting.freed_bytes;
    try harness.runtime.removeTray();
    try std.testing.expectEqual(freed_before + tray_items_bytes, counting.freed_bytes);
    try std.testing.expectEqual(platform_items, harness.null_platform.statusItemCount());

    // A refused allocation creates nothing, here or on the platform.
    counting.fail_index = counting.alloc_index;
    try std.testing.expectError(error.OutOfMemory, harness.runtime.createTray(.{ .items = &.{.{ .id = 9, .label = "Again", .command = "app.again" }} }));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.status_item_count);
    try std.testing.expectEqual(platform_items, harness.null_platform.statusItemCount());
    counting.fail_index = std.math.maxInt(usize);
}
