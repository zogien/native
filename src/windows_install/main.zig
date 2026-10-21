//! The Windows setup program, launcher and uninstaller of an installed
//! Native SDK app: one small program in three roles.
//!
//!   setup.exe            this program with an install payload appended:
//!                        installs the app for the current user, under
//!                        %LOCALAPPDATA%\Programs\<display name>.
//!   <root>\<name>.exe    the launcher at a stable path: finishes a staged
//!                        version switch while the app is not running, then
//!                        starts app\bin\<executable> with the same
//!                        arguments. The Start menu shortcut, file
//!                        associations and URL schemes point here.
//!   <name>.exe --uninstall [--silent]
//!                        removes the shortcut, the registry entries and the
//!                        install folder. User data under the app's data
//!                        directories stays.

const std = @import("std");
const builtin = @import("builtin");
const install_config = @import("config.zig");
const payload = @import("payload.zig");
const install_switch = @import("switch.zig");
const win = @import("win32.zig");

const InstallConfig = install_config.InstallConfig;

pub const launcher_file_in_image = "native-launcher.exe";
const setup_zip_name = ".native-setup.zip";

const exit_ok: u8 = 0;
const exit_failed: u8 = 1;
const exit_app_running: u8 = 2;
const exit_cancelled: u8 = 3;

const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    silent: bool,
    title: []const u8,
};

pub fn main(init: std.process.Init) u8 {
    if (comptime builtin.os.tag != .windows) @compileError("the Native SDK setup program targets Windows");
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    var iterator = std.process.Args.Iterator.initAllocator(init.minimal.args, arena) catch return exit_failed;
    while (iterator.next()) |argument| argv.append(arena, arena.dupe(u8, argument) catch return exit_failed) catch return exit_failed;
    const args = if (argv.items.len > 0) argv.items[1..] else argv.items;

    var context: Context = .{ .gpa = arena, .io = init.io, .silent = hasFlag(args, "--silent"), .title = "Setup" };
    const own_path = ownPath(arena) catch return exit_failed;

    if (args.len >= 1 and std.mem.eql(u8, args[0], "--uninstall-finish")) {
        return uninstallFinish(&context, args[1..]) catch |err| fail(&context, "The app could not be removed completely ({s}).", .{@errorName(err)});
    }
    if (args.len >= 1 and std.mem.eql(u8, args[0], "--uninstall")) {
        return uninstall(&context, own_path) catch |err| fail(&context, "The app could not be uninstalled ({s}).", .{@errorName(err)});
    }
    if (readSetupPayload(&context, own_path) catch |err| return fail(&context, "This installer could not be read ({s}).", .{@errorName(err)})) |setup| {
        return install(&context, own_path, setup) catch |err| fail(&context, "The app could not be installed ({s}).", .{@errorName(err)});
    }
    return launch(&context, own_path) catch |err| fail(&context, "The app could not be started ({s}).", .{@errorName(err)});
}

// ---------------------------------------------------------------------------
// Launcher

fn launch(context: *Context, own_path: []const u8) !u8 {
    const root_path = std.fs.path.dirname(own_path) orelse return error.InvalidInstallRoot;
    var root = try std.Io.Dir.cwd().openDir(context.io, root_path, .{});
    defer root.close(context.io);

    // A staged version moves into place only while nothing runs from app\:
    // Windows would rename the directory under a running app.
    if (!try appRunning(context, root_path)) {
        _ = install_switch.applyStaged(root, context.io) catch {};
    }

    const config = try readInstalledConfig(context, root);
    context.title = config.display_name;
    const executable = try std.fs.path.join(context.gpa, &.{ root_path, install_switch.current, "bin", config.executable });
    const tail = commandLineTail(std.mem.span(win.GetCommandLineW()));
    const process = try startProcess(context.gpa, executable, tail);
    _ = win.AllowSetForegroundWindow(process.dwProcessId);
    _ = win.CloseHandle(process.hThread);
    _ = win.CloseHandle(process.hProcess);
    return exit_ok;
}

// ---------------------------------------------------------------------------
// Setup

const Setup = struct {
    trailer: payload.Trailer,
    config_bytes: []const u8,
};

