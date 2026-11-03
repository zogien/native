//! Asynchronous native dialogs. A request returns at once; the platform
//! presents the dialog without blocking the event loop and reports back
//! through a wake, and the runtime then hands the result to the
//! requester's completion. One dialog shows per parent window (and one
//! among parentless dialogs); later requests for the same parent wait in
//! order. Completions only ever run from a later wake dispatch, never
//! inside `requestDialog` or `cancelDialog`, so a requester never sees its
//! own completion re-enter it.
const std = @import("std");
const platform = @import("../platform/root.zig");
const admission = @import("system_admission_policy.zig");

/// Requests the runtime holds at once, queued and presented together.
pub const max_dialog_requests: usize = 8;
/// Requester bytes a completion gets back verbatim: room for a bridge
/// request id (at most 64 bytes) plus a few bytes of routing.
pub const max_dialog_tag_bytes: usize = 80;

pub const DialogRequestOptions = struct {
    options: platform.DialogOptions,
    /// The owning window. Null picks the focused window, then the first
    /// open one; `detached` presents without a parent instead.
    parent_window_id: ?platform.WindowId = null,
    detached: bool = false,
};

pub fn Completion(comptime Runtime: type) type {
    return struct {
        context: *anyopaque,
        /// Returned to `on_result` unchanged; at most `max_dialog_tag_bytes`.
        tag: []const u8 = "",
        /// Runs exactly once per request from a wake dispatch, unless the
        /// app stops first. `tag` and `result.paths` are valid only for the
        /// duration of the call. An error is recorded like a handler error.
        on_result: *const fn (context: *anyopaque, runtime: *Runtime, tag: []const u8, result: platform.DialogResult) anyerror!void,
    };
}

const State = enum { free, queued, presented, finished, delivering };

fn Entry(comptime Runtime: type) type {
    return struct {
        state: State = .free,
        id: platform.DialogRequestId = 0,
        parent: ?platform.WindowId = null,
        order: u64 = 0,
        completion: Completion(Runtime) = undefined,
        tag_storage: [max_dialog_tag_bytes]u8 = undefined,
        tag_len: usize = 0,
        /// Owns the copied options and, once finished, the result paths.
        arena: std.heap.ArenaAllocator = undefined,
        options: platform.DialogOptions = undefined,
        result: platform.DialogResult = undefined,
    };
}

pub fn Broker(comptime Runtime: type) type {
    return struct {
        entries: [max_dialog_requests]Entry(Runtime) = [_]Entry(Runtime){.{}} ** max_dialog_requests,
        next_id: platform.DialogRequestId = 1,
        next_order: u64 = 0,
        /// Polled platform results and synchronous fallbacks write here.
        result_buffer: [platform.max_dialog_paths_bytes]u8 = undefined,

        /// `Runtime.initAt` skips large field defaults; this is the part
        /// that must start defined.
        pub fn reset(self: *@This()) void {
            for (&self.entries) |*entry| entry.* = .{};
            self.next_id = 1;
            self.next_order = 0;
        }
    };
}

