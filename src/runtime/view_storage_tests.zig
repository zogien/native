//! Allocation discipline of the canvas storage: a runtime owns a
//! `ViewCanvasStorage` exactly for each live gpu-surface view, from the
//! view's creation to its removal, plus one shared `CanvasScratch` from
//! its first gpu-surface view until `deinit`; view compaction moves the
//! per-view storage by pointer.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const core = @import("core.zig");
const runtime_view = @import("view.zig");
const runtime_canvas_scratch = @import("canvas_scratch.zig");
const support = @import("test_support.zig");

const platform = support.platform;
const App = support.App;
const TestHarness = support.TestHarness;

const storage_bytes = @sizeOf(runtime_view.ViewCanvasStorage);
const scratch_bytes = @sizeOf(runtime_canvas_scratch.CanvasScratch);

const StorageApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "view-storage", .source = platform.WebViewSource.html("<h1>Views</h1>") };
    }
};

fn harnessWithRuntimeAllocator(runtime_allocator: std.mem.Allocator) !*TestHarness() {
    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 140) });
    errdefer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    core.Runtime.initAt(&harness.runtime, .{
        .platform = harness.null_platform.platform(),
        .trace_sink = harness.trace_sink.sink(),
        .allocator = runtime_allocator,
        .environ = std.testing.environ,
    });
    harness.runtime.dispatch_error_policy = .propagate;
    return harness;
}

fn createCanvasView(harness: *TestHarness(), label: []const u8) !void {
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = label,
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });
}

fn viewByLabel(harness: *TestHarness(), label: []const u8) *runtime_view.RuntimeView {
    const index = harness.runtime.findViewIndex(1, label).?;
    return &harness.runtime.views[index];
}

test "canvas storage exists only for live gpu-surface views, the shared scratch from the first one on" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const harness = try harnessWithRuntimeAllocator(counting.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: StorageApp = .{};
    try harness.start(app_state.app());

    // Construction and startup allocate nothing.
    try std.testing.expectEqual(@as(usize, 0), counting.allocations);
    try std.testing.expect(harness.runtime.canvas_scratch == null);

    // A native-control view never owns canvas storage, and its canvas
    // reads are honestly empty.
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "toolbar", .kind = .toolbar, .frame = geometry.RectF.init(0, 0, 240, 40) });
    try std.testing.expectEqual(@as(usize, 0), counting.allocations);
    try std.testing.expect(harness.runtime.canvas_scratch == null);
    const toolbar = viewByLabel(harness, "toolbar");
    try std.testing.expect(toolbar.canvas_storage == null);
    try std.testing.expectEqual(@as(usize, 0), toolbar.canvasDisplayList().commands.len);
    try std.testing.expectEqual(@as(usize, 0), toolbar.widgetLayoutTree().nodes.len);
    try std.testing.expectEqual(@as(usize, 0), toolbar.widgetSemantics().len);

    // The first gpu-surface view brings the shared scratch and its own
    // storage block; every later one costs exactly one storage block.
    try createCanvasView(harness, "first");
    try std.testing.expectEqual(@as(usize, 2), counting.allocations);
    try std.testing.expectEqual(scratch_bytes + storage_bytes, counting.allocated_bytes);
    try std.testing.expect(harness.runtime.canvas_scratch != null);
    try createCanvasView(harness, "second");
    try std.testing.expectEqual(@as(usize, 3), counting.allocations);
    try std.testing.expectEqual(scratch_bytes + 2 * storage_bytes, counting.allocated_bytes);

    // Closing a gpu-surface view returns its block; closing the
    // native-control view frees nothing. The scratch stays for the
    // runtime's lifetime.
    try harness.runtime.closeView(1, "first");
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
    try std.testing.expectEqual(storage_bytes, counting.freed_bytes);
    try harness.runtime.closeView(1, "toolbar");
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
    try std.testing.expect(harness.runtime.canvas_scratch != null);

    // Ownership froze at init: a swapped `options.allocator` sees none
    // of the remaining frees, and deinit returns everything.
    var poisoned = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    harness.runtime.options.allocator = poisoned.allocator();
    harness.runtime.deinit();
    try std.testing.expectEqual(counting.allocations, counting.deallocations);
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
    try std.testing.expect(harness.runtime.canvas_scratch == null);
    try std.testing.expectEqual(@as(usize, 0), poisoned.allocations);
    try std.testing.expectEqual(@as(usize, 0), poisoned.deallocations);
}

