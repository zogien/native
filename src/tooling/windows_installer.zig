//! `native package --target windows --installer`: turns the Windows
//! artifact directory into a per-user setup program.
//!
//! The artifact directory becomes the install image: it gains
//! `native-install.json` (the install configuration) and
//! `native-launcher.exe` (the launcher the setup program copies to the
//! stable `<root>\<name>.exe`). setup.exe is the launcher program with the
//! configuration and a ZIP of the image appended, followed by a trailer
//! carrying their SHA-256 (src/windows_install/payload.zig).

const std = @import("std");
const manifest_tool = @import("manifest.zig");
const package = @import("package.zig");
const zip_writer = @import("zip_writer.zig");
const install_config = @import("windows_install_config");
const setup_payload = @import("windows_install_payload");

pub const launcher_file_in_image = "native-launcher.exe";
pub const launcher_x86_64 = @embedFile("windows_launcher_x86_64");
pub const launcher_aarch64 = @embedFile("windows_launcher_aarch64");

pub const Arch = enum {
    x86_64,
    aarch64,

    pub fn launcher(self: Arch) []const u8 {
        return switch (self) {
            .x86_64 => launcher_x86_64,
            .aarch64 => launcher_aarch64,
        };
    }
};

pub const Options = struct {
    /// The Windows artifact directory `native package` just staged.
    artifact_dir: []const u8,
    metadata: manifest_tool.Metadata,
    /// The app executable's file name in `bin\`.
    executable: []const u8,
    arch: Arch,
    output_path: []const u8,
};

/// The setup program's file name: `<name>-<version>-windows-<arch>-setup.exe`.
pub fn setupFileName(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata, arch: Arch) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}-windows-{s}-setup.exe", .{ metadata.name, metadata.version, @tagName(arch) });
}

/// The update archive's file name: `<name>-<version>-windows-<arch>-update.zip`.
pub fn updateArchiveFileName(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata, arch: Arch) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}-windows-{s}-update.zip", .{ metadata.name, metadata.version, @tagName(arch) });
}

pub fn createSetup(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const image = try buildImage(arena, io, options);

    const program = options.arch.launcher();
    const trailer = setup_payload.encode(.{
        .config_offset = program.len,
        .config_size = image.config.len,
        .zip_offset = program.len + image.config.len,
        .zip_size = image.zip.len,
        .sha256 = setup_payload.digest(image.config, image.zip),
    });
    try writeAtomically(io, options.output_path, &.{ program, image.config, image.zip, &trailer });
}

/// The ZIP of the install image the updater downloads: the same image a
/// setup program carries, signed into a feed by `native update sign`.
pub fn createUpdateArchive(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const image = try buildImage(arena_state.allocator(), io, options);
    try writeAtomically(io, options.output_path, &.{image.zip});
}

const Image = struct {
    config: []const u8,
    zip: []const u8,
};

/// Adds the install configuration and launcher to the artifact directory
/// and zips it, without the portable registration script.
fn buildImage(arena: std.mem.Allocator, io: std.Io, options: Options) !Image {
    var artifact = try std.Io.Dir.cwd().openDir(io, options.artifact_dir, .{});
    defer artifact.close(io);
    const has_icon = if (artifact.access(io, "app-icon.ico", .{})) |_| true else |_| false;
    const config = try installConfig(arena, options.metadata, options.executable, has_icon);
    try install_config.validate(config);

    var config_writer: std.Io.Writer.Allocating = .init(arena);
    try install_config.write(config, &config_writer.writer);
    const config_bytes = config_writer.written();
    try artifact.writeFile(io, .{ .sub_path = install_config.file_name, .data = config_bytes });
    try artifact.writeFile(io, .{ .sub_path = launcher_file_in_image, .data = options.arch.launcher() });

    const collected = try zip_writer.collectDirectory(arena, io, options.artifact_dir);
    var image: std.ArrayList(zip_writer.Entry) = .empty;
    for (collected) |entry| {
        // The portable artifact's registration script points at bin\; an
        // installed app registers through the setup program instead.
        if (std.mem.startsWith(u8, entry.name, "install/")) continue;
        try image.append(arena, entry);
    }
    var zip: std.Io.Writer.Allocating = .init(arena);
    try zip_writer.write(arena, &zip.writer, image.items);
    return .{ .config = config_bytes, .zip = zip.written() };
}

