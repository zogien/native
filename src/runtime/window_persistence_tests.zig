//! Window-state persistence: what the runtime writes to the window-state
//! store for each frame event, and what a later create restores from it.
//! The null platform models a host with the placement query (its cache
//! keeps the normal frame through maximize and answers after a close);
//! tests that model a host without the query clear `window_placement_fn`.
const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const platform = support.platform;
const window_state = support.window_state;
const App = support.App;
const TestHarness = support.TestHarness;

const PersistApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "window-persistence", .source = platform.WebViewSource.html("<p>Windows</p>") };
    }
};

/// A store under a fresh temporary directory, with its path buffers.
const TempStore = struct {
    tmp: std.testing.TmpDir,
    dir_buffer: [128]u8 = undefined,
    file_buffer: [160]u8 = undefined,
    store: window_state.Store = undefined,
    read_buffer: [4096]u8 = undefined,

    fn init(self: *TempStore) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        const dir = try std.fmt.bufPrint(&self.dir_buffer, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        const file = try std.fmt.bufPrint(&self.file_buffer, "{s}/windows.zon", .{dir});
        self.store = window_state.Store.init(std.testing.io, dir, file);
    }

    fn deinit(self: *TempStore) void {
        self.tmp.cleanup();
    }

    fn load(self: *TempStore, label: []const u8) !?platform.WindowState {
        return self.store.loadWindow(label, &self.read_buffer);
    }

    fn deleteFile(self: *TempStore) !void {
        try std.Io.Dir.cwd().deleteFile(std.testing.io, self.store.file_path);
    }

    fn fileExists(self: *TempStore) bool {
        _ = std.Io.Dir.cwd().statFile(std.testing.io, self.store.file_path, .{}) catch return false;
        return true;
    }
};

fn windowInfo(harness: anytype, window_id: platform.WindowId) platform.WindowInfo {
    for (harness.runtime.windows[0..harness.runtime.window_count]) |window| {
        if (window.info.id == window_id) return window.info;
    }
    unreachable;
}

test "a maximized window persists its normal frame with maximized set and reopens maximized over it" {
    var temp: TempStore = undefined;
    try temp.init();
    defer temp.deinit();
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: PersistApp = .{};
    const app = app_state.app();
    try harness.start(app);
    harness.runtime.options.window_state_store = temp.store;

    const normal = geometry.RectF.init(120, 80, 900, 640);
    const tools = try harness.runtime.createWindow(.{ .label = "tools", .default_frame = normal });
    try harness.runtime.maximizeWindow(tools.id);
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.windowFrameEvent(tools.id).?);
    // The runtime tracks the live maximized frame; the store keeps the
    // placement.
    try std.testing.expectEqual(harness.null_platform.maximized_frame, windowInfo(harness, tools.id).frame);
    const saved = (try temp.load("tools")).?;
    try std.testing.expectEqual(normal, saved.frame);
    try std.testing.expect(saved.maximized);
    try std.testing.expect(saved.open);

    // The user quits the window while it is maximized; the host removes
    // it before the close event, and the record still holds the placement.
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.userCloseWindow(tools.id).?);
    const closed = (try temp.load("tools")).?;
    try std.testing.expectEqual(normal, closed.frame);
    try std.testing.expect(closed.maximized);
    try std.testing.expect(!closed.open);

    // The next create under the label opens maximized, with the saved
    // normal frame as the frame its Restore returns to.
    const reopened = try harness.runtime.createWindow(.{ .label = "tools", .default_frame = geometry.RectF.init(0, 0, 400, 300) });
    try std.testing.expectEqual(platform.WindowInitialPlacement.restored, harness.null_platform.window_placement[1]);
    try std.testing.expect(harness.null_platform.windows[1].maximized);
    try std.testing.expect(windowInfo(harness, reopened.id).maximized);
    try std.testing.expectEqual(harness.null_platform.maximized_frame, reopened.frame);
    try std.testing.expectEqual(platform.WindowPlacement{ .frame = normal, .maximized = true }, harness.runtime.options.platform.services.windowPlacement(reopened.id).?);
    try harness.runtime.unmaximizeWindow(reopened.id);
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.windowFrameEvent(reopened.id).?);
    try std.testing.expectEqual(normal, windowInfo(harness, reopened.id).frame);
    try std.testing.expect(!(try temp.load("tools")).?.maximized);
}

