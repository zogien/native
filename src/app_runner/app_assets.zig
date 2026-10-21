//! Startup asset reads shared by generated app runners.
//!
//! Relative paths keep their app-directory meaning during development. In a
//! packaged macOS app, the same tree lives below `Contents/Resources`; Finder
//! and `open` do not preserve a useful working directory, so resolve that tree
//! from the executable's bundle layout before reading it. A packaged Windows
//! or Linux artifact keeps the tree in `resources/` beside the executable's
//! `bin/`, and a shortcut or file manager launch starts in some other
//! directory, so resolve that tree the same way.

const std = @import("std");
const builtin = @import("builtin");

pub fn readFileAlloc(
    io: std.Io,
    path: []const u8,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) std.Io.Dir.ReadFileAllocError![]u8 {
    if (comptime builtin.os.tag == .macos) {
        var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const executable_len = std.process.executablePath(io, &executable_buffer) catch
            return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
        return readFileAllocFromMacosExecutable(
            io,
            executable_buffer[0..executable_len],
            path,
            allocator,
            limit,
        );
    }
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .linux) {
        var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const executable_len = std.process.executablePath(io, &executable_buffer) catch
            return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
        return readFileAllocFromDesktopExecutable(
            io,
            executable_buffer[0..executable_len],
            path,
            allocator,
            limit,
        );
    }

    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
}

pub fn readFileAllocFromDesktopExecutable(
    io: std.Io,
    executable_path: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) std.Io.Dir.ReadFileAllocError![]u8 {
    var packaged_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (desktopPackagedResourcePath(executable_path, path, &packaged_path_buffer) catch null) |packaged_path| {
        return std.Io.Dir.cwd().readFileAlloc(io, packaged_path, allocator, limit) catch |err| switch (err) {
            // As on macOS: a package miss keeps the cwd-relative development
            // behavior, while a real read failure is not hidden.
            error.FileNotFound => std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit),
            else => |read_err| read_err,
        };
    }
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
}

/// The packaged copy of a relative asset path when the executable runs
/// from a Windows or Linux artifact's `bin/`: `<artifact>/resources/<path>`.
pub fn desktopPackagedResourcePath(
    executable_path: []const u8,
    asset_path: []const u8,
    output: []u8,
) error{NoSpaceLeft}!?[]const u8 {
    if (asset_path.len == 0 or std.fs.path.isAbsolute(asset_path)) return null;
    const executable_dir = std.fs.path.dirname(executable_path) orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(executable_dir), "bin")) return null;
    const artifact_dir = std.fs.path.dirname(executable_dir) orelse return null;
    return std.fmt.bufPrint(output, "{s}{c}resources{c}{s}", .{ artifact_dir, std.fs.path.sep, std.fs.path.sep, asset_path }) catch
        error.NoSpaceLeft;
}

pub fn readFileAllocFromMacosExecutable(
    io: std.Io,
    executable_path: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) std.Io.Dir.ReadFileAllocError![]u8 {
    var bundled_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (macosBundleResourcePath(executable_path, path, &bundled_path_buffer) catch null) |bundled_path| {
        return std.Io.Dir.cwd().readFileAlloc(io, bundled_path, allocator, limit) catch |err| switch (err) {
            // Match the platform host's asset resolver: a package miss keeps
            // the old cwd-relative behavior, while a real read failure is not
            // hidden by a second lookup.
            error.FileNotFound => std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit),
            else => |read_err| read_err,
        };
    }
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
}

pub fn macosBundleResourcePath(
    executable_path: []const u8,
    asset_path: []const u8,
    output: []u8,
) error{NoSpaceLeft}!?[]const u8 {
    if (asset_path.len == 0 or std.fs.path.isAbsolutePosix(asset_path)) return null;

    const executable_dir = std.fs.path.dirnamePosix(executable_path) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basenamePosix(executable_dir), "MacOS")) return null;

    const contents_dir = std.fs.path.dirnamePosix(executable_dir) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basenamePosix(contents_dir), "Contents")) return null;

    const bundle_dir = std.fs.path.dirnamePosix(contents_dir) orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(bundle_dir), ".app")) return null;

    return std.fmt.bufPrint(output, "{s}/Resources/{s}", .{ contents_dir, asset_path }) catch
        error.NoSpaceLeft;
}

