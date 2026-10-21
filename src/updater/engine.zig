//! The app-driven updater: one process-wide engine an app drives through
//! host requests and observes through a channel source.
//!
//!   native-sdk.updates.status    the current status
//!   native-sdk.updates.check     start a check
//!   native-sdk.updates.download  download, verify and stage the available release
//!   native-sdk.updates.cancel    stop a download
//!   native-sdk.updates.discard   drop a staged release
//!   native-sdk.updates.restart   quit and start the staged release
//!   native-sdk.updates.notes     the known release's notes, as plain text
//!
//! Every request takes an empty payload and answers at once: `ok`, or
//! `err` with a reason (`unsupported`, `busy`, `not_available`,
//! `not_ready`, `not_downloading`, `invalid_request`, `restart_failed`).
//! `status` and `notes` answer with their text; the other requests only
//! say they were accepted. Work runs on a background thread, and every
//! state change, plus download progress, is posted to the
//! `native-sdk.updates` channel as a status record, in order: the channel
//! is the one place the app learns the status from as it changes.
//!
//! A status record is UTF-8 lines of `name value`, in this order:
//!
//!   state <unsupported|idle|checking|up_to_date|available|downloading|ready|error>
//!   installed <version>
//!   version <release version>        while a release is known
//!   size <archive bytes>             while a release is known, once a check named it
//!   received <bytes>                 while downloading
//!   percent <0-100>                  while downloading
//!   reason <code>                    state unsupported: not_configured, platform,
//!                                    not_installed, read_only
//!   error <code>                     state error: network, http_status, feed_invalid,
//!                                    signature_invalid, wrong_app, wrong_target,
//!                                    archive_size, archive_digest, archive_invalid, disk
//!   last updated <from> <to>         in the launch that applied a staged release
//!
//! A record fits one channel post (`max_status_bytes`); release notes,
//! up to 16 KiB, come from the `notes` request instead.
//!
//! The engine never installs on its own and never quits the app: the app
//! asks for `restart`, or the staged release applies at the next launch.
//! A staged release stays `ready` until then; `check` while ready does
//! nothing, and `discard` drops the release to look again. Platform work
//! (fetching, staging, the restart helper) belongs to a `Backend`.

const std = @import("std");
const feed = @import("feed.zig");

pub const request_prefix = "native-sdk.updates.";
pub const channel_source = "native-sdk.updates";
/// The longest status record: every line at its longest is under 512
/// bytes.
pub const max_status_bytes: usize = 1024;
/// The longest answer to a request: a status record or the notes.
pub const max_response_bytes: usize = @max(max_status_bytes, feed.max_release_notes_bytes);
const max_version_bytes: usize = 64;
const max_sinks: usize = 4;
const progress_post_min_bytes: u64 = 64 * 1024;

pub const State = enum { unsupported, idle, checking, up_to_date, available, downloading, ready, failed };

pub const Unsupported = enum { not_configured, platform, not_installed, read_only };

pub const Failure = enum {
    network,
    http_status,
    feed_invalid,
    signature_invalid,
    wrong_app,
    wrong_target,
    archive_size,
    archive_digest,
    archive_invalid,
    disk,
};

pub const FetchError = error{ Network, HttpStatus, TooLarge };
pub const StageError = error{ Network, HttpStatus, Cancelled, ArchiveSize, ArchiveDigest, ArchiveInvalid, Disk };

/// The release a check found, owned by the engine.
pub const Release = struct {
    version_buffer: [max_version_bytes]u8 = undefined,
    version_len: usize = 0,
    url_buffer: [feed.max_archive_url_bytes]u8 = undefined,
    url_len: usize = 0,
    notes_buffer: [feed.max_release_notes_bytes]u8 = undefined,
    notes_len: usize = 0,
    archive_bytes: u64 = 0,
    sha256: [64]u8 = undefined,

    pub fn version(self: *const Release) []const u8 {
        return self.version_buffer[0..self.version_len];
    }
    pub fn url(self: *const Release) []const u8 {
        return self.url_buffer[0..self.url_len];
    }
    pub fn notes(self: *const Release) []const u8 {
        return self.notes_buffer[0..self.notes_len];
    }

    fn set(self: *Release, release: feed.Release) void {
        self.version_len = copyInto(&self.version_buffer, release.version);
        self.url_len = copyInto(&self.url_buffer, release.archive_url);
        self.notes_len = copyInto(&self.notes_buffer, release.release_notes);
        self.archive_bytes = release.archive_bytes;
        @memcpy(&self.sha256, release.sha256[0..64]);
    }
};

