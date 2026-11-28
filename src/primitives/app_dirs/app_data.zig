//! The one source for every directory the SDK keeps an app's data in.
//!
//! A desktop entry point resolves an `AppData` once, at startup, and hands
//! that value to every consumer: the file-access roots, the record and
//! SQLite stores, the model snapshot, the window-state file, the logs, the
//! URL media cache, the services' working directory, and the web engine
//! profile the native hosts receive. No consumer derives a path of its own.
//!
//! Without an override every path is the platform convention `resolveOne`
//! has always produced. A launch can move all of it under one root instead:
//! the `--native-data-dir=<path>` flag (or `--native-data-dir <path>`), else
//! the `NATIVE_SDK_DATA_DIR` environment variable. The root is created if
//! missing and used by its canonical absolute path, with one fixed
//! subfolder per directory (`layout`). An unusable override is a startup
//! error; the SDK never falls back to the default data directory behind it.
//!
//! iOS and Android keep their sandbox paths: their hosts never call this.
const std = @import("std");
const builtin = @import("builtin");
const dirs = @import("root.zig");

/// The command-line flag, in `--native-data-dir=<path>` or
/// `--native-data-dir <path>` form.
pub const flag = "--native-data-dir";
const flag_prefix = flag ++ "=";
/// The environment variable consulted when the flag is absent.
pub const env_var = "NATIVE_SDK_DATA_DIR";

/// Bound on every resolved directory path. The override root leaves room
/// for the longest subfolder and the file names consumers append.
pub const max_dir_bytes: usize = 1024;
pub const max_root_bytes: usize = max_dir_bytes - 64;

/// The fixed subfolders under an override root.
pub const layout = struct {
    pub const config = "config";
    pub const cache = "cache";
    pub const data = "data";
    pub const state = "state";
    pub const logs = "logs";
    pub const temp = "temp";
    /// The former short-name data directory an app may request. Under an
    /// override it starts empty: the root has no former identity.
    pub const legacy_data = "legacy-data";
    /// The web engine profile (cookies, storage, HTTP cache).
    pub const webview = "webview";
};

const kinds = [_]dirs.DirKind{ .config, .cache, .data, .state, .logs, .temp };

fn layoutName(kind: dirs.DirKind) []const u8 {
    return switch (kind) {
        .config => layout.config,
        .cache => layout.cache,
        .data => layout.data,
        .state => layout.state,
        .logs => layout.logs,
        .temp => layout.temp,
    };
}

pub const WebEngine = enum { system, chromium };

/// Who the directories belong to.
pub const Identity = struct {
    /// Keys every durable directory: the manifest's reverse-DNS id.
    bundle_id: []const u8,
    /// Keys the URL media cache and the legacy data directory: the
    /// manifest's short name.
    app_name: []const u8,
    /// Which engine the web profile is for.
    web_engine: WebEngine = .system,
};

pub const Source = enum {
    /// The platform convention.
    default,
    /// `--native-data-dir`.
    flag,
    /// `NATIVE_SDK_DATA_DIR`.
    env,
};

/// A requested override root, before it is created or canonicalized.
pub const Request = struct {
    source: Source,
    path: []const u8,
};

pub const Problem = enum {
    flag_missing_value,
    flag_repeated,
    empty,
    not_a_directory,
    cannot_create,
    cannot_resolve,
    too_long,
    not_writable,
};

/// Why an override was refused, for the startup error message.
pub const Failure = struct {
    source: Source = .default,
    /// The path as given.
    path: []const u8 = "",
    problem: Problem = .empty,
    /// The layout folder that could not be created (`not_writable`).
    folder: []const u8 = "",
    /// The underlying error name, when there is one.
    reason: []const u8 = "",

    pub fn format(self: Failure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.problem) {
            .flag_missing_value => return writer.writeAll(flag ++ " needs a path: " ++ flag ++ "=<path> or " ++ flag ++ " <path>"),
            .flag_repeated => return writer.writeAll(flag ++ " is given more than once"),
            else => {},
        }
        switch (self.source) {
            .flag => try writer.print("the data directory {s}=\"{s}\" cannot be used: ", .{ flag, self.path }),
            else => try writer.print("the data directory {s}=\"{s}\" cannot be used: ", .{ env_var, self.path }),
        }
        switch (self.problem) {
            .flag_missing_value, .flag_repeated => unreachable,
            .empty => try writer.writeAll("the path is empty"),
            .not_a_directory => try writer.writeAll("it, or a folder on the way to it, is a file"),
            .cannot_create => try writer.print("it cannot be created ({s})", .{self.reason}),
            .cannot_resolve => try writer.print("its absolute path cannot be resolved ({s})", .{self.reason}),
            .too_long => try writer.print("its absolute path is longer than {d} bytes", .{max_root_bytes}),
            .not_writable => try writer.print("its {s} folder cannot be created ({s})", .{ self.folder, self.reason }),
        }
    }
};

pub const Error = error{ DataDirUnusable, OutOfMemory };

