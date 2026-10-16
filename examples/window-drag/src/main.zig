const std = @import("std");
const sdk = @import("native_sdk");
const runner = @import("runner");
pub const panic = std.debug.FullPanic(sdk.debug.capturePanic);
fn scene(_: *anyopaque) !sdk.ShellConfig {
    return .{ .windows = &.{
        .{ .label = "main", .title = "Native SDK Window Drag", .width = 1040, .height = 640, .titlebar = .hidden_inset_tall, .window_drag_regions = true, .views = &.{
            .{ .label = "main", .kind = .webview, .url = "zero://app/index.html", .fill = true },
            .{ .label = "child-plain", .kind = .webview, .url = "zero://app/child.html", .x = 720, .y = 500, .width = 280, .height = 100 },
            .{ .label = "child-drag", .kind = .webview, .url = "zero://app/child.html", .x = 720, .y = 120, .width = 280, .height = 360, .window_drag_regions = true },
        } },
        .{ .label = "secondary", .title = "Native SDK Secondary Drag", .width = 640, .height = 480, .window_drag_regions = true, .views = &.{.{ .label = "main", .kind = .webview, .url = "zero://app/index.html", .fill = true }} },
    } };
}
pub fn main(init: std.process.Init) !void {
    var context: u8 = 0;
    try runner.runWithOptions(.{
        .context = &context,
        .name = "window-drag",
        .scene_fn = scene,
        .source = sdk.WebViewSource.assets(.{ .root_path = "assets", .entry = "index.html" }),
    }, .{
        .app_name = "window-drag",
        .window_title = "Native SDK Window Drag",
        .bundle_id = "dev.native_sdk.window_drag",
        .security = .{ .navigation = .{ .allowed_origins = &.{"zero://app"} } },
    }, init);
}
