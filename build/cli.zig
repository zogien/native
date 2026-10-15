//! Production CLI wiring shared by the repository and installed SDK builds.
const std = @import("std");

pub const Modules = struct {
    geometry: *std.Build.Module,
    assets: *std.Build.Module,
    app_dirs: *std.Build.Module,
    trace: *std.Build.Module,
    app_manifest: *std.Build.Module,
    diagnostics: *std.Build.Module,
    platform_info: *std.Build.Module,
    debug: *std.Build.Module,
    tooling: *std.Build.Module,
    automation_protocol: *std.Build.Module,
    ui_markup: *std.Build.Module,
    markup_lsp: *std.Build.Module,
};

pub fn createModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Modules {
    const geometry = module(b, target, optimize, "src/primitives/geometry/root.zig");
    const assets = module(b, target, optimize, "src/primitives/assets/root.zig");
    const app_dirs = module(b, target, optimize, "src/primitives/app_dirs/root.zig");
    const trace = module(b, target, optimize, "src/primitives/trace/root.zig");
    const app_manifest = module(b, target, optimize, "src/primitives/app_manifest/root.zig");
    const diagnostics = module(b, target, optimize, "src/primitives/diagnostics/root.zig");
    const platform_info = module(b, target, optimize, "src/primitives/platform_info/root.zig");
    const debug = module(b, target, optimize, "src/debug/root.zig");
    debug.addImport("app_dirs", app_dirs);
    debug.addImport("trace", trace);
    // The icon pipeline needs only geometry, not the platform-linked canvas.
    const app_icon = module(b, target, optimize, "src/primitives/canvas/app_icon.zig");
    app_icon.addImport("geometry", geometry);
    const tooling = module(b, target, optimize, "src/tooling/root.zig");
    tooling.addImport("assets", assets);
    tooling.addImport("app_dirs", app_dirs);
    tooling.addImport("app_manifest", app_manifest);
    tooling.addImport("diagnostics", diagnostics);
    tooling.addImport("debug", debug);
    tooling.addImport("platform_info", platform_info);
    tooling.addImport("trace", trace);
    tooling.addImport("app_icon", app_icon);
    tooling.addImport("ios_host", module(b, target, optimize, "src/platform/ios/files.zig"));
    tooling.addImport("android_host", module(b, target, optimize, "src/platform/android/files.zig"));
    tooling.addImport("sqlite_engine", module(b, target, optimize, "src/runtime/sqlite_engine.zig"));
    tooling.addImport("update_feed", module(b, target, optimize, "src/updater/feed.zig"));
    tooling.addIncludePath(b.path("third_party/sqlite"));
    tooling.addCSourceFile(.{
        .file = b.path("third_party/sqlite/sqlite3.c"),
        .flags = sqliteCompileFlags(),
    });
    tooling.link_libc = true;
    const ui_markup = module(b, target, optimize, "src/primitives/canvas/ui_markup.zig");
    const markup_lsp = module(b, target, optimize, "tools/native-sdk/markup_lsp.zig");
    markup_lsp.addImport("ui_markup", ui_markup);
    return .{
        .geometry = geometry,
        .assets = assets,
        .app_dirs = app_dirs,
        .trace = trace,
        .app_manifest = app_manifest,
        .diagnostics = diagnostics,
        .platform_info = platform_info,
        .debug = debug,
        .tooling = tooling,
        .automation_protocol = module(b, target, optimize, "src/automation/protocol.zig"),
        .ui_markup = ui_markup,
        .markup_lsp = markup_lsp,
    };
}

pub fn addExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, modules: Modules, build_commit: []const u8) *std.Build.Step.Compile {
    const info = b.addOptions();
    info.addOption([]const u8, "build_commit", build_commit);
    const root = module(b, target, optimize, "tools/native-sdk/main.zig");
    root.addImport("tooling", modules.tooling);
    root.addImport("automation_protocol", modules.automation_protocol);
    root.addImport("ui_markup", modules.ui_markup);
    root.addImport("markup_lsp", modules.markup_lsp);
    root.addOptions("cli_build_info", info);
    return b.addExecutable(.{ .name = "native", .root_module = root });
}

pub fn sqliteCompileFlags() []const []const u8 {
    return &.{
        "-DSQLITE_THREADSAFE=2",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_DQS=0",
        "-DSQLITE_ENABLE_FTS5",
        "-DSQLITE_ENABLE_JSON1",
        "-DSQLITE_ENABLE_UPDATE_HOOK",
        "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
        "-DSQLITE_DEFAULT_MEMSTATUS=0",
    };
}

pub fn buildCommit(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const output = b.runAllowFail(&.{ "git", "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return "unknown";
    const trimmed = std.mem.trim(u8, output, " \n\r\t");
    if (trimmed.len == 0) return "unknown";
    return trimmed;
}

fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}