/// The directories of one app process. Every slice lives as long as the
/// allocator `resolve` was given (entry points pass the process arena).
/// A `null` directory is one the platform convention could not resolve
/// (a missing `HOME`, `LOCALAPPDATA`, ...); consumers keep their existing
/// behavior for it. Under an override none is `null`.
pub const AppData = struct {
    source: Source = .default,
    /// The override root's canonical absolute path; empty for `.default`.
    /// Two launches name the same root exactly when these bytes match.
    root: []const u8 = "",
    /// Under an override: whether the root's `data` folder is the very
    /// directory the default data directory names, so the launch uses the
    /// default data after all (a root at the default location, such as
    /// `%LOCALAPPDATA%\<bundle id>` on Windows). False for `.default`.
    data_is_default: bool = false,
    config: ?[]const u8 = null,
    cache: ?[]const u8 = null,
    data: ?[]const u8 = null,
    state: ?[]const u8 = null,
    logs: ?[]const u8 = null,
    temp: ?[]const u8 = null,
    /// The URL audio/image cache. Default: the caches directory keyed by
    /// the app name. Override: the root's `cache` folder.
    media_cache: ?[]const u8 = null,
    /// The former short-name data directory (legacy data capability).
    legacy_data: ?[]const u8 = null,
    /// Where the web engine keeps its profile; empty leaves the engine's
    /// own default. Default: `%LOCALAPPDATA%\<bundle id>\WebView2` for
    /// WebView2, `<data>/CEF` for macOS CEF, the engine default elsewhere.
    /// Override: the root's `webview` folder.
    web_profile: []const u8 = "",

    pub fn isOverride(self: AppData) bool {
        return self.source != .default;
    }

    /// Whether the data directory in use is the default one: no override,
    /// or an override whose `data` folder is the default data directory.
    pub fn usesDefaultData(self: AppData) bool {
        return !self.isOverride() or self.data_is_default;
    }

    pub fn get(self: AppData, kind: dirs.DirKind) ?[]const u8 {
        return switch (kind) {
            .config => self.config,
            .cache => self.cache,
            .data => self.data,
            .state => self.state,
            .logs => self.logs,
            .temp => self.temp,
        };
    }

    /// All six directories, or null when any of them is unresolved —
    /// the file-access roots need the whole set.
    pub fn all(self: AppData) ?dirs.ResolvedDirs {
        return .{
            .config = self.config orelse return null,
            .cache = self.cache orelse return null,
            .data = self.data orelse return null,
            .state = self.state orelse return null,
            .logs = self.logs orelse return null,
            .temp = self.temp orelse return null,
        };
    }
};

/// `resolve` for an entry point's `main`, called once per process before
/// anything opens a file: the paths live in the process arena, and an
/// unusable override ends the launch right here with exit code 2 and a
/// message naming the problem — never a silent fallback to the defaults.
pub fn forLaunch(init: std.process.Init, identity: Identity) AppData {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch exitOutOfMemory(identity.app_name);
    var failure: Failure = .{};
    return resolve(arena, init.io, identity, if (args.len > 0) args[1..] else args, init.environ_map, &failure) catch |err| switch (err) {
        error.DataDirUnusable => {
            std.debug.print("{s}: {f}\n", .{ identity.app_name, failure });
            std.process.exit(2);
        },
        error.OutOfMemory => exitOutOfMemory(identity.app_name),
    };
}

fn exitOutOfMemory(app_name: []const u8) noreturn {
    std.debug.print("{s}: out of memory while resolving the data directory\n", .{app_name});
    std.process.exit(1);
}

/// Resolves the process's directories from its arguments (argv without
/// argv[0]) and environment.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    identity: Identity,
    args: []const [:0]const u8,
    env_map: *const std.process.Environ.Map,
    failure: *Failure,
) Error!AppData {
    const request = try requestFrom(args, env_map.get(env_var), failure);
    return resolveWith(allocator, io, std.Io.Dir.cwd(), dirs.currentPlatform(), identity, request, dirs.envFromMap(env_map), failure);
}

/// `resolve` with the working directory, platform, and environment given.
pub fn resolveWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    platform: dirs.Platform,
    identity: Identity,
    request: ?Request,
    env: dirs.Env,
    failure: *Failure,
) Error!AppData {
    const wanted = request orelse return defaults(allocator, platform, identity, env);
    var result = try resolveOverride(allocator, io, cwd, platform, wanted, failure);
    var default_buffer: [max_dir_bytes]u8 = undefined;
    if (dirs.resolveOne(.{ .name = identity.bundle_id }, platform, env, .data, &default_buffer)) |default_data| {
        result.data_is_default = sameDirectory(io, cwd, result.data.?, default_data);
    } else |_| {}
    return result;
}

/// Whether two paths name one existing directory, as the file system
/// resolves them: each is opened and canonicalized like an override root
/// (`canonicalPath`), so case on a case-insensitive volume, 8.3 names,
/// `..`, and links compare as the folder they reach. A path that does not
/// open names no directory, so it matches nothing.
fn sameDirectory(io: std.Io, cwd: std.Io.Dir, first: []const u8, second: []const u8) bool {
    var first_buffer: [max_dir_bytes]u8 = undefined;
    var second_buffer: [max_dir_bytes]u8 = undefined;
    const first_canonical = openCanonical(io, cwd, first, &first_buffer) orelse return false;
    const second_canonical = openCanonical(io, cwd, second, &second_buffer) orelse return false;
    return std.mem.eql(u8, first_canonical, second_canonical);
}