fn readSetupPayload(context: *Context, own_path: []const u8) !?Setup {
    var file = try std.Io.Dir.cwd().openFile(context.io, own_path, .{});
    defer file.close(context.io);
    const size = (try file.stat(context.io)).size;
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(context.io, &buffer);

    var headers: [4096]u8 = undefined;
    const header_len: usize = @intCast(@min(size, headers.len));
    try reader.seekTo(0);
    try reader.interface.readSliceAll(headers[0..header_len]);
    const end = payload.dataEnd(headers[0..header_len], size);
    const tail_len: usize = @intCast(@min(end, payload.trailer_len + 7));
    var tail: [payload.trailer_len + 7]u8 = undefined;
    try reader.seekTo(end - tail_len);
    try reader.interface.readSliceAll(tail[0..tail_len]);
    const trailer = payload.find(tail[0..tail_len], end) orelse return null;
    if (trailer.config_size > install_config.max_config_bytes) return error.InvalidInstaller;

    const config_bytes = try context.gpa.alloc(u8, @intCast(trailer.config_size));
    try reader.seekTo(trailer.config_offset);
    try reader.interface.readSliceAll(config_bytes);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(config_bytes);
    var remaining = trailer.zip_size;
    var chunk: [64 * 1024]u8 = undefined;
    while (remaining > 0) {
        const count: usize = @intCast(@min(remaining, chunk.len));
        try reader.interface.readSliceAll(chunk[0..count]);
        hasher.update(chunk[0..count]);
        remaining -= count;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    if (!std.crypto.timing_safe.eql([32]u8, digest, trailer.sha256)) return error.InstallerDamaged;
    return .{ .trailer = trailer, .config_bytes = config_bytes };
}

fn install(context: *Context, own_path: []const u8, setup: Setup) !u8 {
    var parsed = try install_config.parse(context.gpa, setup.config_bytes);
    defer parsed.deinit();
    const config = parsed.value;
    context.title = config.display_name;

    var uninstall_key_buffer: [512]u8 = undefined;
    const uninstall_key = try install_config.uninstallKey(&uninstall_key_buffer, config.bundle_id);
    const root_path = try installRoot(context, config, uninstall_key);
    try std.Io.Dir.cwd().createDirPath(context.io, root_path);
    var root = try std.Io.Dir.cwd().openDir(context.io, root_path, .{});
    defer root.close(context.io);
    if (readInstalledConfig(context, root)) |installed| {
        if (!std.mem.eql(u8, installed.bundle_id, config.bundle_id)) return error.FolderHoldsAnotherApp;
    } else |_| {}

    while (try appRunning(context, root_path)) {
        if (context.silent) return exit_app_running;
        const text = try std.fmt.allocPrint(context.gpa, "{s} is running. Close it, then choose Retry to continue.", .{config.display_name});
        if (messageBox(context, text, win.MB_RETRYCANCEL | win.MB_ICONQUESTION) != win.IDRETRY) return exit_cancelled;
    }

    // Stage the new version beside the current one, then switch.
    try install_switch.recover(root, context.io);
    try install_switch.clearStaged(root, context.io);
    try extractImage(context, own_path, setup.trailer, root);
    try install_switch.markStaged(root, context.io);
    switch (try install_switch.applyStaged(root, context.io)) {
        .switched => {},
        .busy => return error.InstallFolderInUse,
        .nothing_staged => return error.InstallImageMissing,
    }
    if (root.access(context.io, install_switch.previous, .{})) |_| {
        root.deleteTree(context.io, install_switch.previous) catch {};
    } else |_| {}

    const launcher_path = try launcherPath(context.gpa, root_path, config.name);
    try installLauncher(context, root_path, launcher_path);
    const shortcut_path = try registerInstall(context, config, root, root_path, launcher_path, uninstall_key);
    _ = shortcut_path;

    if (!context.silent) {
        const process = try startProcess(context.gpa, launcher_path, &.{});
        _ = win.AllowSetForegroundWindow(process.dwProcessId);
        _ = win.CloseHandle(process.hThread);
        _ = win.CloseHandle(process.hProcess);
    }
    return exit_ok;
}

/// Where the app installs: the folder its existing installation recorded,
/// or %LOCALAPPDATA%\Programs\<display name> for a first install.
fn installRoot(context: *Context, config: InstallConfig, uninstall_key: []const u8) ![]const u8 {
    if (try queryRegistryString(context.gpa, uninstall_key, "InstallLocation")) |location| {
        if (std.fs.path.isAbsolute(location)) {
            if (std.Io.Dir.cwd().openDir(context.io, location, .{})) |dir_value| {
                var dir = dir_value;
                defer dir.close(context.io);
                if (readInstalledConfig(context, dir)) |installed| {
                    if (std.mem.eql(u8, installed.bundle_id, config.bundle_id)) return location;
                } else |_| {}
            } else |_| {}
        }
    }
    const local_app_data = try knownFolder(context.gpa, &win.FOLDERID_LocalAppData);
    var folder_buffer: [install_config.max_text_bytes]u8 = undefined;
    const folder = try install_config.installFolderName(&folder_buffer, config.display_name, config.bundle_id);
    return std.fs.path.join(context.gpa, &.{ local_app_data, "Programs", folder });
}

fn extractImage(context: *Context, own_path: []const u8, trailer: payload.Trailer, root: std.Io.Dir) !void {
    {
        var source = try std.Io.Dir.cwd().openFile(context.io, own_path, .{});
        defer source.close(context.io);
        var read_buffer: [64 * 1024]u8 = undefined;
        var reader = source.reader(context.io, &read_buffer);
        try reader.seekTo(trailer.zip_offset);
        var destination = try root.createFile(context.io, setup_zip_name, .{ .truncate = true });
        defer destination.close(context.io);
        var write_buffer: [64 * 1024]u8 = undefined;
        var writer = destination.writer(context.io, &write_buffer);
        var remaining = trailer.zip_size;
        var chunk: [64 * 1024]u8 = undefined;
        while (remaining > 0) {
            const count: usize = @intCast(@min(remaining, chunk.len));
            try reader.interface.readSliceAll(chunk[0..count]);
            try writer.interface.writeAll(chunk[0..count]);
            remaining -= count;
        }
        try writer.interface.flush();
    }
    defer root.deleteFile(context.io, setup_zip_name) catch {};

    try root.createDirPath(context.io, install_switch.staged);
    var staged = try root.openDir(context.io, install_switch.staged, .{});
    defer staged.close(context.io);
    var archive = try root.openFile(context.io, setup_zip_name, .{});
    defer archive.close(context.io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = archive.reader(context.io, &buffer);
    try std.zip.extract(staged, &reader, .{});
}

/// Copies the launcher the image carries to the stable <root>\<name>.exe.
fn installLauncher(context: *Context, root_path: []const u8, launcher_path: []const u8) !void {
    const source = try std.fs.path.join(context.gpa, &.{ root_path, install_switch.current, launcher_file_in_image });
    const source_w = try wide(context.gpa, source);
    const target_w = try wide(context.gpa, launcher_path);
    var attempt: usize = 0;
    while (win.CopyFileW(source_w, target_w, 0) == 0) : (attempt += 1) {
        if (attempt == 20) return error.LauncherInUse;
        win.Sleep(250);
    }
}

/// Writes the shortcut, the uninstall entry and the app's registry values.
/// Returns the shortcut path.
fn registerInstall(context: *Context, config: InstallConfig, root: std.Io.Dir, root_path: []const u8, launcher_path: []const u8, uninstall_key: []const u8) ![]const u8 {
    const programs = try knownFolder(context.gpa, &win.FOLDERID_Programs);
    var folder_buffer: [install_config.max_text_bytes]u8 = undefined;
    const shortcut_name = try install_config.installFolderName(&folder_buffer, config.display_name, config.bundle_id);
    const shortcut_path = try std.fmt.allocPrint(context.gpa, "{s}\\{s}.lnk", .{ programs, shortcut_name });
    if (try queryRegistryString(context.gpa, uninstall_key, "NativeSdkShortcut")) |previous| {
        if (!std.ascii.eqlIgnoreCase(previous, shortcut_path)) deleteFileIfPresent(context.gpa, previous);
    }
    const icon_path = if (config.icon.len > 0)
        try std.fs.path.join(context.gpa, &.{ root_path, install_switch.current, config.icon })
    else
        launcher_path;
    try createShortcut(context.gpa, shortcut_path, launcher_path, root_path, icon_path, config.display_name, config.bundle_id);

    const uninstall_command = try std.fmt.allocPrint(context.gpa, "\"{s}\" --uninstall", .{launcher_path});
    const quiet_command = try std.fmt.allocPrint(context.gpa, "\"{s}\" --uninstall --silent", .{launcher_path});
    try setRegistryString(context.gpa, uninstall_key, "DisplayName", config.display_name);
    try setRegistryString(context.gpa, uninstall_key, "DisplayVersion", config.version);
    if (config.publisher.len > 0) try setRegistryString(context.gpa, uninstall_key, "Publisher", config.publisher);
    try setRegistryString(context.gpa, uninstall_key, "DisplayIcon", icon_path);
    try setRegistryString(context.gpa, uninstall_key, "InstallLocation", root_path);
    try setRegistryString(context.gpa, uninstall_key, "UninstallString", uninstall_command);
    try setRegistryString(context.gpa, uninstall_key, "QuietUninstallString", quiet_command);
    try setRegistryString(context.gpa, uninstall_key, "NativeSdkShortcut", shortcut_path);
    try setRegistryDword(context.gpa, uninstall_key, "NoModify", 1);
    try setRegistryDword(context.gpa, uninstall_key, "NoRepair", 1);
    try setRegistryDword(context.gpa, uninstall_key, "EstimatedSize", @intCast(@min(try directorySizeKiB(context, root), std.math.maxInt(u32))));

    for (config.registry) |entry| {
        const with_launcher = try std.mem.replaceOwned(u8, context.gpa, entry.value, install_config.launcher_placeholder, launcher_path);
        const value = try std.mem.replaceOwned(u8, context.gpa, with_launcher, install_config.install_placeholder, root_path);
        try setRegistryString(context.gpa, entry.key, entry.name, value);
    }
    if (config.registry.len > 0) win.SHChangeNotify(win.SHCNE_ASSOCCHANGED, win.SHCNF_IDLIST, null, null);
    return shortcut_path;
}

fn directorySizeKiB(context: *Context, root: std.Io.Dir) !u64 {
    var dir = try root.openDir(context.io, install_switch.current, .{ .iterate = true });
    defer dir.close(context.io);
    var walker = try dir.walk(context.gpa);
    defer walker.deinit();
    var total: u64 = 0;
    while (try walker.next(context.io)) |entry| {
        if (entry.kind != .file) continue;
        total += (dir.statFile(context.io, entry.path, .{}) catch continue).size;
    }
    return (total + 1023) / 1024;
}

// ---------------------------------------------------------------------------
// Uninstall

fn uninstall(context: *Context, own_path: []const u8) !u8 {
    const root_path = std.fs.path.dirname(own_path) orelse return error.InvalidInstallRoot;
    var root = try std.Io.Dir.cwd().openDir(context.io, root_path, .{});
    defer root.close(context.io);
    const config = try readInstalledConfig(context, root);
    context.title = config.display_name;

    if (!context.silent) {
        const text = try std.fmt.allocPrint(context.gpa, "Remove {s} from this computer? Your documents and app data are kept.", .{config.display_name});
        if (messageBox(context, text, win.MB_YESNO | win.MB_ICONQUESTION) != win.IDYES) return exit_cancelled;
    }
    while (try appRunning(context, root_path)) {
        if (context.silent) return exit_app_running;
        const text = try std.fmt.allocPrint(context.gpa, "{s} is running. Close it, then choose Retry to continue.", .{config.display_name});
        if (messageBox(context, text, win.MB_RETRYCANCEL | win.MB_ICONQUESTION) != win.IDRETRY) return exit_cancelled;
    }

    // This program runs from the folder it removes, so a copy in the
    // temporary directory finishes the job once this process exits.
    var temp_buffer: [win.MAX_PATH_WIDE]u16 = undefined;
    const temp_len = win.GetTempPathW(temp_buffer.len, &temp_buffer);
    if (temp_len == 0 or temp_len >= temp_buffer.len) return error.NoTempDirectory;
    const temp_dir = try std.unicode.wtf16LeToWtf8Alloc(context.gpa, temp_buffer[0..temp_len]);
    const helper = try std.fmt.allocPrint(context.gpa, "{s}{s}-uninstall-{d}.exe", .{ temp_dir, config.bundle_id, win.GetCurrentProcessId() });
    if (win.CopyFileW(try wide(context.gpa, own_path), try wide(context.gpa, helper), 0) == 0) return error.UninstallHelperCopyFailed;
    const helper_args = try std.fmt.allocPrint(context.gpa, "--uninstall-finish \"{s}\" {d}{s}", .{ root_path, win.GetCurrentProcessId(), if (context.silent) " --silent" else "" });
    const process = try startProcess(context.gpa, helper, try wideSlice(context.gpa, helper_args));
    _ = win.CloseHandle(process.hThread);
    _ = win.CloseHandle(process.hProcess);
    return exit_ok;
}

fn uninstallFinish(context: *Context, args: []const []const u8) !u8 {
    if (args.len < 2) return error.InvalidArguments;
    const root_path = args[0];
    const parent = std.fmt.parseInt(win.DWORD, args[1], 10) catch return error.InvalidArguments;
    if (win.OpenProcess(win.SYNCHRONIZE, 0, parent)) |handle| {
        _ = win.WaitForSingleObject(handle, 10_000);
        _ = win.CloseHandle(handle);
    }
    if (!std.fs.path.isAbsolute(root_path)) return error.InvalidInstallRoot;
    var root = try std.Io.Dir.cwd().openDir(context.io, root_path, .{});
    const config = readInstalledConfig(context, root) catch |err| {
        root.close(context.io);
        return err;
    };
    root.close(context.io);
    context.title = config.display_name;

    var uninstall_key_buffer: [512]u8 = undefined;
    const uninstall_key = try install_config.uninstallKey(&uninstall_key_buffer, config.bundle_id);
    if (try queryRegistryString(context.gpa, uninstall_key, "NativeSdkShortcut")) |shortcut| deleteFileIfPresent(context.gpa, shortcut);
    for (config.registry_cleanup) |entry| {
        if (entry.name) |name| {
            if (entry.if_value) |expected| {
                if (try queryRegistryString(context.gpa, entry.key, name)) |current| {
                    if (std.mem.eql(u8, current, expected)) deleteRegistryValue(context.gpa, entry.key, name);
                }
            } else deleteRegistryValue(context.gpa, entry.key, name);
        } else deleteRegistryTree(context.gpa, entry.key);
    }
    if (config.registry_cleanup.len > 0) win.SHChangeNotify(win.SHCNE_ASSOCCHANGED, win.SHCNF_IDLIST, null, null);
    deleteRegistryTree(context.gpa, uninstall_key);

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        std.Io.Dir.cwd().deleteTree(context.io, root_path) catch |err| {
            if (attempt == 40) return err;
            win.Sleep(250);
            continue;
        };
        break;
    }
    scheduleSelfDelete(context.gpa);
    return exit_ok;
}

/// The uninstall helper runs from the temporary directory and cannot
/// delete its own image while it runs; a hidden command prompt removes it
/// a moment after this process exits.
fn scheduleSelfDelete(allocator: std.mem.Allocator) void {
    const own_path = ownPath(allocator) catch return;
    var system_buffer: [win.MAX_PATH_WIDE]u16 = undefined;
    const system_len = win.GetSystemDirectoryW(&system_buffer, system_buffer.len);
    if (system_len == 0 or system_len >= system_buffer.len) return;
    const system_dir = std.unicode.wtf16LeToWtf8Alloc(allocator, system_buffer[0..system_len]) catch return;
    const shell = std.fmt.allocPrint(allocator, "{s}\\cmd.exe", .{system_dir}) catch return;
    const command = std.fmt.allocPrint(allocator, "/d /c \"ping -n 3 127.0.0.1 >nul & del /f /q \"{s}\"\"", .{own_path}) catch return;
    const arguments = wideSlice(allocator, command) catch return;
    const process = startProcessWithFlags(allocator, shell, arguments, win.CREATE_NO_WINDOW) catch return;
    _ = win.CloseHandle(process.hThread);
    _ = win.CloseHandle(process.hProcess);
}

// ---------------------------------------------------------------------------
// Shared

fn readInstalledConfig(context: *Context, root: std.Io.Dir) !InstallConfig {
    const bytes = try root.readFileAlloc(context.io, install_switch.current ++ "/" ++ install_config.file_name, context.gpa, .limited(install_config.max_config_bytes));
    const parsed = try install_config.parse(context.gpa, bytes);
    return parsed.value;
}

fn launcherPath(allocator: std.mem.Allocator, root_path: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\\{s}.exe", .{ root_path, name });
}

/// Whether any process runs an executable from <root>\app\.
fn appRunning(context: *Context, root_path: []const u8) !bool {
    const prefix = try std.fmt.allocPrint(context.gpa, "{s}\\{s}\\", .{ root_path, install_switch.current });
    const prefix_w = try std.unicode.wtf8ToWtf16LeAlloc(context.gpa, prefix);
    var pids: [4096]win.DWORD = undefined;
    var needed: win.DWORD = 0;
    if (win.K32EnumProcesses(&pids, @sizeOf(@TypeOf(pids)), &needed) == 0) return false;
    const count = needed / @sizeOf(win.DWORD);
    const self = win.GetCurrentProcessId();
    for (pids[0..count]) |pid| {
        if (pid == 0 or pid == self) continue;
        const handle = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse continue;
        defer _ = win.CloseHandle(handle);
        var image: [win.MAX_PATH_WIDE]u16 = undefined;
        var image_len: win.DWORD = image.len;
        if (win.QueryFullProcessImageNameW(handle, 0, &image, &image_len) == 0) continue;
        if (startsWithIgnoreCaseWide(image[0..image_len], prefix_w)) return true;
    }
    return false;
}

fn startsWithIgnoreCaseWide(value: []const u16, prefix: []const u16) bool {
    if (value.len < prefix.len) return false;
    for (value[0..prefix.len], prefix) |a, b| {
        if (lowerWide(a) != lowerWide(b)) return false;
    }
    return true;
}

fn lowerWide(unit: u16) u16 {
    return if (unit >= 'A' and unit <= 'Z') unit + 32 else unit;
}

/// The arguments part of a Windows command line: everything after the
/// program name, as the shell quoted it.
pub fn commandLineTail(line: []const u16) []const u16 {
    var index: usize = 0;
    if (index < line.len and line[index] == '"') {
        index += 1;
        while (index < line.len and line[index] != '"') index += 1;
        if (index < line.len) index += 1;
    } else {
        while (index < line.len and line[index] != ' ' and line[index] != '\t') index += 1;
    }
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) index += 1;
    return line[index..];
}