test "macOS bundle resource path mirrors the app-relative asset tree" {
    var buffer: [256]u8 = undefined;
    const resolved = (try macosBundleResourcePath(
        "/Applications/Kanban.app/Contents/MacOS/kanban",
        "assets/logos/openai-svgl.png",
        &buffer,
    )).?;
    try std.testing.expectEqualStrings(
        "/Applications/Kanban.app/Contents/Resources/assets/logos/openai-svgl.png",
        resolved,
    );

    const uppercase = (try macosBundleResourcePath(
        "/Applications/Kanban.APP/Contents/MacOS/kanban",
        "assets/logo.png",
        &buffer,
    )).?;
    try std.testing.expectEqualStrings(
        "/Applications/Kanban.APP/Contents/Resources/assets/logo.png",
        uppercase,
    );

    try std.testing.expectEqual(null, try macosBundleResourcePath(
        "/tmp/kanban",
        "assets/logo.png",
        &buffer,
    ));
    try std.testing.expectEqual(null, try macosBundleResourcePath(
        "/Applications/Kanban.app/Contents/Helpers/kanban",
        "assets/logo.png",
        &buffer,
    ));
    try std.testing.expectEqual(null, try macosBundleResourcePath(
        "/Applications/Kanban.app/Contents/MacOS/kanban",
        "/tmp/logo.png",
        &buffer,
    ));
}

test "packaged macOS startup assets read from Contents Resources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const resource_dir = "Kanban.app/Contents/Resources/assets/logos";
    try tmp.dir.createDirPath(std.testing.io, resource_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = resource_dir ++ "/openai.png",
        .data = "packaged-avatar",
    });

    var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_path = try std.fmt.bufPrint(
        &executable_buffer,
        ".zig-cache/tmp/{s}/Kanban.app/Contents/MacOS/kanban",
        .{tmp.sub_path[0..]},
    );
    const bytes = try readFileAllocFromMacosExecutable(
        std.testing.io,
        executable_path,
        "assets/logos/openai.png",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("packaged-avatar", bytes);
}

test "desktop packaged resource path mirrors the app-relative asset tree beside bin" {
    var buffer: [256]u8 = undefined;
    const sep = std.fs.path.sep_str;
    const executable = "pkg" ++ sep ++ "demo" ++ sep ++ "bin" ++ sep ++ "demo.exe";
    try std.testing.expectEqualStrings(
        "pkg" ++ sep ++ "demo" ++ sep ++ "resources" ++ sep ++ "assets/fonts/mono.ttf",
        (try desktopPackagedResourcePath(executable, "assets/fonts/mono.ttf", &buffer)).?,
    );
    const uppercase = "pkg" ++ sep ++ "demo" ++ sep ++ "BIN" ++ sep ++ "demo.exe";
    try std.testing.expect((try desktopPackagedResourcePath(uppercase, "assets/logo.png", &buffer)) != null);
    // A development binary outside bin/ keeps reading relative to the
    // working directory, and absolute paths are never redirected.
    try std.testing.expectEqual(null, try desktopPackagedResourcePath("zig-cache" ++ sep ++ "o" ++ sep ++ "demo.exe", "assets/logo.png", &buffer));
    try std.testing.expectEqual(null, try desktopPackagedResourcePath(executable, "", &buffer));
    const absolute = if (builtin.os.tag == .windows) "C:\\logo.png" else "/tmp/logo.png";
    try std.testing.expectEqual(null, try desktopPackagedResourcePath(executable, absolute, &buffer));
}

test "packaged desktop startup assets read from resources beside bin" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "demo/bin");
    try tmp.dir.createDirPath(std.testing.io, "demo/resources/assets/fonts");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "demo/resources/assets/fonts/mono.ttf", .data = "packaged-font" });

    var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_path = try std.fmt.bufPrint(&executable_buffer, ".zig-cache/tmp/{s}/demo/bin/demo.exe", .{tmp.sub_path[0..]});
    const bytes = try readFileAllocFromDesktopExecutable(std.testing.io, executable_path, "assets/fonts/mono.ttf", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("packaged-font", bytes);

    // A package miss falls back to the working directory.
    try std.testing.expectError(error.FileNotFound, readFileAllocFromDesktopExecutable(std.testing.io, executable_path, "assets/fonts/missing.ttf", std.testing.allocator, .limited(1024)));
}
