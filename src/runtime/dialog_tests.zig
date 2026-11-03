const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const platform = support.platform;
const App = support.App;
const Runtime = support.Runtime;
const TestHarness = support.TestHarness;
const DialogCompletion = support.runtime_module.DialogCompletion;

const Probe = struct {
    calls: usize = 0,
    ids: [8]platform.DialogRequestId = undefined,
    outcomes: [8]platform.DialogOutcome = undefined,
    last_paths: [256]u8 = undefined,
    last_paths_len: usize = 0,
    last_count: usize = 0,
    last_button: platform.MessageDialogResult = .primary,
    last_tag: [64]u8 = undefined,
    last_tag_len: usize = 0,

    fn completion(self: *Probe, tag: []const u8) DialogCompletion {
        return .{ .context = self, .tag = tag, .on_result = onResult };
    }

    fn onResult(context: *anyopaque, runtime: *Runtime, tag: []const u8, result: platform.DialogResult) anyerror!void {
        _ = runtime;
        const self: *Probe = @ptrCast(@alignCast(context));
        self.ids[self.calls] = result.id;
        self.outcomes[self.calls] = result.outcome;
        self.calls += 1;
        self.last_paths_len = result.paths.len;
        @memcpy(self.last_paths[0..result.paths.len], result.paths);
        self.last_count = result.count;
        self.last_button = result.button;
        self.last_tag_len = tag.len;
        @memcpy(self.last_tag[0..tag.len], tag);
    }

    fn paths(self: *const Probe) []const u8 {
        return self.last_paths[0..self.last_paths_len];
    }

    fn tagText(self: *const Probe) []const u8 {
        return self.last_tag[0..self.last_tag_len];
    }
};

fn dialogApp(harness: *TestHarness()) App {
    return .{ .context = harness, .name = "dialogs", .source = platform.WebViewSource.html("<p>Dialogs</p>") };
}

/// A started runtime whose null platform presents dialogs asynchronously.
fn started() !*TestHarness() {
    const harness = try startedBlocking();
    harness.null_platform.useAsyncDialogs(&harness.runtime.options.platform.services);
    return harness;
}

/// The null platform as app tests get it: blocking dialogs that answer at
/// once.
fn startedBlocking() !*TestHarness() {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    errdefer harness.destroy(std.testing.allocator);
    try harness.runtime.dispatchPlatformEvent(dialogApp(harness), .app_start);
    return harness;
}

/// Deliver the wakes the platform posted, as a host loop would.
fn deliverWakes(harness: *TestHarness()) !void {
    while (harness.null_platform.takeWake()) |event| try harness.runtime.dispatchPlatformEvent(dialogApp(harness), event);
}

fn closeMainWindow(harness: *TestHarness()) !void {
    try harness.runtime.dispatchPlatformEvent(dialogApp(harness), .{ .window_frame_changed = .{
        .id = 1,
        .label = "main",
        .title = "",
        .frame = geometry.RectF.init(0, 0, 720, 480),
        .scale_factor = 1,
        .open = false,
        .focused = false,
    } });
}

test "dialog requests return at once and complete on a later wake" {
    const harness = try started();
    defer harness.destroy(std.testing.allocator);
    var probe: Probe = .{};

    const id = try harness.runtime.requestOpenDialog(.{ .title = "Open", .allow_multiple = true }, null, probe.completion("request-1"));
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    const shown = harness.null_platform.findPresentedDialog(id).?;
    try std.testing.expectEqual(platform.DialogKind.open, shown.kind);
    try std.testing.expectEqual(@as(?platform.WindowId, 1), shown.parent_window_id);
    try std.testing.expectEqualStrings("Open", shown.titleText());

    try harness.null_platform.finishDialog(id, .selected, "/a.txt\n/b.txt", .primary);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try deliverWakes(harness);

    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(id, probe.ids[0]);
    try std.testing.expectEqual(platform.DialogOutcome.selected, probe.outcomes[0]);
    try std.testing.expectEqualStrings("/a.txt\n/b.txt", probe.paths());
    try std.testing.expectEqual(@as(usize, 2), probe.last_count);
    try std.testing.expectEqualStrings("request-1", probe.tagText());
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDialogCount());
}

