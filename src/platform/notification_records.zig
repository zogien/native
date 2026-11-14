//! Process-scoped command bindings for desktop notifications.
//!
//! A notification can outlive the process that showed it (Notification
//! Center, Action Center and GNotification all keep entries after the app
//! exits), so a host never attaches a command name to the notification it
//! hands the OS. It attaches an opaque random token instead, and this table
//! maps the token back to the commands while the process runs. A click from
//! an earlier process carries a token no table knows, so it dispatches
//! nothing.
//!
//! The table is bounded. Records exist only for notifications that carry a
//! command, any activation consumes the record, reissuing an id retires the
//! record of the notification it replaces, and past `capacity` the oldest
//! record is dropped. A dropped record behaves like one from an earlier
//! process: the OS keeps showing the notification, and clicking it only
//! brings the app forward. Nothing here depends on the OS reporting that a
//! notification was dismissed; most notification channels never report it.

const std = @import("std");
const types = @import("types.zig");

/// Upper bound on live bindings. GNOME Shell keeps at most 10
/// notifications per app; the bound leaves headroom above what any
/// notification list keeps clickable, at a few dozen KiB of storage.
pub const capacity: usize = 64;
pub const token_entropy_bytes: usize = 16;
/// Tokens are lowercase hex, so every host can carry them as plain text.
pub const token_len: usize = token_entropy_bytes * 2;
pub const Token = [token_len]u8;

pub const max_command_bytes: usize = @max(types.max_notification_action_command_bytes, types.max_notification_activation_command_bytes);

/// What the user clicked: the notification itself, or its action button.
pub const Activation = enum(u8) { body, action };

pub const Command = struct {
    bytes: [max_command_bytes]u8 = undefined,
    len: usize = 0,

    pub fn name(self: *const Command) []const u8 {
        return self.bytes[0..self.len];
    }

    fn set(self: *Command, value: []const u8) void {
        @memcpy(self.bytes[0..value.len], value);
        self.len = value.len;
    }
};

const Entry = struct {
    /// Insertion order; zero marks a free slot.
    sequence: u64 = 0,
    token: Token = undefined,
    id: [types.max_notification_id_bytes]u8 = undefined,
    id_len: usize = 0,
    activation: Command = .{},
    action: Command = .{},
};

pub const Records = struct {
    /// Allocated with the first commanded notification; most apps never
    /// show one.
    entries: ?*[capacity]Entry = null,
    next_sequence: u64 = 1,

    pub fn deinit(self: *Records, allocator: std.mem.Allocator) void {
        if (self.entries) |entries| allocator.destroy(entries);
        self.* = .{};
    }

    /// Bind a notification that is about to be shown. A nonempty id first
    /// retires the record of the notification it replaces, whether or not
    /// the new one carries commands. Returns the token the host attaches to
    /// the notification, or null when it carries no command.
    pub fn bind(self: *Records, allocator: std.mem.Allocator, options: types.NotificationOptions) error{ OutOfMemory, NotificationFieldTooLarge }!?Token {
        if (options.id.len > types.max_notification_id_bytes or
            options.action_command.len > types.max_notification_action_command_bytes or
            options.activation_command.len > types.max_notification_activation_command_bytes)
        {
            return error.NotificationFieldTooLarge;
        }
        if (options.id.len > 0) self.forget(options.id);
        if (options.action_command.len == 0 and options.activation_command.len == 0) return null;

        const entries = self.entries orelse blk: {
            const allocated = try allocator.create([capacity]Entry);
            allocated.* = [_]Entry{.{}} ** capacity;
            self.entries = allocated;
            break :blk allocated;
        };
        const entry = slot(entries);
        entry.* = .{ .sequence = self.next_sequence };
        self.next_sequence += 1;
        newToken(&entry.token);
        @memcpy(entry.id[0..options.id.len], options.id);
        entry.id_len = options.id.len;
        entry.activation.set(options.activation_command);
        entry.action.set(options.action_command);
        return entry.token;
    }

    /// Consume the record for `token`. Returns the command bound to that
    /// kind of activation, or null when the token is unknown (an earlier
    /// process, a replaced or dropped record) or nothing is bound to it.
    /// Either way the record is gone afterwards: one notification
    /// dispatches at most once.
    pub fn activate(self: *Records, token: []const u8, kind: Activation) ?Command {
        const entry = self.find(token) orelse return null;
        const command = switch (kind) {
            .body => entry.activation,
            .action => entry.action,
        };
        entry.* = .{};
        return if (command.len == 0) null else command;
    }

    /// The token bound to the live notification with this id, if any.
    pub fn tokenFor(self: *const Records, id: []const u8) ?Token {
        if (id.len == 0) return null;
        const entries = self.entries orelse return null;
        for (entries) |*entry| {
            if (entry.sequence != 0 and std.mem.eql(u8, entry.id[0..entry.id_len], id)) return entry.token;
        }
        return null;
    }

    pub fn count(self: *const Records) usize {
        const entries = self.entries orelse return 0;
        var live: usize = 0;
        for (entries) |*entry| {
            if (entry.sequence != 0) live += 1;
        }
        return live;
    }

    fn forget(self: *Records, id: []const u8) void {
        const entries = self.entries orelse return;
        for (entries) |*entry| {
            if (entry.sequence != 0 and std.mem.eql(u8, entry.id[0..entry.id_len], id)) entry.* = .{};
        }
    }

    fn find(self: *Records, token: []const u8) ?*Entry {
        if (token.len != token_len) return null;
        const entries = self.entries orelse return null;
        for (entries) |*entry| {
            if (entry.sequence != 0 and std.mem.eql(u8, &entry.token, token)) return entry;
        }
        return null;
    }
};

