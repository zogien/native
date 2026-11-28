//! Single-instance ownership (manifest `single_instance`): one process per
//! data directory owns the app's data. The
//! default data directory is keyed by the bundle id, also when a
//! `--native-data-dir` / `NATIVE_SDK_DATA_DIR` root reaches it; data moved
//! under any other root is keyed by that root (`Scope`). The first launch to claim ownership becomes the
//! primary. A later launch hands its working directory and arguments to
//! the primary, reports the delivery through its exit code, and exits
//! before any window exists. The primary's core receives each launch on
//! the `native-sdk.app.launches` channel source (`attach`) as one `"data"`
//! event and decides what to do with it.
//!
//! Windows uses a message-mode named pipe created with
//! FILE_FLAG_FIRST_PIPE_INSTANCE is both the ownership lock and the
//! notification endpoint. The kernel retires it with the process, so a
//! normal exit or a crash leaves no stale ownership. macOS and Linux hold
//! a kernel lock in the data directory and serve same-user launches on
//! a Unix socket. A new lock holder can replace a stale socket.
const std = @import("std");
const builtin = @import("builtin");
const effects = @import("effects.zig");
const clock = @import("clock.zig");
const app_data = @import("app_dirs").app_data;

const is_windows = builtin.os.tag == .windows;
const is_posix_desktop = builtin.os.tag == .macos or (builtin.os.tag == .linux and !builtin.abi.isAndroid());

pub const source_name = "native-sdk.app.launches";

/// One launch notification is the later process's working directory,
/// then each of its arguments (argv[0] and the SDK's `--native-data-dir`
/// excluded: `app_dirs.app_data.ArgumentFilter`), every field preceded by
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

/// What one owner owns: the platform-neutral key material. Each host
/// derives its endpoint from a scope and the current OS user. Windows
/// also includes the login session in the pipe name.
pub const Scope = union(enum) {
    /// The default data directory, keyed by the app's bundle id. The
    /// Windows endpoint keeps the name it had before a data directory
    /// could be overridden, so a running older version of the app and a
    /// newly started newer one still find each other.
    app: []const u8,
    /// A data directory moved under an override root, keyed by that
    /// root's canonical absolute path (`AppData.root`, which is one
    /// spelling per folder). One root has one owner; different roots of
    /// one app run side by side.
    root: []const u8,

    /// The scope a launch claims for its resolved directories, chosen by
    /// the data directory in use rather than by how it was named: an
    /// override whose `data` folder is the default data directory (a
    /// root at the default location) claims the app, like a launch with
    /// no override, so the two never own one set of files at once.
    pub fn of(bundle_id: []const u8, data: *const app_data.AppData) Scope {
        return if (data.usesDefaultData()) .{ .app = bundle_id } else .{ .root = data.root };
    }

    pub const digest_len = 16;

    /// A fixed-size digest of the scope for one OS user, for endpoint
    /// names that cannot hold a whole path. `user` is any stable bytes
    /// naming the user (the SID text on Windows or the POSIX uid). The scope's form is
    /// hashed with its value, so an `.app` scope and a `.root` scope never
    /// digest alike, even for equal strings. The Windows `.app` endpoint
    /// does not use this: it keeps its original name formula.
    pub fn digest(self: Scope, user: []const u8) [digest_len]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("native-sdk.instance\x00");
        hasher.update(@tagName(self));
        hasher.update("\x00");
        hasher.update(switch (self) {
            .app, .root => |value| value,
        });
        hasher.update("\x00");
        hasher.update(user);
        var full: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        hasher.final(&full);
        return full[0..digest_len].*;
    }
};

