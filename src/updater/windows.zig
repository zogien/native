//! The Windows half of the updater (engine.zig) for apps installed by
//! the SDK's per-user setup program (src/windows_install):
//!
//!   <root>\<name>.exe    the launcher
//!   <root>\app\          the running version (this executable is app\bin\<name>.exe)
//!   <root>\app.next\     where a downloaded release is unpacked and staged
//!
//! Fetches and downloads go through WinHTTP with the user's proxy
//! settings. A staged release must carry this app's bundle id and
//! executable, the version its signed feed named, and an executable for
//! this architecture; the launcher moves it into place at the next
//! launch, or right after this process exits when the app asks to
//! restart.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.zig");
const feed = @import("feed.zig");
const install_config = @import("../windows_install/config.zig");
const install_switch = @import("../windows_install/switch.zig");
const win = @import("../windows_install/win32.zig");

const download_name = ".native-update.zip";
const launcher_in_image = "native-launcher.exe";

const Layout = struct {
    root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root_len: usize = 0,
    name_buffer: [install_config.max_text_bytes]u8 = undefined,
    name_len: usize = 0,
    executable_buffer: [install_config.max_text_bytes]u8 = undefined,
    executable_len: usize = 0,
    bundle_buffer: [128]u8 = undefined,
    bundle_len: usize = 0,
    unsupported: ?engine.Unsupported = .not_installed,

    fn root(self: *const Layout) []const u8 {
        return self.root_buffer[0..self.root_len];
    }
    fn name(self: *const Layout) []const u8 {
        return self.name_buffer[0..self.name_len];
    }
    fn executable(self: *const Layout) []const u8 {
        return self.executable_buffer[0..self.executable_len];
    }
    fn bundleId(self: *const Layout) []const u8 {
        return self.bundle_buffer[0..self.bundle_len];
    }
};

var layout: Layout = .{};

/// Finds the installation this executable runs from and returns the
/// backend. An executable outside an SDK installation (a portable copy,
/// a development build) reports `not_installed`.
pub fn backend(bundle_id: []const u8) engine.Backend {
    layout = .{};
    detect(bundle_id) catch {};
    return .{
        .context = &layout,
        .eligibility = eligibility,
        .staged_version = stagedVersion,
        .take_last_update = takeLastUpdate,
        .fetch = fetch,
        .stage = stage,
        .discard = discard,
        .prepare_restart = prepareRestart,
    };
}

fn detect(bundle_id: []const u8) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_path = executable_buffer[0..try std.process.executablePath(io, &executable_buffer)];
    const bin_dir = std.fs.path.dirname(executable_path) orelse return;
    const app_dir = std.fs.path.dirname(bin_dir) orelse return;
    const root = std.fs.path.dirname(app_dir) orelse return;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(bin_dir), "bin")) return;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(app_dir), install_switch.current)) return;

    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer root_dir.close(io);
    var config_buffer: [install_config.max_config_bytes]u8 = undefined;
    const config_bytes = try root_dir.readFile(io, install_switch.current ++ "\\" ++ install_config.file_name, &config_buffer);
    var parsed = try install_config.parse(std.heap.page_allocator, config_bytes);
    defer parsed.deinit();
    const config = parsed.value;
    if (!std.mem.eql(u8, config.bundle_id, bundle_id)) return;
    if (!std.ascii.eqlIgnoreCase(config.executable, std.fs.path.basename(executable_path))) return;
    var launcher_buffer: [install_config.max_text_bytes + 8]u8 = undefined;
    const launcher = try std.fmt.bufPrint(&launcher_buffer, "{s}.exe", .{config.name});
    root_dir.access(io, launcher, .{}) catch return;

    layout.root_len = copyInto(&layout.root_buffer, root);
    layout.name_len = copyInto(&layout.name_buffer, config.name);
    layout.executable_len = copyInto(&layout.executable_buffer, config.executable);
    layout.bundle_len = copyInto(&layout.bundle_buffer, config.bundle_id);
    layout.unsupported = null;

    // Writing beside app\ is how a release gets staged.
    root_dir.writeFile(io, .{ .sub_path = ".native-write-probe", .data = "" }) catch {
        layout.unsupported = .read_only;
        return;
    };
    root_dir.deleteFile(io, ".native-write-probe") catch {};
    refreshLauncher(io, root_dir, launcher);
}

