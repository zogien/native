const std = @import("std");
const platform_types = @import("../platform/types.zig");

pub const feed = @import("feed.zig");
pub const c_api = @import("c_api.zig");
pub const engine = @import("engine.zig");
/// The Windows backend for SDK-installed apps; analyzed only by Windows builds.
pub const windows = @import("windows.zig");

/// The desktop host a runner was built for.
pub const Host = enum { windows, other };

/// Points the app-driven updater at this installation; each runner calls
/// it once at startup. Windows installs get a backend; elsewhere the
/// updater reports why it cannot update. Setting
/// NATIVE_SDK_UPDATES_FEED_URL replaces the manifest's feed URL to test an
/// update end to end, and may then name a loopback http:// server; the
/// manifest's Ed25519 keys stay the authority over what installs.
pub fn configureApp(comptime host: Host, app_info: *platform_types.AppInfo, environ_map: *std.process.Environ.Map) void {
    const override = environ_map.get("NATIVE_SDK_UPDATES_FEED_URL");
    const backend: ?engine.Backend = switch (host) {
        .windows => windows.backend(app_info.bundle_id),
        .other => null,
    };
    engine.configure(.{
        .feed_url = override orelse app_info.update_feed_url,
        .public_keys = app_info.update_public_key,
        .bundle_id = app_info.bundle_id,
        .version = app_info.version,
        .target = feed.currentTarget(),
        .policy = .{ .allow_loopback_http = override != null },
        .backend = backend,
        .check_on_start = app_info.update_check_on_start,
    });
}

pub const Envelope = feed.Envelope;
pub const Release = feed.Release;
pub const VerifiedRelease = feed.VerifiedRelease;
pub const verifyEnvelope = feed.verifyEnvelope;
pub const releaseApplies = feed.releaseApplies;
pub const versionOrder = feed.versionOrder;
pub const archiveHashMatches = feed.archiveHashMatches;
