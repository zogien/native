//! Installed SDK build entry. Repository tests and examples stay in build.zig.
const std = @import("std");
const cli = @import("build/cli.zig");
const app = @import("build/app.zig");

pub const AppOptions = app.AppOptions;
pub const addApp = app.addApp;
pub const AppArtifacts = app.AppArtifacts;
pub const addAppArtifacts = app.addAppArtifacts;
pub const MobileLibOptions = app.MobileLibOptions;
pub const addMobileLib = app.addMobileLib;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const modules = cli.createModules(b, target, optimize);
    // addApp's package step resolves this artifact from the SDK dependency.
    const executable = cli.addExecutable(b, target, optimize, modules, cli.buildCommit(b));
    b.installArtifact(executable);
    const step = b.step("cli", "Build the native CLI executable");
    step.dependOn(&b.addInstallArtifact(executable, .{}).step);
}
