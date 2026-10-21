//! The setup program's payload: `native package --installer` appends the
//! install configuration and the install image (a ZIP) to the setup
//! program, followed by a fixed trailer that locates both and carries
//! their SHA-256. Signing setup.exe with Authenticode appends the
//! certificate table after the trailer (8-byte aligned), so the reader
//! looks for the trailer just before that table when the PE header names
//! one, and at the end of the file otherwise.

const std = @import("std");

pub const magic = "NSDK-SETUP-V1\x00\x00\x00";
pub const trailer_len: usize = magic.len + 4 * @sizeOf(u64) + Sha256.digest_length;

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Trailer = struct {
    config_offset: u64,
    config_size: u64,
    zip_offset: u64,
    zip_size: u64,
    sha256: [Sha256.digest_length]u8,

    /// The setup program itself: everything before the configuration.
    pub fn programSize(self: Trailer) u64 {
        return self.config_offset;
    }
};

pub fn encode(trailer: Trailer) [trailer_len]u8 {
    var bytes: [trailer_len]u8 = undefined;
    @memcpy(bytes[0..magic.len], magic);
    std.mem.writeInt(u64, bytes[16..24], trailer.config_offset, .little);
    std.mem.writeInt(u64, bytes[24..32], trailer.config_size, .little);
    std.mem.writeInt(u64, bytes[32..40], trailer.zip_offset, .little);
    std.mem.writeInt(u64, bytes[40..48], trailer.zip_size, .little);
    @memcpy(bytes[48..80], &trailer.sha256);
    return bytes;
}

/// Decodes a trailer and checks that the regions it names sit in order
/// before `trailer_offset`.
pub fn decode(bytes: *const [trailer_len]u8, trailer_offset: u64) ?Trailer {
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return null;
    const trailer: Trailer = .{
        .config_offset = std.mem.readInt(u64, bytes[16..24], .little),
        .config_size = std.mem.readInt(u64, bytes[24..32], .little),
        .zip_offset = std.mem.readInt(u64, bytes[32..40], .little),
        .zip_size = std.mem.readInt(u64, bytes[40..48], .little),
        .sha256 = bytes[48..80].*,
    };
    if (trailer.config_offset == 0 or trailer.config_size == 0 or trailer.zip_size == 0) return null;
    const config_end = std.math.add(u64, trailer.config_offset, trailer.config_size) catch return null;
    if (trailer.zip_offset != config_end) return null;
    const zip_end = std.math.add(u64, trailer.zip_offset, trailer.zip_size) catch return null;
    if (zip_end != trailer_offset) return null;
    return trailer;
}

/// Where the setup data ends: the start of the Authenticode certificate
/// table when the PE header names one that ends the file, else the file
/// size. `headers` holds the file's first bytes (at least the PE headers).
pub fn dataEnd(headers: []const u8, file_size: u64) u64 {
    if (headers.len < 0x40 or !std.mem.eql(u8, headers[0..2], "MZ")) return file_size;
    const pe_offset: usize = std.mem.readInt(u32, headers[0x3c..0x40], .little);
    if (pe_offset > headers.len -| 24 or !std.mem.eql(u8, headers[pe_offset..][0..4], "PE\x00\x00")) return file_size;
    const optional_offset = pe_offset + 24;
    if (optional_offset + 2 > headers.len) return file_size;
    const directories_offset: usize = switch (std.mem.readInt(u16, headers[optional_offset..][0..2], .little)) {
        0x10b => optional_offset + 96,
        0x20b => optional_offset + 112,
        else => return file_size,
    };
    const security_offset = directories_offset + 4 * 8;
    if (security_offset + 8 > headers.len) return file_size;
    const table_offset: u64 = std.mem.readInt(u32, headers[security_offset..][0..4], .little);
    const table_size: u64 = std.mem.readInt(u32, headers[security_offset + 4 ..][0..4], .little);
    if (table_offset == 0 or table_size == 0 or table_offset + table_size != file_size) return file_size;
    return table_offset;
}

/// Finds the trailer in the bytes that end at `end` (`tail` holds those
/// bytes, at least `trailer_len + 7` of them when available), allowing
/// the up to seven zero bytes of padding signing adds before the
/// certificate table.
pub fn find(tail: []const u8, end: u64) ?Trailer {
    var padding: usize = 0;
    while (padding <= 7 and padding + trailer_len <= tail.len) : (padding += 1) {
        const at = tail.len - padding - trailer_len;
        for (tail[tail.len - padding ..]) |byte| {
            if (byte != 0) return null;
        }
        if (decode(tail[at..][0..trailer_len], end - padding - trailer_len)) |trailer| return trailer;
    }
    return null;
}

pub fn digest(config_bytes: []const u8, zip_bytes: []const u8) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(config_bytes);
    hasher.update(zip_bytes);
    var out: [Sha256.digest_length]u8 = undefined;
    hasher.final(&out);
    return out;
}

test "a trailer locates the configuration and image before it" {
    const trailer: Trailer = .{ .config_offset = 1000, .config_size = 200, .zip_offset = 1200, .zip_size = 5000, .sha256 = [_]u8{7} ** 32 };
    const bytes = encode(trailer);
    const decoded = decode(&bytes, 6200).?;
    try std.testing.expectEqual(@as(u64, 1200), decoded.zip_offset);
    try std.testing.expectEqual(@as(u64, 1000), decoded.programSize());
    try std.testing.expect(decode(&bytes, 6300) == null);
    var corrupt = bytes;
    corrupt[0] = 'X';
    try std.testing.expect(decode(&corrupt, 6200) == null);
}

test "the trailer is found before signing padding" {
    const trailer: Trailer = .{ .config_offset = 10, .config_size = 5, .zip_offset = 15, .zip_size = 20, .sha256 = [_]u8{1} ** 32 };
    var tail: [trailer_len + 7]u8 = undefined;
    @memcpy(tail[0..trailer_len], &encode(trailer));
    @memset(tail[trailer_len..], 0);
    // Payload ends at 35, the trailer takes 80 bytes, then 7 bytes of
    // padding precede the certificate table at 122.
    try std.testing.expectEqual(@as(u64, 15), find(&tail, 35 + trailer_len + 7).?.zip_offset);
    try std.testing.expectEqual(@as(u64, 15), find(tail[0..trailer_len], 35 + trailer_len).?.zip_offset);
    tail[trailer_len + 3] = 1;
    try std.testing.expect(find(&tail, 35 + trailer_len + 7) == null);
}

test "data ends at a certificate table that ends the file" {
    var headers = [_]u8{0} ** 0x200;
    headers[0] = 'M';
    headers[1] = 'Z';
    std.mem.writeInt(u32, headers[0x3c..0x40], 0x80, .little);
    @memcpy(headers[0x80..0x84], "PE\x00\x00");
    std.mem.writeInt(u16, headers[0x98..0x9a], 0x20b, .little);
    const security = 0x98 + 112 + 32;
    std.mem.writeInt(u32, headers[security..][0..4], 4096, .little);
    std.mem.writeInt(u32, headers[security + 4 ..][0..4], 512, .little);
    try std.testing.expectEqual(@as(u64, 4096), dataEnd(&headers, 4608));
    try std.testing.expectEqual(@as(u64, 9000), dataEnd(&headers, 9000));
    std.mem.writeInt(u32, headers[security..][0..4], 0, .little);
    try std.testing.expectEqual(@as(u64, 4608), dataEnd(&headers, 4608));
    try std.testing.expectEqual(@as(u64, 77), dataEnd("not a pe file", 77));
}