fn startProcess(allocator: std.mem.Allocator, executable: []const u8, arguments: []const u16) !win.PROCESS_INFORMATION {
    return startProcessWithFlags(allocator, executable, arguments, 0);
}

fn startProcessWithFlags(allocator: std.mem.Allocator, executable: []const u8, arguments: []const u16, flags: win.DWORD) !win.PROCESS_INFORMATION {
    const executable_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, executable);
    var command: std.ArrayList(u16) = .empty;
    try command.append(allocator, '"');
    try command.appendSlice(allocator, executable_w);
    try command.append(allocator, '"');
    if (arguments.len > 0) {
        try command.append(allocator, ' ');
        try command.appendSlice(allocator, arguments);
    }
    try command.append(allocator, 0);
    const command_line: [:0]u16 = command.items[0 .. command.items.len - 1 :0];
    var startup: win.STARTUPINFOW = .{};
    var process: win.PROCESS_INFORMATION = undefined;
    if (win.CreateProcessW(executable_w.ptr, command_line.ptr, null, null, 0, win.CREATE_UNICODE_ENVIRONMENT | flags, null, null, &startup, &process) == 0) return error.ProcessStartFailed;
    return process;
}

fn ownPath(allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [win.MAX_PATH_WIDE]u16 = undefined;
    const length = win.GetModuleFileNameW(null, &buffer, buffer.len);
    if (length == 0 or length >= buffer.len) return error.OwnPathUnavailable;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..length]);
}