pub fn RuntimeDialogs(comptime Runtime: type) type {
    return struct {
        const DialogEntry = Entry(Runtime);
        const DialogCompletion = Completion(Runtime);

        /// Queue a dialog and return its id. The platform presents it as
        /// soon as no other dialog shows for the same parent.
        pub fn requestDialog(self: *Runtime, request: DialogRequestOptions, completion: DialogCompletion) anyerror!platform.DialogRequestId {
            const broker = &self.dialog_broker;
            if (completion.tag.len > max_dialog_tag_bytes) return error.DialogTagTooLarge;
            try admitOptions(self, request.options);
            if (!canPresent(self.options.platform.services, request.options)) return error.UnsupportedService;
            const parent = try resolveParent(self, request);
            const entry = freeEntry(broker) orelse return error.DialogQueueFull;
            entry.arena = std.heap.ArenaAllocator.init(self.owned_allocator);
            errdefer entry.arena.deinit();
            entry.options = try copyOptions(entry.arena.allocator(), request.options);
            @memcpy(entry.tag_storage[0..completion.tag.len], completion.tag);
            entry.tag_len = completion.tag.len;
            entry.completion = completion;
            entry.completion.tag = "";
            entry.id = broker.next_id;
            broker.next_id += 1;
            entry.order = broker.next_order;
            broker.next_order += 1;
            entry.parent = parent;
            entry.state = .queued;
            const id = entry.id;
            presentNext(self, parent);
            return id;
        }

        pub fn requestOpenDialog(self: *Runtime, options: platform.OpenDialogOptions, parent_window_id: ?platform.WindowId, completion: DialogCompletion) anyerror!platform.DialogRequestId {
            return requestDialog(self, .{ .options = .{ .open = options }, .parent_window_id = parent_window_id }, completion);
        }

        pub fn requestSaveDialog(self: *Runtime, options: platform.SaveDialogOptions, parent_window_id: ?platform.WindowId, completion: DialogCompletion) anyerror!platform.DialogRequestId {
            return requestDialog(self, .{ .options = .{ .save = options }, .parent_window_id = parent_window_id }, completion);
        }

        pub fn requestMessageDialog(self: *Runtime, options: platform.MessageDialogOptions, parent_window_id: ?platform.WindowId, completion: DialogCompletion) anyerror!platform.DialogRequestId {
            return requestDialog(self, .{ .options = .{ .message = options }, .parent_window_id = parent_window_id }, completion);
        }

        /// Close a dialog early. A queued request finishes as `.cancelled`
        /// without ever showing; a presented one is closed by the platform
        /// and reports `.cancelled` through its usual wake. Finished or
        /// unknown ids are a no-op.
        pub fn cancelDialog(self: *Runtime, id: platform.DialogRequestId) void {
            const entry = findEntry(&self.dialog_broker, id) orelse return;
            switch (entry.state) {
                .queued => {
                    finish(entry, .{ .id = id, .outcome = .cancelled }) catch finishFailed(entry);
                    requestWake(self);
                },
                .presented => self.options.platform.services.cancelDialog(id),
                .free, .finished, .delivering => {},
            }
        }

        /// Hand every finished dialog to its completion: the platform's
        /// results in the order it reports them, then the runtime's own
        /// (cancelled while queued, synchronous fallback, failed to
        /// present), oldest first. Called on every `.wake`.
        pub fn adoptDialogResults(self: *Runtime) void {
            const broker = &self.dialog_broker;
            const services = self.options.platform.services;
            while (services.pollDialogResult(&broker.result_buffer)) |result| {
                const entry = findEntry(broker, result.id) orelse continue;
                if (entry.state != .presented) continue;
                finish(entry, result) catch finishFailed(entry);
                deliver(self, entry);
            }
            while (oldestFinished(broker)) |entry| deliver(self, entry);
        }

        /// A window closed: its queued dialogs finish as `.cancelled` and
        /// its presented one is closed (the platform reports it).
        pub fn cancelDialogsForWindow(self: *Runtime, window_id: platform.WindowId) void {
            var finished_any = false;
            for (&self.dialog_broker.entries) |*entry| {
                if (entry.parent == null or entry.parent.? != window_id) continue;
                switch (entry.state) {
                    .queued => {
                        finish(entry, .{ .id = entry.id, .outcome = .cancelled }) catch finishFailed(entry);
                        finished_any = true;
                    },
                    .presented => self.options.platform.services.cancelDialog(entry.id),
                    .free, .finished, .delivering => {},
                }
            }
            if (finished_any) requestWake(self);
        }

        /// The app is stopping: close presented dialogs and drop every
        /// request without running completions. Late platform results find
        /// no request and are discarded.
        pub fn abandonDialogs(self: *Runtime) void {
            for (&self.dialog_broker.entries) |*entry| {
                if (entry.state == .presented) self.options.platform.services.cancelDialog(entry.id);
                if (entry.state != .free) release(entry);
            }
        }

        /// Runtime teardown: return the request storage. Touches no
        /// platform service — the host may already be shutting down.
        pub fn releaseDialogs(self: *Runtime) void {
            for (&self.dialog_broker.entries) |*entry| {
                if (entry.state != .free) release(entry);
            }
        }

        pub fn pendingDialogCount(self: *const Runtime) usize {
            var count: usize = 0;
            for (self.dialog_broker.entries) |entry| {
                if (entry.state != .free) count += 1;
            }
            return count;
        }

        fn admitOptions(self: *Runtime, options: platform.DialogOptions) !void {
            const buffer = &self.dialog_broker.result_buffer;
            switch (options) {
                .open => |open| try admission.open(self.system_admission_policy, open, buffer),
                .save => |save| try admission.save(self.system_admission_policy, save, buffer[0..platform.max_dialog_path_bytes]),
                .message => |message| try admission.message(self.system_admission_policy, message),
            }
        }

        fn canPresent(services: platform.PlatformServices, options: platform.DialogOptions) bool {
            if (services.supportsAsyncDialogs()) return true;
            return switch (options) {
                .open => services.show_open_dialog_fn != null,
                .save => services.show_save_dialog_fn != null,
                .message => services.show_message_dialog_fn != null,
            };
        }

        fn resolveParent(self: *Runtime, request: DialogRequestOptions) !?platform.WindowId {
            if (request.detached) return null;
            const windows = self.windows[0..self.window_count];
            if (request.parent_window_id) |window_id| {
                for (windows) |window| {
                    if (window.info.id == window_id and window.info.open) return window_id;
                }
                return error.WindowNotFound;
            }
            for (windows) |window| {
                if (window.info.open and !window.info.hidden and window.info.focused) return window.info.id;
            }
            for (windows) |window| {
                if (window.info.open and !window.info.hidden) return window.info.id;
            }
            return null;
        }

        /// Present the oldest queued request for `parent` unless a dialog
        /// already shows for it.
        fn presentNext(self: *Runtime, parent: ?platform.WindowId) void {
            const broker = &self.dialog_broker;
            var next: ?*DialogEntry = null;
            for (&broker.entries) |*entry| {
                if (!sameParent(entry.parent, parent)) continue;
                if (entry.state == .presented) return;
                if (entry.state != .queued) continue;
                if (next == null or entry.order < next.?.order) next = entry;
            }
            const entry = next orelse return;
            const services = self.options.platform.services;
            entry.state = .presented;
            if (services.supportsAsyncDialogs()) {
                services.requestDialog(.{ .id = entry.id, .parent_window_id = entry.parent, .options = entry.options }) catch {
                    finish(entry, .{ .id = entry.id, .outcome = .failed }) catch finishFailed(entry);
                    requestWake(self);
                };
                return;
            }
            // Platforms without asynchronous dialogs block here, as the
            // synchronous API always has; the result still arrives through
            // a wake so completions keep one delivery path.
            finish(entry, presentBlocking(services, entry, &broker.result_buffer)) catch finishFailed(entry);
            requestWake(self);
        }

        fn presentBlocking(services: platform.PlatformServices, entry: *DialogEntry, buffer: []u8) platform.DialogResult {
            const id = entry.id;
            switch (entry.options) {
                .open => |open| {
                    const result = services.showOpenDialog(open, buffer) catch return .{ .id = id, .outcome = .failed };
                    if (result.count == 0) return .{ .id = id, .outcome = .cancelled };
                    return .{ .id = id, .outcome = .selected, .paths = result.paths, .count = result.count };
                },
                .save => |save| {
                    const path = services.showSaveDialog(save, buffer[0..platform.max_dialog_path_bytes]) catch return .{ .id = id, .outcome = .failed };
                    const chosen = path orelse return .{ .id = id, .outcome = .cancelled };
                    return .{ .id = id, .outcome = .selected, .paths = chosen, .count = 1 };
                },
                .message => |message| {
                    const button = services.showMessageDialog(message) catch |err| return .{
                        .id = id,
                        .outcome = if (err == error.SessionEnding) .cancelled else .failed,
                    };
                    return .{ .id = id, .outcome = .selected, .button = button };
                },
            }
        }

        fn deliver(self: *Runtime, entry: *DialogEntry) void {
            const completion = entry.completion;
            const parent = entry.parent;
            entry.state = .delivering;
            completion.on_result(completion.context, self, entry.tag_storage[0..entry.tag_len], entry.result) catch |err| {
                self.recordDispatchError("dialog.result", err);
            };
            release(entry);
            presentNext(self, parent);
        }

        fn requestWake(self: *Runtime) void {
            self.options.platform.services.wake() catch {};
        }

        fn sameParent(a: ?platform.WindowId, b: ?platform.WindowId) bool {
            if (a) |left| return if (b) |right| left == right else false;
            return b == null;
        }

        fn freeEntry(broker: *Broker(Runtime)) ?*DialogEntry {
            for (&broker.entries) |*entry| {
                if (entry.state == .free) return entry;
            }
            return null;
        }

        fn findEntry(broker: *Broker(Runtime), id: platform.DialogRequestId) ?*DialogEntry {
            for (&broker.entries) |*entry| {
                if (entry.state != .free and entry.id == id) return entry;
            }
            return null;
        }

        fn oldestFinished(broker: *Broker(Runtime)) ?*DialogEntry {
            var oldest: ?*DialogEntry = null;
            for (&broker.entries) |*entry| {
                if (entry.state != .finished) continue;
                if (oldest == null or entry.order < oldest.?.order) oldest = entry;
            }
            return oldest;
        }

        /// Keep `result` with the entry, its paths copied out of whatever
        /// buffer they borrow: a completion may start another dialog that
        /// reuses that buffer.
        fn finish(entry: *DialogEntry, result: platform.DialogResult) !void {
            var kept = result;
            kept.id = entry.id;
            kept.paths = try entry.arena.allocator().dupe(u8, result.paths);
            entry.result = kept;
            entry.state = .finished;
        }

        /// Out of memory while keeping a result: report the dialog as
        /// failed rather than lose its completion.
        fn finishFailed(entry: *DialogEntry) void {
            entry.result = .{ .id = entry.id, .outcome = .failed };
            entry.state = .finished;
        }

        fn release(entry: *DialogEntry) void {
            entry.arena.deinit();
            entry.* = .{};
        }
    };
}

