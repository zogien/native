const std = @import("std");
const builtin = @import("builtin");

const Ed25519 = std.crypto.sign.Ed25519;

pub const max_envelope_bytes: usize = 64 * 1024;
pub const max_payload_bytes: usize = 32 * 1024;
pub const max_release_notes_bytes: usize = 16 * 1024;
pub const max_archive_url_bytes: usize = 4096;
pub const max_archive_bytes: u64 = 8 * 1024 * 1024 * 1024;
pub const max_feed_url_bytes: usize = 4096;
/// A manifest trusts its `public_key` plus up to three `public_keys`, so
/// a release can still be verified by installs that only know the key it
/// is rotating away from.
pub const max_public_keys: usize = 4;

/// The release targets a feed may name, one per installable build.
pub const targets = [_][]const u8{ "macos-aarch64", "macos-x86_64" };

pub fn isTarget(value: []const u8) bool {
    for (targets) |target| {
        if (std.mem.eql(u8, value, target)) return true;
    }
    return false;
}

/// The target this build installs, or null where the updater has no
/// release format.
pub fn currentTarget() ?[]const u8 {
    return comptime switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "macos-aarch64",
            .x86_64 => "macos-x86_64",
            else => null,
        },
        else => null,
    };
}

pub const Envelope = struct {
    payload: []const u8,
    signature: []const u8,
};

pub const Release = struct {
    bundle_id: []const u8,
    version: []const u8,
    target: []const u8,
    archive_url: []const u8,
    archive_bytes: u64,
    sha256: []const u8,
    release_notes: []const u8 = "",
};

pub const VerifiedRelease = struct {
    payload: []u8,
    parsed: std.json.Parsed(Release),
    release: Release,

    pub fn deinit(self: *VerifiedRelease, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.payload);
    }
};

/// Verifies a feed envelope against the app's trusted keys:
/// `public_keys_base64` is one base64 Ed25519 public key, or several
/// joined with commas (the manifest's `public_key` followed by its
/// `public_keys`). The feed verifies when any of them signed the payload;
/// a malformed key fails closed. Fields this version does not know are
/// ignored, in the envelope and in the signed payload, so feeds can grow
/// without breaking installed apps.
pub fn verifyEnvelope(
    allocator: std.mem.Allocator,
    envelope_bytes: []const u8,
    public_keys_base64: []const u8,
) !VerifiedRelease {
    if (envelope_bytes.len == 0 or envelope_bytes.len > max_envelope_bytes) return error.InvalidUpdateFeed;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const envelope = std.json.parseFromSliceLeaky(Envelope, arena.allocator(), envelope_bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidUpdateFeed;

    const payload_size = std.base64.standard.Decoder.calcSizeForSlice(envelope.payload) catch return error.InvalidUpdateFeed;
    if (payload_size == 0 or payload_size > max_payload_bytes) return error.InvalidUpdateFeed;
    const payload = try allocator.alloc(u8, payload_size);
    errdefer allocator.free(payload);
    std.base64.standard.Decoder.decode(payload, envelope.payload) catch return error.InvalidUpdateFeed;

    var signature_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    const signature_size = std.base64.standard.Decoder.calcSizeForSlice(envelope.signature) catch return error.InvalidUpdateSignature;
    if (signature_size != signature_bytes.len) return error.InvalidUpdateSignature;
    std.base64.standard.Decoder.decode(&signature_bytes, envelope.signature) catch return error.InvalidUpdateSignature;

    var public_keys: [max_public_keys]Ed25519.PublicKey = undefined;
    const public_key_count = try parsePublicKeys(public_keys_base64, &public_keys);
    const signature = Ed25519.Signature.fromBytes(signature_bytes);
    const signed = for (public_keys[0..public_key_count]) |public_key| {
        signature.verifyStrict(payload, public_key) catch continue;
        break true;
    } else false;
    if (!signed) return error.InvalidUpdateSignature;

    var parsed = std.json.parseFromSlice(Release, allocator, payload, .{ .ignore_unknown_fields = true }) catch return error.InvalidUpdatePayload;
    errdefer parsed.deinit();
    try validateRelease(parsed.value);
    return .{
        .payload = payload,
        .release = parsed.value,
        .parsed = parsed,
    };
}

/// Decodes a comma-separated list of base64 Ed25519 public keys.
pub fn parsePublicKeys(list: []const u8, output: *[max_public_keys]Ed25519.PublicKey) !usize {
    if (list.len == 0) return error.InvalidUpdateKey;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, list, ',');
    while (parts.next()) |part| {
        if (count == output.len) return error.InvalidUpdateKey;
        var key_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
        const key_size = std.base64.standard.Decoder.calcSizeForSlice(part) catch return error.InvalidUpdateKey;
        if (key_size != key_bytes.len) return error.InvalidUpdateKey;
        std.base64.standard.Decoder.decode(&key_bytes, part) catch return error.InvalidUpdateKey;
        output[count] = Ed25519.PublicKey.fromBytes(key_bytes) catch return error.InvalidUpdateKey;
        count += 1;
    }
    return count;
}