fn knownFolder(allocator: std.mem.Allocator, id: *const win.GUID) ![]const u8 {
    var path: ?[*:0]u16 = null;
    if (win.SHGetKnownFolderPath(id, 0, null, &path) < 0) return error.KnownFolderUnavailable;
    defer win.CoTaskMemFree(path);
    return std.unicode.wtf16LeToWtf8Alloc(allocator, std.mem.span(path.?));
}

/// A NUL-terminated wide copy of a WTF-8 string, for Win32 parameters.
fn wide(allocator: std.mem.Allocator, value: []const u8) ![*:0]const u16 {
    return (try std.unicode.wtf8ToWtf16LeAllocZ(allocator, value)).ptr;
}

fn wideSlice(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    return std.unicode.wtf8ToWtf16LeAlloc(allocator, value);
}

fn deleteFileIfPresent(allocator: std.mem.Allocator, path: []const u8) void {
    const path_w = wide(allocator, path) catch return;
    _ = win.DeleteFileW(path_w);
}

fn setRegistryString(allocator: std.mem.Allocator, key_path: []const u8, name: []const u8, value: []const u8) !void {
    var key: win.HKEY = undefined;
    if (win.RegCreateKeyExW(win.HKEY_CURRENT_USER, try wide(allocator, key_path), 0, null, 0, win.KEY_WRITE, null, &key, null) != win.ERROR_SUCCESS) return error.RegistryWriteFailed;
    defer _ = win.RegCloseKey(key);
    const value_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, value);
    const bytes = std.mem.sliceAsBytes(value_w[0 .. value_w.len + 1]);
    const name_w: ?[*:0]const u16 = if (name.len == 0) null else try wide(allocator, name);
    if (win.RegSetValueExW(key, name_w, 0, win.REG_SZ, bytes.ptr, @intCast(bytes.len)) != win.ERROR_SUCCESS) return error.RegistryWriteFailed;
}