fn openCanonical(io: std.Io, cwd: std.Io.Dir, path: []const u8, buffer: []u8) ?[]const u8 {
    var dir = cwd.openDir(io, path, .{}) catch return null;
    defer dir.close(io);
    return canonicalPath(io, dir, buffer) catch null;
}

/// The override a launch asks for: the flag before the first `--`, else
/// the environment variable. Null asks for the default directories.
pub fn requestFrom(args: []const [:0]const u8, env_value: ?[]const u8, failure: *Failure) error{DataDirUnusable}!?Request {
    var found: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument: []const u8 = args[index];
        if (std.mem.eql(u8, argument, "--")) break;
        const value: []const u8 = if (std.mem.eql(u8, argument, flag)) value: {
            if (index + 1 >= args.len or std.mem.eql(u8, args[index + 1], "--")) {
                failure.* = .{ .source = .flag, .problem = .flag_missing_value };
                return error.DataDirUnusable;
            }
            index += 1;
            break :value args[index];
        } else if (std.mem.startsWith(u8, argument, flag_prefix))
            argument[flag_prefix.len..]
        else
            continue;
        if (found != null) {
            failure.* = .{ .source = .flag, .problem = .flag_repeated };
            return error.DataDirUnusable;
        }
        found = value;
    }
    if (found) |path| return .{ .source = .flag, .path = path };
    if (env_value) |path| return .{ .source = .env, .path = path };
    return null;
}

/// Separates the app's own arguments from the data-directory flag. Feed
/// it argv[1..] in order: `keep` is false for the flag and, in the
/// two-argument form, for its path. A `--` and everything after it are
/// always the app's. Every place the SDK reports launch arguments to an
/// app passes them through this filter.
pub const ArgumentFilter = struct {
    terminated: bool = false,
    skip_value: bool = false,

    pub fn keep(self: *ArgumentFilter, argument: []const u8) bool {
        if (self.skip_value) {
            self.skip_value = false;
            return false;
        }
        if (self.terminated) return true;
        if (std.mem.eql(u8, argument, "--")) {
            self.terminated = true;
            return true;
        }
        if (std.mem.eql(u8, argument, flag)) {
            self.skip_value = true;
            return false;
        }
        return !std.mem.startsWith(u8, argument, flag_prefix);
    }
};

/// Today's platform-convention paths, byte for byte: the six kinds keyed
/// by bundle id, the media cache and legacy data keyed by app name.
pub fn defaults(allocator: std.mem.Allocator, platform: dirs.Platform, identity: Identity, env: dirs.Env) error{OutOfMemory}!AppData {
    var result: AppData = .{};
    const owner: dirs.AppInfo = .{ .name = identity.bundle_id };
    inline for (kinds) |kind| {
        @field(result, @tagName(kind)) = try dupeResolved(allocator, owner, platform, env, kind);
    }
    const short: dirs.AppInfo = .{ .name = identity.app_name };
    result.media_cache = try dupeResolved(allocator, short, platform, env, .cache);
    result.legacy_data = try dupeResolved(allocator, short, platform, env, .data);
    result.web_profile = try defaultWebProfile(allocator, platform, identity, env);
    return result;
}

fn dupeResolved(allocator: std.mem.Allocator, app: dirs.AppInfo, platform: dirs.Platform, env: dirs.Env, kind: dirs.DirKind) error{OutOfMemory}!?[]const u8 {
    var buffer: [max_dir_bytes]u8 = undefined;
    const path = dirs.resolveOne(app, platform, env, kind, &buffer) catch return null;
    return try allocator.dupe(u8, path);
}

/// The web profile the SDK picks when nothing overrides it, or empty for
/// the engine's own default. WebView2 keeps the folder the Windows host
/// has always named (beside the app's Data/Cache/State/Logs folders, with
/// the same name checks); macOS CEF gets a per-app profile in the app's
/// data directory instead of one shared by every app.
pub fn defaultWebProfile(allocator: std.mem.Allocator, platform: dirs.Platform, identity: Identity, env: dirs.Env) error{OutOfMemory}![]const u8 {
    switch (platform) {
        .windows => {
            if (identity.web_engine != .system or !webView2FolderNameUsable(identity.bundle_id)) return "";
            const local_app_data = std.mem.trimEnd(u8, env.local_app_data orelse return "", "\\/");
            if (local_app_data.len == 0) return "";
            return std.mem.concat(allocator, u8, &.{ local_app_data, "\\", identity.bundle_id, "\\WebView2" });
        },
        .macos => {
            if (identity.web_engine != .chromium) return "";
            var buffer: [max_dir_bytes]u8 = undefined;
            const data = dirs.resolveOne(.{ .name = identity.bundle_id }, .macos, env, .data, &buffer) catch return "";
            return std.mem.concat(allocator, u8, &.{ data, "/CEF" });
        },
        else => return "",
    }
}

/// The checks the WebView2 host applied to the bundle id before it named
/// a folder after it: a single Win32 path component.
fn webView2FolderNameUsable(bundle_id: []const u8) bool {
    if (bundle_id.len == 0 or std.mem.eql(u8, bundle_id, ".") or std.mem.eql(u8, bundle_id, "..")) return false;
    if (std.mem.indexOfAny(u8, bundle_id, "\\/:*?\"<>|") != null) return false;
    for (bundle_id) |ch| if (ch < 0x20) return false;
    return true;
}