test "removing a view moves later views with their storage and every slice into it" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const harness = try harnessWithRuntimeAllocator(counting.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: StorageApp = .{};
    try harness.start(app_state.app());

    try createCanvasView(harness, "removed");
    try createCanvasView(harness, "drawn");
    try createCanvasView(harness, "widgets");

    // "drawn" retains a display list whose gradient fill slices into the
    // view's gradient stop buffer.
    const stops = [_]canvas.GradientStop{
        .{ .offset = 0, .color = canvas.Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = canvas.Color.rgb8(37, 99, 235) },
    };
    const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{
        .id = 7,
        .rect = geometry.RectF.init(0, 0, 40, 20),
        .fill = .{ .linear_gradient = .{ .start = geometry.PointF.init(0, 0), .end = geometry.PointF.init(40, 20), .stops = &stops } },
    } }};
    _ = try harness.runtime.setCanvasDisplayList(1, "drawn", .{ .commands = &commands });

    // "widgets" retains a widget tree whose text slices into the view's
    // widget text pool.
    const rows = [_]canvas.Widget{
        .{ .id = 2, .kind = .text, .text = "first retained line" },
        .{ .id = 3, .kind = .text, .text = "second retained line" },
    };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .column, .children = &rows }, geometry.RectF.init(0, 0, 240, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "widgets", layout);

    const drawn_storage = viewByLabel(harness, "drawn").canvas_storage.?;
    const widgets_storage = viewByLabel(harness, "widgets").canvas_storage.?;
    const allocations_before = counting.allocations;

    try harness.runtime.closeView(1, "removed");

    // Removal frees exactly the removed view's block and allocates
    // nothing: the survivors move down a slot with their blocks.
    try std.testing.expectEqual(allocations_before, counting.allocations);
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
    try std.testing.expectEqual(@as(usize, 2), harness.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.findViewIndex(1, "drawn").?);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.findViewIndex(1, "widgets").?);
    try std.testing.expectEqual(drawn_storage, viewByLabel(harness, "drawn").canvas_storage.?);
    try std.testing.expectEqual(widgets_storage, viewByLabel(harness, "widgets").canvas_storage.?);
    // The vacated tail slot forgot the block its occupant took along.
    try std.testing.expect(harness.runtime.views[harness.runtime.view_count].canvas_storage == null);

    // The moved display list still reads its gradient stops.
    const drawn_list = viewByLabel(harness, "drawn").canvasDisplayList();
    try std.testing.expectEqual(@as(usize, 1), drawn_list.commands.len);
    const fill = drawn_list.commands[0].fill_rect.fill.linear_gradient;
    try std.testing.expectEqualSlices(canvas.GradientStop, &stops, fill.stops);

    // The moved widget tree still reads its text.
    const tree = viewByLabel(harness, "widgets").widgetLayoutTree();
    var found: usize = 0;
    for (tree.nodes) |node| {
        if (node.widget.id == 2) {
            try std.testing.expectEqualStrings("first retained line", node.widget.text);
            found += 1;
        }
        if (node.widget.id == 3) {
            try std.testing.expectEqualStrings("second retained line", node.widget.text);
            found += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), found);
}

