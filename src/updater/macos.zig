//! The macOS half of the updater (engine.zig) for apps whose manifest sets
//! `updates.mode` to `app`. The AppKit host does the Cocoa work
//! (appkit_host.m, `native_sdk_macos_updates_*`): fetching through the
//! user's network settings, unpacking with ditto, checking the bundle and
//! its signing team, and the helper that swaps the bundle once this
//! process exits. This file checks the archive's signed size and SHA-256
//! and maps results onto the engine's.
//!
//! A release stages beside the app as `.<App.app>.native-update/` and
//! installs when the app restarts into it or quits; the version that
//! starts next reports `last updated`.

const std = @import("std");
const engine = @import("engine.zig");
const feed = @import("feed.zig");

extern fn native_sdk_macos_updates_eligibility() c_int;
extern fn native_sdk_macos_updates_staged_version(bundle_id: [*]const u8, bundle_id_len: usize, output: [*]u8, capacity: usize) usize;
extern fn native_sdk_macos_updates_take_last(bundle_id: [*]const u8, bundle_id_len: usize, output: [*]u8, capacity: usize) usize;
extern fn native_sdk_macos_updates_fetch(url: [*]const u8, url_len: usize, allow_loopback_http: c_int, output: [*]u8, capacity: usize, output_len: *usize) c_int;
extern fn native_sdk_macos_updates_download(url: [*]const u8, url_len: usize, allow_loopback_http: c_int, limit: u64, path_output: [*]u8, path_capacity: usize, path_len: *usize, context: ?*anyopaque, progress: *const fn (?*anyopaque, u64) callconv(.c) void, cancelled: *const fn (?*anyopaque) callconv(.c) c_int) c_int;
extern fn native_sdk_macos_updates_stage(archive_path: [*]const u8, archive_path_len: usize, bundle_id: [*]const u8, bundle_id_len: usize, version: [*]const u8, version_len: usize) c_int;
extern fn native_sdk_macos_updates_discard() void;
extern fn native_sdk_macos_updates_install(bundle_id: [*]const u8, bundle_id_len: usize, from_version: [*]const u8, from_version_len: usize, relaunch: c_int) c_int;

// Transfer results, as appkit_host.m numbers them.
const transfer_network = 1;
const transfer_http_status = 2;
const transfer_too_large = 3;
const transfer_cancelled = 4;

const Install = struct {
    bundle_buffer: [128]u8 = undefined,
    bundle_len: usize = 0,
    version_buffer: [64]u8 = undefined,
    version_len: usize = 0,

    fn bundleId(self: *const Install) []const u8 {
        return self.bundle_buffer[0..self.bundle_len];
    }
    fn version(self: *const Install) []const u8 {
        return self.version_buffer[0..self.version_len];
    }
};

var install: Install = .{};

/// The backend for this app; `version` is the running version, which the
/// install records as the one it replaced.
pub fn backend(bundle_id: []const u8, version: []const u8) engine.Backend {
    install = .{};
    install.bundle_len = copyInto(&install.bundle_buffer, bundle_id);
    install.version_len = copyInto(&install.version_buffer, version);
    return .{
        .context = &install,
        .eligibility = eligibility,
        .staged_version = stagedVersion,
        .take_last_update = takeLastUpdate,
        .fetch = fetch,
        .stage = stage,
        .discard = discard,
        .prepare_restart = prepareRestart,
        .install_on_exit = installOnExit,
    };
}

fn get(context: *anyopaque) *Install {
    return @ptrCast(@alignCast(context));
}

fn eligibility(context: *anyopaque) ?engine.Unsupported {
    _ = context;
    return switch (native_sdk_macos_updates_eligibility()) {
        0 => null,
        1 => .not_installed,
        else => .read_only,
    };
}

