//! The install configuration `native package --installer` writes into the
//! install image as `app\native-install.json`. The setup program, the
//! launcher and the uninstaller read it to name the install folder, the
//! executable they start, the shortcut, the uninstall entry, and the
//! registry values the app registers under HKCU\Software\Classes.
//!
//! The setup payload is checked against its SHA-256 before anything is
//! read, but the values still name paths and registry keys, so every
//! field is validated: file names are plain names, registry keys stay
//! under Software\Classes, and nothing escapes the install folder.

const std = @import("std");

pub const file_name = "native-install.json";
pub const format_version: u32 = 1;

/// A string value the installer sets under HKCU. `{launcher}` in `value`
/// becomes the installed launcher's path and `{install}` the install
/// folder.
pub const RegistryValue = struct {
    key: []const u8,
    /// Empty for the key's default value.
    name: []const u8 = "",
    value: []const u8,
};

/// What the uninstaller removes. Without `name`, the whole key tree goes;
/// with `name`, only that value, and only while it still holds `if_value`
/// (so an association another app has since claimed stays).
pub const RegistryCleanup = struct {
    key: []const u8,
    name: ?[]const u8 = null,
    if_value: ?[]const u8 = null,
};

pub const InstallConfig = struct {
    format: u32 = format_version,
    bundle_id: []const u8,
    /// The manifest's short name: the launcher is `<name>.exe`.
    name: []const u8,
    display_name: []const u8,
    version: []const u8,
    publisher: []const u8 = "",
    /// The app executable, in `app\bin\`.
    executable: []const u8,
    /// The app icon, relative to `app\`, or empty.
    icon: []const u8 = "",
    registry: []const RegistryValue = &.{},
    registry_cleanup: []const RegistryCleanup = &.{},
};

pub const max_config_bytes: usize = 64 * 1024;
pub const max_registry_values: usize = 256;
pub const max_text_bytes: usize = 256;
pub const classes_prefix = "Software\\Classes\\";
/// In a registry value: the installed launcher's path.
pub const launcher_placeholder = "{launcher}";
/// In a registry value: the install folder.
pub const install_placeholder = "{install}";