/// A release can ship a newer launcher than the one setup installed.
/// The launcher exits as soon as it has started the app, so the app
/// replaces it here when the copies differ; a launcher still exiting
/// keeps its place until the next launch.
fn refreshLauncher(io: std.Io, root_dir: std.Io.Dir, launcher: []const u8) void {
    const bundled = root_dir.readFileAlloc(io, install_switch.current ++ "\\" ++ launcher_in_image, std.heap.page_allocator, .limited(16 * 1024 * 1024)) catch return;
    defer std.heap.page_allocator.free(bundled);
    const installed = root_dir.readFileAlloc(io, launcher, std.heap.page_allocator, .limited(16 * 1024 * 1024)) catch return;
    defer std.heap.page_allocator.free(installed);
    if (std.mem.eql(u8, bundled, installed)) return;
    var temp_buffer: [install_config.max_text_bytes + 16]u8 = undefined;
    const temp = std.fmt.bufPrint(&temp_buffer, "{s}.new", .{launcher}) catch return;
    root_dir.writeFile(io, .{ .sub_path = temp, .data = bundled }) catch return;
    root_dir.rename(temp, root_dir, launcher, io) catch {
        root_dir.deleteFile(io, temp) catch {};
    };
}

fn eligibility(context: *anyopaque) ?engine.Unsupported {
    const self: *Layout = @ptrCast(@alignCast(context));
    return self.unsupported;
}

fn stagedVersion(context: *anyopaque, output: []u8) ?[]const u8 {
    const self: *Layout = @ptrCast(@alignCast(context));
    if (self.unsupported != null) return null;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var root_dir = std.Io.Dir.cwd().openDir(io, self.root(), .{}) catch return null;
    defer root_dir.close(io);
    root_dir.access(io, install_switch.staged ++ "\\" ++ install_switch.staged_marker, .{}) catch return null;
    var config_buffer: [install_config.max_config_bytes]u8 = undefined;
    const config_bytes = root_dir.readFile(io, install_switch.staged ++ "\\" ++ install_config.file_name, &config_buffer) catch return null;
    var parsed = install_config.parse(std.heap.page_allocator, config_bytes) catch return null;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.bundle_id, self.bundleId())) return null;
    return output[0..copyInto(output, parsed.value.version)];
}

fn takeLastUpdate(context: *anyopaque, output: []u8) ?[]const u8 {
    const self: *Layout = @ptrCast(@alignCast(context));
    if (self.root_len == 0) return null;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var root_dir = std.Io.Dir.cwd().openDir(io, self.root(), .{}) catch return null;
    defer root_dir.close(io);
    var buffer: [256]u8 = undefined;
    const text = root_dir.readFile(io, install_switch.update_result, &buffer) catch return null;
    root_dir.deleteFile(io, install_switch.update_result) catch {};
    const line = std.mem.trim(u8, text, " \r\n");
    const prefix = "updated ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return output[0..copyInto(output, line[prefix.len..])];
}

fn discard(context: *anyopaque) void {
    const self: *Layout = @ptrCast(@alignCast(context));
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var root_dir = std.Io.Dir.cwd().openDir(io, self.root(), .{}) catch return;
    defer root_dir.close(io);
    install_switch.clearStaged(root_dir, io) catch {};
}

fn prepareRestart(context: *anyopaque) bool {
    const self: *Layout = @ptrCast(@alignCast(context));
    var launcher_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const launcher = std.fmt.bufPrint(&launcher_buffer, "{s}\\{s}.exe", .{ self.root(), self.name() }) catch return false;
    var arguments_buffer: [64]u8 = undefined;
    const arguments = std.fmt.bufPrint(&arguments_buffer, "--apply-after {d}", .{win.GetCurrentProcessId()}) catch return false;
    return startDetached(launcher, arguments);
}

