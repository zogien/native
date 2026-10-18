//! Single-instance ownership (manifest `single_instance`): one process per
//! bundle id, user, and login session owns the app. The first launch to
//! claim ownership becomes the primary. A later launch hands its working
//! directory and arguments to the primary, reports the delivery through
//! its exit code, and exits before any window exists. The primary's core
//! receives each launch on the `native-sdk.app.launches` channel source
//! (`attach`) as one `"data"` event and decides what to do with it.
//!
//! Windows is the implemented host: a message-mode named pipe created with
//! FILE_FLAG_FIRST_PIPE_INSTANCE is both the ownership lock and the
//! notification endpoint. The kernel retires it with the process, so a
//! normal exit or a crash leaves no stale ownership. Other hosts answer
//! `.standalone` and run without ownership.
const std = @import("std");
const builtin = @import("builtin");
const effects = @import("effects.zig");
const clock = @import("clock.zig");

const is_windows = builtin.os.tag == .windows;

pub const source_name = "native-sdk.app.launches";

/// One launch notification is the later process's working directory,
/// then each of its arguments (argv[0] excluded), every field preceded by
/// a NUL except the first. Paths and arguments never contain NUL, so the
/// split is unambiguous; a launch without arguments is the bare working
/// directory. The bound is the channel's post bound.
pub const max_launch_bytes = effects.max_effect_channel_bytes;

/// How long the primary holds a launch while its core has not opened the
/// source yet (during startup, or in a core that never opens it).
pub const hold_ms: u64 = 5_000;

/// A later launch's whole budget: waiting for a free endpoint, the
/// primary's hold, and the reply.
pub const notify_timeout_ms: u64 = 10_000;

/// What a later launch learned. Each member has its own exit code so a
/// launching shell or script can tell the outcomes apart.
pub const NotifyResult = enum {
    /// The primary accepted the launch into its core's event queue.
    delivered,
    /// No reply arrived within `notify_timeout_ms`.
    not_responding,
    /// The primary is running, but its core did not open the
    /// `native-sdk.app.launches` source within `hold_ms`.
    not_listening,
    /// The source's event queue was full.
    queue_full,
    /// The launch exceeds `max_launch_bytes`; nothing was sent.
    too_large,
    /// The primary's endpoint could not be reached, or it is not owned
    /// by this user in this login session.
    ipc_failed,

    pub fn exitCode(self: NotifyResult) u8 {
        return switch (self) {
            .delivered => 0,
            .not_responding => 3,
            .not_listening => 4,
            .queue_full => 5,
            .too_large => 6,
            .ipc_failed => 7,
        };
    }

    pub fn describe(self: NotifyResult) []const u8 {
        return switch (self) {
            .delivered => "launch delivered to the running instance",
            .not_responding => "the running instance did not respond",
            .not_listening => "the running instance is not listening for launches (its core never opened " ++ source_name ++ ")",
            .queue_full => "the running instance's launch queue is full",
            .too_large => std.fmt.comptimePrint("the launch arguments exceed the {d}-byte notification limit", .{max_launch_bytes}),
            .ipc_failed => "the running instance's endpoint could not be reached or verified",
        };
    }
};

pub const Claim = union(enum) {
    /// This process owns the app and serves later launches.
    primary,
    /// Another process owns the app; this launch was handed over (or
    /// not), and the process should exit with `result.exitCode()`.
    secondary: NotifyResult,
    /// Ownership is unavailable; the process runs as an ordinary
    /// instance. The reason is static text.
    standalone: []const u8,
};

/// Claims ownership for `bundle_id`. Only the first call in a process
/// claims; every later call answers null, so a process that fell back to
/// `.standalone` never re-attempts after its startup work has begun.
pub fn claim(io: std.Io, gpa: std.mem.Allocator, args: std.process.Args, bundle_id: []const u8) ?Claim {
    if (!beginClaim()) return null;
    if (comptime !is_windows) return .{ .standalone = "single_instance is not implemented on this platform yet" };
    return claimWindows(io, gpa, args, bundle_id);
}

/// True exactly once per process: for the first claim attempt.
fn beginClaim() bool {
    owner.lock();
    defer owner.unlock();
    if (owner.claim_started) return false;
    owner.claim_started = true;
    return true;
}

/// Whether this process owns the app.
pub fn owned() bool {
    owner.lock();
    defer owner.unlock();
    return owner.owned;
}

/// The `native-sdk.app.launches` channel source: the core's open hands
/// the posting handle to the listener. A reopen replaces the previous
/// handle; launches held while no handle was live deliver to the new one.
pub fn attach(payload: []const u8, handle: effects.ChannelHandle) !void {
    if (payload.len != 0) return error.InvalidChannelSourceArguments;
    if (comptime !is_windows) return error.UnsupportedChannelSource;
    owner.lock();
    defer owner.unlock();
    if (!owner.owned) return error.SingleInstanceNotOwned;
    owner.handle = handle;
}