test "dialogs for one window show one at a time in request order" {
    const harness = try started();
    defer harness.destroy(std.testing.allocator);
    var probe: Probe = .{};

    const first = try harness.runtime.requestOpenDialog(.{}, null, probe.completion(""));
    const second = try harness.runtime.requestMessageDialog(.{ .message = "Next" }, 1, probe.completion(""));
    const detached = try harness.runtime.requestDialog(.{ .options = .{ .save = .{ .default_name = "a.txt" } }, .detached = true }, probe.completion(""));
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.presentedDialogCount());
    try std.testing.expect(harness.null_platform.findPresentedDialog(second) == null);
    try std.testing.expectEqual(@as(?platform.WindowId, null), harness.null_platform.findPresentedDialog(detached).?.parent_window_id);

    try harness.null_platform.finishDialog(first, .cancelled, "", .primary);
    try deliverWakes(harness);
    try std.testing.expect(harness.null_platform.findPresentedDialog(second) != null);

    try harness.null_platform.finishDialog(detached, .selected, "/a.txt", .primary);
    try deliverWakes(harness);
    try harness.null_platform.finishDialog(second, .selected, "", .secondary);
    try deliverWakes(harness);

    try std.testing.expectEqual(@as(usize, 3), probe.calls);
    try std.testing.expectEqualSlices(platform.DialogRequestId, &.{ first, detached, second }, probe.ids[0..3]);
    try std.testing.expectEqual(platform.MessageDialogResult.secondary, probe.last_button);
}

test "cancelling a queued dialog never shows it and a presented one closes" {
    const harness = try started();
    defer harness.destroy(std.testing.allocator);
    var probe: Probe = .{};

    const first = try harness.runtime.requestOpenDialog(.{}, null, probe.completion(""));
    const second = try harness.runtime.requestOpenDialog(.{}, null, probe.completion(""));
    harness.runtime.cancelDialog(second);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try deliverWakes(harness);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(second, probe.ids[0]);
    try std.testing.expectEqual(platform.DialogOutcome.cancelled, probe.outcomes[0]);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.dialog_request_count);

    harness.runtime.cancelDialog(first);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.dialog_cancel_count);
    try deliverWakes(harness);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqual(platform.DialogOutcome.cancelled, probe.outcomes[1]);
    harness.runtime.cancelDialog(first);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.dialog_cancel_count);
}

test "closing the parent window cancels its dialogs and leaves others" {
    const harness = try started();
    defer harness.destroy(std.testing.allocator);
    var probe: Probe = .{};

    const shown = try harness.runtime.requestOpenDialog(.{}, null, probe.completion(""));
    const queued = try harness.runtime.requestOpenDialog(.{}, null, probe.completion(""));
    const detached = try harness.runtime.requestDialog(.{ .options = .{ .open = .{} }, .detached = true }, probe.completion(""));
    try closeMainWindow(harness);
    try deliverWakes(harness);

    // Platform-reported results drain before the runtime's own.
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqualSlices(platform.DialogRequestId, &.{ shown, queued }, probe.ids[0..2]);
    try std.testing.expectEqualSlices(platform.DialogOutcome, &.{ .cancelled, .cancelled }, probe.outcomes[0..2]);
    try std.testing.expect(harness.null_platform.findPresentedDialog(detached) != null);
}

test "an app stop drops pending dialogs without running completions" {
    const harness = try started();
    defer harness.destroy(std.testing.allocator);
    var probe: Probe = .{};

    _ = try harness.runtime.requestOpenDialog(.{}, null, probe.completion(""));
    _ = try harness.runtime.requestOpenDialog(.{}, null, probe.completion(""));
    try harness.runtime.dispatchPlatformEvent(dialogApp(harness), .app_shutdown);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDialogCount());
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.dialog_cancel_count);
    try deliverWakes(harness);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "a dialog the platform cannot present reports failed" {
    const harness = try started();
    defer harness.destroy(std.testing.allocator);
    var probe: Probe = .{};

    harness.null_platform.fail_next_dialog_request = true;
    const failed = try harness.runtime.requestOpenDialog(.{}, null, probe.completion(""));
    const next = try harness.runtime.requestOpenDialog(.{}, null, probe.completion(""));
    try deliverWakes(harness);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(failed, probe.ids[0]);
    try std.testing.expectEqual(platform.DialogOutcome.failed, probe.outcomes[0]);
    try std.testing.expect(harness.null_platform.findPresentedDialog(next) != null);
}