fn startDetached(executable: []const u8, arguments: []const u8) bool {
    var command_buffer: [std.Io.Dir.max_path_bytes + 128]u16 = undefined;
    var command: std.ArrayList(u16) = .initBuffer(&command_buffer);
    var executable_buffer: [std.Io.Dir.max_path_bytes]u16 = undefined;
    const executable_len = std.unicode.wtf8ToWtf16Le(&executable_buffer, executable) catch return false;
    if (executable_len >= executable_buffer.len) return false;
    executable_buffer[executable_len] = 0;
    command.appendBounded('"') catch return false;
    command.appendSliceBounded(executable_buffer[0..executable_len]) catch return false;
    command.appendSliceBounded(&.{ '"', ' ' }) catch return false;
    var arguments_buffer: [128]u16 = undefined;
    const arguments_len = std.unicode.wtf8ToWtf16Le(&arguments_buffer, arguments) catch return false;
    command.appendSliceBounded(arguments_buffer[0..arguments_len]) catch return false;
    command.appendBounded(0) catch return false;
    var startup: win.STARTUPINFOW = .{};
    var process: win.PROCESS_INFORMATION = undefined;
    const command_line: [*:0]u16 = @ptrCast(command.items.ptr);
    if (win.CreateProcessW(@ptrCast(&executable_buffer), command_line, null, null, 0, win.CREATE_UNICODE_ENVIRONMENT, null, null, &startup, &process) == 0) return false;
    _ = win.CloseHandle(process.hThread);
    _ = win.CloseHandle(process.hProcess);
    return true;
}

// ---------------------------------------------------------------------------
// HTTP

fn fetch(context: *anyopaque, url: []const u8, policy: feed.UrlPolicy, output: []u8) engine.FetchError![]const u8 {
    _ = context;
    var sink: BufferSink = .{ .buffer = output };
    get(url, policy, sink.writer(), null) catch |err| return switch (err) {
        error.HttpStatus => error.HttpStatus,
        error.TooLarge => error.TooLarge,
        else => error.Network,
    };
    return output[0..sink.len];
}

fn stage(context: *anyopaque, release: *const engine.Release, policy: feed.UrlPolicy, progress: *engine.Progress) engine.StageError!void {
    const self: *Layout = @ptrCast(@alignCast(context));
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var root_dir = std.Io.Dir.cwd().openDir(io, self.root(), .{}) catch return error.Disk;
    defer root_dir.close(io);
    defer root_dir.deleteFile(io, download_name) catch {};

    {
        var file = root_dir.createFile(io, download_name, .{ .truncate = true }) catch return error.Disk;
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        var sink: FileSink = .{ .file_writer = &writer, .limit = release.archive_bytes, .progress = progress };
        get(release.url(), policy, sink.writer(), progress) catch |err| return switch (err) {
            error.HttpStatus => error.HttpStatus,
            error.TooLarge => error.ArchiveSize,
            error.Cancelled => error.Cancelled,
            error.Disk => error.Disk,
            else => error.Network,
        };
        writer.interface.flush() catch return error.Disk;
        if (sink.received != release.archive_bytes) return error.ArchiveSize;
        var digest: [32]u8 = undefined;
        sink.hasher.final(&digest);
        const actual = std.fmt.bytesToHex(digest, .lower);
        if (!std.crypto.timing_safe.eql([64]u8, actual, release.sha256)) return error.ArchiveDigest;
    }

    install_switch.clearStaged(root_dir, io) catch return error.Disk;
    root_dir.createDirPath(io, install_switch.staged) catch return error.Disk;
    {
        var staged = root_dir.openDir(io, install_switch.staged, .{}) catch return error.Disk;
        defer staged.close(io);
        var archive = root_dir.openFile(io, download_name, .{}) catch return error.Disk;
        defer archive.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var reader = archive.reader(io, &buffer);
        std.zip.extract(staged, &reader, .{}) catch {
            install_switch.clearStaged(root_dir, io) catch {};
            return error.ArchiveInvalid;
        };
    }
    validateStaged(io, root_dir, self, release) catch {
        install_switch.clearStaged(root_dir, io) catch {};
        return error.ArchiveInvalid;
    };
    install_switch.markStaged(root_dir, io) catch return error.Disk;
}