/// Encodes one launch into a caller-owned buffer (see `max_launch_bytes`).
pub const LaunchWriter = struct {
    buffer: []u8,
    len: usize = 0,
    overflow: bool = false,

    pub fn init(buffer: []u8, cwd: []const u8) LaunchWriter {
        var writer: LaunchWriter = .{ .buffer = buffer };
        writer.append(cwd);
        return writer;
    }

    pub fn addArgument(self: *LaunchWriter, argument: []const u8) void {
        self.append("\x00");
        self.append(argument);
    }

    /// The encoded launch, or null when it did not fit.
    pub fn bytes(self: *const LaunchWriter) ?[]const u8 {
        return if (self.overflow) null else self.buffer[0..self.len];
    }

    fn append(self: *LaunchWriter, chunk: []const u8) void {
        if (self.overflow) return;
        if (chunk.len > self.buffer.len - self.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buffer[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
    }
};

/// The primary's process-wide state. Guarded sections are a flag or one
/// handle copy, so a spin lock suffices (0.16 has no blocking thread
/// mutex outside `Io`).
const Owner = struct {
    mutex: std.atomic.Mutex = .unlocked,
    claim_started: bool = false,
    owned: bool = false,
    handle: ?effects.ChannelHandle = null,

    fn lock(self: *Owner) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Owner) void {
        self.mutex.unlock();
    }
};

var owner: Owner = .{};

/// The primary's answer to one launch, as it crosses the endpoint.
const Reply = enum(u8) {
    accepted = 0,
    not_listening = 1,
    queue_full = 2,
    too_large = 3,
    bad_request = 4,
    _,

    fn result(self: Reply) NotifyResult {
        return switch (self) {
            .accepted => .delivered,
            .not_listening => .not_listening,
            .queue_full => .queue_full,
            .too_large => .too_large,
            .bad_request, _ => .ipc_failed,
        };
    }
};

/// Where the endpoint hands a received launch: the core's channel in the
/// primary, a recorder in tests.
const Sink = struct {
    context: *anyopaque,
    deliver_fn: *const fn (context: *anyopaque, launch: []const u8) Reply,

    fn deliver(self: Sink, launch: []const u8) Reply {
        return self.deliver_fn(self.context, launch);
    }
};

/// Posts a launch to the core's channel, holding it up to `hold` while no
/// live handle is attached.
fn deliverToCore(io: std.Io, launch: []const u8, hold: u64) Reply {
    if (launch.len > max_launch_bytes) return .too_large;
    const deadline = clock.monotonicMs() + hold;
    while (true) {
        if (currentHandle()) |handle| switch (handle.post(launch)) {
            .accepted => return .accepted,
            .dropped_full => return .queue_full,
            .dropped_oversized => return .too_large,
            // The core closed the channel (or tore down): wait for a
            // reopen within the same hold.
            .closed => forgetHandle(handle),
        };
        if (clock.monotonicMs() >= deadline) return .not_listening;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(25), .awake) catch return .not_listening;
    }
}

fn currentHandle() ?effects.ChannelHandle {
    owner.lock();
    defer owner.unlock();
    return owner.handle;
}

fn forgetHandle(handle: effects.ChannelHandle) void {
    owner.lock();
    defer owner.unlock();
    const current = owner.handle orelse return;
    if (current.shared == handle.shared and current.generation == handle.generation) owner.handle = null;
}

const CoreSink = struct {
    io: std.Io,

    fn sink(self: *CoreSink) Sink {
        return .{ .context = self, .deliver_fn = deliver };
    }

    fn deliver(context: *anyopaque, launch: []const u8) Reply {
        const self: *CoreSink = @ptrCast(@alignCast(context));
        return deliverToCore(self.io, launch, hold_ms);
    }
};

/// Leads every request so a stray client cannot pass for a launch.
const request_magic = "NSL1";
const request_capacity = request_magic.len + max_launch_bytes;
const reply_capacity = 64;

fn remainingMs(deadline: u64) ?u64 {
    const now = clock.monotonicMs();
    return if (now >= deadline) null else deadline - now;
}