/// Download progress a backend reports while staging, and the cancel
/// request it honors between reads.
pub const Progress = struct {
    cancel_requested: std.atomic.Value(bool) = .init(false),

    pub fn report(self: *Progress, received: u64) void {
        _ = self;
        reportProgress(received);
    }

    pub fn cancelled(self: *Progress) bool {
        return self.cancel_requested.load(.acquire);
    }
};

/// The platform half of the updater.
pub const Backend = struct {
    context: *anyopaque,
    /// Why this installation cannot update itself, or null when it can.
    eligibility: *const fn (context: *anyopaque) ?Unsupported,
    /// The version staged for the next launch, if a complete one is.
    staged_version: *const fn (context: *anyopaque, output: []u8) ?[]const u8,
    /// The previous launch's switch, `<from> <to>`, reported once.
    take_last_update: *const fn (context: *anyopaque, output: []u8) ?[]const u8,
    /// GET `url` into `output`.
    fetch: *const fn (context: *anyopaque, url: []const u8, policy: feed.UrlPolicy, output: []u8) FetchError![]const u8,
    /// Download the release's archive, check its size and SHA-256,
    /// unpack and validate it, and stage it for the next launch.
    stage: *const fn (context: *anyopaque, release: *const Release, policy: feed.UrlPolicy, progress: *Progress) StageError!void,
    discard: *const fn (context: *anyopaque) void,
    /// Starts the helper that installs the staged release once this
    /// process exits, then starts it.
    prepare_restart: *const fn (context: *anyopaque) bool,
};

/// Where status records go: the open `native-sdk.updates` channels.
pub const Sink = struct {
    context: *anyopaque,
    post: *const fn (context: *anyopaque, bytes: []const u8) Posted,
};

pub const Posted = enum {
    delivered,
    /// The channel holds too many undelivered posts; this one was dropped.
    dropped,
    /// The channel is closed for good.
    closed,
};

pub const Config = struct {
    /// The manifest feed URL, before expansion; empty when updates are
    /// not configured.
    feed_url: []const u8 = "",
    /// Trusted keys, comma-joined.
    public_keys: []const u8 = "",
    bundle_id: []const u8 = "",
    version: []const u8 = "",
    target: ?[]const u8 = null,
    policy: feed.UrlPolicy = .{},
    backend: ?Backend = null,
    /// Start a check right away (the manifest's `check_on_start`); the
    /// app learns its result like any other check's.
    check_on_start: bool = false,
};

pub const Response = struct {
    ok: bool,
    bytes: []const u8,
    /// The app should quit now so the restart helper can install.
    quit: bool = false,
};

const Engine = struct {
    mutex: SpinMutex = .{},
    state: State = .unsupported,
    unsupported: Unsupported = .not_configured,
    failure: Failure = .network,
    feed_url_buffer: [feed.max_feed_url_bytes]u8 = undefined,
    feed_url_len: usize = 0,
    keys_buffer: [256]u8 = undefined,
    keys_len: usize = 0,
    bundle_buffer: [128]u8 = undefined,
    bundle_len: usize = 0,
    installed_buffer: [max_version_bytes]u8 = undefined,
    installed_len: usize = 0,
    target_buffer: [32]u8 = undefined,
    target_len: usize = 0,
    policy: feed.UrlPolicy = .{},
    backend: ?Backend = null,
    release: Release = .{},
    has_release: bool = false,
    received: u64 = 0,
    last_update_buffer: [2 * max_version_bytes + 1]u8 = undefined,
    last_update_len: usize = 0,
    restart_prepared: bool = false,
    sinks: [max_sinks]?Sink = .{null} ** max_sinks,
    worker: ?std.Thread = null,
    progress: Progress = .{},
    last_progress_post_bytes: u64 = 0,
};

var engine: Engine = .{};

/// Configures the process's updater. Called once at startup, before the
/// app can send requests.
pub fn configure(config: Config) void {
    configureState(config);
    if (config.check_on_start) {
        var output: [max_status_bytes]u8 = undefined;
        _ = handleRequest(request_prefix ++ "check", "", &output);
    }
}

