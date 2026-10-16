//! Entry-analysis fixture for the managed app build's `native test`.
//!
//! `Model.count` deliberately has no default value, which UiApp.create's
//! Model-defaults rule rejects at compile time. Only `main` reaches
//! `create` and the fixture declares no tests, so the unit-test compile
//! stays clean: the rule can surface at `native test` only through the
//! app build's entry analysis. The root build's
//! `test-app-entry-analysis-teaching` step requires `native test` to fail
//! with that teaching message.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 320;
const window_height: f32 = 200;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Counter canvas", .accessibility_label = "Counter", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Entry Analysis",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub const Msg = union(enum) {
    increment,
};

pub const Model = struct {
    // No default: the rule under test.
    count: i64,
};

pub const Effects = native_sdk.Effects(Msg);

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    _ = fx;
    switch (msg) {
        .increment => model.count += 1,
    }
}

pub const app_markup = @embedFile("app.native");

const EntryAnalysisApp = native_sdk.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    const app_state = try EntryAnalysisApp.create(std.heap.page_allocator, .{
        .name = "entry-analysis",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "entry-analysis",
        .window_title = "Entry Analysis",
        .bundle_id = "dev.native_sdk.entry-analysis",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}