/// Claims ownership of `scope`. Only the first call in a process claims;
/// every later call answers null, so a process that fell back to
/// `.standalone` never re-attempts after its startup work has begun.
pub fn claim(io: std.Io, gpa: std.mem.Allocator, args: std.process.Args, scope: Scope) ?Claim {
    if (!beginClaim()) return null;
    if (comptime is_windows) return claimWindows(io, gpa, args, scope);
    if (comptime is_posix_desktop) return Posix.claimScope(io, gpa, args, scope) catch .{ .secondary = .ipc_failed };
    return .{ .standalone = "single_instance is not implemented on this platform yet" };
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
    if (comptime !is_windows and !is_posix_desktop) return error.UnsupportedChannelSource;
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

const Posix = struct {
    const c = std.c;
    const Address = c.sockaddr.un;
    const lock_name = ".native-sdk-instance.lock";

    fn env(name: [*:0]const u8) ?[]const u8 {
        return std.mem.span(c.getenv(name) orelse return null);
    }

    fn openLock(io: std.Io, scope: Scope) !std.Io.File {
        const dirs = @import("app_dirs");
        var buf: [app_data.max_dir_bytes]u8 = undefined;
        const path = switch (scope) {
            .root => |root| try dirs.join(dirs.currentPlatform(), &buf, &.{ root, app_data.layout.data }),
            .app => |id| try dirs.resolveOne(.{ .name = id }, dirs.currentPlatform(), .{
                .home = env("HOME"),
                .xdg_data_home = env("XDG_DATA_HOME"),
            }, .data, &buf),
        };
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
        defer dir.close(io);
        const fd = try std.posix.openat(dir.handle, lock_name, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
            .NONBLOCK = true,
        }, 0o600);
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        errdefer file.close(io);
        if ((try file.stat(io)).kind != .file) return error.InvalidLockFile;
        return file;
    }

    fn socketAddress(dir: []const u8, scope: Scope, uid: c.uid_t) !Address {
        var addr: Address = .{ .path = @splat(0) };
        _ = try std.fmt.bufPrintZ(&addr.path, "{s}/native-sdk-{x}.sock", .{
            std.mem.trimEnd(u8, dir, "/"), &scope.digest(std.mem.asBytes(&uid)),
        });
        return addr;
    }

    fn privateDirectory(io: std.Io, path: []const u8, uid: c.uid_t) bool {
        if (!std.fs.path.isAbsolute(path)) return false;
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .follow_symlinks = false }) catch return false;
        defer dir.close(io);
        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            var stat: linux.Statx = undefined;
            return linux.errno(linux.statx(dir.handle, "", linux.AT.EMPTY_PATH, .{ .MODE = true, .UID = true }, &stat)) == .SUCCESS and
                stat.uid == uid and stat.mode & 0o777 == 0o700;
        }
        var stat: c.Stat = undefined;
        return c.fstat(dir.handle, &stat) == 0 and stat.uid == uid and stat.mode & 0o777 == 0o700;
    }

    fn endpoint(io: std.Io, scope: Scope, uid: c.uid_t) !Address {
        if (env(if (builtin.os.tag == .macos) "TMPDIR" else "XDG_RUNTIME_DIR")) |path| {
            if (privateDirectory(io, path, uid)) {
                if (socketAddress(path, scope, uid)) |addr| return addr else |_| {}
            }
        }
        // The environment can be absent, shared, or longer than sun_path.
        var fallback: [48]u8 = undefined;
        const path = try std.fmt.bufPrint(&fallback, "/tmp/native-sdk-{d}", .{uid});
        std.Io.Dir.cwd().createDir(io, path, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        if (!privateDirectory(io, path, uid)) return error.UnsafeRuntimeDirectory;
        return socketAddress(path, scope, uid);
    }

    fn claimScope(io: std.Io, gpa: std.mem.Allocator, args: std.process.Args, scope: Scope) !Claim {
        const deadline = clock.monotonicMs() + notify_timeout_ms;
        const addr = try endpoint(io, scope, c.geteuid());
        // On macOS concurrent O_CREAT opens of a new lock file can transiently
        // return ENOENT even when the parent directory is already open.
        const lock = while (remainingMs(deadline) != null) {
            break openLock(io, scope) catch |err| switch (err) {
                error.FileNotFound => {
                    try std.Io.sleep(io, .fromMilliseconds(10), .awake);
                    continue;
                },
                else => return err,
            };
        } else return .{ .secondary = .ipc_failed };
        var held_for_process = false;
        defer if (!held_for_process) lock.close(io);
        var launch_buffer: [max_launch_bytes]u8 = undefined;
        var launch: ?[]const u8 = null;
        while (remainingMs(deadline) != null) {
            if (try lock.tryLock(io, .exclusive)) {
                const server = try listen(io, &addr);
                errdefer _ = c.close(server);
                const listener = try std.Thread.spawn(.{}, listenMain, .{server});
                listener.detach();
                // Never unlink the lock file: a waiting process already has
                // this inode open. Closing the fd at process exit releases it.
                held_for_process = true;
                owner.lock();
                owner.owned = true;
                owner.unlock();
                return .primary;
            }
            if (launch == null) launch = encodeCurrentLaunch(io, gpa, args, &launch_buffer) orelse return .{ .secondary = .too_large };
            switch (notifyOwner(&addr, launch.?, deadline)) {
                .result => |result| return .{ .secondary = result },
                .vanished => try std.Io.sleep(io, .fromMilliseconds(10), .awake),
            }
        }
        return .{ .secondary = .not_responding };
    }

    fn newSocket(nonblocking: bool) !c_int {
        const fd = if (builtin.os.tag == .linux)
            c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC | @as(u32, if (nonblocking) c.SOCK.NONBLOCK else 0), 0)
        else
            c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        if (builtin.os.tag == .macos) {
            try closeOnExec(fd);
            const flags: c_int = @bitCast(@as(c.O, .{ .NONBLOCK = nonblocking }));
            if (c.fcntl(fd, c.F.SETFL, flags) < 0) return error.SocketFailed;
        }
        return fd;
    }

    fn closeOnExec(fd: c_int) !void {
        if (c.fcntl(fd, c.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)) < 0) return error.SocketFailed;
    }

    /// Called under the data lock. Only its holder may replace a stale socket.
    fn listen(io: std.Io, addr: *const Address) !c_int {
        const path = std.mem.sliceTo(&addr.path, 0);
        const cwd = std.Io.Dir.cwd();
        if (cwd.statFile(io, path, .{ .follow_symlinks = false })) |stat| {
            if (stat.kind != .unix_domain_socket) return error.UnexpectedEndpoint;
            try cwd.deleteFile(io, path);
        } else |err| if (err != error.FileNotFound) return err;
        const fd = try newSocket(false);
        errdefer _ = c.close(fd);
        if (c.bind(fd, @ptrCast(addr), @sizeOf(Address)) != 0) return error.BindFailed;
        errdefer cwd.deleteFile(io, path) catch {};
        if (c.chmod(@ptrCast(&addr.path), 0o600) != 0) return error.SocketFailed;
        if (c.listen(fd, 16) != 0) return error.SocketFailed;
        return fd;
    }

    extern "c" fn getpeereid(fd: c_int, uid: *c.uid_t, gid: *c.gid_t) c_int;

    fn trustedPeer(fd: c_int, uid: c.uid_t) bool {
        if (builtin.os.tag == .macos) {
            var peer: c.uid_t = undefined;
            var group: c.gid_t = undefined;
            return getpeereid(fd, &peer, &group) == 0 and peer == uid;
        }
        var cred: extern struct { pid: c.pid_t, uid: c.uid_t, gid: c.gid_t } = undefined;
        var len: c.socklen_t = @sizeOf(@TypeOf(cred));
        return c.getsockopt(fd, c.SOL.SOCKET, c.SO.PEERCRED, &cred, &len) == 0 and len == @sizeOf(@TypeOf(cred)) and cred.uid == uid;
    }

    // Use a single absolute deadline even across signal interruptions,
    // partial transfers, and a full listen backlog.
    fn waitReady(fd: c_int, events: i16, deadline: u64) TransferError!void {
        var pollfd: c.pollfd = .{ .fd = fd, .events = events, .revents = 0 };
        while (remainingMs(deadline)) |ms| {
            const rc = c.poll(@ptrCast(&pollfd), 1, @intCast(ms));
            if (rc > 0) return;
            if (rc == 0) return error.Timeout;
            if (c.errno(rc) != .INTR) return error.Failed;
        }
        return error.Timeout;
    }

    fn readSome(fd: c_int, buf: []u8, deadline: u64) TransferError!usize {
        while (true) {
            try waitReady(fd, c.POLL.IN, deadline);
            const rc = c.recv(fd, buf.ptr, buf.len, c.MSG.DONTWAIT);
            switch (c.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR, .AGAIN => continue,
                else => return error.Failed,
            }
        }
    }

    fn writeAll(fd: c_int, bytes: []const u8, deadline: u64) TransferError!void {
        var pending = bytes;
        while (pending.len != 0) {
            try waitReady(fd, c.POLL.OUT, deadline);
            const rc = c.send(fd, pending.ptr, pending.len, c.MSG.DONTWAIT | c.MSG.NOSIGNAL);
            switch (c.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.Failed;
                    pending = pending[@intCast(rc)..];
                },
                .INTR, .AGAIN => continue,
                else => return error.Failed,
            }
        }
    }

    fn notifyOwner(addr: *const Address, launch: []const u8, deadline: u64) NotifyOutcome {
        const failed: NotifyOutcome = .{ .result = .ipc_failed };
        const fd = newSocket(true) catch return failed;
        defer _ = c.close(fd);
        switch (c.errno(c.connect(fd, @ptrCast(addr), @sizeOf(Address)))) {
            .SUCCESS => {},
            .NOENT, .CONNREFUSED, .AGAIN, .INTR => return .vanished,
            .INPROGRESS => {
                waitReady(fd, c.POLL.OUT, deadline) catch |err| return .{ .result = ioFailure(err) };
                var status: c_int = undefined;
                var len: c.socklen_t = @sizeOf(c_int);
                if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &status, &len) != 0) return failed;
                if (status == @intFromEnum(c.E.CONNREFUSED)) return .vanished;
                if (status != 0) return failed;
            },
            else => return failed,
        }
        if (!trustedPeer(fd, c.geteuid())) return failed;
        writeAll(fd, request_magic, deadline) catch |err| return .{ .result = ioFailure(err) };
        writeAll(fd, launch, deadline) catch |err| return .{ .result = ioFailure(err) };
        if (c.shutdown(fd, c.SHUT.WR) != 0) return failed;
        var byte: [1]u8 = undefined;
        const n = readSome(fd, &byte, deadline) catch |err| return .{ .result = ioFailure(err) };
        if (n != 1) return failed;
        return .{ .result = @as(Reply, @enumFromInt(byte[0])).result() };
    }

    fn listenMain(server: c_int) void {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        var core: CoreSink = .{ .io = threaded.io() };
        while (true) {
            const fd = if (builtin.os.tag == .linux) c.accept4(server, null, null, c.SOCK.CLOEXEC) else c.accept(server, null, null);
            if (fd < 0) {
                std.Io.sleep(core.io, .fromMilliseconds(25), .awake) catch {};
                continue;
            }
            defer _ = c.close(fd);
            if (builtin.os.tag == .macos) closeOnExec(fd) catch continue;
            if (!trustedPeer(fd, c.geteuid())) continue;
            const deadline = clock.monotonicMs() + notify_timeout_ms;
            const reply = readRequest(fd, core.sink(), deadline) catch continue;
            writeAll(fd, &.{@intFromEnum(reply)}, deadline) catch continue;
        }
    }

    fn readRequest(fd: c_int, sink: Sink, deadline: u64) TransferError!Reply {
        var request: [request_capacity + 1]u8 = undefined;
        var n: usize = 0;
        while (n < request.len) {
            const read = try readSome(fd, request[n..], deadline);
            if (read == 0) return answer(request[0..n], sink);
            n += read;
        }
        return .too_large;
    }
};