fn setRegistryDword(allocator: std.mem.Allocator, key_path: []const u8, name: []const u8, value: u32) !void {
    var key: win.HKEY = undefined;
    if (win.RegCreateKeyExW(win.HKEY_CURRENT_USER, try wide(allocator, key_path), 0, null, 0, win.KEY_WRITE, null, &key, null) != win.ERROR_SUCCESS) return error.RegistryWriteFailed;
    defer _ = win.RegCloseKey(key);
    const bytes = std.mem.asBytes(&value);
    if (win.RegSetValueExW(key, try wide(allocator, name), 0, win.REG_DWORD, bytes.ptr, bytes.len) != win.ERROR_SUCCESS) return error.RegistryWriteFailed;
}

fn queryRegistryString(allocator: std.mem.Allocator, key_path: []const u8, name: []const u8) !?[]const u8 {
    var key: win.HKEY = undefined;
    if (win.RegOpenKeyExW(win.HKEY_CURRENT_USER, try wide(allocator, key_path), 0, win.KEY_READ, &key) != win.ERROR_SUCCESS) return null;
    defer _ = win.RegCloseKey(key);
    const name_w: ?[*:0]const u16 = if (name.len == 0) null else try wide(allocator, name);
    var kind: win.DWORD = 0;
    var size: win.DWORD = 0;
    if (win.RegQueryValueExW(key, name_w, null, &kind, null, &size) != win.ERROR_SUCCESS or kind != win.REG_SZ) return null;
    const units = try allocator.alloc(u16, size / 2 + 1);
    var read_size: win.DWORD = @intCast(units.len * 2);
    if (win.RegQueryValueExW(key, name_w, null, &kind, std.mem.sliceAsBytes(units).ptr, &read_size) != win.ERROR_SUCCESS) return null;
    var length: usize = read_size / 2;
    while (length > 0 and units[length - 1] == 0) length -= 1;
    return try std.unicode.wtf16LeToWtf8Alloc(allocator, units[0..length]);
}