fn claimWindows(io: std.Io, gpa: std.mem.Allocator, args: std.process.Args, bundle_id: []const u8) Claim {
    if (comptime !is_windows) unreachable;
    var identity: Identity = undefined;
    if (!identity.loadCurrent()) return .{ .standalone = "the current user's identity is unavailable" };
    var name_buffer: [pipe_name_capacity:0]u16 = undefined;
    const name = pipeName(&name_buffer, identity.session, identity.sidText(), bundle_id);
    var security: Security = undefined;
    if (!security.init(identity.sidText())) return .{ .standalone = "the instance endpoint's security descriptor could not be built" };
    defer security.deinit();

    var launch_buffer: [max_launch_bytes]u8 = undefined;
    var launch: ?[]const u8 = null;
    const deadline = clock.monotonicMs() + notify_timeout_ms;
    while (true) {
        switch (createEndpoint(name, &security.attributes)) {
            .owned => |pipe| {
                owner.lock();
                owner.owned = true;
                owner.unlock();
                const listener = std.Thread.spawn(.{}, listenerMain, .{pipe}) catch {
                    owner.lock();
                    owner.owned = false;
                    owner.unlock();
                    _ = win.CloseHandle(pipe);
                    return .{ .standalone = "the launch listener thread could not start" };
                };
                listener.detach();
                return .primary;
            },
            .taken => {},
            .failed => return .{ .standalone = "the instance endpoint could not be created" },
        }
        const bytes = launch orelse encoded: {
            const encoded = encodeCurrentLaunch(io, gpa, args, &launch_buffer) orelse return .{ .secondary = .too_large };
            launch = encoded;
            break :encoded encoded;
        };
        switch (notify(name, bytes, deadline)) {
            .result => |result| return .{ .secondary = result },
            // The owner exited between our create and connect: try to
            // own the app ourselves.
            .vanished => if (remainingMs(deadline) == null) return .{ .secondary = .not_responding },
        }
    }
}

fn encodeCurrentLaunch(io: std.Io, gpa: std.mem.Allocator, args: std.process.Args, buffer: []u8) ?[]const u8 {
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer) catch 0;
    var writer: LaunchWriter = .init(buffer, cwd_buffer[0..cwd_len]);
    var iterator = std.process.Args.Iterator.initAllocator(args, gpa) catch return null;
    defer iterator.deinit();
    _ = iterator.next();
    while (iterator.next()) |argument| writer.addArgument(argument);
    return writer.bytes();
}

fn listenerMain(pipe: win.HANDLE) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    var core_sink: CoreSink = .{ .io = threaded.io() };
    const sink = core_sink.sink();
    while (true) serveNext(pipe, sink);
}

const CreateResult = union(enum) {
    owned: win.HANDLE,
    /// Another process holds the name.
    taken,
    failed: u32,
};

/// One pipe instance, so the name exists exactly while the owner lives.
fn createEndpoint(name: [*:0]const u16, attributes: ?*win.SECURITY_ATTRIBUTES) CreateResult {
    if (comptime !is_windows) unreachable;
    const pipe = win.CreateNamedPipeW(
        name,
        win.PIPE_ACCESS_DUPLEX | win.FILE_FLAG_FIRST_PIPE_INSTANCE,
        win.PIPE_TYPE_MESSAGE | win.PIPE_READMODE_MESSAGE | win.PIPE_WAIT | win.PIPE_REJECT_REMOTE_CLIENTS,
        1,
        reply_capacity,
        request_capacity,
        0,
        attributes,
    );
    if (pipe != win.INVALID_HANDLE_VALUE) return .{ .owned = pipe };
    const err = lastError();
    if (err == win.ERROR_ACCESS_DENIED or err == win.ERROR_PIPE_BUSY) return .taken;
    return .{ .failed = err };
}

/// Serves one client on the owner's pipe: read one launch, hand it to the
/// sink, reply with the sink's answer.
fn serveNext(pipe: win.HANDLE, sink: Sink) void {
    if (comptime !is_windows) unreachable;
    if (win.ConnectNamedPipe(pipe, null) == 0) {
        const err = lastError();
        if (err != win.ERROR_PIPE_CONNECTED) {
            _ = win.DisconnectNamedPipe(pipe);
            // A client that left before we connected is routine; any
            // other failure backs off so the loop cannot spin.
            if (err != win.ERROR_NO_DATA) win.Sleep(50);
            return;
        }
    }
    defer _ = win.DisconnectNamedPipe(pipe);
    var request: [request_capacity]u8 = undefined;
    var read: win.DWORD = 0;
    const reply: Reply = if (win.ReadFile(pipe, &request, request.len, &read, null) != 0)
        answer(request[0..read], sink)
    else if (lastError() == win.ERROR_MORE_DATA) oversized: {
        drainMessage(pipe);
        break :oversized .too_large;
    } else return;
    const out = [1]u8{@intFromEnum(reply)};
    var written: win.DWORD = 0;
    if (win.WriteFile(pipe, &out, out.len, &written, null) == 0) return;
    // Disconnecting discards unread data: wait until the client has the
    // reply.
    _ = win.FlushFileBuffers(pipe);
}

fn answer(request: []const u8, sink: Sink) Reply {
    if (!std.mem.startsWith(u8, request, request_magic)) return .bad_request;
    const launch = request[request_magic.len..];
    if (launch.len > max_launch_bytes) return .too_large;
    return sink.deliver(launch);
}