fn claimWindows(io: std.Io, gpa: std.mem.Allocator, args: std.process.Args, scope: Scope) Claim {
    if (comptime !is_windows) unreachable;
    var identity: Identity = undefined;
    if (!identity.loadCurrent()) return .{ .standalone = "the current user's identity is unavailable" };
    var name_buffer: [pipe_name_capacity:0]u16 = undefined;
    const name = endpointName(&name_buffer, identity.session, identity.sidText(), scope);
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
    var filter: app_data.ArgumentFilter = .{};
    while (iterator.next()) |argument| {
        if (filter.keep(argument)) writer.addArgument(argument);
    }
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

/// Pipe names are machine-wide, so every name carries the login session
/// and a hash that includes the user SID, keeping each user's sessions
/// apart. The two scopes have disjoint name shapes: after
/// `native-sdk-instance-` an app name continues with the session's digits
/// and a root name with `root-`.
const pipe_name_capacity = 96;

fn endpointName(buffer: *[pipe_name_capacity:0]u16, session: u32, sid_text: []const u16, scope: Scope) [:0]const u16 {
    return switch (scope) {
        .app => |bundle_id| pipeName(buffer, session, sid_text, bundle_id),
        .root => rootPipeName(buffer, session, sid_text, scope),
    };
}

/// `\\.\pipe\native-sdk-instance-<session>-<hash>`, the hash a Wyhash of
/// the bundle id and user SID: the name every version has used for the
/// default data directory. It must not change, or an installed older
/// version and a newer one would both own the app during an upgrade.
fn pipeName(buffer: *[pipe_name_capacity:0]u16, session: u32, sid_text: []const u16, bundle_id: []const u8) [:0]const u16 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(bundle_id);
    hasher.update("\x00");
    hasher.update(std.mem.sliceAsBytes(sid_text));
    var ascii: [pipe_name_capacity]u8 = undefined;
    const text = std.fmt.bufPrint(&ascii, "\\\\.\\pipe\\native-sdk-instance-{d}-{x:0>16}", .{ session, hasher.final() }) catch unreachable;
    return widenName(buffer, text);
}