/// A free slot, else the oldest record, which is dropped.
fn slot(entries: *[capacity]Entry) *Entry {
    var oldest: *Entry = &entries[0];
    for (entries) |*entry| {
        if (entry.sequence == 0) return entry;
        if (entry.sequence < oldest.sequence) oldest = entry;
    }
    return oldest;
}

fn newToken(out: *Token) void {
    var entropy: [token_entropy_bytes]u8 = undefined;
    // Platform hosts hold no `std.Io`; the process-global instance's CSPRNG
    // is seeded from OS entropy and is thread-safe.
    std.Io.Threaded.global_single_threaded.io().random(&entropy);
    const digits = "0123456789abcdef";
    for (entropy, 0..) |byte, index| {
        out[index * 2] = digits[byte >> 4];
        out[index * 2 + 1] = digits[byte & 0x0f];
    }
}

const testing = std.testing;

fn sample(id: []const u8, activation: []const u8, action: []const u8) types.NotificationOptions {
    return .{
        .id = id,
        .title = "Title",
        .activation_command = activation,
        .action_label = if (action.len > 0) "Act" else "",
        .action_command = action,
    };
}

test "notifications without commands need no record" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);
    try testing.expect((try records.bind(testing.allocator, sample("", "", ""))) == null);
    try testing.expect((try records.bind(testing.allocator, sample("status", "", ""))) == null);
    try testing.expect(records.entries == null);
    try testing.expectEqual(@as(usize, 0), records.count());
}

test "body and action clicks dispatch their own command once" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);
    const both = (try records.bind(testing.allocator, sample("sync", "sync.open", "sync.cancel"))).?;
    try testing.expectEqualStrings("sync.open", records.activate(&both, .body).?.name());
    try testing.expect(records.activate(&both, .action) == null);

    const again = (try records.bind(testing.allocator, sample("sync", "sync.open", "sync.cancel"))).?;
    try testing.expectEqualStrings("sync.cancel", records.activate(&again, .action).?.name());
    try testing.expect(records.activate(&again, .body) == null);
    try testing.expectEqual(@as(usize, 0), records.count());
}

test "a body click without an activation command still consumes the record" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);
    const token = (try records.bind(testing.allocator, sample("", "", "build.open"))).?;
    try testing.expect(records.activate(&token, .body) == null);
    try testing.expect(records.activate(&token, .action) == null);
    try testing.expectEqual(@as(usize, 0), records.count());
}

test "reissuing an id retires the replaced binding even for display-only notifications" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);
    const first = (try records.bind(testing.allocator, sample("sync", "", "sync.cancel"))).?;
    const second = (try records.bind(testing.allocator, sample("sync", "", "sync.view"))).?;
    try testing.expect(!std.mem.eql(u8, &first, &second));
    try testing.expect(records.activate(&first, .action) == null);
    try testing.expectEqualSlices(u8, &second, &records.tokenFor("sync").?);

    try testing.expect((try records.bind(testing.allocator, sample("sync", "", ""))) == null);
    try testing.expect(records.tokenFor("sync") == null);
    try testing.expect(records.activate(&second, .action) == null);
}

test "the oldest binding is dropped past capacity" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);
    var tokens: [capacity + 1]Token = undefined;
    for (&tokens) |*token| token.* = (try records.bind(testing.allocator, sample("", "", "app.open"))).?;
    try testing.expectEqual(capacity, records.count());
    try testing.expect(records.activate(&tokens[0], .action) == null);
    try testing.expectEqualStrings("app.open", records.activate(&tokens[1], .action).?.name());
    try testing.expectEqualStrings("app.open", records.activate(&tokens[capacity], .action).?.name());
}

test "unknown and malformed tokens dispatch nothing" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);
    try testing.expect(records.activate("", .body) == null);
    const token = (try records.bind(testing.allocator, sample("", "app.open", ""))).?;
    try testing.expect(records.activate(token[0 .. token_len - 1], .body) == null);
    var foreign = token;
    foreign[0] = if (foreign[0] == 'a') 'b' else 'a';
    try testing.expect(records.activate(&foreign, .body) == null);
    for (token) |digit| try testing.expect(std.ascii.isDigit(digit) or (digit >= 'a' and digit <= 'f'));
    try testing.expectEqualStrings("app.open", records.activate(&token, .body).?.name());
}

test "over-bound fields are refused without touching the table" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);
    const long_command = [_]u8{'x'} ** (max_command_bytes + 1);
    try testing.expectError(error.NotificationFieldTooLarge, records.bind(testing.allocator, sample("", &long_command, "")));
    try testing.expect(records.entries == null);
}