fn configureState(config: Config) void {
    join();
    engine.mutex.lock();
    defer engine.mutex.unlock();
    engine = .{ .mutex = engine.mutex };
    engine.installed_len = copyInto(&engine.installed_buffer, config.version);
    engine.bundle_len = copyInto(&engine.bundle_buffer, config.bundle_id);
    engine.policy = config.policy;
    engine.backend = config.backend;
    if (config.feed_url.len == 0 or config.public_keys.len == 0) {
        engine.unsupported = .not_configured;
        return;
    }
    const backend = config.backend orelse {
        engine.unsupported = .platform;
        return;
    };
    const target = config.target orelse {
        engine.unsupported = .platform;
        return;
    };
    const expanded = feed.expandFeedUrlWithPolicy(&engine.feed_url_buffer, config.feed_url, target, config.version, config.policy) catch {
        engine.unsupported = .not_configured;
        return;
    };
    engine.feed_url_len = expanded.len;
    if (config.public_keys.len > engine.keys_buffer.len) {
        engine.unsupported = .not_configured;
        return;
    }
    engine.keys_len = copyInto(&engine.keys_buffer, config.public_keys);
    engine.target_len = copyInto(&engine.target_buffer, target);
    if (backend.take_last_update(backend.context, &engine.last_update_buffer)) |last| engine.last_update_len = last.len;
    if (backend.eligibility(backend.context)) |reason| {
        engine.unsupported = reason;
        return;
    }
    var staged_buffer: [max_version_bytes]u8 = undefined;
    if (backend.staged_version(backend.context, &staged_buffer)) |staged| {
        engine.release = .{};
        engine.release.version_len = copyInto(&engine.release.version_buffer, staged);
        engine.has_release = true;
        engine.state = .ready;
    } else {
        engine.state = .idle;
    }
}

/// Answers one `native-sdk.updates.*` request. `output` receives the
/// status or the notes; the other requests answer an empty `ok`, and the
/// changes they make reach the app through the channel.
pub fn handleRequest(name: []const u8, payload: []const u8, output: []u8) Response {
    if (!std.mem.startsWith(u8, name, request_prefix)) return .{ .ok = false, .bytes = "invalid_request" };
    const verb = name[request_prefix.len..];
    if (payload.len != 0) return .{ .ok = false, .bytes = "invalid_request" };
    engine.mutex.lock();
    if (std.mem.eql(u8, verb, "status")) {
        defer engine.mutex.unlock();
        return .{ .ok = true, .bytes = renderLocked(output) };
    }
    if (engine.state == .unsupported) {
        engine.mutex.unlock();
        return .{ .ok = false, .bytes = "unsupported" };
    }
    if (std.mem.eql(u8, verb, "check")) {
        if (engine.state == .checking or engine.state == .downloading) {
            engine.mutex.unlock();
            return .{ .ok = false, .bytes = "busy" };
        }
        if (engine.state == .ready) {
            engine.mutex.unlock();
            return .{ .ok = true, .bytes = "" };
        }
        return startWorker(checkMain, .checking);
    }
    if (std.mem.eql(u8, verb, "download")) {
        if (engine.state == .checking or engine.state == .downloading) {
            engine.mutex.unlock();
            return .{ .ok = false, .bytes = "busy" };
        }
        // A failed check forgets its release, so a failure that still has
        // one is a download to retry.
        if (engine.state != .available and !(engine.state == .failed and engine.has_release)) {
            engine.mutex.unlock();
            return .{ .ok = false, .bytes = "not_available" };
        }
        engine.received = 0;
        engine.last_progress_post_bytes = 0;
        engine.progress = .{};
        return startWorker(downloadMain, .downloading);
    }
    if (std.mem.eql(u8, verb, "cancel")) {
        defer engine.mutex.unlock();
        if (engine.state != .downloading) return .{ .ok = false, .bytes = "not_downloading" };
        engine.progress.cancel_requested.store(true, .release);
        return .{ .ok = true, .bytes = "" };
    }
    if (std.mem.eql(u8, verb, "notes")) {
        defer engine.mutex.unlock();
        if (!engine.has_release) return .{ .ok = false, .bytes = "not_available" };
        return .{ .ok = true, .bytes = output[0..copyInto(output, engine.release.notes())] };
    }
    // Requests arrive one at a time on the app's loop and no worker runs
    // while a release is ready, so the backend's file and process work
    // below runs outside the lock.
    if (std.mem.eql(u8, verb, "discard")) {
        if (engine.state != .ready) {
            engine.mutex.unlock();
            return .{ .ok = false, .bytes = "not_ready" };
        }
        const backend = engine.backend.?;
        engine.has_release = false;
        engine.state = .idle;
        engine.mutex.unlock();
        backend.discard(backend.context);
        postStatus();
        return .{ .ok = true, .bytes = "" };
    }
    if (std.mem.eql(u8, verb, "restart")) {
        if (engine.state != .ready) {
            engine.mutex.unlock();
            return .{ .ok = false, .bytes = "not_ready" };
        }
        const backend = engine.backend.?;
        // One helper per process: a repeated restart only asks to quit.
        const prepared = engine.restart_prepared;
        engine.mutex.unlock();
        if (!prepared) {
            if (!backend.prepare_restart(backend.context)) return .{ .ok = false, .bytes = "restart_failed" };
            engine.mutex.lock();
            engine.restart_prepared = true;
            engine.mutex.unlock();
        }
        return .{ .ok = true, .bytes = "", .quit = true };
    }
    engine.mutex.unlock();
    return .{ .ok = false, .bytes = "invalid_request" };
}