test "frame events whose placement is unchanged do not rewrite the store" {
    var temp: TempStore = undefined;
    try temp.init();
    defer temp.deinit();
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: PersistApp = .{};
    const app = app_state.app();
    try harness.start(app);
    harness.runtime.options.window_state_store = temp.store;

    const tools = try harness.runtime.createWindow(.{ .label = "tools", .default_frame = geometry.RectF.init(10, 20, 640, 480) });
    const settled = geometry.RectF.init(40, 50, 700, 500);
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.userMoveWindow(tools.id, settled, true).?);
    try std.testing.expectEqual(settled, (try temp.load("tools")).?.frame);

    // A drag in progress: every frame event carries a new live frame, but
    // the host's placement has not settled, so nothing is written.
    try temp.deleteFile();
    var step: f32 = 1;
    while (step <= 5) : (step += 1) {
        try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.userMoveWindow(tools.id, geometry.RectF.init(40 + step * 10, 50, 700, 500), false).?);
    }
    try std.testing.expect(!temp.fileExists());

    // The drop settles the placement: one write.
    const dropped = geometry.RectF.init(90, 50, 700, 500);
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.userMoveWindow(tools.id, dropped, true).?);
    try std.testing.expectEqual(dropped, (try temp.load("tools")).?.frame);
}

test "a window that does not restore its state is never written" {
    var temp: TempStore = undefined;
    try temp.init();
    defer temp.deinit();
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    // The startup window's declaration opts out too.
    harness.runtime.options.platform.app_info.main_window.restore_state = false;
    var app_state: PersistApp = .{};
    const app = app_state.app();
    try harness.start(app);
    harness.runtime.options.window_state_store = temp.store;

    const panel = try harness.runtime.createWindow(.{ .label = "panel", .default_frame = geometry.RectF.init(10, 20, 640, 480), .restore_state = false });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.userMoveWindow(panel.id, geometry.RectF.init(30, 40, 640, 480), true).?);
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.userCloseWindow(panel.id).?);
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = .{
        .id = 1,
        .label = "main",
        .frame = geometry.RectF.init(0, 0, 800, 600),
        .open = true,
        .focused = true,
    } });
    try std.testing.expect(!temp.fileExists());

    // A re-created window under the same label follows its new options.
    const restoring = try harness.runtime.createWindow(.{ .label = "panel", .default_frame = geometry.RectF.init(10, 20, 640, 480) });
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.userMoveWindow(restoring.id, geometry.RectF.init(50, 60, 640, 480), true).?);
    try std.testing.expectEqual(geometry.RectF.init(50, 60, 640, 480), (try temp.load("panel")).?.frame);
    try std.testing.expect((try temp.load("main")) == null);
}

test "without the placement query frame events persist their own values, fullscreen excepted" {
    var temp: TempStore = undefined;
    try temp.init();
    defer temp.deinit();
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.window_placement_fn = null;
    var app_state: PersistApp = .{};
    const app = app_state.app();
    try harness.start(app);
    harness.runtime.options.window_state_store = temp.store;

    const tools = try harness.runtime.createWindow(.{ .label = "tools", .default_frame = geometry.RectF.init(10, 20, 640, 480) });
    try harness.runtime.maximizeWindow(tools.id);
    var event = harness.null_platform.windowFrameEvent(tools.id).?;
    event.window_frame_changed.fullscreen = true;
    try harness.runtime.dispatchPlatformEvent(app, event);
    // The earlier behavior: the event's live frame is what persists.
    const saved = (try temp.load("tools")).?;
    try std.testing.expectEqual(harness.null_platform.maximized_frame, saved.frame);
    try std.testing.expect(saved.maximized);
    try std.testing.expect(!saved.fullscreen);
}