fn resolveOverride(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, platform: dirs.Platform, request: Request, failure: *Failure) Error!AppData {
    failure.* = .{ .source = request.source, .path = request.path };
    if (request.path.len == 0) return refuse(failure, .empty, "");
    var root_dir = cwd.createDirPathOpen(io, request.path, .{}) catch |err| return refuse(failure, switch (err) {
        error.NotDir, error.PathAlreadyExists => .not_a_directory,
        else => .cannot_create,
    }, @errorName(err));
    defer root_dir.close(io);

    var root_buffer: [max_root_bytes]u8 = undefined;
    const canonical = canonicalPath(io, root_dir, &root_buffer) catch |err| return switch (err) {
        error.NameTooLong => refuse(failure, .too_long, ""),
        else => refuse(failure, .cannot_resolve, @errorName(err)),
    };
    const root = try allocator.dupe(u8, canonical);

    var result: AppData = .{ .source = request.source, .root = root };
    inline for (kinds) |kind| {
        const name = comptime layoutName(kind);
        root_dir.createDirPath(io, name) catch |err| {
            failure.folder = name;
            return refuse(failure, .not_writable, @errorName(err));
        };
        @field(result, @tagName(kind)) = try under(allocator, platform, root, name);
    }
    result.media_cache = result.cache;
    result.legacy_data = try under(allocator, platform, root, layout.legacy_data);
    result.web_profile = try under(allocator, platform, root, layout.webview);
    return result;
}

/// The one spelling of an open directory: symlinks and `..` resolved, and
/// on Windows also 8.3 short names expanded and the on-disk case used
/// (`GetFinalPathNameByHandleW` with FILE_NAME_NORMALIZED; std's realPath
/// keeps a short-name spelling as given, so `C:\PROGRA~1\x` and
/// `C:\Program Files\x` would name one folder by two roots).
fn canonicalPath(io: std.Io, dir: std.Io.Dir, buffer: []u8) error{ NameTooLong, Unexpected, CannotResolve }![]const u8 {
    if (comptime builtin.os.tag == .windows) return windowsFinalPath(dir.handle, buffer);
    // Resolve into a full-size buffer: on Linux std's realPath is a
    // readlink of /proc/self/fd/N, which truncates to the buffer silently
    // instead of failing, so a short buffer would yield a wrong root.
    var full: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = dir.realPath(io, &full) catch |err| return switch (err) {
        error.NameTooLong => error.NameTooLong,
        else => error.CannotResolve,
    };
    if (len >= full.len or len > buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..len], full[0..len]);
    return buffer[0..len];
}

extern "kernel32" fn GetFinalPathNameByHandleW(file: std.os.windows.HANDLE, path: [*]u16, path_len: u32, flags: u32) callconv(.winapi) u32;

fn windowsFinalPath(handle: std.os.windows.HANDLE, buffer: []u8) error{ NameTooLong, Unexpected, CannotResolve }![]const u8 {
    var wide: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
    // FILE_NAME_NORMALIZED | VOLUME_NAME_DOS: `\\?\C:\...` or `\\?\UNC\server\share\...`.
    const len = GetFinalPathNameByHandleW(handle, &wide, wide.len, 0);
    if (len == 0) return error.CannotResolve;
    if (len >= wide.len) return error.NameTooLong;
    const final = wide[0..len];
    const unc_prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\UNC\\");
    const local_prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    var start: usize = 0;
    var out: usize = 0;
    if (std.mem.startsWith(u16, final, unc_prefix)) {
        if (buffer.len < 2) return error.NameTooLong;
        buffer[0] = '\\';
        buffer[1] = '\\';
        out = 2;
        start = unc_prefix.len;
    } else if (std.mem.startsWith(u16, final, local_prefix)) {
        start = local_prefix.len;
    }
    const rest = final[start..];
    if (out + std.unicode.calcWtf8Len(rest) > buffer.len) return error.NameTooLong;
    out += std.unicode.wtf16LeToWtf8(buffer[out..], rest);
    return buffer[0..out];
}

fn under(allocator: std.mem.Allocator, platform: dirs.Platform, root: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    const separator = [_]u8{dirs.platformSeparator(platform)};
    const joiner: []const u8 = if (root.len > 0 and root[root.len - 1] == separator[0]) "" else &separator;
    return std.mem.concat(allocator, u8, &.{ root, joiner, name });
}

fn refuse(failure: *Failure, problem: Problem, reason: []const u8) error{DataDirUnusable} {
    failure.problem = problem;
    failure.reason = reason;
    return error.DataDirUnusable;
}

/// A stable identifier for an isolated web data store, derived from the
/// profile path: WKWebView keys persistent stores by UUID rather than by
/// directory, so the same root reopens the same store. Name-based (the
/// RFC 9562 version 8 layout over SHA-256 of the path bytes).
pub fn webDataStoreIdentifier(profile: []const u8) [16]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("native-sdk.web-data-store\x00");
    hasher.update(profile);
    hasher.final(&digest);
    var id: [16]u8 = digest[0..16].*;
    id[6] = (id[6] & 0x0f) | 0x80;
    id[8] = (id[8] & 0x3f) | 0x80;
    return id;
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