/// Adds an open `native-sdk.updates` channel and posts the current status
/// to it.
pub fn attach(sink: Sink) error{TooManyChannels}!void {
    post_order.lock();
    defer post_order.unlock();
    var status_buffer: [max_status_bytes]u8 = undefined;
    engine.mutex.lock();
    const slot = for (&engine.sinks) |*slot| {
        if (slot.* == null) break slot;
    } else {
        engine.mutex.unlock();
        return error.TooManyChannels;
    };
    slot.* = sink;
    const status = renderLocked(&status_buffer);
    engine.mutex.unlock();
    if (sink.post(sink.context, status) == .closed) detach(sink);
}

/// Waits for background work to finish (shutdown and tests).
pub fn join() void {
    engine.mutex.lock();
    const worker = engine.worker;
    engine.worker = null;
    engine.mutex.unlock();
    if (worker) |thread| thread.join();
}

/// Called with the mutex held; releases it.
fn startWorker(comptime main: fn () void, state: State) Response {
    const previous = engine.worker;
    engine.worker = null;
    const restore = engine.state;
    engine.state = state;
    engine.mutex.unlock();
    if (previous) |thread| thread.join();
    postStatus();
    const thread = std.Thread.spawn(.{}, main, .{}) catch {
        engine.mutex.lock();
        engine.state = restore;
        engine.mutex.unlock();
        postStatus();
        return .{ .ok = false, .bytes = "busy" };
    };
    engine.mutex.lock();
    engine.worker = thread;
    engine.mutex.unlock();
    return .{ .ok = true, .bytes = "" };
}

fn checkMain() void {
    var url_buffer: [feed.max_feed_url_bytes]u8 = undefined;
    var keys_buffer: [256]u8 = undefined;
    var bundle_buffer: [128]u8 = undefined;
    var installed_buffer: [max_version_bytes]u8 = undefined;
    var target_buffer: [32]u8 = undefined;
    engine.mutex.lock();
    const backend = engine.backend.?;
    const policy = engine.policy;
    const url = url_buffer[0..copyInto(&url_buffer, engine.feed_url_buffer[0..engine.feed_url_len])];
    const keys = keys_buffer[0..copyInto(&keys_buffer, engine.keys_buffer[0..engine.keys_len])];
    const bundle_id = bundle_buffer[0..copyInto(&bundle_buffer, engine.bundle_buffer[0..engine.bundle_len])];
    const installed = installed_buffer[0..copyInto(&installed_buffer, engine.installed_buffer[0..engine.installed_len])];
    const target = target_buffer[0..copyInto(&target_buffer, engine.target_buffer[0..engine.target_len])];
    engine.mutex.unlock();

    var feed_buffer: [feed.max_envelope_bytes]u8 = undefined;
    const outcome: union(enum) { failed: Failure, up_to_date, available: feed.Release } = outcome: {
        const envelope = backend.fetch(backend.context, url, policy, &feed_buffer) catch |err| break :outcome .{ .failed = switch (err) {
            error.HttpStatus => .http_status,
            error.TooLarge => .feed_invalid,
            error.Network => .network,
        } };
        var verified = feed.verifyEnvelopeWithPolicy(std.heap.page_allocator, envelope, keys, policy) catch |err| break :outcome .{ .failed = switch (err) {
            error.InvalidUpdateSignature, error.InvalidUpdateKey => .signature_invalid,
            else => .feed_invalid,
        } };
        defer verified.deinit(std.heap.page_allocator);
        const applies = feed.releaseApplies(verified.release, bundle_id, installed, target) catch |err| break :outcome .{ .failed = switch (err) {
            error.UpdateBundleMismatch => .wrong_app,
            error.UpdateTargetMismatch => .wrong_target,
            else => .feed_invalid,
        } };
        if (!applies) break :outcome .up_to_date;
        engine.mutex.lock();
        engine.release.set(verified.release);
        engine.mutex.unlock();
        break :outcome .{ .available = verified.release };
    };

    engine.mutex.lock();
    switch (outcome) {
        .failed => |failure| {
            engine.state = .failed;
            engine.failure = failure;
            engine.has_release = false;
        },
        .up_to_date => {
            engine.state = .up_to_date;
            engine.has_release = false;
        },
        .available => {
            engine.state = .available;
            engine.has_release = true;
        },
    }
    engine.mutex.unlock();
    postFinalStatus();
}