test "a gpu-surface view whose storage cannot be allocated is refused before the platform sees it" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const harness = try harnessWithRuntimeAllocator(failing.allocator());
    defer harness.destroy(std.testing.allocator);
    var app_state: StorageApp = .{};
    try harness.start(app_state.app());

    const platform_views = harness.null_platform.view_count;

    // Refused at the shared scratch: nothing exists afterwards.
    try std.testing.expectError(error.OutOfMemory, createCanvasView(harness, "canvas"));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.view_count);
    try std.testing.expectEqual(platform_views, harness.null_platform.view_count);
    try std.testing.expect(harness.runtime.canvas_scratch == null);

    // Refused at the view's own storage: the scratch (runtime-lifetime
    // by design) stays, the view does not exist anywhere.
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, createCanvasView(harness, "canvas"));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.view_count);
    try std.testing.expectEqual(platform_views, harness.null_platform.view_count);
    try std.testing.expect(harness.runtime.canvas_scratch != null);

    // Nothing was half-created: once memory is available the same view
    // is created normally.
    failing.fail_index = std.math.maxInt(usize);
    try createCanvasView(harness, "canvas");
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.view_count);
    try std.testing.expect(viewByLabel(harness, "canvas").canvas_storage != null);
}

test "gpu-surface events and canvas reads aimed at a native-control view never reach canvas storage" {
    // Only gpu-surface views own canvas storage, and `canvasStorage()`
    // asserts it exists. Every event a host (or a damaged journal or a
    // misaddressed automation script) can aim at a view label must
    // therefore check the view's kind before touching canvas state; a
    // path that does not fails this test on the assertion.
    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 140) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: StorageApp = .{};
    const app = app_state.app();
    try harness.start(app);
    // A canvas view exists too, so only the targeted view lacks storage.
    try createCanvasView(harness, "canvas");
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "toolbar", .kind = .toolbar, .frame = geometry.RectF.init(0, 0, 240, 40) });
    // Refusals are fine here (the view is not a canvas); only reaching
    // the absent storage is a failure.
    harness.runtime.dispatch_error_policy = .degrade;

    const label = "toolbar";
    harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{ .label = label, .size = geometry.SizeF.init(240, 40), .timestamp_ns = 1 } }) catch {};
    harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_resized = .{ .label = label, .frame = geometry.RectF.init(0, 0, 200, 30) } }) catch {};
    for (std.enums.values(platform.GpuSurfaceInputKind)) |kind| {
        const keyed = kind == .key_down or kind == .key_up;
        const texted = kind == .text_input or kind == .ime_set_composition or kind == .ime_commit_composition;
        for ([_]i32{ 1, 2 }) |button| {
            harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
                .label = label,
                .kind = kind,
                .timestamp_ns = 2,
                .x = 10,
                .y = 10,
                .button = button,
                .delta_y = 3,
                .key = if (keyed) "Tab" else "",
                .text = if (texted) "x" else "",
            } }) catch {};
        }
    }
    harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_scroll_driver = .{ .label = label, .driver_id = 1, .offset_y = 5 } }) catch {};
    harness.runtime.dispatchPlatformEvent(app, .{ .files_dropped = .{ .view_label = label, .point = geometry.PointF.init(5, 5), .paths = &.{"/tmp/dropped.txt"} } }) catch {};
    harness.runtime.dispatchPlatformEvent(app, .{ .widget_context_menu_action = .{ .label = label, .id = 1, .item_index = 0 } }) catch {};

    _ = harness.runtime.canvasDisplayList(1, label) catch {};
    _ = harness.runtime.canvasWidgetLayout(1, label) catch {};
    _ = harness.runtime.canvasWidgetSemantics(1, label) catch {};
    _ = harness.runtime.canvasRenderAnimations(1, label) catch {};
    _ = harness.runtime.stepCanvasWidgetKineticScroll(1, label, 16) catch {};
    _ = harness.runtime.emitCanvasWidgetDisplayList(1, label, .{}) catch {};
    _ = harness.runtime.automationSnapshot("native-control");

    try std.testing.expect(viewByLabel(harness, label).canvas_storage == null);
}