/// Expands a manifest feed_url for one installed app: `{target}` becomes
/// the release target the build installs (for example `macos-aarch64`)
/// and `{current_version}` its version, so one manifest serves a feed
/// per target, or lets a feed server answer per version. Placeholders
/// belong to the path and query; any other brace, or one in the scheme
/// or host, is invalid.
pub fn expandFeedUrl(output: []u8, template: []const u8, target: []const u8, current_version: []const u8) ![]const u8 {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, template, scheme)) return error.InvalidUpdateFeedUrl;
    const authority_end = std.mem.findAnyPos(u8, template, scheme.len, "/?#") orelse template.len;
    if (std.mem.findAny(u8, template[0..authority_end], "{}") != null) return error.InvalidUpdateFeedUrl;
    if (!isTarget(target)) return error.InvalidUpdateFeedUrl;
    _ = try parseVersion(current_version);

    var length: usize = 0;
    var index: usize = 0;
    while (index < template.len) {
        var replacement: []const u8 = template[index .. index + 1];
        var consumed: usize = 1;
        if (template[index] == '{') {
            if (std.mem.startsWith(u8, template[index..], "{target}")) {
                replacement = target;
                consumed = "{target}".len;
            } else if (std.mem.startsWith(u8, template[index..], "{current_version}")) {
                replacement = current_version;
                consumed = "{current_version}".len;
            } else return error.InvalidUpdateFeedUrl;
        } else if (template[index] == '}') return error.InvalidUpdateFeedUrl;
        if (replacement.len > output.len - length) return error.InvalidUpdateFeedUrl;
        @memcpy(output[length..][0..replacement.len], replacement);
        length += replacement.len;
        index += consumed;
    }
    const expanded = output[0..length];
    if (expanded.len > max_feed_url_bytes or !archiveUrlIsValid(expanded)) return error.InvalidUpdateFeedUrl;
    return expanded;
}

pub fn validateRelease(release: Release) !void {
    if (release.bundle_id.len == 0 or release.bundle_id.len > 128) return error.InvalidUpdatePayload;
    _ = try parseVersion(release.version);
    if (!isTarget(release.target)) return error.InvalidUpdatePayload;
    if (!archiveUrlIsValid(release.archive_url)) return error.InvalidUpdatePayload;
    if (release.archive_bytes == 0 or release.archive_bytes > max_archive_bytes) return error.InvalidUpdatePayload;
    if (release.sha256.len != 64) return error.InvalidUpdatePayload;
    for (release.sha256) |byte| if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return error.InvalidUpdatePayload;
    if (release.release_notes.len > max_release_notes_bytes) return error.InvalidUpdatePayload;
}

pub fn archiveUrlIsValid(value: []const u8) bool {
    if (value.len == 0 or value.len > max_archive_url_bytes) return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    const uri = std.Uri.parse(value) catch return false;
    return std.mem.eql(u8, uri.scheme, "https") and uri.host != null and !uri.host.?.isEmpty();
}

pub fn releaseApplies(release: Release, bundle_id: []const u8, current_version: []const u8, target: []const u8) !bool {
    if (!std.mem.eql(u8, release.bundle_id, bundle_id)) return error.UpdateBundleMismatch;
    if (!std.mem.eql(u8, release.target, target)) return error.UpdateTargetMismatch;
    return try versionOrder(current_version, release.version) == .lt;
}

