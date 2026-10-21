//! Moving a staged app version into place inside an install root:
//!
//!   <root>\<name>.exe   the launcher, at a stable path
//!   <root>\app\         the current version
//!   <root>\app.next\    a staged version, complete once it holds .native-staged
//!   <root>\app.prev\    the version before the last switch
//!
//! The executable inside app\ keeps one path across versions, so the
//! settings Windows keys to that path (firewall rules, GPU preference,
//! compatibility flags) survive updates. The switch renames whole
//! directories. Windows renames a directory even while an executable in
//! it runs, so callers first make sure no process runs from app\; a
//! rename that still fails (another program holding a file open) leaves
//! the install as it was. A journal file marks the window between the two
//! renames, and `recover` finishes or undoes an interrupted switch on the
//! next launch.

const std = @import("std");

pub const current = "app";
pub const staged = "app.next";
pub const previous = "app.prev";
pub const journal = ".native-switch";
/// Written into app.next last, after every file of the staged version.
pub const staged_marker = ".native-staged";
/// `updated <from> <to>`, written by the launcher after it switched to a
/// staged version, and read once by that version's updater.
pub const update_result = ".native-update-result";

pub const Outcome = enum {
    /// No complete staged version.
    nothing_staged,
    switched,
    /// A file of the current version is held open; nothing changed.
    busy,
};

/// Finishes an interrupted switch, then moves a complete staged version
/// into place. The caller has checked that no process runs from app\.
/// The steps:
///   1. remove an old app.prev,
///   2. write the journal,
///   3. rename app -> app.prev,
///   4. rename app.next -> app,
///   5. remove the journal.
/// A failed step 1 or 3 leaves the install as it was.
pub fn applyStaged(root: std.Io.Dir, io: std.Io) !Outcome {
    try recover(root, io);
    if (!exists(root, io, staged ++ "/" ++ staged_marker)) return .nothing_staged;

    if (exists(root, io, previous)) {
        root.deleteTree(io, previous) catch return .busy;
    }
    const had_current = exists(root, io, current);
    try root.writeFile(io, .{ .sub_path = journal, .data = "switching\n" });
    if (had_current) {
        root.renamePreserve(current, root, previous, io) catch {
            root.deleteFile(io, journal) catch {};
            return .busy;
        };
    }
    try root.renamePreserve(staged, root, current, io);
    root.deleteFile(io, current ++ "/" ++ staged_marker) catch {};
    try root.deleteFile(io, journal);
    return .switched;
}

/// Completes or undoes a switch a crash interrupted. Only acts while the
/// journal exists.
pub fn recover(root: std.Io.Dir, io: std.Io) !void {
    if (!exists(root, io, journal)) return;
    if (!exists(root, io, current)) {
        if (exists(root, io, staged)) {
            try root.renamePreserve(staged, root, current, io);
            root.deleteFile(io, current ++ "/" ++ staged_marker) catch {};
        } else if (exists(root, io, previous)) {
            try root.renamePreserve(previous, root, current, io);
        }
    }
    try root.deleteFile(io, journal);
}

/// Prepares app.next for a new staged copy, removing an earlier one.
pub fn clearStaged(root: std.Io.Dir, io: std.Io) !void {
    if (exists(root, io, staged)) try root.deleteTree(io, staged);
}

/// Marks app.next complete. Call after every file is in place.
pub fn markStaged(root: std.Io.Dir, io: std.Io) !void {
    try root.writeFile(io, .{ .sub_path = staged ++ "/" ++ staged_marker, .data = "staged\n" });
}

fn exists(root: std.Io.Dir, io: std.Io, sub_path: []const u8) bool {
    root.access(io, sub_path, .{}) catch return false;
    return true;
}

fn writeVersion(root: std.Io.Dir, io: std.Io, comptime dir: []const u8, version: []const u8) !void {
    try root.createDirPath(io, dir ++ "/bin");
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/bin/version.txt", .{dir});
    defer std.testing.allocator.free(path);
    try root.writeFile(io, .{ .sub_path = path, .data = version });
}

fn readVersion(root: std.Io.Dir, io: std.Io, dir: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/bin/version.txt", .{dir});
    defer std.testing.allocator.free(path);
    return root.readFileAlloc(io, path, std.testing.allocator, .limited(64));
}

test "a first install moves the staged version into place" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeVersion(tmp.dir, io, staged, "1.0.0");
    try std.testing.expectEqual(Outcome.nothing_staged, try applyStaged(tmp.dir, io));
    try markStaged(tmp.dir, io);
    try std.testing.expectEqual(Outcome.switched, try applyStaged(tmp.dir, io));
    const version = try readVersion(tmp.dir, io, current);
    defer std.testing.allocator.free(version);
    try std.testing.expectEqualStrings("1.0.0", version);
    try std.testing.expect(!exists(tmp.dir, io, staged));
    try std.testing.expect(!exists(tmp.dir, io, journal));
    try std.testing.expect(!exists(tmp.dir, io, current ++ "/" ++ staged_marker));
}

test "a switch keeps the previous version and replaces an older one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeVersion(tmp.dir, io, previous, "0.9.0");
    try writeVersion(tmp.dir, io, current, "1.0.0");
    try writeVersion(tmp.dir, io, staged, "1.1.0");
    try markStaged(tmp.dir, io);
    try std.testing.expectEqual(Outcome.switched, try applyStaged(tmp.dir, io));
    const now = try readVersion(tmp.dir, io, current);
    defer std.testing.allocator.free(now);
    const before = try readVersion(tmp.dir, io, previous);
    defer std.testing.allocator.free(before);
    try std.testing.expectEqualStrings("1.1.0", now);
    try std.testing.expectEqualStrings("1.0.0", before);
}

test "recovery finishes a switch interrupted between its renames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    // A crash after app -> app.prev and before app.next -> app.
    try writeVersion(tmp.dir, io, previous, "1.0.0");
    try writeVersion(tmp.dir, io, staged, "1.1.0");
    try markStaged(tmp.dir, io);
    try tmp.dir.writeFile(io, .{ .sub_path = journal, .data = "switching\n" });
    try recover(tmp.dir, io);
    const version = try readVersion(tmp.dir, io, current);
    defer std.testing.allocator.free(version);
    try std.testing.expectEqualStrings("1.1.0", version);
    try std.testing.expect(!exists(tmp.dir, io, journal));
}

test "recovery restores the previous version when the staged copy is gone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeVersion(tmp.dir, io, previous, "1.0.0");
    try tmp.dir.writeFile(io, .{ .sub_path = journal, .data = "switching\n" });
    try recover(tmp.dir, io);
    const version = try readVersion(tmp.dir, io, current);
    defer std.testing.allocator.free(version);
    try std.testing.expectEqualStrings("1.0.0", version);
}

test "an incomplete staged copy is never switched in" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeVersion(tmp.dir, io, current, "1.0.0");
    try writeVersion(tmp.dir, io, staged, "1.1.0");
    try std.testing.expectEqual(Outcome.nothing_staged, try applyStaged(tmp.dir, io));
    const version = try readVersion(tmp.dir, io, current);
    defer std.testing.allocator.free(version);
    try std.testing.expectEqualStrings("1.0.0", version);
    try clearStaged(tmp.dir, io);
    try std.testing.expect(!exists(tmp.dir, io, staged));
}