fn downloadMain() void {
    engine.mutex.lock();
    const backend = engine.backend.?;
    const policy = engine.policy;
    const release = engine.release;
    engine.mutex.unlock();

    const result = backend.stage(backend.context, &release, policy, &engine.progress);
    engine.mutex.lock();
    if (result) |_| {
        engine.state = .ready;
    } else |err| switch (err) {
        error.Cancelled => engine.state = .available,
        else => {
            engine.state = .failed;
            engine.failure = switch (err) {
                error.Network => .network,
                error.HttpStatus => .http_status,
                error.ArchiveSize => .archive_size,
                error.ArchiveDigest => .archive_digest,
                error.ArchiveInvalid => .archive_invalid,
                error.Disk => .disk,
                error.Cancelled => unreachable,
            };
        },
    }
    engine.mutex.unlock();
    postFinalStatus();
}

/// Posts progress about every 1% of the archive (at least 64 KiB apart)
/// and once at the end.
fn reportProgress(received: u64) void {
    engine.mutex.lock();
    engine.received = received;
    const step = @max(engine.release.archive_bytes / 100, progress_post_min_bytes);
    const due = received -| engine.last_progress_post_bytes >= step or received == engine.release.archive_bytes;
    if (due) engine.last_progress_post_bytes = received;
    engine.mutex.unlock();
    if (due) postStatus();
}

/// Serializes rendering and posting, so channels receive records in the
/// order their states happened and the last record is the current state.
var post_order: SpinMutex = .{};

fn postStatus() void {
    _ = postStatusTo(@splat(true));
}

/// Posts the current status to the sinks `targets` selects and answers
/// which of them dropped it.
fn postStatusTo(targets: [max_sinks]bool) [max_sinks]bool {
    post_order.lock();
    defer post_order.unlock();
    var status_buffer: [max_status_bytes]u8 = undefined;
    var sinks: [max_sinks]?Sink = undefined;
    engine.mutex.lock();
    const status = renderLocked(&status_buffer);
    sinks = engine.sinks;
    engine.mutex.unlock();
    var dropped: [max_sinks]bool = @splat(false);
    for (sinks, targets, &dropped) |maybe_sink, target, *drop| {
        if (!target) continue;
        const sink = maybe_sink orelse continue;
        switch (sink.post(sink.context, status)) {
            .delivered => {},
            .dropped => drop.* = true,
            .closed => detach(sink),
        }
    }
    return dropped;
}

/// Posts the state a worker ends in. Nothing follows that record, so a
/// channel too full to take it gets it again, for about a second.
fn postFinalStatus() void {
    var dropped = postStatusTo(@splat(true));
    if (std.mem.indexOfScalar(bool, &dropped, true) == null) return;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var attempts: usize = 0;
    while (attempts < 50 and std.mem.indexOfScalar(bool, &dropped, true) != null) : (attempts += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch return;
        dropped = postStatusTo(dropped);
    }
}

fn detach(sink: Sink) void {
    engine.mutex.lock();
    defer engine.mutex.unlock();
    for (&engine.sinks) |*slot| {
        if (slot.*) |existing| {
            if (existing.context == sink.context and existing.post == sink.post) slot.* = null;
        }
    }
}

/// Renders the status record. Called with the mutex held.
fn renderLocked(output: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(output);
    renderTo(&writer) catch return output[0..writer.end];
    return writer.buffered();
}

fn renderTo(writer: *std.Io.Writer) !void {
    try writer.print("state {s}\n", .{stateName(engine.state)});
    try writer.print("installed {s}\n", .{engine.installed_buffer[0..engine.installed_len]});
    if (engine.has_release) {
        try writer.print("version {s}\n", .{engine.release.version()});
        if (engine.release.archive_bytes > 0) try writer.print("size {d}\n", .{engine.release.archive_bytes});
    }
    if (engine.state == .downloading) {
        try writer.print("received {d}\n", .{engine.received});
        const total = engine.release.archive_bytes;
        try writer.print("percent {d}\n", .{if (total == 0) 0 else @min(100, engine.received * 100 / total)});
    }
    if (engine.state == .unsupported) try writer.print("reason {s}\n", .{@tagName(engine.unsupported)});
    if (engine.state == .failed) try writer.print("error {s}\n", .{@tagName(engine.failure)});
    if (engine.last_update_len > 0) try writer.print("last updated {s}\n", .{engine.last_update_buffer[0..engine.last_update_len]});
}