pub fn versionOrder(left: []const u8, right: []const u8) !std.math.Order {
    const left_version = try parseVersion(left);
    const right_version = try parseVersion(right);
    const major = std.math.order(left_version.major, right_version.major);
    if (major != .eq) return major;
    const minor = std.math.order(left_version.minor, right_version.minor);
    if (minor != .eq) return minor;
    return std.math.order(left_version.patch, right_version.patch);
}

pub fn archiveHashMatches(bytes: []const u8, expected_hex: []const u8) bool {
    if (expected_hex.len != std.crypto.hash.sha2.Sha256.digest_length * 2) return false;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    return std.crypto.timing_safe.eql([actual.len]u8, actual, expected_hex[0..actual.len].*);
}

const Version = struct { major: u64, minor: u64, patch: u64 };

fn parseVersion(value: []const u8) !Version {
    var parts = std.mem.splitScalar(u8, value, '.');
    const major = try parseVersionPart(parts.next() orelse return error.InvalidVersion);
    const minor = try parseVersionPart(parts.next() orelse return error.InvalidVersion);
    const patch = try parseVersionPart(parts.next() orelse return error.InvalidVersion);
    if (parts.next() != null) return error.InvalidVersion;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn parseVersionPart(value: []const u8) !u64 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return error.InvalidVersion;
    return std.fmt.parseUnsigned(u64, value, 10) catch error.InvalidVersion;
}

test "signed envelope verifies and yields its release" {
    const allocator = std.testing.allocator;
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** Ed25519.KeyPair.seed_length);
    const payload =
        \\{"bundle_id":"com.example.demo","version":"1.2.3","target":"macos-aarch64","archive_url":"https://example.com/demo.tar.gz","archive_bytes":42,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","release_notes":"Better."}
    ;
    const signature = try key_pair.sign(payload, null);
    var payload_base64: [std.base64.standard.Encoder.calcSize(payload.len)]u8 = undefined;
    var signature_base64: [std.base64.standard.Encoder.calcSize(Ed25519.Signature.encoded_length)]u8 = undefined;
    var public_key_base64: [std.base64.standard.Encoder.calcSize(Ed25519.PublicKey.encoded_length)]u8 = undefined;
    const envelope = try std.fmt.allocPrint(allocator, "{{\"payload\":\"{s}\",\"signature\":\"{s}\"}}", .{
        std.base64.standard.Encoder.encode(&payload_base64, payload),
        std.base64.standard.Encoder.encode(&signature_base64, &signature.toBytes()),
    });
    defer allocator.free(envelope);
    const public_key = std.base64.standard.Encoder.encode(&public_key_base64, &key_pair.public_key.toBytes());
    var verified = try verifyEnvelope(allocator, envelope, public_key);
    defer verified.deinit(allocator);
    try std.testing.expectEqualStrings("1.2.3", verified.release.version);
    try std.testing.expect(try releaseApplies(verified.release, "com.example.demo", "1.2.2", "macos-aarch64"));
}

test "tampered payload is rejected" {
    const allocator = std.testing.allocator;
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x24} ** Ed25519.KeyPair.seed_length);
    const payload = "{}";
    const signature = try key_pair.sign(payload, null);
    var signature_base64: [std.base64.standard.Encoder.calcSize(Ed25519.Signature.encoded_length)]u8 = undefined;
    var public_key_base64: [std.base64.standard.Encoder.calcSize(Ed25519.PublicKey.encoded_length)]u8 = undefined;
    const envelope = try std.fmt.allocPrint(allocator, "{{\"payload\":\"eyJhIjoxfQ==\",\"signature\":\"{s}\"}}", .{
        std.base64.standard.Encoder.encode(&signature_base64, &signature.toBytes()),
    });
    defer allocator.free(envelope);
    const public_key = std.base64.standard.Encoder.encode(&public_key_base64, &key_pair.public_key.toBytes());
    try std.testing.expectError(error.InvalidUpdateSignature, verifyEnvelope(allocator, envelope, public_key));
}

