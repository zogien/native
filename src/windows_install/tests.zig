//! Test root for the Windows setup program, launcher and uninstaller.
//! The modules other than win32/main run on every host; the Windows-only
//! program entry is never analyzed here.

test {
    _ = @import("config.zig");
    _ = @import("payload.zig");
    _ = @import("switch.zig");
    _ = @import("win32.zig");
    _ = @import("main.zig");
}