/// A staged release must be this app, at the version the signed feed
/// named, with its executable built for this architecture.
fn validateStaged(io: std.Io, root_dir: std.Io.Dir, self: *const Layout, release: *const engine.Release) !void {
    var config_buffer: [install_config.max_config_bytes]u8 = undefined;
    const config_bytes = try root_dir.readFile(io, install_switch.staged ++ "\\" ++ install_config.file_name, &config_buffer);
    var parsed = try install_config.parse(std.heap.page_allocator, config_bytes);
    defer parsed.deinit();
    const config = parsed.value;
    if (!std.mem.eql(u8, config.bundle_id, self.bundleId())) return error.WrongApp;
    if (!std.mem.eql(u8, config.version, release.version())) return error.WrongVersion;
    if (!std.mem.eql(u8, config.name, self.name()) or !std.ascii.eqlIgnoreCase(config.executable, self.executable())) return error.WrongExecutable;
    try root_dir.access(io, install_switch.staged ++ "\\" ++ launcher_in_image, .{});
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable = try std.fmt.bufPrint(&path_buffer, "{s}\\bin\\{s}", .{ install_switch.staged, config.executable });
    var header: [4096]u8 = undefined;
    const header_len = (try root_dir.readFile(io, executable, &header)).len;
    if (peMachine(header[0..header_len]) != expected_machine) return error.WrongArchitecture;
}

const expected_machine: u16 = switch (builtin.cpu.arch) {
    .aarch64 => 0xaa64,
    else => 0x8664,
};

pub fn peMachine(header: []const u8) ?u16 {
    if (header.len < 0x40 or header[0] != 'M' or header[1] != 'Z') return null;
    const pe_offset: usize = std.mem.readInt(u32, header[0x3c..0x40], .little);
    if (pe_offset + 6 > header.len or !std.mem.eql(u8, header[pe_offset..][0..4], "PE\x00\x00")) return null;
    return std.mem.readInt(u16, header[pe_offset + 4 ..][0..2], .little);
}

const Sink = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, bytes: []const u8) GetError!void,
};