test "without the placement query a close event keeps the last known placement" {
    var temp: TempStore = undefined;
    try temp.init();
    defer temp.deinit();
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.window_placement_fn = null;
    var app_state: PersistApp = .{};
    const app = app_state.app();
    try harness.start(app);
    harness.runtime.options.window_state_store = temp.store;

    const launch = geometry.RectF.init(10, 20, 640, 480);
    const tools = try harness.runtime.createWindow(.{ .label = "tools", .default_frame = launch });
    const resized = geometry.RectF.init(30, 40, 1000, 700);
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.userMoveWindow(tools.id, resized, true).?);
    // The placement comes from what the runtime saw, not from reading the
    // record back: the file is gone, the close still knows the frame.
    try temp.deleteFile();
    // A host whose close path has lost the window reports its launch
    // frame (the Windows host before its placement cache).
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = .{
        .id = tools.id,
        .label = "tools",
        .frame = launch,
        .open = false,
        .focused = false,
    } });
    const closed = (try temp.load("tools")).?;
    try std.testing.expectEqual(resized, closed.frame);
    try std.testing.expect(!closed.open);
}

test "without the placement query a close with no placement this session keeps the stored record" {
    var temp: TempStore = undefined;
    try temp.init();
    defer temp.deinit();
    const stored = geometry.RectF.init(200, 150, 1100, 760);
    try temp.store.saveWindow(.{ .id = 2, .label = "tools", .frame = stored, .maximized = true });

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.window_placement_fn = null;
    var app_state: PersistApp = .{};
    const app = app_state.app();
    try harness.start(app);
    harness.runtime.options.window_state_store = temp.store;

    const tools = try harness.runtime.createWindow(.{ .label = "tools", .default_frame = geometry.RectF.init(10, 20, 640, 480) });
    try std.testing.expect(harness.null_platform.windows[1].maximized);
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = .{
        .id = tools.id,
        .label = "tools",
        .frame = geometry.RectF.init(0, 0, 0, 0),
        .open = false,
        .focused = false,
    } });
    const closed = (try temp.load("tools")).?;
    try std.testing.expectEqual(stored, closed.frame);
    try std.testing.expect(closed.maximized);
    try std.testing.expect(!closed.open);
}

test "a failed store write is retried by the next event with the same record" {
    var temp: TempStore = undefined;
    try temp.init();
    defer temp.deinit();
    // The state directory sits under a regular file, so creating it fails.
    try temp.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocker", .data = "" });
    var blocked_dir_buffer: [160]u8 = undefined;
    var blocked_file_buffer: [192]u8 = undefined;
    const blocked_dir = try std.fmt.bufPrint(&blocked_dir_buffer, ".zig-cache/tmp/{s}/blocker/state", .{temp.tmp.sub_path});
    const blocked_file = try std.fmt.bufPrint(&blocked_file_buffer, "{s}/windows.zon", .{blocked_dir});
    const blocked = window_state.Store.init(std.testing.io, blocked_dir, blocked_file);

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: PersistApp = .{};
    const app = app_state.app();
    try harness.start(app);
    harness.runtime.options.window_state_store = blocked;

    const tools = try harness.runtime.createWindow(.{ .label = "tools", .default_frame = geometry.RectF.init(10, 20, 640, 480) });
    const settled = geometry.RectF.init(30, 40, 640, 480);
    // The failure is logged, not raised: the frame event still lands.
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.userMoveWindow(tools.id, settled, true).?);
    try std.testing.expectEqual(settled, windowInfo(harness, tools.id).frame);

    harness.runtime.options.window_state_store = temp.store;
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.windowFrameEvent(tools.id).?);
    try std.testing.expectEqual(settled, (try temp.load("tools")).?.frame);
}
