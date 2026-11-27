const std = @import("std");
const native_sdk = @import("native_sdk");

/// Apply the state-store lookup result at the one layer that can distinguish
/// an actual restore from a fresh launch with persistence merely enabled.
/// The saved placement goes through `WindowOptions.applySavedPlacement`, the
/// helper the runtime's later-created windows use too.
pub fn applySavedWindow(window: *native_sdk.WindowOptions, saved: ?native_sdk.WindowState) bool {
    const state = saved orelse return false;
    window.applySavedPlacement(state);
    return true;
}

/// Restore every opted-in startup window from `store` (anything with the
/// window-state store's `loadWindow(label, buffer)`). A read failure is a
/// miss: the window keeps its declared placement. With declared windows,
/// the first one's restore is mirrored into `main_window`, which hosts
/// create the primary window from.
pub fn restoreStartupWindows(app_info: *native_sdk.AppInfo, restored_windows: []native_sdk.WindowOptions, store: anytype, buffer: []u8) void {
    if (restored_windows.len > 0) {
        for (restored_windows, 0..) |*window, index| {
            if (!window.restore_state) continue;
            const saved = store.loadWindow(window.label, buffer) catch null;
            if (applySavedWindow(window, saved) and index == 0) {
                _ = applySavedWindow(&app_info.main_window, saved);
            }
        }
    } else if (app_info.main_window.restore_state) {
        _ = applySavedWindow(&app_info.main_window, store.loadWindow(app_info.main_window.label, buffer) catch null);
    }
}

/// An omitted shell field must not erase the caller's direct-SDK fallback.
pub fn applyShellRestorePolicy(fallback: native_sdk.WindowRestorePolicy, declared: ?native_sdk.WindowRestorePolicy) native_sdk.WindowRestorePolicy {
    return declared orelse fallback;
}

/// Only an authored shell origin overrides the caller's placement reason.
pub fn applyShellInitialPlacement(fallback: native_sdk.WindowInitialPlacement, has_explicit_origin: bool) native_sdk.WindowInitialPlacement {
    return if (has_explicit_origin) .explicit else fallback;
}

test "fresh default-restoring window keeps default placement on a store miss" {
    var window: native_sdk.WindowOptions = .{ .restore_state = true };
    try std.testing.expect(!applySavedWindow(&window, null));
    try std.testing.expectEqual(native_sdk.WindowInitialPlacement.default, window.initial_placement);
    try std.testing.expect(!window.initial_maximized);
}

test "fresh explicitly positioned window keeps explicit placement on a store miss" {
    var window: native_sdk.WindowOptions = .{ .initial_placement = .explicit };
    try std.testing.expect(!applySavedWindow(&window, null));
    try std.testing.expectEqual(native_sdk.WindowInitialPlacement.explicit, window.initial_placement);
}

test "state-store hit replaces the frame and marks it restored" {
    var window: native_sdk.WindowOptions = .{ .initial_placement = .explicit };
    const frame = native_sdk.geometry.RectF.init(40, 60, 900, 640);
    try std.testing.expect(applySavedWindow(&window, .{ .frame = frame }));
    try std.testing.expectEqual(frame, window.default_frame);
    try std.testing.expectEqual(native_sdk.WindowInitialPlacement.restored, window.initial_placement);
    try std.testing.expect(!window.initial_maximized);
}

test "a record saved maximized opens maximized over its normal frame" {
    var window: native_sdk.WindowOptions = .{};
    const normal = native_sdk.geometry.RectF.init(40, 60, 900, 640);
    try std.testing.expect(applySavedWindow(&window, .{ .frame = normal, .maximized = true, .fullscreen = true, .hidden = true }));
    try std.testing.expectEqual(normal, window.default_frame);
    try std.testing.expectEqual(native_sdk.WindowInitialPlacement.restored, window.initial_placement);
    try std.testing.expect(window.initial_maximized);
    // Only placement restores: the show policy stays the declaration's.
    try std.testing.expectEqual(native_sdk.WindowShowMode.immediate, window.show);

    var fixed: native_sdk.WindowOptions = .{ .resizable = false };
    try std.testing.expect(applySavedWindow(&fixed, .{ .frame = normal, .maximized = true }));
    try std.testing.expect(!fixed.initial_maximized);
}