const BufferSink = struct {
    buffer: []u8,
    len: usize = 0,

    fn writer(self: *BufferSink) Sink {
        return .{ .context = self, .write = write };
    }
    fn write(context: *anyopaque, bytes: []const u8) GetError!void {
        const self: *BufferSink = @ptrCast(@alignCast(context));
        if (bytes.len > self.buffer.len - self.len) return error.TooLarge;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

const FileSink = struct {
    file_writer: *std.Io.File.Writer,
    limit: u64,
    progress: *engine.Progress,
    received: u64 = 0,
    hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),

    fn writer(self: *FileSink) Sink {
        return .{ .context = self, .write = write };
    }
    fn write(context: *anyopaque, bytes: []const u8) GetError!void {
        const self: *FileSink = @ptrCast(@alignCast(context));
        if (bytes.len > self.limit - self.received) return error.TooLarge;
        self.file_writer.interface.writeAll(bytes) catch return error.Disk;
        self.hasher.update(bytes);
        self.received += bytes.len;
        self.progress.report(self.received);
    }
};

const GetError = error{ Network, HttpStatus, TooLarge, Cancelled, Disk, InvalidUrl };

/// GETs `url` through WinHTTP, honoring the user's proxy settings, and
/// streams the body to `sink`. Redirects may not leave HTTPS (WinHTTP's
/// default); a loopback http:// request, allowed only for testing, may
/// be redirected anywhere, so its final URL is held to `policy`.
fn get(url: []const u8, policy: feed.UrlPolicy, sink: Sink, progress: ?*engine.Progress) GetError!void {
    if (!feed.urlAllowed(url, policy)) return error.InvalidUrl;
    var url_buffer: [feed.max_archive_url_bytes + 1]u16 = undefined;
    const url_len = std.unicode.wtf8ToWtf16Le(&url_buffer, url) catch return error.InvalidUrl;
    if (url_len >= url_buffer.len) return error.InvalidUrl;
    url_buffer[url_len] = 0;
    var parts: http.URL_COMPONENTS = .{ .dwHostNameLength = std.math.maxInt(u32), .dwUrlPathLength = std.math.maxInt(u32), .dwExtraInfoLength = std.math.maxInt(u32) };
    if (http.WinHttpCrackUrl(@ptrCast(&url_buffer), @intCast(url_len), 0, &parts) == 0) return error.InvalidUrl;
    var host_buffer: [256]u16 = undefined;
    if (parts.dwHostNameLength + 1 > host_buffer.len) return error.InvalidUrl;
    @memcpy(host_buffer[0..parts.dwHostNameLength], parts.lpszHostName.?[0..parts.dwHostNameLength]);
    host_buffer[parts.dwHostNameLength] = 0;
    var object_buffer: [feed.max_archive_url_bytes + 1]u16 = undefined;
    const object_len = parts.dwUrlPathLength + parts.dwExtraInfoLength;
    if (object_len + 1 > object_buffer.len) return error.InvalidUrl;
    if (parts.dwUrlPathLength > 0) @memcpy(object_buffer[0..parts.dwUrlPathLength], parts.lpszUrlPath.?[0..parts.dwUrlPathLength]);
    if (parts.dwExtraInfoLength > 0) @memcpy(object_buffer[parts.dwUrlPathLength..object_len], parts.lpszExtraInfo.?[0..parts.dwExtraInfoLength]);
    object_buffer[object_len] = 0;

    const agent = std.unicode.utf8ToUtf16LeStringLiteral("native-sdk-updater");
    const session = http.WinHttpOpen(agent, http.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse
        http.WinHttpOpen(agent, http.WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, null, null, 0) orelse return error.Network;
    defer _ = http.WinHttpCloseHandle(session);
    _ = http.WinHttpSetTimeouts(session, 30_000, 30_000, 30_000, 60_000);
    const connection = http.WinHttpConnect(session, @ptrCast(&host_buffer), parts.nPort, 0) orelse return error.Network;
    defer _ = http.WinHttpCloseHandle(connection);
    const secure = parts.nScheme == http.INTERNET_SCHEME_HTTPS;
    const request = http.WinHttpOpenRequest(connection, std.unicode.utf8ToUtf16LeStringLiteral("GET"), @ptrCast(&object_buffer), null, null, null, if (secure) http.WINHTTP_FLAG_SECURE else 0) orelse return error.Network;
    defer _ = http.WinHttpCloseHandle(request);
    if (http.WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == 0) return error.Network;
    if (http.WinHttpReceiveResponse(request, null) == 0) return error.Network;

    if (!secure) {
        var final_buffer: [feed.max_archive_url_bytes + 1]u16 = undefined;
        var final_size: u32 = @sizeOf(@TypeOf(final_buffer));
        if (http.WinHttpQueryOption(request, http.WINHTTP_OPTION_URL, &final_buffer, &final_size) == 0) return error.InvalidUrl;
        var final_utf8: [feed.max_archive_url_bytes * 3]u8 = undefined;
        const final_units = @min(final_size / 2, final_buffer.len);
        const final_len = std.unicode.wtf16LeToWtf8(&final_utf8, final_buffer[0..final_units]);
        if (!feed.urlAllowed(std.mem.trimEnd(u8, final_utf8[0..final_len], &.{0}), policy)) return error.InvalidUrl;
    }
    var status: u32 = 0;
    var status_size: u32 = @sizeOf(u32);
    if (http.WinHttpQueryHeaders(request, http.WINHTTP_QUERY_STATUS_CODE | http.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null) == 0) return error.Network;
    if (status != 200) return error.HttpStatus;

    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        if (progress) |active| if (active.cancelled()) return error.Cancelled;
        var read: u32 = 0;
        if (http.WinHttpReadData(request, &chunk, chunk.len, &read) == 0) return error.Network;
        if (read == 0) break;
        try sink.write(sink.context, chunk[0..read]);
    }
}

const http = struct {
    const HINTERNET = *opaque {};
    const BOOL = i32;

    const URL_COMPONENTS = extern struct {
        dwStructSize: u32 = @sizeOf(URL_COMPONENTS),
        lpszScheme: ?[*]u16 = null,
        dwSchemeLength: u32 = 0,
        nScheme: i32 = 0,
        lpszHostName: ?[*]u16 = null,
        dwHostNameLength: u32 = 0,
        nPort: u16 = 0,
        lpszUserName: ?[*]u16 = null,
        dwUserNameLength: u32 = 0,
        lpszPassword: ?[*]u16 = null,
        dwPasswordLength: u32 = 0,
        lpszUrlPath: ?[*]u16 = null,
        dwUrlPathLength: u32 = 0,
        lpszExtraInfo: ?[*]u16 = null,
        dwExtraInfoLength: u32 = 0,
    };

    const WINHTTP_ACCESS_TYPE_DEFAULT_PROXY: u32 = 0;
    const WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY: u32 = 4;
    const WINHTTP_FLAG_SECURE: u32 = 0x0080_0000;
    const WINHTTP_QUERY_STATUS_CODE: u32 = 19;
    const WINHTTP_QUERY_FLAG_NUMBER: u32 = 0x2000_0000;
    const WINHTTP_OPTION_URL: u32 = 34;
    const INTERNET_SCHEME_HTTPS: i32 = 2;

    extern "winhttp" fn WinHttpOpen(pszAgentW: ?[*:0]const u16, dwAccessType: u32, pszProxyW: ?[*:0]const u16, pszProxyBypassW: ?[*:0]const u16, dwFlags: u32) callconv(.winapi) ?HINTERNET;
    extern "winhttp" fn WinHttpCrackUrl(pwszUrl: [*:0]const u16, dwUrlLength: u32, dwFlags: u32, lpUrlComponents: *URL_COMPONENTS) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpConnect(hSession: HINTERNET, pswzServerName: [*:0]const u16, nServerPort: u16, dwReserved: u32) callconv(.winapi) ?HINTERNET;
    extern "winhttp" fn WinHttpOpenRequest(hConnect: HINTERNET, pwszVerb: ?[*:0]const u16, pwszObjectName: ?[*:0]const u16, pwszVersion: ?[*:0]const u16, pwszReferrer: ?[*:0]const u16, ppwszAcceptTypes: ?*const ?[*:0]const u16, dwFlags: u32) callconv(.winapi) ?HINTERNET;
    extern "winhttp" fn WinHttpSetTimeouts(hInternet: HINTERNET, nResolveTimeout: i32, nConnectTimeout: i32, nSendTimeout: i32, nReceiveTimeout: i32) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpSendRequest(hRequest: HINTERNET, lpszHeaders: ?[*]const u16, dwHeadersLength: u32, lpOptional: ?*anyopaque, dwOptionalLength: u32, dwTotalLength: u32, dwContext: usize) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpReceiveResponse(hRequest: HINTERNET, lpReserved: ?*anyopaque) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpQueryHeaders(hRequest: HINTERNET, dwInfoLevel: u32, pwszName: ?[*:0]const u16, lpBuffer: ?*anyopaque, lpdwBufferLength: *u32, lpdwIndex: ?*u32) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpQueryOption(hInternet: HINTERNET, dwOption: u32, lpBuffer: ?*anyopaque, lpdwBufferLength: *u32) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpReadData(hRequest: HINTERNET, lpBuffer: [*]u8, dwNumberOfBytesToRead: u32, lpdwNumberOfBytesRead: *u32) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpCloseHandle(hInternet: HINTERNET) callconv(.winapi) BOOL;
};

fn copyInto(buffer: []u8, value: []const u8) usize {
    const length = @min(buffer.len, value.len);
    @memcpy(buffer[0..length], value[0..length]);
    return length;
}

test "the backend compiles for every Windows build" {
    if (comptime builtin.os.tag == .windows) _ = &backend;
}

test "the PE machine field names the executable's architecture" {
    var header = [_]u8{0} ** 0x100;
    header[0] = 'M';
    header[1] = 'Z';
    std.mem.writeInt(u32, header[0x3c..0x40], 0x80, .little);
    @memcpy(header[0x80..0x84], "PE\x00\x00");
    std.mem.writeInt(u16, header[0x84..0x86], 0xaa64, .little);
    try std.testing.expectEqual(@as(?u16, 0xaa64), peMachine(&header));
    try std.testing.expectEqual(@as(?u16, null), peMachine("MZ-short"));
}
