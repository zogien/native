//! Real-window fixture for app-drawn window controls on Windows: three
//! chromeless windows whose pages draw Minimize, Maximize/Restore, and
//! Close buttons and route them through the command bridge to
//! `Runtime.minimizeWindow`, `maximizeWindow`, `unmaximizeWindow`, and
//! `requestCloseWindow`. `scripts/test-window-controls-windows.ps1`
//! drives it with real input.
const std = @import("std");
const sdk = @import("native_sdk");
const runner = @import("runner");
pub const panic = std.debug.FullPanic(sdk.debug.capturePanic);

const bridge_origins = [_][]const u8{"zero://app"};
const command_permission = [_][]const u8{sdk.security.permission_command};
const window_permission = [_][]const u8{sdk.security.permission_window};
const app_permissions = [_][]const u8{ sdk.security.permission_command, sdk.security.permission_window };
const builtin_policies = [_]sdk.BridgeCommandPolicy{
    .{ .name = "native-sdk.command.invoke", .permissions = &command_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.window.list", .permissions = &window_permission, .origins = &bridge_origins },
};
// close_policy "hide" on Windows needs a live tray icon to re-show from.
const tray_items = [_]sdk.TrayMenuItem{.{ .id = 1, .label = "Show palette", .command = "controls.show-palette" }};

fn scene(_: *anyopaque) !sdk.ShellConfig {
    return .{ .windows = &.{
        .{ .label = "main", .title = "Window Controls Main", .width = 900, .height = 560, .titlebar = .chromeless, .window_drag_regions = true, .restore_state = false, .views = &.{
            .{ .label = "main", .kind = .webview, .url = "zero://app/main.html", .fill = true },
        } },
        .{ .label = "palette", .title = "Window Controls Palette", .width = 520, .height = 380, .x = 160, .y = 160, .titlebar = .chromeless, .window_drag_regions = true, .close_policy = .hide, .restore_state = false, .views = &.{
            .{ .label = "main", .kind = .webview, .url = "zero://app/palette.html", .fill = true },
        } },
        .{ .label = "quitter", .title = "Window Controls Quitter", .width = 520, .height = 380, .x = 220, .y = 220, .titlebar = .chromeless, .resizable = false, .window_drag_regions = true, .restore_state = false, .views = &.{
            .{ .label = "main", .kind = .webview, .url = "zero://app/quitter.html", .fill = true },
        } },
    } };
}

fn start(_: *anyopaque, runtime: *sdk.Runtime) anyerror!void {
    try runtime.createTray(.{ .tooltip = "Window Controls", .items = &tray_items });
}

fn event(_: *anyopaque, runtime: *sdk.Runtime, incoming: sdk.Event) anyerror!void {
    switch (incoming) {
        .command => |command| try handleCommand(runtime, command),
        // Only user closes arrive here: the app's own closeWindow never
        // reports back. The main page shows which window it was.
        .window_closed => |closed| try notify(runtime, windowIdByLabel(runtime, "main") orelse return, "fixture:closed", "label", closed.label),
        else => {},
    }
}

fn handleCommand(runtime: *sdk.Runtime, command: sdk.CommandEvent) !void {
    const window_id = command.window_id;
    const name = command.name;
    const result = if (std.mem.eql(u8, name, "controls.minimize"))
        runtime.minimizeWindow(window_id)
    else if (std.mem.eql(u8, name, "controls.maximize"))
        runtime.maximizeWindow(window_id)
    else if (std.mem.eql(u8, name, "controls.restore"))
        runtime.unmaximizeWindow(window_id)
    else if (std.mem.eql(u8, name, "controls.close"))
        runtime.requestCloseWindow(window_id)
    else if (std.mem.eql(u8, name, "controls.show-palette"))
        runtime.showWindow(windowIdByLabel(runtime, "palette") orelse return)
    else
        return;
    // A refusal is part of the contract under test: show it on the page
    // that asked instead of failing the bridge call.
    result catch |err| if (window_id != 0) try notify(runtime, window_id, "fixture:error", "error", @errorName(err));
}

fn windowIdByLabel(runtime: *sdk.Runtime, label: []const u8) ?sdk.platform.WindowId {
    var output: [sdk.platform.max_windows]sdk.platform.WindowInfo = undefined;
    for (runtime.listWindows(&output)) |window| {
        if (window.open and std.mem.eql(u8, window.label, label)) return window.id;
    }
    return null;
}

fn notify(runtime: *sdk.Runtime, window_id: sdk.platform.WindowId, name: []const u8, field: []const u8, value: []const u8) !void {
    var detail_buffer: [128]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buffer, "{{\"{s}\":\"{s}\"}}", .{ field, value });
    try runtime.emitWindowEvent(window_id, name, detail);
}

pub fn main(init: std.process.Init) !void {
    var context: u8 = 0;
    try runner.runWithOptions(.{
        .context = &context,
        .name = "window-controls",
        .scene_fn = scene,
        .start_fn = start,
        .event_fn = event,
        .source = sdk.WebViewSource.assets(.{ .root_path = "assets", .entry = "main.html" }),
    }, .{
        .app_name = "window-controls",
        .window_title = "Window Controls Main",
        .bundle_id = "dev.native_sdk.window_controls",
        .builtin_bridge = .{ .enabled = true, .commands = &builtin_policies },
        .js_window_api = true,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &bridge_origins },
        },
    }, init);
}