/// Deletes one value, and then the key itself when nothing is left in it
/// (an extension key the app created only for its association).
fn deleteRegistryValue(allocator: std.mem.Allocator, key_path: []const u8, name: []const u8) void {
    const key_w = wide(allocator, key_path) catch return;
    var key: win.HKEY = undefined;
    if (win.RegOpenKeyExW(win.HKEY_CURRENT_USER, key_w, 0, win.KEY_READ | win.KEY_WRITE, &key) != win.ERROR_SUCCESS) return;
    const name_w: ?[*:0]const u16 = if (name.len == 0) null else (wide(allocator, name) catch {
        _ = win.RegCloseKey(key);
        return;
    });
    _ = win.RegDeleteValueW(key, name_w);
    var subkeys: win.DWORD = 1;
    var values: win.DWORD = 1;
    const queried = win.RegQueryInfoKeyW(key, null, null, null, &subkeys, null, null, &values, null, null, null, null);
    _ = win.RegCloseKey(key);
    if (queried == win.ERROR_SUCCESS and subkeys == 0 and values == 0) _ = win.RegDeleteKeyW(win.HKEY_CURRENT_USER, key_w);
}

fn deleteRegistryTree(allocator: std.mem.Allocator, key_path: []const u8) void {
    const key_w = wide(allocator, key_path) catch return;
    _ = win.RegDeleteTreeW(win.HKEY_CURRENT_USER, key_w);
}