test "semantic versions compare numerically" {
    try std.testing.expectEqual(std.math.Order.lt, try versionOrder("1.9.9", "1.10.0"));
    try std.testing.expectEqual(std.math.Order.eq, try versionOrder("2.0.0", "2.0.0"));
    try std.testing.expectEqual(std.math.Order.gt, try versionOrder("3.0.0", "2.99.99"));
    try std.testing.expectError(error.InvalidVersion, versionOrder("1.010.0", "1.9.0"));
    try std.testing.expectError(error.InvalidVersion, versionOrder("1.9.0", "1.010.0"));
    try std.testing.expectError(error.InvalidVersion, releaseApplies(.{
        .bundle_id = "com.example.demo",
        .version = "1.9.0",
        .target = "macos-aarch64",
        .archive_url = "https://example.com/demo.zip",
        .archive_bytes = 42,
        .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }, "com.example.demo", "1.010.0", "macos-aarch64"));
}

test "archive URLs fit the runtime output buffer" {
    var maximum: [max_archive_url_bytes]u8 = [_]u8{'a'} ** max_archive_url_bytes;
    @memcpy(maximum[0.."https://".len], "https://");
    try validateRelease(.{
        .bundle_id = "com.example.demo",
        .version = "1.2.3",
        .target = "macos-aarch64",
        .archive_url = &maximum,
        .archive_bytes = 42,
        .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    });

    var oversized: [max_archive_url_bytes + 1]u8 = [_]u8{'a'} ** (max_archive_url_bytes + 1);
    @memcpy(oversized[0.."https://".len], "https://");
    try std.testing.expectError(error.InvalidUpdatePayload, validateRelease(.{
        .bundle_id = "com.example.demo",
        .version = "1.2.3",
        .target = "macos-aarch64",
        .archive_url = &oversized,
        .archive_bytes = 42,
        .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }));

    try std.testing.expect(!archiveUrlIsValid("https://"));
    try std.testing.expect(!archiveUrlIsValid("https://example.com/release file.zip"));
    try std.testing.expect(!archiveUrlIsValid("https://example.com/release.zip\n"));
    try std.testing.expect(!archiveUrlIsValid("http://example.com/release.zip"));
    try std.testing.expect(archiveUrlIsValid("https://example.com/releases/demo.zip?channel=stable"));
}

fn testEnvelopeAlloc(allocator: std.mem.Allocator, key_pair: Ed25519.KeyPair, payload: []const u8) ![]u8 {
    const signature = try key_pair.sign(payload, null);
    const payload_base64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(payload.len));
    defer allocator.free(payload_base64);
    var signature_base64: [std.base64.standard.Encoder.calcSize(Ed25519.Signature.encoded_length)]u8 = undefined;
    return std.fmt.allocPrint(allocator, "{{\"payload\":\"{s}\",\"signature\":\"{s}\"}}", .{
        std.base64.standard.Encoder.encode(payload_base64, payload),
        std.base64.standard.Encoder.encode(&signature_base64, &signature.toBytes()),
    });
}

fn testPublicKey(key_pair: Ed25519.KeyPair, buffer: *[std.base64.standard.Encoder.calcSize(Ed25519.PublicKey.encoded_length)]u8) []const u8 {
    return std.base64.standard.Encoder.encode(buffer, &key_pair.public_key.toBytes());
}

