//! Window controls for app-drawn title bars, beyond minimize: maximize,
//! restore from maximized, and the user-close request. Each is the real
//! OS verb for a tracked, open window. Like `minimizeWindow`, no runtime
//! bookkeeping moves here: the host's own frame events report what the
//! OS did, the same way they report the caption buttons, the system menu,
//! and keyboard shortcuts.
const lifecycle = @import("window_lifecycle_policy.zig");
const std = @import("std");
const runtime_window_views = @import("window_views.zig");
const platform = @import("../platform/root.zig");

/// The page event a window's WebViews receive when its maximized state
/// changes, whoever changed it, so a page-drawn maximize/restore button
/// can follow the caption double-click, the system menu, and keyboard
/// shortcuts: `window.zero.on("window:state", ({ maximized }) => ...)`.
pub const window_state_event = "window:state";

/// Called by the runtime's window-state update when `maximized` flips.
/// Best effort, like the other page notifications: the detail is always
/// valid JSON, so the only failure is a host without page events
/// (`error.UnsupportedService`), where no page exists to tell.
pub fn announceMaximized(runtime: anytype, window_id: platform.WindowId, maximized: bool) void {
    var detail_buffer: [64]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buffer, "{{\"windowId\":{d},\"maximized\":{s}}}", .{ window_id, if (maximized) "true" else "false" }) catch return;
    runtime.options.platform.services.emitWindowEvent(window_id, window_state_event, detail) catch {};
}

pub fn RuntimeWindowControls(comptime Runtime: type) type {
    const WindowViewMethods = runtime_window_views.RuntimeWindowViews(Runtime);

    return struct {
        /// Maximize a window. Refused for a non-resizable window
        /// (`error.WindowNotResizable`) and for one that is not on the
        /// glass (`error.WindowHidden`). `WindowInfo.maximized` follows
        /// the host's frame event.
        pub fn maximizeWindow(self: *Runtime, window_id: platform.WindowId) anyerror!void {
            try requireOpenWindow(self, window_id);
            try self.options.platform.services.maximizeWindow(window_id);
        }

        /// Restore a maximized window to its normal frame. A window that
        /// is not maximized is left as it is.
        pub fn unmaximizeWindow(self: *Runtime, window_id: platform.WindowId) anyerror!void {
            try requireOpenWindow(self, window_id);
            try self.options.platform.services.unmaximizeWindow(window_id);
        }

        /// Ask a window to close as if the user pressed its close button,
        /// so its `close_policy` applies: `.hide` hides it and keeps its
        /// views, `.quit` closes it and dispatches `window_closed`.
        /// `closeWindow` remains the app's own unconditional close. The
        /// request is queued; its outcome arrives as the host's frame
        /// events, so success here means the request was delivered.
        pub fn requestCloseWindow(self: *Runtime, window_id: platform.WindowId) anyerror!void {
            try requireOpenWindow(self, window_id);
            try self.options.platform.services.requestCloseWindow(window_id);
        }

        /// The liveness gate every window verb shares: a closed window
        /// keeps its table slot, so a resolvable id is not enough.
        fn requireOpenWindow(self: *Runtime, window_id: platform.WindowId) !void {
            if (self.window_lifecycle_policy) |policy| {
                // The compiled policy knows close, hide, show, and focus,
                // which move runtime flags, and minimize, which moves
                // none. These controls move none either, so they take
                // minimize's admission: the window exists and is open.
                return lifecycle.plan(policy, self, .begin, .{ .id = window_id, .variant = @intFromEnum(lifecycle.Verb.minimize) }).admitted();
            }
            const index = WindowViewMethods.findWindowIndexById(self, window_id) orelse return error.WindowNotFound;
            if (!self.windows[index].info.open) return error.WindowNotFound;
        }
    };
}
