const std = @import("std");
const app_dirs = @import("app_dirs");
const trace = @import("trace");

pub const TraceMode = enum {
    off,
    events,
    runtime,
    all,

    pub fn includes(self: TraceMode, category: TraceMode) bool {
        return self == .all or self == category;
    }
};

pub const Config = struct {
    trace: TraceMode = .events,
    debug_overlay: bool = false,
};

pub const LogFormat = enum {
    text,
    json_lines,

    pub fn parse(value: []const u8) ?LogFormat {
        if (std.mem.eql(u8, value, "text")) return .text;
        if (std.mem.eql(u8, value, "jsonl") or std.mem.eql(u8, value, "json_lines")) return .json_lines;
        return null;
    }

    fn traceFormat(self: LogFormat) trace.Format {
        return switch (self) {
            .text => .text,
            .json_lines => .json_lines,
        };
    }
};

pub const LogPathBuffers = struct {
    log_dir: [1024]u8 = undefined,
    log_file: [1200]u8 = undefined,
    panic_file: [1200]u8 = undefined,
};

pub const LogPaths = struct {
    log_dir: []const u8,
    log_file: []const u8,
    panic_file: []const u8,
};

pub const LogSetup = struct {
    paths: LogPaths,
    format: LogFormat = .json_lines,
};

pub const FileTraceSink = struct {
    io: std.Io,
    log_dir: []const u8,
    path: []const u8,
    format: LogFormat = .json_lines,

    pub fn init(io: std.Io, log_dir: []const u8, path: []const u8, format: LogFormat) FileTraceSink {
        return .{ .io = io, .log_dir = log_dir, .path = path, .format = format };
    }

    pub fn sink(self: *FileTraceSink) trace.Sink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, record: trace.Record) trace.WriteError!void {
        const self: *FileTraceSink = @ptrCast(@alignCast(context));
        appendTraceRecord(self.io, self.log_dir, self.path, self.format, record) catch {};
    }
};

pub const FanoutTraceSink = struct {
    sinks: []const trace.Sink,

    pub fn sink(self: *FanoutTraceSink) trace.Sink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, record: trace.Record) trace.WriteError!void {
        const self: *FanoutTraceSink = @ptrCast(@alignCast(context));
        var first_error: ?trace.WriteError = null;
        for (self.sinks) |child| {
            child.write(record) catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        if (first_error) |err| return err;
    }
};

pub fn setupLogging(io: std.Io, env_map: *std.process.Environ.Map, app_name: []const u8, buffers: *LogPathBuffers) !LogSetup {
    _ = io;
    const paths = try resolveLogPaths(buffers, app_name, envFromMap(env_map), env_map.get("NATIVE_SDK_LOG_DIR"));
    return .{
        .paths = paths,
        .format = if (env_map.get("NATIVE_SDK_LOG_FORMAT")) |value| LogFormat.parse(value) orelse .json_lines else .json_lines,
    };
}

/// Logging into the app's resolved logs directory (`AppData.logs`, null
/// when the platform convention could not resolve it). `NATIVE_SDK_LOG_DIR`
/// still wins over it, data-directory override or not.
pub fn setupLoggingIn(io: std.Io, env_map: *std.process.Environ.Map, logs_dir: ?[]const u8, buffers: *LogPathBuffers) !LogSetup {
    _ = io;
    const paths = try logPathsIn(buffers, env_map.get("NATIVE_SDK_LOG_DIR") orelse logs_dir orelse return error.MissingLogDir);
    return .{
        .paths = paths,
        .format = if (env_map.get("NATIVE_SDK_LOG_FORMAT")) |value| LogFormat.parse(value) orelse .json_lines else .json_lines,
    };
}

pub fn resolveLogPaths(buffers: *LogPathBuffers, app_name: []const u8, env: app_dirs.Env, override_dir: ?[]const u8) !LogPaths {
    if (override_dir) |dir| return logPathsIn(buffers, dir);
    var log_dir_buffer: [1024]u8 = undefined;
    return logPathsIn(buffers, try app_dirs.resolveOne(.{ .name = app_name }, app_dirs.currentPlatform(), env, .logs, &log_dir_buffer));
}

fn logPathsIn(buffers: *LogPathBuffers, dir: []const u8) !LogPaths {
    const platform = app_dirs.currentPlatform();
    const log_dir = try copyInto(&buffers.log_dir, dir);
    const log_file = try app_dirs.join(platform, &buffers.log_file, &.{ log_dir, "native-sdk.jsonl" });
    const panic_file = try app_dirs.join(platform, &buffers.panic_file, &.{ log_dir, "last-panic.txt" });
    return .{ .log_dir = log_dir, .log_file = log_file, .panic_file = panic_file };
}

pub fn installPanicCapture(io: std.Io, paths: LogPaths) void {
    panic_state.install(io, paths) catch {};
}

pub fn capturePanic(msg: []const u8, ra: ?usize) noreturn {
    panic_state.write(msg, ra) catch {};
    std.debug.defaultPanic(msg, ra);
}

pub fn parseTraceMode(value: []const u8) ?TraceMode {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "events")) return .events;
    if (std.mem.eql(u8, value, "runtime")) return .runtime;
    if (std.mem.eql(u8, value, "all")) return .all;
    return null;
}

pub fn envFromMap(env_map: *std.process.Environ.Map) app_dirs.Env {
    return app_dirs.envFromMap(env_map);
}