fn stateName(state: State) []const u8 {
    return switch (state) {
        .failed => "error",
        else => @tagName(state),
    };
}

fn copyInto(buffer: []u8, value: []const u8) usize {
    const length = @min(buffer.len, value.len);
    @memcpy(buffer[0..length], value[0..length]);
    return length;
}

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

// ---------------------------------------------------------------------------
// Tests

const Ed25519 = std.crypto.sign.Ed25519;

const FakeBackend = struct {
    eligibility_reason: ?Unsupported = null,
    staged: ?[]const u8 = null,
    last_update: ?[]const u8 = null,
    envelope: []const u8 = "",
    fetch_error: ?FetchError = null,
    stage_error: ?StageError = null,
    stage_calls: usize = 0,
    discarded: bool = false,
    restart_calls: usize = 0,
    wait_for_cancel: bool = false,

    fn backend(self: *FakeBackend) Backend {
        return .{
            .context = self,
            .eligibility = eligibility,
            .staged_version = stagedVersion,
            .take_last_update = takeLastUpdate,
            .fetch = fetch,
            .stage = stage,
            .discard = discard,
            .prepare_restart = prepareRestart,
        };
    }
    fn get(context: *anyopaque) *FakeBackend {
        return @ptrCast(@alignCast(context));
    }
    fn eligibility(context: *anyopaque) ?Unsupported {
        return get(context).eligibility_reason;
    }
    fn stagedVersion(context: *anyopaque, output: []u8) ?[]const u8 {
        const staged = get(context).staged orelse return null;
        return output[0..copyInto(output, staged)];
    }
    fn takeLastUpdate(context: *anyopaque, output: []u8) ?[]const u8 {
        const last = get(context).last_update orelse return null;
        return output[0..copyInto(output, last)];
    }
    fn fetch(context: *anyopaque, url: []const u8, policy: feed.UrlPolicy, output: []u8) FetchError![]const u8 {
        _ = url;
        _ = policy;
        const self = get(context);
        if (self.fetch_error) |err| return err;
        return output[0..copyInto(output, self.envelope)];
    }
    fn stage(context: *anyopaque, release: *const Release, policy: feed.UrlPolicy, progress: *Progress) StageError!void {
        _ = policy;
        const self = get(context);
        self.stage_calls += 1;
        progress.report(release.archive_bytes / 2);
        if (self.wait_for_cancel) {
            while (!progress.cancelled()) std.atomic.spinLoopHint();
            return error.Cancelled;
        }
        if (self.stage_error) |err| return err;
        progress.report(release.archive_bytes);
    }
    fn discard(context: *anyopaque) void {
        get(context).discarded = true;
    }
    fn prepareRestart(context: *anyopaque) bool {
        get(context).restart_calls += 1;
        return true;
    }
};

const RecordingSink = struct {
    last: [max_status_bytes]u8 = undefined,
    last_len: usize = 0,
    /// Each record's state, in posting order.
    log: [512]u8 = undefined,
    log_len: usize = 0,
    /// Posts to refuse as a full channel would.
    drop_next: usize = 0,
    mutex: SpinMutex = .{},

    fn sink(self: *RecordingSink) Sink {
        return .{ .context = self, .post = post };
    }
    fn post(context: *anyopaque, bytes: []const u8) Posted {
        const self: *RecordingSink = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.drop_next > 0) {
            self.drop_next -= 1;
            return .dropped;
        }
        self.last_len = copyInto(&self.last, bytes);
        const state = bytes["state ".len .. std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len];
        self.log_len += copyInto(self.log[self.log_len..], state);
        self.log_len += copyInto(self.log[self.log_len..], " ");
        return .delivered;
    }
    fn status(self: *RecordingSink) []const u8 {
        return self.last[0..self.last_len];
    }
    fn states(self: *RecordingSink) []const u8 {
        return self.log[0..self.log_len];
    }
};

fn signedFeed(allocator: std.mem.Allocator, key_pair: Ed25519.KeyPair, payload: []const u8) ![]u8 {
    const signature = try key_pair.sign(payload, null);
    const payload_base64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(payload.len));
    defer allocator.free(payload_base64);
    var signature_base64: [std.base64.standard.Encoder.calcSize(Ed25519.Signature.encoded_length)]u8 = undefined;
    return std.fmt.allocPrint(allocator, "{{\"payload\":\"{s}\",\"signature\":\"{s}\"}}", .{
        std.base64.standard.Encoder.encode(payload_base64, payload),
        std.base64.standard.Encoder.encode(&signature_base64, &signature.toBytes()),
    });
}