const test_payload =
    \\{"bundle_id":"com.example.demo","version":"1.2.3","target":"macos-aarch64","archive_url":"https://example.com/demo.zip","archive_bytes":42,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
;

test "a feed verifies when any trusted key signed it" {
    const allocator = std.testing.allocator;
    const old_key = try Ed25519.KeyPair.generateDeterministic([_]u8{0x11} ** Ed25519.KeyPair.seed_length);
    const new_key = try Ed25519.KeyPair.generateDeterministic([_]u8{0x22} ** Ed25519.KeyPair.seed_length);
    var old_buffer: [44]u8 = undefined;
    var new_buffer: [44]u8 = undefined;
    const old_public = testPublicKey(old_key, &old_buffer);
    const new_public = testPublicKey(new_key, &new_buffer);
    const envelope = try testEnvelopeAlloc(allocator, old_key, test_payload);
    defer allocator.free(envelope);

    const both = try std.fmt.allocPrint(allocator, "{s},{s}", .{ new_public, old_public });
    defer allocator.free(both);
    var verified = try verifyEnvelope(allocator, envelope, both);
    verified.deinit(allocator);
    try std.testing.expectError(error.InvalidUpdateSignature, verifyEnvelope(allocator, envelope, new_public));

    const malformed = try std.fmt.allocPrint(allocator, "{s},not-a-key", .{old_public});
    defer allocator.free(malformed);
    try std.testing.expectError(error.InvalidUpdateKey, verifyEnvelope(allocator, envelope, malformed));
    const trailing = try std.fmt.allocPrint(allocator, "{s},", .{old_public});
    defer allocator.free(trailing);
    try std.testing.expectError(error.InvalidUpdateKey, verifyEnvelope(allocator, envelope, trailing));
    const too_many = try std.fmt.allocPrint(allocator, "{s},{s},{s},{s},{s}", .{ new_public, new_public, new_public, new_public, old_public });
    defer allocator.free(too_many);
    try std.testing.expectError(error.InvalidUpdateKey, verifyEnvelope(allocator, envelope, too_many));
}

test "fields a newer feed adds are ignored" {
    const allocator = std.testing.allocator;
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x33} ** Ed25519.KeyPair.seed_length);
    var key_buffer: [44]u8 = undefined;
    const payload =
        \\{"bundle_id":"com.example.demo","version":"1.2.3","target":"macos-x86_64","archive_url":"https://example.com/demo.zip","archive_bytes":42,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","channel":"beta"}
    ;
    const envelope = try testEnvelopeAlloc(allocator, key_pair, payload);
    defer allocator.free(envelope);
    const extended = try std.fmt.allocPrint(allocator, "{s},\"format\":2}}", .{envelope[0 .. envelope.len - 1]});
    defer allocator.free(extended);
    var verified = try verifyEnvelope(allocator, extended, testPublicKey(key_pair, &key_buffer));
    defer verified.deinit(allocator);
    try std.testing.expectEqualStrings("macos-x86_64", verified.release.target);
}

test "feed URLs expand the target and installed version" {
    var buffer: [max_feed_url_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://example.com/releases/macos-aarch64/native-update.json?from=1.2.3",
        try expandFeedUrl(&buffer, "https://example.com/releases/{target}/native-update.json?from={current_version}", "macos-aarch64", "1.2.3"),
    );
    try std.testing.expectEqualStrings(
        "https://example.com/native-update.json",
        try expandFeedUrl(&buffer, "https://example.com/native-update.json", "macos-x86_64", "1.0.0"),
    );
    try std.testing.expectError(error.InvalidUpdateFeedUrl, expandFeedUrl(&buffer, "https://example.com/{arch}/feed.json", "macos-aarch64", "1.2.3"));
    try std.testing.expectError(error.InvalidUpdateFeedUrl, expandFeedUrl(&buffer, "https://example.com/{target/feed.json", "macos-aarch64", "1.2.3"));
    try std.testing.expectError(error.InvalidUpdateFeedUrl, expandFeedUrl(&buffer, "https://example.com/target}/feed.json", "macos-aarch64", "1.2.3"));
    try std.testing.expectError(error.InvalidUpdateFeedUrl, expandFeedUrl(&buffer, "https://{target}.example.com/feed.json", "macos-aarch64", "1.2.3"));
    try std.testing.expectError(error.InvalidUpdateFeedUrl, expandFeedUrl(&buffer, "http://example.com/{target}/feed.json", "macos-aarch64", "1.2.3"));
    try std.testing.expectError(error.InvalidUpdateFeedUrl, expandFeedUrl(&buffer, "https://example.com/{target}/feed.json", "linux-x86_64", "1.2.3"));
    try std.testing.expectError(error.InvalidVersion, expandFeedUrl(&buffer, "https://example.com/{target}/feed.json", "macos-aarch64", "1.02.3"));
    var small: [24]u8 = undefined;
    try std.testing.expectError(error.InvalidUpdateFeedUrl, expandFeedUrl(&small, "https://example.com/{target}/feed.json", "macos-aarch64", "1.2.3"));
}

test "only builds with a release format have an update target" {
    const target = currentTarget();
    if (builtin.os.tag == .macos and (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64)) {
        try std.testing.expect(isTarget(target.?));
    } else {
        try std.testing.expect(target == null);
    }
}