fn stagedVersion(context: *anyopaque, output: []u8) ?[]const u8 {
    const bundle_id = get(context).bundleId();
    const length = native_sdk_macos_updates_staged_version(bundle_id.ptr, bundle_id.len, output.ptr, output.len);
    return if (length == 0) null else output[0..length];
}

fn takeLastUpdate(context: *anyopaque, output: []u8) ?[]const u8 {
    const bundle_id = get(context).bundleId();
    const length = native_sdk_macos_updates_take_last(bundle_id.ptr, bundle_id.len, output.ptr, output.len);
    return if (length == 0) null else output[0..length];
}

fn fetch(context: *anyopaque, url: []const u8, policy: feed.UrlPolicy, output: []u8) engine.FetchError![]const u8 {
    _ = context;
    var length: usize = 0;
    return switch (native_sdk_macos_updates_fetch(url.ptr, url.len, @intFromBool(policy.allow_loopback_http), output.ptr, output.len, &length)) {
        0 => output[0..length],
        transfer_http_status => error.HttpStatus,
        transfer_too_large => error.TooLarge,
        else => error.Network,
    };
}

fn stage(context: *anyopaque, release: *const engine.Release, policy: feed.UrlPolicy, progress: *engine.Progress) engine.StageError!void {
    const self = get(context);
    const url = release.url();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var path_len: usize = 0;
    switch (native_sdk_macos_updates_download(url.ptr, url.len, @intFromBool(policy.allow_loopback_http), release.archive_bytes, &path_buffer, path_buffer.len, &path_len, progress, reportProgress, isCancelled)) {
        0 => {},
        transfer_network => return error.Network,
        transfer_http_status => return error.HttpStatus,
        transfer_too_large => return error.ArchiveSize,
        transfer_cancelled => return error.Cancelled,
        else => return error.Disk,
    }
    const path = path_buffer[0..path_len];

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try verifyArchive(io, path, release);

    const version = release.version();
    const bundle_id = self.bundleId();
    return switch (native_sdk_macos_updates_stage(path.ptr, path.len, bundle_id.ptr, bundle_id.len, version.ptr, version.len)) {
        0 => {},
        1 => error.ArchiveInvalid,
        else => error.Disk,
    };
}

/// The archive must be exactly the size and SHA-256 the signed feed named.
fn verifyArchive(io: std.Io, path: []const u8, release: *const engine.Release) engine.StageError!void {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.Disk;
    defer file.close(io);
    const size = (file.stat(io) catch return error.Disk).size;
    if (size != release.archive_bytes) return error.ArchiveSize;
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const count = reader.interface.readSliceShort(&chunk) catch return error.Disk;
        if (count == 0) break;
        hasher.update(chunk[0..count]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.crypto.timing_safe.eql([64]u8, actual, release.sha256)) return error.ArchiveDigest;
}

fn discard(context: *anyopaque) void {
    _ = context;
    native_sdk_macos_updates_discard();
}

fn prepareRestart(context: *anyopaque) bool {
    return startInstall(get(context), true);
}

fn installOnExit(context: *anyopaque) void {
    _ = startInstall(get(context), false);
}

fn startInstall(self: *const Install, relaunch: bool) bool {
    const bundle_id = self.bundleId();
    const from = self.version();
    return native_sdk_macos_updates_install(bundle_id.ptr, bundle_id.len, from.ptr, from.len, @intFromBool(relaunch)) == 1;
}

fn reportProgress(context: ?*anyopaque, received: u64) callconv(.c) void {
    const progress: *engine.Progress = @ptrCast(@alignCast(context.?));
    progress.report(received);
}

fn isCancelled(context: ?*anyopaque) callconv(.c) c_int {
    const progress: *engine.Progress = @ptrCast(@alignCast(context.?));
    return @intFromBool(progress.cancelled());
}

fn copyInto(buffer: []u8, value: []const u8) usize {
    const length = @min(buffer.len, value.len);
    @memcpy(buffer[0..length], value[0..length]);
    return length;
}
