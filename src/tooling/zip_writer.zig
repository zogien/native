//! A small ZIP writer for install images and update archives: deflate
//! (or store, when deflate does not help), UTF-8 names with forward
//! slashes, and a fixed timestamp so the same tree always produces the
//! same bytes. No ZIP64: an archive stays below 4 GiB and 65535 entries.
//! `std.zip` reads what this writes.

const std = @import("std");
const flate = std.compress.flate;

pub const Entry = struct {
    /// Forward-slash path inside the archive, without a leading slash.
    name: []const u8,
    data: []const u8,
};

pub const Error = error{ ZipTooLarge, InvalidZipEntryName } || std.mem.Allocator.Error || std.Io.Writer.Error;

const dos_time: u16 = 0;
/// 1980-01-01, the earliest date a ZIP timestamp can hold.
const dos_date: u16 = (0 << 9) | (1 << 5) | 1;
const version: u16 = 20;
/// General purpose flag bit 11: names are UTF-8.
const utf8_flag: u16 = 0x0800;

const Written = struct {
    name: []const u8,
    method: std.zip.CompressionMethod,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    offset: u32,
};

pub fn write(allocator: std.mem.Allocator, out: *std.Io.Writer, entries: []const Entry) Error!void {
    if (entries.len > std.math.maxInt(u16)) return error.ZipTooLarge;
    const written = try allocator.alloc(Written, entries.len);
    defer allocator.free(written);
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);

    var offset: u64 = 0;
    for (entries, 0..) |entry, index| {
        try validateName(entry.name);
        if (entry.data.len > std.math.maxInt(u32)) return error.ZipTooLarge;
        var compressed: std.Io.Writer.Allocating = try .initCapacity(allocator, @max(64, entry.data.len / 2));
        defer compressed.deinit();
        var compressor = try flate.Compress.init(&compressed.writer, window, .raw, .default);
        try compressor.writer.writeAll(entry.data);
        try compressor.finish();
        const deflated = compressed.written().len < entry.data.len;
        const body = if (deflated) compressed.written() else entry.data;
        if (offset > std.math.maxInt(u32)) return error.ZipTooLarge;
        written[index] = .{
            .name = entry.name,
            .method = if (deflated) .deflate else .store,
            .crc32 = std.hash.Crc32.hash(entry.data),
            .compressed_size = @intCast(body.len),
            .uncompressed_size = @intCast(entry.data.len),
            .offset = @intCast(offset),
        };
        const record = written[index];
        try out.writeAll(&std.zip.local_file_header_sig);
        try out.writeInt(u16, version, .little);
        try out.writeInt(u16, utf8_flag, .little);
        try out.writeInt(u16, @intFromEnum(record.method), .little);
        try out.writeInt(u16, dos_time, .little);
        try out.writeInt(u16, dos_date, .little);
        try out.writeInt(u32, record.crc32, .little);
        try out.writeInt(u32, record.compressed_size, .little);
        try out.writeInt(u32, record.uncompressed_size, .little);
        try out.writeInt(u16, @intCast(entry.name.len), .little);
        try out.writeInt(u16, 0, .little);
        try out.writeAll(entry.name);
        try out.writeAll(body);
        offset += 30 + entry.name.len + body.len;
    }

    if (offset > std.math.maxInt(u32)) return error.ZipTooLarge;
    const central_offset: u32 = @intCast(offset);
    var central_size: u64 = 0;
    for (written) |record| {
        try out.writeAll(&std.zip.central_file_header_sig);
        try out.writeInt(u16, version, .little);
        try out.writeInt(u16, version, .little);
        try out.writeInt(u16, utf8_flag, .little);
        try out.writeInt(u16, @intFromEnum(record.method), .little);
        try out.writeInt(u16, dos_time, .little);
        try out.writeInt(u16, dos_date, .little);
        try out.writeInt(u32, record.crc32, .little);
        try out.writeInt(u32, record.compressed_size, .little);
        try out.writeInt(u32, record.uncompressed_size, .little);
        try out.writeInt(u16, @intCast(record.name.len), .little);
        try out.writeInt(u16, 0, .little);
        try out.writeInt(u16, 0, .little);
        try out.writeInt(u16, 0, .little);
        try out.writeInt(u16, 0, .little);
        try out.writeInt(u32, 0, .little);
        try out.writeInt(u32, record.offset, .little);
        try out.writeAll(record.name);
        central_size += 46 + record.name.len;
    }
    if (central_size > std.math.maxInt(u32)) return error.ZipTooLarge;
    try out.writeAll(&std.zip.end_record_sig);
    try out.writeInt(u16, 0, .little);
    try out.writeInt(u16, 0, .little);
    try out.writeInt(u16, @intCast(entries.len), .little);
    try out.writeInt(u16, @intCast(entries.len), .little);
    try out.writeInt(u32, @intCast(central_size), .little);
    try out.writeInt(u32, central_offset, .little);
    try out.writeInt(u16, 0, .little);
}