const test_release =
    \\{"bundle_id":"dev.example.notes","version":"1.1.0","target":"windows-x86_64","archive_url":"https://example.com/notes-1.1.0.zip","archive_bytes":1000,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","release_notes":"Faster sync.\nNew icons."}
;

fn testConfig(fake: *FakeBackend, public_key: []const u8) Config {
    return .{
        .feed_url = "https://example.com/{target}/native-update.json",
        .public_keys = public_key,
        .bundle_id = "dev.example.notes",
        .version = "1.0.0",
        .target = "windows-x86_64",
        .backend = fake.backend(),
    };
}

test "a check finds a release, a download stages it and a restart asks the app to quit" {
    const allocator = std.testing.allocator;
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x61} ** Ed25519.KeyPair.seed_length);
    var key_buffer: [44]u8 = undefined;
    const public_key = std.base64.standard.Encoder.encode(&key_buffer, &key_pair.public_key.toBytes());
    const envelope = try signedFeed(allocator, key_pair, test_release);
    defer allocator.free(envelope);
    var fake: FakeBackend = .{ .envelope = envelope };
    configure(testConfig(&fake, public_key));
    var sink: RecordingSink = .{};
    try attach(sink.sink());
    try std.testing.expect(std.mem.startsWith(u8, sink.status(), "state idle\ninstalled 1.0.0\n"));

    var output: [max_status_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("not_available", handleRequest("native-sdk.updates.download", "", &output).bytes);
    // Requests that start work only say they were accepted; the channel
    // carries what happens.
    const check = handleRequest("native-sdk.updates.check", "", &output);
    try std.testing.expect(check.ok and check.bytes.len == 0);
    join();
    try std.testing.expectEqualStrings("state available\ninstalled 1.0.0\nversion 1.1.0\nsize 1000\n", sink.status());
    try std.testing.expectEqualStrings("Faster sync.\nNew icons.", handleRequest("native-sdk.updates.notes", "", &output).bytes);

    try std.testing.expect(handleRequest("native-sdk.updates.download", "", &output).ok);
    join();
    try std.testing.expectEqual(@as(usize, 1), fake.stage_calls);
    try std.testing.expectEqualStrings("state ready\ninstalled 1.0.0\nversion 1.1.0\nsize 1000\n", sink.status());
    try std.testing.expectEqualStrings("idle checking available downloading downloading ready ", sink.states());

    const restart = handleRequest("native-sdk.updates.restart", "", &output);
    try std.testing.expect(restart.ok and restart.quit);
    const again = handleRequest("native-sdk.updates.restart", "", &output);
    try std.testing.expect(again.ok and again.quit);
    try std.testing.expectEqual(@as(usize, 1), fake.restart_calls);
}

test "the state a check ends in reaches a channel that was too full to take it" {
    const allocator = std.testing.allocator;
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x65} ** Ed25519.KeyPair.seed_length);
    var key_buffer: [44]u8 = undefined;
    const public_key = std.base64.standard.Encoder.encode(&key_buffer, &key_pair.public_key.toBytes());
    const envelope = try signedFeed(allocator, key_pair, test_release);
    defer allocator.free(envelope);
    var fake: FakeBackend = .{ .envelope = envelope };
    configure(testConfig(&fake, public_key));
    var sink: RecordingSink = .{};
    try attach(sink.sink());
    // `checking` and the first post of `available` are refused.
    sink.drop_next = 2;
    var output: [max_status_bytes]u8 = undefined;
    try std.testing.expect(handleRequest("native-sdk.updates.check", "", &output).ok);
    join();
    try std.testing.expectEqualStrings("idle available ", sink.states());
}