const identity_fixture: Identity = .{ .bundle_id = "dev.native_sdk.demo", .app_name = "demo" };

fn expectSame(expected: []const u8, actual: ?[]const u8) !void {
    try testing.expectEqualStrings(expected, actual orelse return error.TestExpectedEqual);
}

/// The default paths must stay exactly what each consumer resolved on
/// its own before this module existed: `resolveOne` for the six kinds
/// keyed by bundle id, `.cache`/`.data` keyed by app name.
fn expectDefaultsMatchResolveOne(platform: dirs.Platform, env: dirs.Env) !void {
    var arena = testArena();
    defer arena.deinit();
    const data = try defaults(arena.allocator(), platform, identity_fixture, env);
    try testing.expectEqual(Source.default, data.source);
    try testing.expectEqualStrings("", data.root);
    var buffer: [max_dir_bytes]u8 = undefined;
    inline for (kinds) |kind| {
        try expectSame(try dirs.resolveOne(.{ .name = identity_fixture.bundle_id }, platform, env, kind, &buffer), data.get(kind));
    }
    try expectSame(try dirs.resolveOne(.{ .name = identity_fixture.app_name }, platform, env, .cache, &buffer), data.media_cache);
    try expectSame(try dirs.resolveOne(.{ .name = identity_fixture.app_name }, platform, env, .data, &buffer), data.legacy_data);
}

test "default directories are the platform conventions on every platform" {
    const linux_env: dirs.Env = .{ .home = "/home/alice", .xdg_state_home = "/xdg/state" };
    const macos_env: dirs.Env = .{ .home = "/Users/alice", .tmpdir = "/var/folders/t" };
    const windows_env: dirs.Env = .{
        .app_data = "C:\\Users\\alice\\AppData\\Roaming",
        .local_app_data = "C:\\Users\\alice\\AppData\\Local",
        .temp = "C:\\Users\\alice\\AppData\\Local\\Temp",
    };
    const ios_env: dirs.Env = .{ .home = "/var/mobile/Containers/Data/Application/ABC" };
    const android_env: dirs.Env = .{ .home = "/data/user/0/dev.native_sdk.demo" };
    try expectDefaultsMatchResolveOne(.linux, linux_env);
    try expectDefaultsMatchResolveOne(.macos, macos_env);
    try expectDefaultsMatchResolveOne(.windows, windows_env);
    try expectDefaultsMatchResolveOne(.ios, ios_env);
    try expectDefaultsMatchResolveOne(.android, android_env);

    // The literal values today's runners produce, so a change to
    // resolveOne itself shows up here too.
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    const windows = try defaults(allocator, .windows, identity_fixture, windows_env);
    try expectSame("C:\\Users\\alice\\AppData\\Roaming\\dev.native_sdk.demo", windows.config);
    try expectSame("C:\\Users\\alice\\AppData\\Local\\dev.native_sdk.demo\\Data", windows.data);
    try expectSame("C:\\Users\\alice\\AppData\\Local\\dev.native_sdk.demo\\State", windows.state);
    try expectSame("C:\\Users\\alice\\AppData\\Local\\dev.native_sdk.demo\\Logs", windows.logs);
    try expectSame("C:\\Users\\alice\\AppData\\Local\\demo\\Cache", windows.media_cache);
    try expectSame("C:\\Users\\alice\\AppData\\Local\\demo\\Data", windows.legacy_data);
    try testing.expectEqualStrings("C:\\Users\\alice\\AppData\\Local\\dev.native_sdk.demo\\WebView2", windows.web_profile);

    const macos = try defaults(allocator, .macos, identity_fixture, macos_env);
    try expectSame("/Users/alice/Library/Application Support/dev.native_sdk.demo", macos.data);
    try expectSame("/Users/alice/Library/Application Support/dev.native_sdk.demo/State", macos.state);
    try expectSame("/Users/alice/Library/Logs/dev.native_sdk.demo", macos.logs);
    try expectSame("/Users/alice/Library/Caches/demo", macos.media_cache);
    try testing.expectEqualStrings("", macos.web_profile);

    const linux = try defaults(allocator, .linux, identity_fixture, linux_env);
    try expectSame("/home/alice/.local/share/dev.native_sdk.demo", linux.data);
    try expectSame("/xdg/state/dev.native_sdk.demo/logs", linux.logs);
    try expectSame("/home/alice/.cache/demo", linux.media_cache);
    try testing.expectEqualStrings("", linux.web_profile);
}

test "default directories stay unresolved where the convention cannot resolve" {
    var arena = testArena();
    defer arena.deinit();
    // Windows without APPDATA: config is unresolved, so the whole set is
    // too (the file-access roots), while Data still resolves for stores.
    const data = try defaults(arena.allocator(), .windows, identity_fixture, .{ .local_app_data = "C:\\Local", .temp = "C:\\Temp" });
    try testing.expect(data.config == null);
    try testing.expect(data.all() == null);
    try expectSame("C:\\Local\\dev.native_sdk.demo\\Data", data.data);
    const none = try defaults(arena.allocator(), .linux, .{ .bundle_id = "bad/id", .app_name = "demo" }, .{ .home = "/home/a" });
    try testing.expect(none.data == null and none.state == null and none.logs == null);
    try expectSame("/home/a/.cache/demo", none.media_cache);
}