fn createShortcut(allocator: std.mem.Allocator, link_path: []const u8, target: []const u8, working_directory: []const u8, icon: []const u8, description: []const u8, app_user_model_id: []const u8) !void {
    const initialized = win.CoInitializeEx(null, win.COINIT_APARTMENTTHREADED);
    defer if (initialized >= 0) win.CoUninitialize();
    var link_object: ?*anyopaque = null;
    if (win.CoCreateInstance(&win.CLSID_ShellLink, null, win.CLSCTX_INPROC_SERVER, &win.IID_IShellLinkW, &link_object) < 0) return error.ShortcutFailed;
    const link: *win.IShellLinkW = @ptrCast(@alignCast(link_object.?));
    defer _ = link.vtable.unknown.Release(link);
    if (link.vtable.SetPath(link, try wide(allocator, target)) < 0) return error.ShortcutFailed;
    _ = link.vtable.SetWorkingDirectory(link, try wide(allocator, working_directory));
    _ = link.vtable.SetIconLocation(link, try wide(allocator, icon), 0);
    _ = link.vtable.SetDescription(link, try wide(allocator, description));

    // The shortcut and the running app share an AppUserModelID, so the
    // taskbar groups the app's windows under this shortcut and pins it.
    var store_object: ?*anyopaque = null;
    if (link.vtable.unknown.QueryInterface(link, &win.IID_IPropertyStore, &store_object) >= 0) {
        const store: *win.IPropertyStore = @ptrCast(@alignCast(store_object.?));
        defer _ = store.vtable.unknown.Release(store);
        const id_w = try wide(allocator, app_user_model_id);
        var value: win.PROPVARIANT = .{ .vt = win.VT_LPWSTR };
        value.value[0] = @intFromPtr(id_w);
        if (store.vtable.SetValue(store, &win.PKEY_AppUserModel_ID, &value) >= 0) _ = store.vtable.Commit(store);
    }

    var persist_object: ?*anyopaque = null;
    if (link.vtable.unknown.QueryInterface(link, &win.IID_IPersistFile, &persist_object) < 0) return error.ShortcutFailed;
    const persist: *win.IPersistFile = @ptrCast(@alignCast(persist_object.?));
    defer _ = persist.vtable.unknown.Release(persist);
    if (persist.vtable.Save(persist, try wide(allocator, link_path), 1) < 0) return error.ShortcutFailed;
}