fn writeAtomically(io: std.Io, path: []const u8, parts: []const []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    for (parts) |part| try writer.interface.writeAll(part);
    try writer.interface.flush();
    try atomic.replace(io);
}

/// The install configuration for an app: its identity, executable and
/// icon, and the HKCU\Software\Classes values its file associations and
/// URL schemes need, pointing at the installed launcher so a pending
/// version switch also applies when a document or link opens the app.
pub fn installConfig(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata, executable: []const u8, has_icon: bool) !install_config.InstallConfig {
    var registry: std.ArrayList(install_config.RegistryValue) = .empty;
    var cleanup: std.ArrayList(install_config.RegistryCleanup) = .empty;
    const open_command = "\"" ++ install_config.launcher_placeholder ++ "\" \"%1\"";
    const document_icon = if (has_icon) install_config.install_placeholder ++ "\\app\\app-icon.ico" else install_config.launcher_placeholder;

    for (metadata.file_associations) |association| {
        const prog_id = try package.windowsProgId(allocator, metadata, association);
        const prog_key = try std.fmt.allocPrint(allocator, "Software\\Classes\\{s}", .{prog_id});
        for (association.extensions) |extension| {
            const extension_key = try std.fmt.allocPrint(allocator, "Software\\Classes\\.{s}", .{package.trimExtensionDot(extension)});
            try registry.append(allocator, .{ .key = extension_key, .value = prog_id });
            try cleanup.append(allocator, .{ .key = extension_key, .name = "", .if_value = prog_id });
        }
        try registry.append(allocator, .{ .key = prog_key, .value = association.name });
        try registry.append(allocator, .{ .key = prog_key, .name = "FriendlyTypeName", .value = association.name });
        try registry.append(allocator, .{ .key = try std.fmt.allocPrint(allocator, "{s}\\DefaultIcon", .{prog_key}), .value = document_icon });
        try registry.append(allocator, .{ .key = try std.fmt.allocPrint(allocator, "{s}\\shell\\open\\command", .{prog_key}), .value = open_command });
        try cleanup.append(allocator, .{ .key = prog_key });
    }
    for (metadata.url_schemes) |url_scheme| {
        const scheme_key = try std.fmt.allocPrint(allocator, "Software\\Classes\\{s}", .{url_scheme.scheme});
        try registry.append(allocator, .{ .key = scheme_key, .value = try std.fmt.allocPrint(allocator, "URL:{s}", .{url_scheme.scheme}) });
        try registry.append(allocator, .{ .key = scheme_key, .name = "URL Protocol", .value = "" });
        try registry.append(allocator, .{ .key = try std.fmt.allocPrint(allocator, "{s}\\shell\\open\\command", .{scheme_key}), .value = open_command });
        try cleanup.append(allocator, .{ .key = scheme_key });
    }

    return .{
        .bundle_id = metadata.id,
        .name = metadata.name,
        .display_name = metadata.displayName(),
        .version = metadata.version,
        .executable = executable,
        .icon = if (has_icon) "app-icon.ico" else "",
        .registry = try registry.toOwnedSlice(allocator),
        .registry_cleanup = try cleanup.toOwnedSlice(allocator),
    };
}