test "default web profiles keep the hosts' former folders" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    // The WebView2 host trimmed trailing separators and refused names
    // that are not one Win32 path component.
    try testing.expectEqualStrings("C:\\Local\\dev.native_sdk.demo\\WebView2", try defaultWebProfile(allocator, .windows, identity_fixture, .{ .local_app_data = "C:\\Local\\/" }));
    try testing.expectEqualStrings("", try defaultWebProfile(allocator, .windows, identity_fixture, .{}));
    try testing.expectEqualStrings("", try defaultWebProfile(allocator, .windows, identity_fixture, .{ .local_app_data = "\\" }));
    try testing.expectEqualStrings("", try defaultWebProfile(allocator, .windows, .{ .bundle_id = "a:b", .app_name = "a" }, .{ .local_app_data = "C:\\Local" }));
    try testing.expectEqualStrings("", try defaultWebProfile(allocator, .windows, .{ .bundle_id = "..", .app_name = "a" }, .{ .local_app_data = "C:\\Local" }));
    try testing.expectEqualStrings("", try defaultWebProfile(allocator, .windows, .{ .bundle_id = "a\x01", .app_name = "a" }, .{ .local_app_data = "C:\\Local" }));
    // macOS CEF: per app, inside the app's data directory.
    const cef: Identity = .{ .bundle_id = "dev.native_sdk.demo", .app_name = "demo", .web_engine = .chromium };
    try testing.expectEqualStrings("/Users/a/Library/Application Support/dev.native_sdk.demo/CEF", try defaultWebProfile(allocator, .macos, cef, .{ .home = "/Users/a" }));
    try testing.expectEqualStrings("", try defaultWebProfile(allocator, .macos, cef, .{}));
    // WKWebView and WebKitGTK keep their engine defaults.
    try testing.expectEqualStrings("", try defaultWebProfile(allocator, .macos, identity_fixture, .{ .home = "/Users/a" }));
    try testing.expectEqualStrings("", try defaultWebProfile(allocator, .linux, identity_fixture, .{ .home = "/home/a" }));
}

test "the flag wins over the environment variable" {
    var failure: Failure = .{};
    const both = (try requestFrom(&.{ "--native-data-dir=flag-root", "file.txt" }, "env-root", &failure)).?;
    try testing.expectEqual(Source.flag, both.source);
    try testing.expectEqualStrings("flag-root", both.path);
    const split = (try requestFrom(&.{ "a", "--native-data-dir", "two arg root", "b" }, null, &failure)).?;
    try testing.expectEqualStrings("two arg root", split.path);
    const env = (try requestFrom(&.{"file.txt"}, "env-root", &failure)).?;
    try testing.expectEqual(Source.env, env.source);
    try testing.expectEqualStrings("env-root", env.path);
    try testing.expect(try requestFrom(&.{"file.txt"}, null, &failure) == null);
    // An empty flag value is a request (refused later), not an absence.
    const empty = (try requestFrom(&.{"--native-data-dir="}, "env-root", &failure)).?;
    try testing.expectEqual(Source.flag, empty.source);
    try testing.expectEqualStrings("", empty.path);
}

test "the flag is read only before a -- terminator" {
    var failure: Failure = .{};
    try testing.expect(try requestFrom(&.{ "--", "--native-data-dir=x" }, null, &failure) == null);
    const env = (try requestFrom(&.{ "--", "--native-data-dir", "x" }, "env-root", &failure)).?;
    try testing.expectEqual(Source.env, env.source);
}

test "malformed flags are startup errors" {
    var failure: Failure = .{};
    try testing.expectError(error.DataDirUnusable, requestFrom(&.{"--native-data-dir"}, "env-root", &failure));
    try testing.expectEqual(Problem.flag_missing_value, failure.problem);
    try testing.expectError(error.DataDirUnusable, requestFrom(&.{ "--native-data-dir", "--" }, null, &failure));
    try testing.expectEqual(Problem.flag_missing_value, failure.problem);
    try testing.expectError(error.DataDirUnusable, requestFrom(&.{ "--native-data-dir=a", "--native-data-dir", "b" }, null, &failure));
    try testing.expectEqual(Problem.flag_repeated, failure.problem);
    var message: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&message);
    try writer.print("{f}", .{failure});
    try testing.expectEqualStrings("--native-data-dir is given more than once", writer.buffered());
}

test "the argument filter drops exactly the flag the request reads" {
    const args = [_][]const u8{ "first.txt", "--native-data-dir", "root", "--native-data-dir=other", "--native-data-dirx", "--", "--native-data-dir=kept", "--native-data-dir", "kept-too" };
    var filter: ArgumentFilter = .{};
    var kept: [args.len][]const u8 = undefined;
    var count: usize = 0;
    for (args) |argument| {
        if (filter.keep(argument)) {
            kept[count] = argument;
            count += 1;
        }
    }
    const expected = [_][]const u8{ "first.txt", "--native-data-dirx", "--", "--native-data-dir=kept", "--native-data-dir", "kept-too" };
    try testing.expectEqual(expected.len, count);
    for (expected, kept[0..count]) |want, got| try testing.expectEqualStrings(want, got);
}