fn drainMessage(pipe: win.HANDLE) void {
    var scratch: [512]u8 = undefined;
    while (true) {
        var read: win.DWORD = 0;
        if (win.ReadFile(pipe, &scratch, scratch.len, &read, null) != 0) return;
        if (lastError() != win.ERROR_MORE_DATA) return;
    }
}

const NotifyOutcome = union(enum) {
    result: NotifyResult,
    /// No endpoint exists under the name.
    vanished,
};

/// Hands one launch to the endpoint's owner and waits for its reply.
fn notify(name: [*:0]const u16, launch: []const u8, deadline: u64) NotifyOutcome {
    if (comptime !is_windows) unreachable;
    const pipe = connect: while (true) {
        const candidate = win.CreateFileW(name, win.GENERIC_READ | win.GENERIC_WRITE, 0, null, win.OPEN_EXISTING, win.FILE_FLAG_OVERLAPPED, null);
        if (candidate != win.INVALID_HANDLE_VALUE) break :connect candidate;
        switch (lastError()) {
            win.ERROR_FILE_NOT_FOUND => return .vanished,
            win.ERROR_PIPE_BUSY => {
                // The owner is serving another launch.
                const remaining = remainingMs(deadline) orelse return .{ .result = .not_responding };
                _ = win.WaitNamedPipeW(name, waitMs(remaining));
            },
            else => return .{ .result = .ipc_failed },
        }
    };
    defer _ = win.CloseHandle(pipe);
    return .{ .result = transact(pipe, launch, deadline) };
}

fn transact(pipe: win.HANDLE, launch: []const u8, deadline: u64) NotifyResult {
    // A name squatted by another user, or by another session, gets nothing.
    if (!trustedEndpoint(pipe)) return .ipc_failed;
    var server_pid: win.DWORD = 0;
    if (win.GetNamedPipeServerProcessId(pipe, &server_pid) == 0) return .ipc_failed;
    // Lets the primary's window come to the front when its core shows
    // or focuses it; without this Windows only flashes the taskbar.
    _ = win.AllowSetForegroundWindow(server_pid);
    var mode: win.DWORD = win.PIPE_READMODE_MESSAGE;
    if (win.SetNamedPipeHandleState(pipe, &mode, null, null) == 0) return .ipc_failed;

    var request: [request_capacity]u8 = undefined;
    @memcpy(request[0..request_magic.len], request_magic);
    @memcpy(request[request_magic.len..][0..launch.len], launch);
    const event = win.CreateEventW(null, 1, 0, null) orelse return .ipc_failed;
    defer _ = win.CloseHandle(event);
    _ = transfer(pipe, event, .write, request[0 .. request_magic.len + launch.len], deadline) catch |err| return ioFailure(err);
    var reply: [1]u8 = undefined;
    const read = transfer(pipe, event, .read, &reply, deadline) catch |err| return ioFailure(err);
    if (read != reply.len) return .ipc_failed;
    return @as(Reply, @enumFromInt(reply[0])).result();
}

fn ioFailure(err: TransferError) NotifyResult {
    return switch (err) {
        error.Timeout => .not_responding,
        error.Failed => .ipc_failed,
    };
}

const TransferError = error{ Timeout, Failed };

/// One overlapped read or write, bounded by `deadline`.
fn transfer(pipe: win.HANDLE, event: win.HANDLE, comptime direction: enum { read, write }, buffer: []u8, deadline: u64) TransferError!win.DWORD {
    var overlapped: win.OVERLAPPED = .{ .hEvent = event };
    const length: win.DWORD = @intCast(buffer.len);
    const started = switch (direction) {
        .read => win.ReadFile(pipe, buffer.ptr, length, null, &overlapped),
        .write => win.WriteFile(pipe, buffer.ptr, length, null, &overlapped),
    };
    if (started == 0 and lastError() != win.ERROR_IO_PENDING) return error.Failed;
    const waited = win.WaitForSingleObject(event, waitMs(remainingMs(deadline) orelse 0));
    if (waited != win.WAIT_OBJECT_0) {
        _ = win.CancelIo(pipe);
        var ignored: win.DWORD = 0;
        _ = win.GetOverlappedResult(pipe, &overlapped, &ignored, 1);
        return if (waited == win.WAIT_TIMEOUT) error.Timeout else error.Failed;
    }
    var transferred: win.DWORD = 0;
    if (win.GetOverlappedResult(pipe, &overlapped, &transferred, 0) == 0) return error.Failed;
    return transferred;
}

/// A finite Win32 wait: never 0 for WaitNamedPipe's "default" or
/// INFINITE's all-ones.
fn waitMs(remaining: u64) win.DWORD {
    return @intCast(std.math.clamp(remaining, 1, std.math.maxInt(win.DWORD) - 1));
}

/// `\\.\pipe\native-sdk-instance-<session>-<hash>`: pipe names are
/// machine-wide, so the session and a hash of the bundle id and user SID
/// keep each user's sessions apart.
const pipe_name_capacity = 96;