test "platforms without asynchronous dialogs fall back to the blocking call" {
    const harness = try startedBlocking();
    defer harness.destroy(std.testing.allocator);
    var probe: Probe = .{};

    _ = try harness.runtime.requestOpenDialog(.{}, null, probe.completion(""));
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.open_dialog_count);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try deliverWakes(harness);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqualStrings("/tmp/native-sdk-open.txt", probe.paths());

    harness.null_platform.message_dialog_result = .tertiary;
    _ = try harness.runtime.requestMessageDialog(.{ .message = "Sure?" }, null, probe.completion(""));
    try deliverWakes(harness);
    try std.testing.expectEqual(platform.DialogOutcome.selected, probe.outcomes[1]);
    try std.testing.expectEqual(platform.MessageDialogResult.tertiary, probe.last_button);
}

test "a completion may request the next dialog without jumping the queue" {
    const harness = try started();
    defer harness.destroy(std.testing.allocator);
    const Chain = struct {
        harness: *TestHarness(),
        probe: Probe = .{},
        third: platform.DialogRequestId = 0,

        fn onResult(context: *anyopaque, runtime: *Runtime, tag: []const u8, result: platform.DialogResult) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try Probe.onResult(&self.probe, runtime, tag, result);
            if (self.third == 0) self.third = try runtime.requestOpenDialog(.{}, 1, .{ .context = self, .on_result = onResult });
        }
    };
    var chain: Chain = .{ .harness = harness };

    const first = try harness.runtime.requestOpenDialog(.{}, null, .{ .context = &chain, .on_result = Chain.onResult });
    const second = try harness.runtime.requestOpenDialog(.{}, null, .{ .context = &chain, .on_result = Chain.onResult });
    try harness.null_platform.finishDialog(first, .cancelled, "", .primary);
    try deliverWakes(harness);
    try std.testing.expect(chain.third != 0);
    try std.testing.expect(harness.null_platform.findPresentedDialog(second) != null);
    try std.testing.expect(harness.null_platform.findPresentedDialog(chain.third) == null);

    try harness.null_platform.finishDialog(second, .cancelled, "", .primary);
    try deliverWakes(harness);
    try std.testing.expect(harness.null_platform.findPresentedDialog(chain.third) != null);
}

test "dialog requests are validated before they queue" {
    const harness = try started();
    defer harness.destroy(std.testing.allocator);
    var probe: Probe = .{};

    const long_tag = [_]u8{'t'} ** (support.runtime_module.max_dialog_tag_bytes + 1);
    try std.testing.expectError(error.DialogTagTooLarge, harness.runtime.requestOpenDialog(.{}, null, probe.completion(&long_tag)));
    try std.testing.expectError(error.InvalidDialogOptions, harness.runtime.requestMessageDialog(.{ .primary_button = "" }, null, probe.completion("")));
    const long_title = [_]u8{'x'} ** (platform.max_dialog_title_bytes + 1);
    try std.testing.expectError(error.DialogFieldTooLarge, harness.runtime.requestOpenDialog(.{ .title = &long_title }, null, probe.completion("")));
    try std.testing.expectError(error.WindowNotFound, harness.runtime.requestOpenDialog(.{}, 99, probe.completion("")));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDialogCount());

    for (0..support.runtime_module.max_dialog_requests) |_| _ = try harness.runtime.requestOpenDialog(.{}, null, probe.completion(""));
    try std.testing.expectError(error.DialogQueueFull, harness.runtime.requestOpenDialog(.{}, null, probe.completion("")));
}

test "a failing completion is recorded and the queue moves on" {
    const harness = try started();
    defer harness.destroy(std.testing.allocator);
    const Failing = struct {
        fn onResult(context: *anyopaque, runtime: *Runtime, tag: []const u8, result: platform.DialogResult) anyerror!void {
            _ = .{ context, runtime, tag, result };
            return error.CompletionFailed;
        }
    };
    var probe: Probe = .{};
    const first = try harness.runtime.requestOpenDialog(.{}, null, .{ .context = &probe, .on_result = Failing.onResult });
    const second = try harness.runtime.requestOpenDialog(.{}, null, probe.completion(""));
    const errors_before = harness.runtime.dispatch_error_total;
    try harness.null_platform.finishDialog(first, .cancelled, "", .primary);
    try deliverWakes(harness);
    try std.testing.expectEqual(errors_before + 1, harness.runtime.dispatch_error_total);
    try std.testing.expect(harness.null_platform.findPresentedDialog(second) != null);
}