fn expectOverrideLayout(data: AppData, root: []const u8) !void {
    const sep = [_]u8{dirs.platformSeparator(dirs.currentPlatform())};
    var buffer: [max_dir_bytes]u8 = undefined;
    inline for (kinds) |kind| {
        const want = try std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{ root, &sep, comptime layoutName(kind) });
        try expectSame(want, data.get(kind));
    }
    try expectSame(data.cache.?, data.media_cache);
    try expectSame(try std.fmt.bufPrint(&buffer, "{s}{s}legacy-data", .{ root, &sep }), data.legacy_data);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "{s}{s}webview", .{ root, &sep }), data.web_profile);
}

test "an override moves every directory under one canonical root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    var failure: Failure = .{};
    // A relative root resolves against the working directory given (here
    // the temp dir, standing in for a launch from a different cwd), is
    // created with its parents, and is reported by its canonical path.
    const data = try resolveWith(allocator, testing.io, tmp.dir, dirs.currentPlatform(), identity_fixture, .{ .source = .flag, .path = "profiles/./one" }, .{}, &failure);
    try testing.expectEqual(Source.flag, data.source);
    try testing.expect(data.isOverride());
    try testing.expect(std.fs.path.isAbsolute(data.root));
    var expected_buffer: [max_root_bytes]u8 = undefined;
    const expected_len = try tmp.dir.realPathFile(testing.io, "profiles" ++ std.fs.path.sep_str ++ "one", &expected_buffer);
    try testing.expectEqualStrings(expected_buffer[0..expected_len], data.root);
    try expectOverrideLayout(data, data.root);
    try testing.expect(data.all() != null);
    // The six kinds exist; the legacy and web folders are left to the
    // consumers that use them.
    inline for (kinds) |kind| {
        var sub = try tmp.dir.openDir(testing.io, "profiles" ++ std.fs.path.sep_str ++ "one" ++ std.fs.path.sep_str ++ comptime layoutName(kind), .{});
        sub.close(testing.io);
    }
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(testing.io, "profiles" ++ std.fs.path.sep_str ++ "one" ++ std.fs.path.sep_str ++ "webview", .{}));

    // The same root by another spelling is the same canonical root.
    const again = try resolveWith(allocator, testing.io, tmp.dir, dirs.currentPlatform(), identity_fixture, .{ .source = .env, .path = data.root }, .{}, &failure);
    try testing.expectEqualStrings(data.root, again.root);
    try testing.expectEqual(Source.env, again.source);
}

extern "kernel32" fn GetShortPathNameW(long_path: [*:0]const u16, short_path: [*]u16, short_len: u32) callconv(.winapi) u32;

test "every spelling of one folder resolves to one root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    const platform = dirs.currentPlatform();
    var failure: Failure = .{};
    const sep = std.fs.path.sep_str;
    const first = try resolveWith(allocator, testing.io, tmp.dir, platform, identity_fixture, .{ .source = .flag, .path = "Profile Folder" ++ sep ++ "Long Name One" }, .{}, &failure);
    const dotted = try resolveWith(allocator, testing.io, tmp.dir, platform, identity_fixture, .{ .source = .flag, .path = "Profile Folder/./Long Name One/../Long Name One/" }, .{}, &failure);
    try testing.expectEqualStrings(first.root, dotted.root);
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .macos) {
        // Case-insensitive file systems: the on-disk case wins.
        const upper = try resolveWith(allocator, testing.io, tmp.dir, platform, identity_fixture, .{ .source = .flag, .path = "PROFILE FOLDER" ++ sep ++ "LONG NAME ONE" }, .{}, &failure);
        try testing.expectEqualStrings(first.root, upper.root);
    }
    if (comptime builtin.os.tag == .windows) {
        // An 8.3 short spelling, where the volume generates short names.
        var long_wide: [max_root_bytes + 1:0]u16 = undefined;
        const long_len = try std.unicode.wtf8ToWtf16Le(&long_wide, first.root);
        long_wide[long_len] = 0;
        var short_wide: [max_root_bytes + 1]u16 = undefined;
        const short_len = GetShortPathNameW(long_wide[0..long_len :0], &short_wide, short_wide.len);
        if (short_len > 0 and short_len < short_wide.len and !std.mem.eql(u16, short_wide[0..short_len], long_wide[0..long_len])) {
            const short = try std.unicode.wtf16LeToWtf8Alloc(allocator, short_wide[0..short_len]);
            const via_short = try resolveWith(allocator, testing.io, tmp.dir, platform, identity_fixture, .{ .source = .flag, .path = short }, .{}, &failure);
            try testing.expectEqualStrings(first.root, via_short.root);
        }
    }
}