pub const ValidationError = error{InvalidInstallConfig};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(InstallConfig) {
    if (bytes.len == 0 or bytes.len > max_config_bytes) return error.InvalidInstallConfig;
    var parsed = std.json.parseFromSlice(InstallConfig, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidInstallConfig;
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

pub fn write(config: InstallConfig, writer: *std.Io.Writer) !void {
    try std.json.Stringify.value(config, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');
}

pub fn validate(config: InstallConfig) ValidationError!void {
    if (config.format != format_version) return error.InvalidInstallConfig;
    if (!isPathName(config.bundle_id) or config.bundle_id.len > 128) return error.InvalidInstallConfig;
    if (!isPathName(config.name) or std.ascii.endsWithIgnoreCase(config.name, ".exe")) return error.InvalidInstallConfig;
    if (!isPathName(config.executable) or !std.ascii.endsWithIgnoreCase(config.executable, ".exe")) return error.InvalidInstallConfig;
    if (!isText(config.display_name) or config.display_name.len == 0) return error.InvalidInstallConfig;
    if (!isText(config.version) or config.version.len == 0) return error.InvalidInstallConfig;
    if (!isText(config.publisher)) return error.InvalidInstallConfig;
    if (config.icon.len > 0 and !isRelativePath(config.icon)) return error.InvalidInstallConfig;
    if (config.registry.len > max_registry_values or config.registry_cleanup.len > max_registry_values) return error.InvalidInstallConfig;
    for (config.registry) |entry| {
        if (!isClassesKey(entry.key) or !isText(entry.name) or entry.value.len > 1024 or hasControl(entry.value)) return error.InvalidInstallConfig;
    }
    for (config.registry_cleanup) |entry| {
        if (!isClassesKey(entry.key)) return error.InvalidInstallConfig;
        if (entry.name) |name| if (!isText(name)) return error.InvalidInstallConfig;
        if (entry.if_value) |value| if (value.len > 1024 or hasControl(value)) return error.InvalidInstallConfig;
    }
}

/// The folder under `%LOCALAPPDATA%\Programs` the app installs into: its
/// display name with the characters Windows does not allow in a file
/// name removed, or the bundle id when nothing usable is left.
pub fn installFolderName(output: []u8, display_name: []const u8, bundle_id: []const u8) ![]const u8 {
    var length: usize = 0;
    for (display_name) |byte| {
        if (byte < 0x20 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", byte) != null) continue;
        if (length == output.len) return error.NoSpaceLeft;
        output[length] = byte;
        length += 1;
    }
    var name = std.mem.trim(u8, output[0..length], " .");
    if (name.len == 0 or isReservedDeviceName(name)) {
        if (bundle_id.len > output.len) return error.NoSpaceLeft;
        @memcpy(output[0..bundle_id.len], bundle_id);
        name = output[0..bundle_id.len];
    } else if (name.ptr != output.ptr) {
        std.mem.copyForwards(u8, output[0..name.len], name);
        name = output[0..name.len];
    }
    return name;
}

/// The registry key of the app's entry in Settings > Apps, under HKCU.
pub fn uninstallKey(output: []u8, bundle_id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(output, "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{s}", .{bundle_id});
}

fn isPathName(value: []const u8) bool {
    if (value.len == 0 or value.len > max_text_bytes) return false;
    if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |byte| {
        if (byte < 0x20 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", byte) != null) return false;
    }
    if (value[value.len - 1] == '.' or value[value.len - 1] == ' ') return false;
    return !isReservedDeviceName(value);
}

fn isRelativePath(value: []const u8) bool {
    if (value.len == 0 or value.len > max_text_bytes) return false;
    var parts = std.mem.tokenizeAny(u8, value, "/\\");
    var count: usize = 0;
    while (parts.next()) |part| {
        if (!isPathName(part)) return false;
        count += 1;
    }
    return count > 0 and value[0] != '/' and value[0] != '\\';
}

fn isText(value: []const u8) bool {
    return value.len <= max_text_bytes and !hasControl(value) and std.unicode.utf8ValidateSlice(value);
}

fn hasControl(value: []const u8) bool {
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return true;
    }
    return false;
}

fn isClassesKey(key: []const u8) bool {
    if (!std.mem.startsWith(u8, key, classes_prefix) or key.len == classes_prefix.len or key.len > 512) return false;
    if (hasControl(key) or std.mem.indexOf(u8, key, "\\\\") != null or key[key.len - 1] == '\\') return false;
    var parts = std.mem.splitScalar(u8, key, '\\');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn isReservedDeviceName(value: []const u8) bool {
    const stem_end = std.mem.indexOfScalar(u8, value, '.') orelse value.len;
    const stem = std.mem.trimEnd(u8, value[0..stem_end], " ");
    const reserved = [_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" };
    for (reserved) |name| {
        if (std.ascii.eqlIgnoreCase(stem, name)) return true;
    }
    return false;
}

const test_config: InstallConfig = .{
    .bundle_id = "dev.example.notes",
    .name = "notes",
    .display_name = "Acme Notes",
    .version = "1.2.3",
    .publisher = "Acme",
    .executable = "notes.exe",
    .icon = "app-icon.ico",
    .registry = &.{
        .{ .key = "Software\\Classes\\.acme", .value = "dev.example.notes.Note" },
        .{ .key = "Software\\Classes\\dev.example.notes.Note\\shell\\open\\command", .value = "\"{launcher}\" \"%1\"" },
    },
    .registry_cleanup = &.{
        .{ .key = "Software\\Classes\\dev.example.notes.Note" },
        .{ .key = "Software\\Classes\\.acme", .name = "", .if_value = "dev.example.notes.Note" },
    },
};

test "install config round-trips through its JSON form" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try write(test_config, &output.writer);
    var parsed = try parse(std.testing.allocator, output.written());
    defer parsed.deinit();
    try std.testing.expectEqualStrings("notes.exe", parsed.value.executable);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.registry.len);
    try std.testing.expectEqualStrings("dev.example.notes.Note", parsed.value.registry_cleanup[1].if_value.?);
}

test "install config refuses names and keys that escape their place" {
    var config = test_config;
    config.executable = "..\\evil.exe";
    try std.testing.expectError(error.InvalidInstallConfig, validate(config));
    config = test_config;
    config.name = "notes.exe";
    try std.testing.expectError(error.InvalidInstallConfig, validate(config));
    config = test_config;
    config.bundle_id = "CON";
    try std.testing.expectError(error.InvalidInstallConfig, validate(config));
    config = test_config;
    config.icon = "..\\..\\icon.ico";
    try std.testing.expectError(error.InvalidInstallConfig, validate(config));
    config = test_config;
    config.registry = &.{.{ .key = "Software\\Microsoft\\Windows\\CurrentVersion\\Run", .name = "x", .value = "y" }};
    try std.testing.expectError(error.InvalidInstallConfig, validate(config));
    config = test_config;
    config.registry = &.{.{ .key = "Software\\Classes\\..\\Microsoft", .value = "y" }};
    try std.testing.expectError(error.InvalidInstallConfig, validate(config));
    config = test_config;
    config.registry_cleanup = &.{.{ .key = "Software\\Classes" }};
    try std.testing.expectError(error.InvalidInstallConfig, validate(config));
    config = test_config;
    config.format = 2;
    try std.testing.expectError(error.InvalidInstallConfig, validate(config));
}

test "install folders take the display name without forbidden characters" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Acme Notes", try installFolderName(&buffer, "Acme Notes", "dev.example.notes"));
    try std.testing.expectEqualStrings("Acme Notes 2", try installFolderName(&buffer, "Acme: Notes 2?", "dev.example.notes"));
    try std.testing.expectEqualStrings("Notes", try installFolderName(&buffer, " .Notes. ", "dev.example.notes"));
    try std.testing.expectEqualStrings("dev.example.notes", try installFolderName(&buffer, "???", "dev.example.notes"));
    try std.testing.expectEqualStrings("dev.example.notes", try installFolderName(&buffer, "nul", "dev.example.notes"));
}

test "the uninstall entry lives under the current user's Uninstall key" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\dev.example.notes",
        try uninstallKey(&buffer, "dev.example.notes"),
    );
}