/// Collects every file under `root` (a directory path relative to the
/// working directory) as archive entries named by their forward-slash
/// path below it, sorted so the archive is reproducible. The caller frees
/// the names and data with `freeEntries`.
pub fn collectDirectory(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]Entry {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var entries: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(allocator, entries.items);
    errdefer entries.deinit(allocator);
    while (try walker.next(io)) |item| {
        if (item.kind != .file) continue;
        const name = try allocator.dupe(u8, item.path);
        errdefer allocator.free(name);
        std.mem.replaceScalar(u8, name, '\\', '/');
        const data = try dir.readFileAlloc(io, item.path, allocator, .unlimited);
        errdefer allocator.free(data);
        try entries.append(allocator, .{ .name = name, .data = data });
    }
    std.mem.sort(Entry, entries.items, {}, lessThan);
    return entries.toOwnedSlice(allocator);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []const Entry) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.data);
    }
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn validateName(name: []const u8) error{InvalidZipEntryName}!void {
    if (name.len == 0 or name.len > std.math.maxInt(u16)) return error.InvalidZipEntryName;
    if (name[0] == '/' or std.mem.indexOfScalar(u8, name, '\\') != null) return error.InvalidZipEntryName;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidZipEntryName;
    }
}

test "an archive std.zip extracts back to the same tree" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const repetitive = "native " ** 4096;
    const entries = [_]Entry{
        .{ .name = "bin/demo.exe", .data = "MZ-not-really" },
        .{ .name = "resources/assets/text.txt", .data = repetitive },
        .{ .name = "native-install.json", .data = "{}" },
    };
    var archive: std.Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    try write(allocator, &archive.writer, &entries);
    try tmp.dir.writeFile(io, .{ .sub_path = "image.zip", .data = archive.written() });
    try std.testing.expect(archive.written().len < repetitive.len);

    try tmp.dir.createDirPath(io, "out");
    var out = try tmp.dir.openDir(io, "out", .{});
    defer out.close(io);
    var file = try tmp.dir.openFile(io, "image.zip", .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try std.zip.extract(out, &reader, .{});

    for (entries) |entry| {
        const bytes = try out.readFileAlloc(io, entry.name, allocator, .unlimited);
        defer allocator.free(bytes);
        try std.testing.expectEqualStrings(entry.data, bytes);
    }
}

test "the same entries always produce the same bytes" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{.{ .name = "a.txt", .data = "abc" }};
    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();
    try write(allocator, &first.writer, &entries);
    try write(allocator, &second.writer, &entries);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
}

test "entry names stay inside the archive" {
    const allocator = std.testing.allocator;
    var archive: std.Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    for ([_][]const u8{ "", "/abs.txt", "../up.txt", "a/../b.txt", "a\\b.txt", "a//b.txt" }) |name| {
        try std.testing.expectError(error.InvalidZipEntryName, write(allocator, &archive.writer, &.{.{ .name = name, .data = "x" }}));
    }
}