const FakeStore = struct {
    records: []const native_sdk.WindowState,
    fail: bool = false,
    loads: usize = 0,

    pub fn loadWindow(self: *FakeStore, label: []const u8, buffer: []u8) !?native_sdk.WindowState {
        _ = buffer;
        self.loads += 1;
        if (self.fail) return error.InvalidState;
        for (self.records) |record| {
            if (std.mem.eql(u8, record.label, label)) return record;
        }
        return null;
    }
};

test "startup restore mirrors the first declared window's maximized placement into main_window" {
    const normal = native_sdk.geometry.RectF.init(120, 80, 1000, 700);
    var store: FakeStore = .{ .records = &.{
        .{ .label = "main", .frame = normal, .maximized = true },
        .{ .label = "inspector", .frame = native_sdk.geometry.RectF.init(10, 20, 300, 400) },
        .{ .label = "opted-out", .frame = native_sdk.geometry.RectF.init(1, 2, 3, 4), .maximized = true },
    } };
    var windows = [_]native_sdk.WindowOptions{
        .{ .id = 1, .label = "main" },
        .{ .id = 2, .label = "inspector" },
        .{ .id = 3, .label = "opted-out", .restore_state = false },
    };
    var app_info: native_sdk.AppInfo = .{ .main_window = windows[0], .windows = &windows };
    var buffer: [64]u8 = undefined;
    restoreStartupWindows(&app_info, &windows, &store, &buffer);

    try std.testing.expectEqual(normal, windows[0].default_frame);
    try std.testing.expect(windows[0].initial_maximized);
    try std.testing.expectEqual(normal, app_info.main_window.default_frame);
    try std.testing.expect(app_info.main_window.initial_maximized);
    try std.testing.expectEqual(native_sdk.WindowInitialPlacement.restored, app_info.main_window.initial_placement);
    try std.testing.expect(!windows[1].initial_maximized);
    try std.testing.expectEqual(native_sdk.WindowInitialPlacement.restored, windows[1].initial_placement);
    // restore_state = false is never looked up, so its record cannot apply.
    try std.testing.expectEqual(native_sdk.WindowInitialPlacement.default, windows[2].initial_placement);
    try std.testing.expect(!windows[2].initial_maximized);
    try std.testing.expectEqual(@as(usize, 2), store.loads);
}

test "startup restore of a lone main window applies its maximized placement" {
    const normal = native_sdk.geometry.RectF.init(0, 0, 800, 600);
    var store: FakeStore = .{ .records = &.{.{ .label = "main", .frame = normal, .maximized = true }} };
    var app_info: native_sdk.AppInfo = .{};
    var buffer: [64]u8 = undefined;
    var none: [0]native_sdk.WindowOptions = .{};
    restoreStartupWindows(&app_info, &none, &store, &buffer);
    try std.testing.expectEqual(normal, app_info.main_window.default_frame);
    try std.testing.expect(app_info.main_window.initial_maximized);
}

test "startup restore treats a store read failure as a miss" {
    var store: FakeStore = .{ .records = &.{}, .fail = true };
    var app_info: native_sdk.AppInfo = .{ .main_window = .{ .initial_placement = .explicit } };
    var buffer: [64]u8 = undefined;
    var none: [0]native_sdk.WindowOptions = .{};
    restoreStartupWindows(&app_info, &none, &store, &buffer);
    try std.testing.expectEqual(native_sdk.WindowInitialPlacement.explicit, app_info.main_window.initial_placement);
    try std.testing.expect(!app_info.main_window.initial_maximized);
}

test "omitted shell placement fields preserve direct runner fallbacks" {
    try std.testing.expectEqual(
        native_sdk.WindowRestorePolicy.center_on_primary,
        applyShellRestorePolicy(.center_on_primary, null),
    );
    try std.testing.expectEqual(
        native_sdk.WindowInitialPlacement.restored,
        applyShellInitialPlacement(.restored, false),
    );
}

test "authored shell placement fields override direct runner fallbacks" {
    try std.testing.expectEqual(
        native_sdk.WindowRestorePolicy.clamp_to_visible_screen,
        applyShellRestorePolicy(.center_on_primary, .clamp_to_visible_screen),
    );
    try std.testing.expectEqual(
        native_sdk.WindowInitialPlacement.explicit,
        applyShellInitialPlacement(.restored, true),
    );
}