test "an app's associations and URL schemes register through the installed launcher" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const associations = [_]manifest_tool.FileAssociationMetadata{.{ .name = "Markdown", .extensions = &.{"md"} }};
    const schemes = [_]manifest_tool.UrlSchemeMetadata{.{ .scheme = "acme-notes" }};
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.example.notes",
        .name = "notes",
        .display_name = "Acme Notes",
        .version = "1.2.3",
        .file_associations = &associations,
        .url_schemes = &schemes,
    };
    const config = try installConfig(arena, metadata, "notes.exe", true);
    try install_config.validate(config);
    try std.testing.expectEqualStrings("Acme Notes", config.display_name);
    try std.testing.expectEqualStrings("app-icon.ico", config.icon);
    try std.testing.expectEqualStrings("Software\\Classes\\.md", config.registry[0].key);
    try std.testing.expectEqualStrings("dev.example.notes.Markdown", config.registry[0].value);
    try std.testing.expectEqualStrings("\"{launcher}\" \"%1\"", config.registry[4].value);
    try std.testing.expectEqualStrings("Software\\Classes\\acme-notes\\shell\\open\\command", config.registry[7].key);
    // The extension's default value goes only while it still names this
    // app; the app's own ProgID and scheme keys go whole.
    try std.testing.expectEqualStrings("dev.example.notes.Markdown", config.registry_cleanup[0].if_value.?);
    try std.testing.expect(config.registry_cleanup[1].name == null);
}

test "setup.exe carries the launcher, its configuration and the install image" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-windows-setup";
    try cwd.deleteTree(io, root);
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/artifact/bin");
    try cwd.createDirPath(io, root ++ "/artifact/install");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/artifact/bin/notes.exe", .data = "app" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/artifact/install/register-file-types.ps1", .data = "script" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/artifact/app-icon.ico", .data = "icon" });

    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.notes", .name = "notes", .version = "1.2.3" };
    try createSetup(allocator, io, .{ .artifact_dir = root ++ "/artifact", .metadata = metadata, .executable = "notes.exe", .arch = .x86_64, .output_path = root ++ "/notes-setup.exe" });

    const setup = try cwd.readFileAlloc(io, root ++ "/notes-setup.exe", allocator, .unlimited);
    defer allocator.free(setup);
    try std.testing.expect(std.mem.startsWith(u8, setup, launcher_x86_64));
    const trailer = setup_payload.find(setup[setup.len - setup_payload.trailer_len ..], setup.len).?;
    try std.testing.expectEqual(@as(u64, launcher_x86_64.len), trailer.config_offset);
    const config_bytes = setup[@intCast(trailer.config_offset)..][0..@intCast(trailer.config_size)];
    const zip_bytes = setup[@intCast(trailer.zip_offset)..][0..@intCast(trailer.zip_size)];
    try std.testing.expectEqualSlices(u8, &trailer.sha256, &setup_payload.digest(config_bytes, zip_bytes));
    var parsed = try install_config.parse(allocator, config_bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("notes", parsed.value.name);

    try cwd.writeFile(io, .{ .sub_path = root ++ "/image.zip", .data = zip_bytes });
    try cwd.createDirPath(io, root ++ "/extracted");
    var extracted = try cwd.openDir(io, root ++ "/extracted", .{});
    defer extracted.close(io);
    var archive = try cwd.openFile(io, root ++ "/image.zip", .{});
    defer archive.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = archive.reader(io, &buffer);
    try std.zip.extract(extracted, &reader, .{});
    const launcher = try extracted.readFileAlloc(io, launcher_file_in_image, allocator, .unlimited);
    defer allocator.free(launcher);
    try std.testing.expectEqualSlices(u8, launcher_x86_64, launcher);
    try std.testing.expectError(error.FileNotFound, extracted.access(io, "install/register-file-types.ps1", .{}));
    try extracted.access(io, "bin/notes.exe", .{});
    try extracted.access(io, install_config.file_name, .{});

    // The updater downloads the very image the setup program carries.
    try createUpdateArchive(allocator, io, .{ .artifact_dir = root ++ "/artifact", .metadata = metadata, .executable = "notes.exe", .arch = .x86_64, .output_path = root ++ "/notes-update.zip" });
    const update_archive = try cwd.readFileAlloc(io, root ++ "/notes-update.zip", allocator, .unlimited);
    defer allocator.free(update_archive);
    try std.testing.expectEqualSlices(u8, zip_bytes, update_archive);
}