fn pipeName(buffer: *[pipe_name_capacity:0]u16, session: u32, sid_text: []const u16, bundle_id: []const u8) [:0]const u16 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(bundle_id);
    hasher.update("\x00");
    hasher.update(std.mem.sliceAsBytes(sid_text));
    var ascii: [pipe_name_capacity]u8 = undefined;
    const text = std.fmt.bufPrint(&ascii, "\\\\.\\pipe\\native-sdk-instance-{d}-{x:0>16}", .{ session, hasher.final() }) catch unreachable;
    for (text, 0..) |byte, index| buffer[index] = byte;
    buffer[text.len] = 0;
    return buffer[0..text.len :0];
}

/// The current user's SID (as SDDL text) and login session.
const Identity = struct {
    session: u32,
    sid_text: [sid_text_capacity]u16,
    sid_text_len: usize,

    const sid_text_capacity = 192;

    fn loadCurrent(self: *Identity) bool {
        if (comptime !is_windows) return false;
        if (win.ProcessIdToSessionId(win.GetCurrentProcessId(), &self.session) == 0) return false;
        var token_buffer: [token_user_capacity]u8 align(@alignOf(usize)) = undefined;
        const sid = tokenUserSid(win.GetCurrentProcess(), &token_buffer) orelse return false;
        var text: ?[*:0]u16 = null;
        if (win.ConvertSidToStringSidW(sid, &text) == 0) return false;
        const owned_text = text orelse return false;
        defer _ = win.LocalFree(@ptrCast(owned_text));
        const span = std.mem.span(owned_text);
        if (span.len > self.sid_text.len) return false;
        @memcpy(self.sid_text[0..span.len], span);
        self.sid_text_len = span.len;
        return true;
    }

    fn sidText(self: *const Identity) []const u16 {
        return self.sid_text[0..self.sid_text_len];
    }
};