test "an installed version reports no update and failures name their cause" {
    const allocator = std.testing.allocator;
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x62} ** Ed25519.KeyPair.seed_length);
    const other = try Ed25519.KeyPair.generateDeterministic([_]u8{0x63} ** Ed25519.KeyPair.seed_length);
    var key_buffer: [44]u8 = undefined;
    const public_key = std.base64.standard.Encoder.encode(&key_buffer, &key_pair.public_key.toBytes());
    var output: [max_status_bytes]u8 = undefined;

    const forged = try signedFeed(allocator, other, test_release);
    defer allocator.free(forged);
    var fake: FakeBackend = .{ .envelope = forged };
    configure(testConfig(&fake, public_key));
    _ = handleRequest("native-sdk.updates.check", "", &output);
    join();
    try std.testing.expect(std.mem.indexOf(u8, handleRequest("native-sdk.updates.status", "", &output).bytes, "state error\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, handleRequest("native-sdk.updates.status", "", &output).bytes, "error signature_invalid\n") != null);

    const same = try signedFeed(allocator, key_pair, test_release);
    defer allocator.free(same);
    fake = .{ .envelope = same };
    var config = testConfig(&fake, public_key);
    config.version = "1.1.0";
    configure(config);
    _ = handleRequest("native-sdk.updates.check", "", &output);
    join();
    try std.testing.expect(std.mem.startsWith(u8, handleRequest("native-sdk.updates.status", "", &output).bytes, "state up_to_date\n"));

    fake = .{ .fetch_error = error.HttpStatus };
    configure(testConfig(&fake, public_key));
    _ = handleRequest("native-sdk.updates.check", "", &output);
    join();
    try std.testing.expect(std.mem.indexOf(u8, handleRequest("native-sdk.updates.status", "", &output).bytes, "error http_status\n") != null);
}

test "an install that cannot update itself says why and refuses to act" {
    var fake: FakeBackend = .{ .eligibility_reason = .not_installed };
    configure(testConfig(&fake, "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="));
    var output: [max_status_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("state unsupported\ninstalled 1.0.0\nreason not_installed\n", handleRequest("native-sdk.updates.status", "", &output).bytes);
    try std.testing.expectEqualStrings("unsupported", handleRequest("native-sdk.updates.check", "", &output).bytes);

    configure(.{ .version = "1.0.0" });
    try std.testing.expectEqualStrings("state unsupported\ninstalled 1.0.0\nreason not_configured\n", handleRequest("native-sdk.updates.status", "", &output).bytes);
}

test "a staged release and the last update survive a relaunch" {
    var fake: FakeBackend = .{ .staged = "1.1.0", .last_update = "0.9.0 1.0.0" };
    configure(testConfig(&fake, "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="));
    var output: [max_status_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("state ready\ninstalled 1.0.0\nversion 1.1.0\nlast updated 0.9.0 1.0.0\n", handleRequest("native-sdk.updates.status", "", &output).bytes);
    // A release staged by an earlier launch has no notes to show.
    const notes = handleRequest("native-sdk.updates.notes", "", &output);
    try std.testing.expect(notes.ok and notes.bytes.len == 0);
    try std.testing.expect(handleRequest("native-sdk.updates.discard", "", &output).ok);
    try std.testing.expect(fake.discarded);
    try std.testing.expect(std.mem.startsWith(u8, handleRequest("native-sdk.updates.status", "", &output).bytes, "state idle\n"));
    try std.testing.expectEqualStrings("not_available", handleRequest("native-sdk.updates.notes", "", &output).bytes);
}

test "a cancelled download returns to the available release" {
    const allocator = std.testing.allocator;
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x64} ** Ed25519.KeyPair.seed_length);
    var key_buffer: [44]u8 = undefined;
    const public_key = std.base64.standard.Encoder.encode(&key_buffer, &key_pair.public_key.toBytes());
    const envelope = try signedFeed(allocator, key_pair, test_release);
    defer allocator.free(envelope);
    var fake: FakeBackend = .{ .envelope = envelope, .wait_for_cancel = true };
    var config = testConfig(&fake, public_key);
    config.check_on_start = true;
    configure(config);
    join();
    var output: [max_status_bytes]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, handleRequest("native-sdk.updates.status", "", &output).bytes, "state available\n"));
    try std.testing.expect(handleRequest("native-sdk.updates.download", "", &output).ok);
    try std.testing.expectEqualStrings("busy", handleRequest("native-sdk.updates.check", "", &output).bytes);
    var downloading: []const u8 = "";
    var spins: usize = 0;
    while (std.mem.indexOf(u8, downloading, "received 500\n") == null and spins < 100_000_000) : (spins += 1) {
        downloading = handleRequest("native-sdk.updates.status", "", &output).bytes;
    }
    try std.testing.expectEqualStrings("state downloading\ninstalled 1.0.0\nversion 1.1.0\nsize 1000\nreceived 500\npercent 50\n", downloading);
    try std.testing.expect(handleRequest("native-sdk.updates.cancel", "", &output).ok);
    join();
    try std.testing.expect(std.mem.startsWith(u8, handleRequest("native-sdk.updates.status", "", &output).bytes, "state available\n"));
    try std.testing.expectEqualStrings("not_downloading", handleRequest("native-sdk.updates.cancel", "", &output).bytes);
    try std.testing.expectEqualStrings("invalid_request", handleRequest("native-sdk.updates.check", "x", &output).bytes);
}
