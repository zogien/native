const support = @import("test_support.zig");
const std = support.std;
const platform = support.platform;
const App = support.App;
const Runtime = support.Runtime;
const Event = support.Event;
const TestHarness = support.TestHarness;
const window_controls = @import("window_controls.zig");
const bridge_responses = @import("bridge_responses.zig");

const ControlsApp = struct {
    window_closed_count: u32 = 0,

    fn app(self: *@This()) App {
        return .{ .context = self, .name = "window-controls", .source = platform.WebViewSource.html("<p>Controls</p>"), .event_fn = event };
    }

    fn event(context: *anyopaque, runtime: *Runtime, incoming: Event) !void {
        _ = runtime;
        const self: *@This() = @ptrCast(@alignCast(context));
        if (incoming == .window_closed) self.window_closed_count += 1;
    }
};

fn windowInfo(runtime: *const Runtime, window_id: platform.WindowId) ?platform.WindowInfo {
    for (runtime.windows[0..runtime.window_count]) |window| {
        if (window.info.id == window_id) return window.info;
    }
    return null;
}

fn expectEveryControlRefused(runtime: *Runtime, window_id: platform.WindowId, expected: anyerror) !void {
    try std.testing.expectError(expected, runtime.maximizeWindow(window_id));
    try std.testing.expectError(expected, runtime.unmaximizeWindow(window_id));
    try std.testing.expectError(expected, runtime.requestCloseWindow(window_id));
}

test "maximize and unmaximize reach the host and maximized follows its frame events" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: ControlsApp = .{};
    try harness.start(app_state.app());

    const tools = try harness.runtime.createWindow(.{ .label = "tools", .title = "Tools" });
    try harness.runtime.maximizeWindow(tools.id);
    // The verb moves no runtime state; the host's frame event reports it.
    try std.testing.expect(!windowInfo(&harness.runtime, tools.id).?.maximized);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), harness.null_platform.windowFrameEvent(tools.id).?);
    try std.testing.expect(windowInfo(&harness.runtime, tools.id).?.maximized);
    try std.testing.expect(windowInfo(&harness.runtime, tools.id).?.state().maximized);
    var output: [platform.max_windows]platform.WindowInfo = undefined;
    for (harness.runtime.listWindows(&output)) |listed| {
        if (listed.id == tools.id) try std.testing.expect(listed.maximized);
    }

    try harness.runtime.unmaximizeWindow(tools.id);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), harness.null_platform.windowFrameEvent(tools.id).?);
    try std.testing.expect(!windowInfo(&harness.runtime, tools.id).?.maximized);
    // Restoring a window that is not maximized leaves it as it is.
    try harness.runtime.unmaximizeWindow(tools.id);
    try std.testing.expect(!harness.null_platform.windows[1].maximized);
}

test "a maximized change reaches the window's pages and its window JSON" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: ControlsApp = .{};
    try harness.start(app_state.app());

    const tools = try harness.runtime.createWindow(.{ .label = "tools" });
    try harness.runtime.maximizeWindow(tools.id);
    const before = harness.null_platform.windowEventCount();
    try harness.runtime.dispatchPlatformEvent(app_state.app(), harness.null_platform.windowFrameEvent(tools.id).?);
    try std.testing.expectEqual(before + 1, harness.null_platform.windowEventCount());
    try std.testing.expectEqual(tools.id, harness.null_platform.lastWindowEventWindowId());
    try std.testing.expectEqualStrings(window_controls.window_state_event, harness.null_platform.lastWindowEventName());
    try std.testing.expectEqualStrings("{\"windowId\":2,\"maximized\":true}", harness.null_platform.lastWindowEventDetail());

    // A page loading now reads the same state from the window list.
    var json_buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&json_buffer);
    try bridge_responses.writeWindowJsonToWriter(windowInfo(&harness.runtime, tools.id).?, &writer);
    try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), ",\"maximized\":true}"));

    // A frame event that leaves the state alone (a move) tells nobody.
    try harness.runtime.dispatchPlatformEvent(app_state.app(), harness.null_platform.windowFrameEvent(tools.id).?);
    try std.testing.expectEqual(before + 1, harness.null_platform.windowEventCount());

    try harness.runtime.unmaximizeWindow(tools.id);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), harness.null_platform.windowFrameEvent(tools.id).?);
    try std.testing.expectEqual(before + 2, harness.null_platform.windowEventCount());
    try std.testing.expectEqualStrings("{\"windowId\":2,\"maximized\":false}", harness.null_platform.lastWindowEventDetail());
}