/// The endpoint's descriptor: owned by the current user (an elevated
/// token would otherwise make Administrators the owner, which the owner
/// check below would refuse), a protected DACL granting that user alone,
/// and a medium mandatory label so a non-elevated later launch can reach
/// an elevated owner.
const Security = struct {
    descriptor: ?*anyopaque = null,
    attributes: win.SECURITY_ATTRIBUTES = undefined,

    fn init(self: *Security, sid_text: []const u16) bool {
        if (comptime !is_windows) return false;
        const owner_part = std.unicode.utf8ToUtf16LeStringLiteral("O:");
        const dacl_part = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;");
        const label_part = std.unicode.utf8ToUtf16LeStringLiteral(")S:(ML;;NW;;;ME)");
        var sddl: [owner_part.len + dacl_part.len + label_part.len + 2 * Identity.sid_text_capacity:0]u16 = undefined;
        var len: usize = 0;
        for ([_][]const u16{ owner_part, sid_text, dacl_part, sid_text, label_part }) |part| {
            @memcpy(sddl[len..][0..part.len], part);
            len += part.len;
        }
        sddl[len] = 0;
        self.descriptor = null;
        if (win.ConvertStringSecurityDescriptorToSecurityDescriptorW(&sddl, win.SDDL_REVISION_1, &self.descriptor, null) == 0) return false;
        self.attributes = .{
            .nLength = @sizeOf(win.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = self.descriptor,
            .bInheritHandle = .FALSE,
        };
        return true;
    }

    fn deinit(self: *Security) void {
        if (self.descriptor) |descriptor| _ = win.LocalFree(descriptor);
        self.descriptor = null;
    }
};

const token_user_capacity = 256;

/// The token user's SID, pointing into `buffer`.
fn tokenUserSid(process: win.HANDLE, buffer: *align(@alignOf(usize)) [token_user_capacity]u8) ?*anyopaque {
    var token: win.HANDLE = undefined;
    if (win.OpenProcessToken(process, win.TOKEN_QUERY, &token) == 0) return null;
    defer _ = win.CloseHandle(token);
    var needed: win.DWORD = 0;
    if (win.GetTokenInformation(token, win.TokenUser, buffer, buffer.len, &needed) == 0) return null;
    const user: *const win.TOKEN_USER = @ptrCast(buffer);
    return user.User.Sid;
}

/// Whether a connected endpoint belongs to this user in this login
/// session. Reads only the pipe handle: querying the owner's process
/// would need PROCESS_QUERY_INFORMATION, which a non-elevated launch
/// never holds on an elevated owner.
fn trustedEndpoint(pipe: win.HANDLE) bool {
    var own_session: win.DWORD = 0;
    var server_session: win.DWORD = 0;
    if (win.ProcessIdToSessionId(win.GetCurrentProcessId(), &own_session) == 0) return false;
    if (win.GetNamedPipeServerSessionId(pipe, &server_session) == 0) return false;
    if (own_session != server_session) return false;
    var endpoint_owner: ?*anyopaque = null;
    var descriptor: ?*anyopaque = null;
    if (win.GetSecurityInfo(pipe, win.SE_FILE_OBJECT, win.OWNER_SECURITY_INFORMATION, &endpoint_owner, null, null, null, &descriptor) != 0) return false;
    defer _ = win.LocalFree(descriptor);
    var own_buffer: [token_user_capacity]u8 align(@alignOf(usize)) = undefined;
    const own = tokenUserSid(win.GetCurrentProcess(), &own_buffer) orelse return false;
    const found = endpoint_owner orelse return false;
    return win.EqualSid(own, found) != 0;
}

fn lastError() u32 {
    return @intFromEnum(std.os.windows.GetLastError());
}

/// Self-contained Win32 surface, declared here like `pty_windows.zig`
/// does so the runtime keeps no dependence on the platform layer.
const win = struct {
    const HANDLE = std.os.windows.HANDLE;
    const DWORD = u32;
    const BOOL = i32;
    const SECURITY_ATTRIBUTES = std.os.windows.SECURITY_ATTRIBUTES;
    const OVERLAPPED = extern struct {
        Internal: usize = 0,
        InternalHigh: usize = 0,
        Offset: DWORD = 0,
        OffsetHigh: DWORD = 0,
        hEvent: ?HANDLE = null,
    };
    const SID_AND_ATTRIBUTES = extern struct {
        Sid: *anyopaque,
        Attributes: DWORD,
    };
    const TOKEN_USER = extern struct {
        User: SID_AND_ATTRIBUTES,
    };

    const INVALID_HANDLE_VALUE = std.os.windows.INVALID_HANDLE_VALUE;
    const GENERIC_READ: DWORD = 0x8000_0000;
    const GENERIC_WRITE: DWORD = 0x4000_0000;
    const OPEN_EXISTING: DWORD = 3;
    const PIPE_ACCESS_DUPLEX: DWORD = 0x3;
    const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x0008_0000;
    const FILE_FLAG_OVERLAPPED: DWORD = 0x4000_0000;
    const PIPE_TYPE_MESSAGE: DWORD = 0x4;
    const PIPE_READMODE_MESSAGE: DWORD = 0x2;
    const PIPE_WAIT: DWORD = 0x0;
    const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x8;
    const TOKEN_QUERY: DWORD = 0x0008;
    const TokenUser: u32 = 1;
    const SDDL_REVISION_1: DWORD = 1;
    const SE_FILE_OBJECT: u32 = 1;
    const OWNER_SECURITY_INFORMATION: DWORD = 0x1;
    const WAIT_OBJECT_0: DWORD = 0;
    const WAIT_TIMEOUT: DWORD = 0x102;
    const ERROR_FILE_NOT_FOUND: u32 = 2;
    const ERROR_ACCESS_DENIED: u32 = 5;
    const ERROR_PIPE_BUSY: u32 = 231;
    const ERROR_NO_DATA: u32 = 232;
    const ERROR_MORE_DATA: u32 = 234;
    const ERROR_PIPE_CONNECTED: u32 = 535;
    const ERROR_IO_PENDING: u32 = 997;

    extern "kernel32" fn CreateNamedPipeW(
        lpName: [*:0]const u16,
        dwOpenMode: DWORD,
        dwPipeMode: DWORD,
        nMaxInstances: DWORD,
        nOutBufferSize: DWORD,
        nInBufferSize: DWORD,
        nDefaultTimeOut: DWORD,
        lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
    extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitNamedPipeW(lpNamedPipeName: [*:0]const u16, nTimeOut: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn SetNamedPipeHandleState(hNamedPipe: HANDLE, lpMode: ?*DWORD, lpMaxCollectionCount: ?*DWORD, lpCollectDataTimeout: ?*DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetNamedPipeServerProcessId(Pipe: HANDLE, ServerProcessId: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetNamedPipeServerSessionId(Pipe: HANDLE, ServerSessionId: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
    extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn CancelIo(hFile: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GetOverlappedResult(hFile: HANDLE, lpOverlapped: *OVERLAPPED, lpNumberOfBytesTransferred: *DWORD, bWait: BOOL) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateEventW(lpEventAttributes: ?*SECURITY_ATTRIBUTES, bManualReset: BOOL, bInitialState: BOOL, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    extern "kernel32" fn ProcessIdToSessionId(dwProcessId: DWORD, pSessionId: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "advapi32" fn OpenProcessToken(ProcessHandle: HANDLE, DesiredAccess: DWORD, TokenHandle: *HANDLE) callconv(.winapi) BOOL;
    extern "advapi32" fn GetTokenInformation(TokenHandle: HANDLE, TokenInformationClass: u32, TokenInformation: ?*anyopaque, TokenInformationLength: DWORD, ReturnLength: *DWORD) callconv(.winapi) BOOL;
    extern "advapi32" fn ConvertSidToStringSidW(Sid: *anyopaque, StringSid: *?[*:0]u16) callconv(.winapi) BOOL;
    extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(StringSecurityDescriptor: [*:0]const u16, StringSDRevision: DWORD, SecurityDescriptor: *?*anyopaque, SecurityDescriptorSize: ?*u32) callconv(.winapi) BOOL;
    extern "advapi32" fn EqualSid(pSid1: *anyopaque, pSid2: *anyopaque) callconv(.winapi) BOOL;
    extern "advapi32" fn GetSecurityInfo(
        handle: HANDLE,
        ObjectType: u32,
        SecurityInfo: DWORD,
        ppsidOwner: ?*?*anyopaque,
        ppsidGroup: ?*?*anyopaque,
        ppDacl: ?*?*anyopaque,
        ppSacl: ?*?*anyopaque,
        ppSecurityDescriptor: ?*?*anyopaque,
    ) callconv(.winapi) DWORD;
    extern "user32" fn AllowSetForegroundWindow(dwProcessId: DWORD) callconv(.winapi) BOOL;
};

const testing = std.testing;

test "a launch is the working directory then each argument, NUL-separated" {
    var buffer: [64]u8 = undefined;
    var writer: LaunchWriter = .init(&buffer, "C:\\work");
    writer.addArgument("--open");
    writer.addArgument("");
    try testing.expectEqualStrings("C:\\work\x00--open\x00", writer.bytes().?);

    var bare_buffer: [16]u8 = undefined;
    const bare: LaunchWriter = .init(&bare_buffer, "/tmp");
    try testing.expectEqualStrings("/tmp", bare.bytes().?);
}

test "a launch that does not fit encodes to nothing" {
    var buffer: [8]u8 = undefined;
    var writer: LaunchWriter = .init(&buffer, "C:\\work");
    writer.addArgument("x");
    try testing.expect(writer.bytes() == null);
    writer.addArgument("");
    try testing.expect(writer.bytes() == null);
}

test "every notification result has its own exit code and only delivery exits zero" {
    const results = std.enums.values(NotifyResult);
    for (results, 0..) |result, index| {
        try testing.expectEqual(result == .delivered, result.exitCode() == 0);
        for (results[index + 1 ..]) |other| try testing.expect(result.exitCode() != other.exitCode());
    }
}

test "only the first claim in a process claims; later calls are no-ops" {
    owner.lock();
    const saved = owner.claim_started;
    owner.claim_started = false;
    owner.unlock();
    defer {
        owner.lock();
        owner.claim_started = saved;
        owner.unlock();
    }
    try testing.expect(beginClaim());
    // A later claim answers null before touching its arguments, so a
    // standalone fallback is never retried mid-startup.
    try testing.expect(claim(testing.io, testing.allocator, undefined, "test.native_sdk.single_instance") == null);
    try testing.expect(!owned());
}

test "the source refuses arguments, and refuses a process that does not own the app" {
    try testing.expectError(error.InvalidChannelSourceArguments, attach("x", .{}));
    const expected = if (is_windows) error.SingleInstanceNotOwned else error.UnsupportedChannelSource;
    try testing.expectError(expected, attach("", .{}));
}

test "a launch held with no live channel reports the core is not listening" {
    owner.lock();
    owner.handle = .{};
    owner.unlock();
    try testing.expectEqual(Reply.not_listening, deliverToCore(testing.io, "C:\\work", 0));
    // The dead handle answered `.closed` and was forgotten.
    try testing.expect(currentHandle() == null);
    try testing.expectEqual(Reply.too_large, deliverToCore(testing.io, &([_]u8{'a'} ** (max_launch_bytes + 1)), 0));
}

test "the endpoint name separates bundle ids, users, and sessions" {
    const sid_a = std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-1-1001");
    const sid_b = std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-1-1002");
    var first: [pipe_name_capacity:0]u16 = undefined;
    var second: [pipe_name_capacity:0]u16 = undefined;
    const base = pipeName(&first, 1, sid_a, "dev.example.app");
    try testing.expect(std.mem.startsWith(u16, base, std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\native-sdk-instance-1-")));
    try testing.expectEqualSlices(u16, base, pipeName(&second, 1, sid_a, "dev.example.app"));
    try testing.expect(!std.mem.eql(u16, base, pipeName(&second, 1, sid_a, "dev.example.other")));
    try testing.expect(!std.mem.eql(u16, base, pipeName(&second, 1, sid_b, "dev.example.app")));
    try testing.expect(!std.mem.eql(u16, base, pipeName(&second, 2, sid_a, "dev.example.app")));
}

/// A per-test endpoint name, so concurrent test runs never collide.
fn testPipeName(buffer: *[pipe_name_capacity:0]u16, label: []const u8) [:0]const u16 {
    var bundle: [96]u8 = undefined;
    const id = std.fmt.bufPrint(&bundle, "test.native_sdk.single_instance.{s}.{d}", .{ label, win.GetCurrentProcessId() }) catch unreachable;
    return pipeName(buffer, 0, std.unicode.utf8ToUtf16LeStringLiteral("test"), id);
}

const Recorder = struct {
    answer: Reply,
    launch: [max_launch_bytes]u8 = undefined,
    launch_len: usize = 0,

    fn sink(self: *Recorder) Sink {
        return .{ .context = self, .deliver_fn = deliver };
    }

    fn deliver(context: *anyopaque, launch: []const u8) Reply {
        const self: *Recorder = @ptrCast(@alignCast(context));
        @memcpy(self.launch[0..launch.len], launch);
        self.launch_len = launch.len;
        return self.answer;
    }
};

test "exactly one process owns a name, and ownership ends with the owner" {
    if (comptime !is_windows) return error.SkipZigTest;
    var name_buffer: [pipe_name_capacity:0]u16 = undefined;
    const name = testPipeName(&name_buffer, "ownership");
    var security: Security = undefined;
    try initTestSecurity(&security);
    defer security.deinit();
    const first = createEndpoint(name, &security.attributes);
    try testing.expect(first == .owned);
    try testing.expect(createEndpoint(name, &security.attributes) == .taken);
    _ = win.CloseHandle(first.owned);
    const next = createEndpoint(name, &security.attributes);
    try testing.expect(next == .owned);
    _ = win.CloseHandle(next.owned);
}

test "a later launch reaches the owner and carries the owner's answer back" {
    if (comptime !is_windows) return error.SkipZigTest;
    var name_buffer: [pipe_name_capacity:0]u16 = undefined;
    const name = testPipeName(&name_buffer, "delivery");
    var security: Security = undefined;
    try initTestSecurity(&security);
    defer security.deinit();
    const created = createEndpoint(name, &security.attributes);
    try testing.expect(created == .owned);
    defer _ = win.CloseHandle(created.owned);

    const answers = [_]struct { Reply, NotifyResult }{
        .{ .accepted, .delivered },
        .{ .not_listening, .not_listening },
        .{ .queue_full, .queue_full },
    };
    for (answers) |pair| {
        var recorder: Recorder = .{ .answer = pair[0] };
        const server = try std.Thread.spawn(.{}, serveNext, .{ created.owned, recorder.sink() });
        const outcome = notify(name, "C:\\work\x00--open\x00notes.txt", clock.monotonicMs() + 5_000);
        server.join();
        try testing.expectEqual(NotifyOutcome{ .result = pair[1] }, outcome);
        try testing.expectEqualStrings("C:\\work\x00--open\x00notes.txt", recorder.launch[0..recorder.launch_len]);
    }
}

test "a launch with no owner finds no endpoint, and a silent owner times out" {
    if (comptime !is_windows) return error.SkipZigTest;
    var name_buffer: [pipe_name_capacity:0]u16 = undefined;
    const name = testPipeName(&name_buffer, "silent");
    try testing.expectEqual(NotifyOutcome.vanished, notify(name, "C:\\work", clock.monotonicMs() + 1_000));

    var security: Security = undefined;
    try initTestSecurity(&security);
    defer security.deinit();
    const created = createEndpoint(name, &security.attributes);
    try testing.expect(created == .owned);
    defer _ = win.CloseHandle(created.owned);
    try testing.expectEqual(NotifyOutcome{ .result = .not_responding }, notify(name, "C:\\work", clock.monotonicMs() + 200));
}

test "an endpoint with the launcher's descriptor passes the handle-only owner check" {
    if (comptime !is_windows) return error.SkipZigTest;
    var name_buffer: [pipe_name_capacity:0]u16 = undefined;
    const name = testPipeName(&name_buffer, "trust");
    var security: Security = undefined;
    try initTestSecurity(&security);
    defer security.deinit();
    const created = createEndpoint(name, &security.attributes);
    try testing.expect(created == .owned);
    defer _ = win.CloseHandle(created.owned);
    const client = win.CreateFileW(name, win.GENERIC_READ | win.GENERIC_WRITE, 0, null, win.OPEN_EXISTING, win.FILE_FLAG_OVERLAPPED, null);
    try testing.expect(client != win.INVALID_HANDLE_VALUE);
    defer _ = win.CloseHandle(client);
    try testing.expect(trustedEndpoint(client));
}

/// The launcher's own descriptor for the current user, so the endpoint
/// tests exercise the owner, DACL, and label production creates.
fn initTestSecurity(security: *Security) !void {
    var identity: Identity = undefined;
    try testing.expect(identity.loadCurrent());
    try testing.expect(security.init(identity.sidText()));
}