fn messageBox(context: *Context, text: []const u8, flags: u32) i32 {
    const text_w = wide(context.gpa, text) catch return 0;
    const title_w = wide(context.gpa, context.title) catch return 0;
    return win.MessageBoxW(null, text_w, title_w, flags | win.MB_SETFOREGROUND);
}

fn fail(context: *Context, comptime format: []const u8, args: anytype) u8 {
    if (!context.silent) {
        const text = std.fmt.allocPrint(context.gpa, format, args) catch return exit_failed;
        _ = messageBox(context, text, win.MB_OK | win.MB_ICONERROR);
    }
    return exit_failed;
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |argument| {
        if (std.mem.eql(u8, argument, flag)) return true;
    }
    return false;
}

test "the command-line tail keeps the arguments as the shell quoted them" {
    const line = std.unicode.utf8ToUtf16LeStringLiteral("\"C:\\Program Files\\Demo\\demo.exe\"  \"C:\\Docs\\a b.txt\" --flag");
    const tail = commandLineTail(line);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("\"C:\\Docs\\a b.txt\" --flag"), tail);
    try std.testing.expectEqual(@as(usize, 0), commandLineTail(std.unicode.utf8ToUtf16LeStringLiteral("demo.exe")).len);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("x"), commandLineTail(std.unicode.utf8ToUtf16LeStringLiteral("demo.exe\tx")));
}

test "process image paths match the install folder case-insensitively" {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Users\\Me\\AppData\\Local\\Programs\\Demo\\app\\");
    try std.testing.expect(startsWithIgnoreCaseWide(std.unicode.utf8ToUtf16LeStringLiteral("c:\\users\\me\\appdata\\local\\programs\\demo\\APP\\bin\\demo.exe"), prefix));
    try std.testing.expect(!startsWithIgnoreCaseWide(std.unicode.utf8ToUtf16LeStringLiteral("C:\\Users\\Me\\AppData\\Local\\Programs\\Demo\\app.prev\\bin\\demo.exe"), prefix));
}