test "a maximize the app did not request still updates maximized" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: ControlsApp = .{};
    try harness.start(app_state.app());

    // A caption double-click, the system menu, or Win+Up: the host's
    // frame event is the only signal, and it is enough.
    var state = windowInfo(&harness.runtime, 1).?.state();
    state.maximized = true;
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .window_frame_changed = state });
    try std.testing.expect(windowInfo(&harness.runtime, 1).?.maximized);
    state.maximized = false;
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .window_frame_changed = state });
    try std.testing.expect(!windowInfo(&harness.runtime, 1).?.maximized);
}

test "window controls refuse unknown, closed, hidden, and non-resizable windows" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: ControlsApp = .{};
    try harness.start(app_state.app());

    try expectEveryControlRefused(&harness.runtime, 99, error.WindowNotFound);

    const fixed = try harness.runtime.createWindow(.{ .label = "fixed", .resizable = false });
    try std.testing.expectError(error.WindowNotResizable, harness.runtime.maximizeWindow(fixed.id));

    const tools = try harness.runtime.createWindow(.{ .label = "tools" });
    try harness.runtime.hideWindow(tools.id);
    try std.testing.expectError(error.WindowHidden, harness.runtime.maximizeWindow(tools.id));

    // A closed window keeps its runtime slot; resolving its id is not
    // liveness, and no verb reaches the host for it.
    try harness.runtime.closeWindow(tools.id);
    try expectEveryControlRefused(&harness.runtime, tools.id, error.WindowNotFound);
    try std.testing.expect(harness.null_platform.takeQueuedCloseRequest() == null);
}

test "requestCloseWindow closes a quit-policy window the way the user's close button does" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: ControlsApp = .{};
    try harness.start(app_state.app());

    const tools = try harness.runtime.createWindow(.{ .label = "tools" });
    try harness.runtime.requestCloseWindow(tools.id);
    // Only a request: the window is untouched until the host handles it.
    try std.testing.expect(windowInfo(&harness.runtime, tools.id).?.open);
    try std.testing.expectEqual(@as(u32, 0), app_state.window_closed_count);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), harness.null_platform.takeQueuedCloseRequest().?);
    try std.testing.expect(!windowInfo(&harness.runtime, tools.id).?.open);
    try std.testing.expectEqual(@as(u32, 1), app_state.window_closed_count);
    try std.testing.expect(harness.null_platform.takeQueuedCloseRequest() == null);

    // closeWindow keeps its meaning: the app's own close, which never
    // reports back as a user close.
    const other = try harness.runtime.createWindow(.{ .label = "other" });
    try harness.runtime.closeWindow(other.id);
    try std.testing.expectEqual(@as(u32, 1), app_state.window_closed_count);
}

test "requestCloseWindow hides a hide-policy window and keeps it alive" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: ControlsApp = .{};
    try harness.start(app_state.app());

    const palette = try harness.runtime.createWindow(.{ .label = "palette", .close_policy = .hide });
    _ = try harness.runtime.createView(.{ .window_id = palette.id, .label = "action", .kind = .button, .frame = .init(10, 10, 80, 30) });
    const view_count = harness.runtime.view_count;

    try harness.runtime.requestCloseWindow(palette.id);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), harness.null_platform.takeQueuedCloseRequest().?);
    const info = windowInfo(&harness.runtime, palette.id).?;
    try std.testing.expect(info.open);
    try std.testing.expect(info.hidden);
    try std.testing.expectEqual(view_count, harness.runtime.view_count);
    try std.testing.expectEqual(@as(u32, 0), app_state.window_closed_count);

    // The hidden window comes back with its views, as after a user close.
    try harness.runtime.showWindow(palette.id);
    try std.testing.expect(!windowInfo(&harness.runtime, palette.id).?.hidden);
}

test "a close request for a window the app closed first is dropped" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: ControlsApp = .{};
    try harness.start(app_state.app());

    const tools = try harness.runtime.createWindow(.{ .label = "tools" });
    try harness.runtime.requestCloseWindow(tools.id);
    try harness.runtime.closeWindow(tools.id);
    try std.testing.expect(harness.null_platform.takeQueuedCloseRequest() == null);
    try std.testing.expectEqual(@as(u32, 0), app_state.window_closed_count);
}