/// `\\.\pipe\native-sdk-instance-root-<session>-<digest>`, the digest
/// `Scope.digest` of the root for the user SID, in lowercase hex.
fn rootPipeName(buffer: *[pipe_name_capacity:0]u16, session: u32, sid_text: []const u16, scope: Scope) [:0]const u16 {
    const hex = std.fmt.bytesToHex(scope.digest(std.mem.sliceAsBytes(sid_text)), .lower);
    var ascii: [pipe_name_capacity]u8 = undefined;
    const text = std.fmt.bufPrint(&ascii, "\\\\.\\pipe\\native-sdk-instance-root-{d}-{s}", .{ session, &hex }) catch unreachable;
    return widenName(buffer, text);
}

fn widenName(buffer: *[pipe_name_capacity:0]u16, text: []const u8) [:0]const u16 {
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
    try testing.expect(claim(testing.io, testing.allocator, undefined, .{ .app = "test.native_sdk.single_instance" }) == null);
    try testing.expect(!owned());
}

test "the source refuses arguments, and refuses a process that does not own the app" {
    try testing.expectError(error.InvalidChannelSourceArguments, attach("x", .{}));
    const expected = if (is_windows or is_posix_desktop) error.SingleInstanceNotOwned else error.UnsupportedChannelSource;
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

/// The pipe name as ASCII, for comparing against literals.
fn narrowName(buffer: []u8, name: []const u16) []const u8 {
    for (name, 0..) |unit, index| buffer[index] = @intCast(unit);
    return buffer[0..name.len];
}

test "the default data directory keeps the endpoint name of earlier versions" {
    // Printed by main 41fa5a00's pipeName for these inputs, before data
    // directories keyed ownership. An installed older version and a
    // newer one find each other only while these stay byte-identical.
    const cases = [_]struct { u32, []const u16, []const u8, []const u8 }{
        .{ 1, std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-1-1001"), "dev.example.app", "\\\\.\\pipe\\native-sdk-instance-1-0dbe9aa8a3a3f39b" },
        .{ 2, std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-3623811015-3361044348-30300820-1013"), "dev.native_sdk.single_instance_probe", "\\\\.\\pipe\\native-sdk-instance-2-57fb7101749262e5" },
    };
    for (cases) |case| {
        var name_buffer: [pipe_name_capacity:0]u16 = undefined;
        var ascii: [pipe_name_capacity]u8 = undefined;
        const name = endpointName(&name_buffer, case[0], case[1], .{ .app = case[2] });
        try testing.expectEqualStrings(case[3], narrowName(&ascii, name));
        // Exactly the name a default launch claims.
        const default_data: app_data.AppData = .{};
        var claimed_buffer: [pipe_name_capacity:0]u16 = undefined;
        try testing.expectEqualSlices(u16, name, endpointName(&claimed_buffer, case[0], case[1], .of(case[2], &default_data)));
    }
}

test "an overridden data directory's endpoint is keyed by its root, user, and session" {
    const sid_a = std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-1-1001");
    const sid_b = std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-1-1002");
    var first: [pipe_name_capacity:0]u16 = undefined;
    var second: [pipe_name_capacity:0]u16 = undefined;
    const one: Scope = .{ .root = "C:\\Profiles\\One" };
    const base = endpointName(&first, 1, sid_a, one);
    var ascii: [pipe_name_capacity]u8 = undefined;
    const text = narrowName(&ascii, base);
    try testing.expect(std.mem.startsWith(u8, text, "\\\\.\\pipe\\native-sdk-instance-root-1-"));
    try testing.expectEqual("\\\\.\\pipe\\native-sdk-instance-root-1-".len + 2 * Scope.digest_len, text.len);
    for (text["\\\\.\\pipe\\native-sdk-instance-root-1-".len..]) |ch| try testing.expect(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'));
    try testing.expectEqualSlices(u16, base, endpointName(&second, 1, sid_a, one));
    try testing.expect(!std.mem.eql(u16, base, endpointName(&second, 1, sid_a, .{ .root = "C:\\Profiles\\Two" })));
    try testing.expect(!std.mem.eql(u16, base, endpointName(&second, 1, sid_b, one)));
    try testing.expect(!std.mem.eql(u16, base, endpointName(&second, 2, sid_a, one)));
    // The longest root and session still fit the name buffer.
    const longest = [_]u8{'x'} ** app_data.max_root_bytes;
    _ = endpointName(&second, std.math.maxInt(u32), sid_a, .{ .root = &longest });
}

test "a default endpoint and an override endpoint never share a name" {
    const sid = std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-1-1001");
    var app_buffer: [pipe_name_capacity:0]u16 = undefined;
    var root_buffer: [pipe_name_capacity:0]u16 = undefined;
    var app_ascii: [pipe_name_capacity]u8 = undefined;
    var root_ascii: [pipe_name_capacity]u8 = undefined;
    // Even the same string as a bundle id and as a root.
    for ([_][]const u8{ "dev.example.app", "C:\\Profiles\\One", "" }) |value| {
        const app_name = narrowName(&app_ascii, endpointName(&app_buffer, 7, sid, .{ .app = value }));
        const root_name = narrowName(&root_ascii, endpointName(&root_buffer, 7, sid, .{ .root = value }));
        try testing.expect(!std.mem.eql(u8, app_name, root_name));
        // Disjoint shapes: an app name continues with the session's
        // digits where a root name continues with `root-`.
        const prefix = "\\\\.\\pipe\\native-sdk-instance-";
        try testing.expect(std.ascii.isDigit(app_name[prefix.len]));
        try testing.expect(std.mem.startsWith(u8, root_name[prefix.len..], "root-"));
        // The shared digest separates the forms too, for hosts that key
        // both forms by it.
        const user = std.mem.sliceAsBytes(sid);
        try testing.expect(!std.mem.eql(u8, &(Scope{ .app = value }).digest(user), &(Scope{ .root = value }).digest(user)));
    }
}

test "a launch claims by the data directory it uses, not by whether it named one" {
    const default_data: app_data.AppData = .{};
    try testing.expectEqualDeep(Scope{ .app = "dev.example.app" }, Scope.of("dev.example.app", &default_data));
    const flagged: app_data.AppData = .{ .source = .flag, .root = "C:\\Profiles\\One" };
    try testing.expectEqualDeep(Scope{ .root = "C:\\Profiles\\One" }, Scope.of("dev.example.app", &flagged));
    const from_env: app_data.AppData = .{ .source = .env, .root = "/home/a/profile" };
    try testing.expectEqualDeep(Scope{ .root = "/home/a/profile" }, Scope.of("dev.example.app", &from_env));
    // A root whose data folder is the default data directory claims the
    // app, under the very name a launch without an override claims.
    const at_default: app_data.AppData = .{ .source = .flag, .root = "C:\\Users\\a\\AppData\\Local\\dev.example.app", .data_is_default = true };
    try testing.expectEqualDeep(Scope{ .app = "dev.example.app" }, Scope.of("dev.example.app", &at_default));
    const sid = std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-1-1001");
    var name_buffer: [pipe_name_capacity:0]u16 = undefined;
    var ascii: [pipe_name_capacity]u8 = undefined;
    try testing.expectEqualStrings("\\\\.\\pipe\\native-sdk-instance-1-0dbe9aa8a3a3f39b", narrowName(&ascii, endpointName(&name_buffer, 1, sid, .of("dev.example.app", &at_default))));
}

test "every spelling of one data directory claims one endpoint" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const dirs = @import("app_dirs");
    const platform = dirs.currentPlatform();
    const identity: app_data.Identity = .{ .bundle_id = "dev.example.app", .app_name = "example" };
    const sep = std.fs.path.sep_str;
    var failure: app_data.Failure = .{};
    const spellings = [_][]const u8{
        "Profile Folder" ++ sep ++ "Root One",
        "Profile Folder/./Root One/../Root One/",
        // Case-insensitive file systems resolve to the on-disk case.
        if (is_windows or builtin.os.tag == .macos) "PROFILE FOLDER" ++ sep ++ "ROOT ONE" else "Profile Folder" ++ sep ++ "Root One",
    };
    const sid = std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-1-1001");
    var expected: [pipe_name_capacity:0]u16 = undefined;
    const first_data = try app_data.resolveWith(allocator, testing.io, tmp.dir, platform, identity, .{ .source = .flag, .path = spellings[0] }, .{}, &failure);
    const first = endpointName(&expected, 1, sid, .of(identity.bundle_id, &first_data));
    for (spellings[1..]) |spelling| {
        const data = try app_data.resolveWith(allocator, testing.io, tmp.dir, platform, identity, .{ .source = .env, .path = spelling }, .{}, &failure);
        var name: [pipe_name_capacity:0]u16 = undefined;
        try testing.expectEqualSlices(u16, first, endpointName(&name, 1, sid, .of(identity.bundle_id, &data)));
    }
    const other_data = try app_data.resolveWith(allocator, testing.io, tmp.dir, platform, identity, .{ .source = .flag, .path = "Profile Folder" ++ sep ++ "Root Two" }, .{}, &failure);
    var other: [pipe_name_capacity:0]u16 = undefined;
    try testing.expect(!std.mem.eql(u16, first, endpointName(&other, 1, sid, .of(identity.bundle_id, &other_data))));
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

test "POSIX socket names fit sun_path and never embed the data root" {
    if (comptime !is_posix_desktop) return error.SkipZigTest;
    const scope: Scope = .{ .root = &([_]u8{'x'} ** app_data.max_root_bytes) };
    const uid = Posix.c.geteuid();
    const addr = try Posix.socketAddress("/tmp/", scope, uid);
    const name = std.mem.sliceTo(&addr.path, 0);
    try testing.expect(std.mem.startsWith(u8, name, "/tmp/native-sdk-"));
    try testing.expectEqual("/tmp/native-sdk-.sock".len + 2 * Scope.digest_len, name.len);
    const room = addr.path.len - 1 - (name.len - "/tmp".len);
    var dir: [108]u8 = @splat('x');
    dir[0] = '/';
    const longest = try Posix.socketAddress(dir[0..room], scope, uid);
    try testing.expectEqual(longest.path.len - 1, std.mem.sliceTo(&longest.path, 0).len);
    try testing.expectError(error.NoSpaceLeft, Posix.socketAddress(dir[0 .. room + 1], scope, uid));
}

test "POSIX locks survive contention and release on close without unlinking" {
    if (comptime !is_posix_desktop) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path);
    const scope: Scope = .{ .root = path[0..n] };
    const first = try Posix.openLock(testing.io, scope);
    var first_open = true;
    defer if (first_open) first.close(testing.io);
    try testing.expect(try first.tryLock(testing.io, .exclusive));
    try testing.expect(Posix.c.fcntl(first.handle, Posix.c.F.GETFD) & std.posix.FD_CLOEXEC != 0);
    const second = try Posix.openLock(testing.io, scope);
    defer second.close(testing.io);
    try testing.expect(!try second.tryLock(testing.io, .exclusive));
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), (try second.stat(testing.io)).permissions.toMode() & 0o777);
    first.close(testing.io);
    first_open = false;
    try testing.expect(try second.tryLock(testing.io, .exclusive));
}

test "POSIX verifies private directory ownership and socket permissions" {
    if (comptime !is_posix_desktop) return error.SkipZigTest;
    const io = testing.io;
    const uid = Posix.c.geteuid();
    var name: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&name, "/tmp/nsl-{d}-{x}", .{ Posix.c.getpid(), testing.random_seed });
    try std.Io.Dir.cwd().createDir(io, path, .fromMode(0o700));
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try testing.expect(Posix.privateDirectory(io, path, uid));
    try testing.expect(!Posix.privateDirectory(io, path, uid ^ 1));
    const addr = try Posix.socketAddress(path, .{ .app = "permissions" }, uid);
    const fd = try Posix.listen(io, &addr);
    defer _ = Posix.c.close(fd);
    const stat = try std.Io.Dir.cwd().statFile(io, std.mem.sliceTo(&addr.path, 0), .{});
    try testing.expectEqual(.unix_domain_socket, stat.kind);
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "POSIX verifies both socket peers and reads a bounded EOF-delimited frame" {
    if (comptime !is_posix_desktop) return error.SkipZigTest;
    const c = Posix.c;
    const uid = c.geteuid();
    const cases = [_]struct { []const u8, Reply }{
        .{ request_magic ++ "/cwd\x00one\x00", .accepted },
        .{ request_magic ++ ("x" ** max_launch_bytes), .accepted },
        .{ request_magic ++ ("x" ** (max_launch_bytes + 1)), .too_large },
        .{ "NSL", .bad_request },
    };
    for (cases) |case| {
        var pair: [2]c_int = undefined;
        try testing.expect(c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &pair) == 0);
        defer for (pair) |fd| {
            _ = c.close(fd);
        };
        for (pair) |fd| {
            try testing.expect(Posix.trustedPeer(fd, uid));
            try testing.expect(!Posix.trustedPeer(fd, uid ^ 1));
        }
        var recorder: Recorder = .{ .answer = .accepted };
        const sender = try std.Thread.spawn(.{}, sendTestFrame, .{ pair[0], case[0] });
        defer sender.join();
        try testing.expectEqual(case[1], try Posix.readRequest(pair[1], recorder.sink(), clock.monotonicMs() + 5_000));
        if (case[1] == .accepted) try testing.expectEqualStrings(case[0][request_magic.len..], recorder.launch[0..recorder.launch_len]);
    }
}

fn sendTestFrame(fd: c_int, frame: []const u8) void {
    const deadline = clock.monotonicMs() + 5_000;
    defer _ = Posix.c.shutdown(fd, Posix.c.SHUT.WR);
    Posix.writeAll(fd, frame[0..2], deadline) catch return;
    std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch return;
    Posix.writeAll(fd, frame[2..], deadline) catch return;
}