pub fn appendTraceRecord(io: std.Io, log_dir: []const u8, path: []const u8, format: LogFormat, record: trace.Record) !void {
    // Bounded formatting: oversized records are truncated (text) or
    // rewritten minimally (json), never turned into a write error that
    // would fail dispatch upstream.
    var line_buffer: [4096]u8 = undefined;
    const line = switch (format.traceFormat()) {
        .text => blk: {
            const text = trace.formatTextBounded(record, line_buffer[0 .. line_buffer.len - 1]);
            line_buffer[text.len] = '\n';
            break :blk line_buffer[0 .. text.len + 1];
        },
        .json_lines => trace.formatJsonLineBounded(record, &line_buffer),
    };
    if (line.len == 0) return;
    try appendFile(io, log_dir, path, line);
}

fn appendFile(io: std.Io, directory: []const u8, path: []const u8, bytes: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, directory) catch {};
    var file = try cwd.createFile(io, path, .{ .read = true, .truncate = false });
    defer file.close(io);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, bytes, stat.size);
}

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

const PanicState = struct {
    installed: bool = false,
    io: std.Io = undefined,
    log_dir_buffer: [1024]u8 = undefined,
    log_file_buffer: [1200]u8 = undefined,
    panic_file_buffer: [1200]u8 = undefined,
    log_dir: []const u8 = &.{},
    log_file: []const u8 = &.{},
    panic_file: []const u8 = &.{},

    fn install(self: *PanicState, io: std.Io, paths: LogPaths) !void {
        self.io = io;
        self.log_dir = try copyInto(&self.log_dir_buffer, paths.log_dir);
        self.log_file = try copyInto(&self.log_file_buffer, paths.log_file);
        self.panic_file = try copyInto(&self.panic_file_buffer, paths.panic_file);
        self.installed = true;
    }

    fn write(self: *PanicState, msg: []const u8, ra: ?usize) !void {
        if (!self.installed) return;
        var report_buffer: [1024]u8 = undefined;
        var report = std.Io.Writer.fixed(&report_buffer);
        try report.print("panic: {s}\n", .{msg});
        if (ra) |addr| try report.print("return_address: 0x{x}\n", .{addr});

        var cwd = std.Io.Dir.cwd();
        cwd.createDirPath(self.io, self.log_dir) catch {};
        try cwd.writeFile(self.io, .{ .sub_path = self.panic_file, .data = report.buffered() });

        var fields: [1]trace.Field = undefined;
        const field_slice = if (ra) |addr| blk: {
            fields[0] = trace.uint("return_address", addr);
            break :blk fields[0..1];
        } else fields[0..0];
        try appendTraceRecord(self.io, self.log_dir, self.log_file, .json_lines, trace.event(.{}, .fatal, "panic", msg, field_slice));
    }
};

var panic_state: PanicState = .{};

test "trace mode parsing and matching" {
    try std.testing.expectEqual(TraceMode.events, parseTraceMode("events").?);
    try std.testing.expect(TraceMode.all.includes(.runtime));
    try std.testing.expect(!TraceMode.events.includes(.runtime));
}

test "log path resolution uses platform logs directory and overrides" {
    var buffers: LogPathBuffers = .{};
    const env: app_dirs.Env = .{ .home = "/Users/alice", .tmpdir = "/tmp" };
    const paths = try resolveLogPaths(&buffers, "dev.native_sdk.test", env, "/tmp/native-sdk-logs");
    try std.testing.expectEqualStrings("/tmp/native-sdk-logs", paths.log_dir);
    try std.testing.expect(std.mem.indexOf(u8, paths.log_file, "native-sdk.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, paths.panic_file, "last-panic.txt") != null);
}

test "log setup uses the resolved logs directory unless NATIVE_SDK_LOG_DIR overrides it" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var buffers: LogPathBuffers = .{};
    const sep = std.fs.path.sep_str;
    const resolved = try setupLoggingIn(std.testing.io, &env, "root" ++ sep ++ "logs", &buffers);
    try std.testing.expectEqualStrings("root" ++ sep ++ "logs", resolved.paths.log_dir);
    try std.testing.expectEqualStrings("root" ++ sep ++ "logs" ++ sep ++ "native-sdk.jsonl", resolved.paths.log_file);
    try std.testing.expectEqualStrings("root" ++ sep ++ "logs" ++ sep ++ "last-panic.txt", resolved.paths.panic_file);
    try std.testing.expectError(error.MissingLogDir, setupLoggingIn(std.testing.io, &env, null, &buffers));
    try env.put("NATIVE_SDK_LOG_DIR", "elsewhere");
    try std.testing.expectEqualStrings("elsewhere", (try setupLoggingIn(std.testing.io, &env, "root" ++ sep ++ "logs", &buffers)).paths.log_dir);
    try std.testing.expectEqualStrings("elsewhere", (try setupLoggingIn(std.testing.io, &env, null, &buffers)).paths.log_dir);
}

test "fanout sink writes every child sink" {
    var records_a: [2]trace.Record = undefined;
    var records_b: [2]trace.Record = undefined;
    var sink_a = trace.BufferSink.init(&records_a);
    var sink_b = trace.BufferSink.init(&records_b);
    const sinks = [_]trace.Sink{ sink_a.sink(), sink_b.sink() };
    var fanout: FanoutTraceSink = .{ .sinks = &sinks };

    try fanout.sink().write(trace.event(.{ .ns = 1 }, .info, "one", null, &.{}));

    try std.testing.expectEqual(@as(usize, 1), sink_a.written().len);
    try std.testing.expectEqual(@as(usize, 1), sink_b.written().len);
}