test "a root whose data folder is the default data directory uses the default data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    const platform = dirs.currentPlatform();
    const sep = std.fs.path.sep_str;
    var base_buffer: [max_root_bytes]u8 = undefined;
    const base = base_buffer[0..try tmp.dir.realPathFile(testing.io, ".", &base_buffer)];
    // The default data directory under the temp dir, for an identity whose
    // default data folder is `<parent>/data` on every platform: Windows
    // names it `%LOCALAPPDATA%\<bundle id>\Data` for any id, the others
    // name it after the bundle id itself.
    const identity: Identity = if (builtin.os.tag == .windows) identity_fixture else .{ .bundle_id = "data", .app_name = "demo" };
    const env: dirs.Env = switch (platform) {
        .windows => .{ .local_app_data = base },
        .macos => .{ .home = base },
        else => .{ .xdg_data_home = base },
    };
    var default_buffer: [max_dir_bytes]u8 = undefined;
    const default_data = try dirs.resolveOne(.{ .name = identity.bundle_id }, platform, env, .data, &default_buffer);
    const default_location = std.fs.path.dirname(default_data).?;
    var failure: Failure = .{};

    // The root at the default location, before the default data folder
    // exists, and on Windows in another case than the folders on disk.
    const spelling = if (builtin.os.tag == .windows)
        try std.mem.concat(allocator, u8, &.{ base, sep, "DEV.NATIVE_SDK.DEMO" })
    else
        default_location;
    const at_default = try resolveWith(allocator, testing.io, tmp.dir, platform, identity, .{ .source = .flag, .path = spelling }, env, &failure);
    try testing.expect(at_default.isOverride());
    try testing.expect(at_default.data_is_default);
    try testing.expect(at_default.usesDefaultData());

    // Any other root keeps its own data: a sibling, and the default data
    // folder itself (its data folder is one level further down).
    const sibling = try resolveWith(allocator, testing.io, tmp.dir, platform, identity, .{ .source = .env, .path = try std.mem.concat(allocator, u8, &.{ base, sep, "elsewhere" }) }, env, &failure);
    try testing.expect(!sibling.data_is_default);
    try testing.expect(!sibling.usesDefaultData());
    const inside = try resolveWith(allocator, testing.io, tmp.dir, platform, identity, .{ .source = .flag, .path = default_data }, env, &failure);
    try testing.expect(!inside.usesDefaultData());

    // No override is the default data, and never marked as an override's.
    const default_dirs = try resolveWith(allocator, testing.io, tmp.dir, platform, identity, null, env, &failure);
    try testing.expect(default_dirs.usesDefaultData());
    try testing.expect(!default_dirs.data_is_default);
}

test "an unusable override is refused, never replaced by the default" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    const platform = dirs.currentPlatform();
    var failure: Failure = .{};
    try testing.expectError(error.DataDirUnusable, resolveWith(allocator, testing.io, tmp.dir, platform, identity_fixture, .{ .source = .env, .path = "" }, .{}, &failure));
    try testing.expectEqual(Problem.empty, failure.problem);
    try testing.expectEqual(Source.env, failure.source);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a-file", .data = "x" });
    try testing.expectError(error.DataDirUnusable, resolveWith(allocator, testing.io, tmp.dir, platform, identity_fixture, .{ .source = .flag, .path = "a-file" }, .{}, &failure));
    try testing.expectEqual(Problem.not_a_directory, failure.problem);
    try testing.expectError(error.DataDirUnusable, resolveWith(allocator, testing.io, tmp.dir, platform, identity_fixture, .{ .source = .flag, .path = "a-file" ++ std.fs.path.sep_str ++ "below" }, .{}, &failure));
    try testing.expectEqual(Problem.not_a_directory, failure.problem);

    // A root whose layout folder is taken by a file cannot hold the data.
    try tmp.dir.createDirPath(testing.io, "blocked");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blocked" ++ std.fs.path.sep_str ++ "state", .data = "x" });
    try testing.expectError(error.DataDirUnusable, resolveWith(allocator, testing.io, tmp.dir, platform, identity_fixture, .{ .source = .flag, .path = "blocked" }, .{}, &failure));
    try testing.expectEqual(Problem.not_writable, failure.problem);
    try testing.expectEqualStrings("state", failure.folder);

    var message: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&message);
    try writer.print("{f}", .{failure});
    try testing.expect(std.mem.startsWith(u8, writer.buffered(), "the data directory --native-data-dir=\"blocked\" cannot be used: its state folder cannot be created ("));

    // Too long for the layout bound.
    const long = "x" ** 200;
    const deep = long ++ std.fs.path.sep_str ++ long ++ std.fs.path.sep_str ++ long ++ std.fs.path.sep_str ++ long ++ std.fs.path.sep_str ++ long;
    if (resolveWith(allocator, testing.io, tmp.dir, platform, identity_fixture, .{ .source = .flag, .path = deep }, .{}, &failure)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {
        // Windows may already refuse the creation itself (MAX_PATH
        // policy); elsewhere the directory is created and its canonical
        // path is over the bound (never a silently shortened root).
        if (comptime builtin.os.tag == .windows) {
            try testing.expect(failure.problem == .too_long or failure.problem == .cannot_create);
        } else {
            try testing.expectEqual(Problem.too_long, failure.problem);
        }
    }
}

test "web data store identifiers are stable per profile and distinct across profiles" {
    const a = webDataStoreIdentifier("/Users/a/profile-one/webview");
    try testing.expectEqualSlices(u8, &a, &webDataStoreIdentifier("/Users/a/profile-one/webview"));
    const b = webDataStoreIdentifier("/Users/a/profile-two/webview");
    try testing.expect(!std.mem.eql(u8, &a, &b));
    try testing.expectEqual(@as(u8, 0x80), a[6] & 0xf0);
    try testing.expectEqual(@as(u8, 0x80), a[8] & 0xc0);
}