fn copyOptions(allocator: std.mem.Allocator, options: platform.DialogOptions) !platform.DialogOptions {
    return switch (options) {
        .open => |open| .{ .open = .{
            .title = try allocator.dupe(u8, open.title),
            .default_path = try allocator.dupe(u8, open.default_path),
            .filters = try copyFilters(allocator, open.filters),
            .allow_directories = open.allow_directories,
            .allow_multiple = open.allow_multiple,
        } },
        .save => |save| .{ .save = .{
            .title = try allocator.dupe(u8, save.title),
            .default_path = try allocator.dupe(u8, save.default_path),
            .default_name = try allocator.dupe(u8, save.default_name),
            .filters = try copyFilters(allocator, save.filters),
        } },
        .message => |message| .{ .message = .{
            .style = message.style,
            .title = try allocator.dupe(u8, message.title),
            .message = try allocator.dupe(u8, message.message),
            .informative_text = try allocator.dupe(u8, message.informative_text),
            .primary_button = try allocator.dupe(u8, message.primary_button),
            .secondary_button = try allocator.dupe(u8, message.secondary_button),
            .tertiary_button = try allocator.dupe(u8, message.tertiary_button),
        } },
    };
}

fn copyFilters(allocator: std.mem.Allocator, filters: []const platform.FileFilter) ![]const platform.FileFilter {
    const copied = try allocator.alloc(platform.FileFilter, filters.len);
    for (filters, copied) |filter, *out| {
        const extensions = try allocator.alloc([]const u8, filter.extensions.len);
        for (filter.extensions, extensions) |extension, *slot| slot.* = try allocator.dupe(u8, extension);
        out.* = .{ .name = try allocator.dupe(u8, filter.name), .extensions = extensions };
    }
    return copied;
}
