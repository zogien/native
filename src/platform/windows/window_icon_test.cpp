/* Window icons from icon_path against the production Windows host:
 *
 *   window-icon-test <icon_path> icon   the file loads
 *   window-icon-test <icon_path> none   the file is missing or unreadable
 *
 * build.zig runs it with a PNG, an .ico, a missing path, a file that is
 * not an image, and a relative path both from the working directory and
 * from a packaged layout (bin\ beside resources\). Each step checks the
 * icons Windows draws for Alt+Tab and the taskbar preview (WM_GETICON):
 *
 *  startup    The startup window has icon_path at its DPI's large and
 *             small sizes, or no icon when the file cannot be loaded.
 *  dpi        WM_DPICHANGED hands the icons over again.
 *  second     A window opened later at the same DPI shares the handles.
 *  teardown   Destroying the host releases the icons.
 *
 * A watchdog names the step that stalled. */
#include "webview2_host.cpp"

namespace {

std::atomic<const char *> step{"startup"};
Host *fixture = nullptr;
bool expect_icon = false;
HICON startup_large = nullptr;
HICON startup_small = nullptr;
bool checked = false;

void require(bool condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "FAIL (%s, %s): %s\n", expect_icon ? "icon" : "none", step.load(), message);
    ExitProcess(1);
}

HWND appWindow(uint64_t window_id) {
    auto found = fixture->windows.find(window_id);
    return found == fixture->windows.end() ? nullptr : found->second.hwnd;
}

HICON windowIcon(HWND hwnd, WPARAM which) {
    return reinterpret_cast<HICON>(SendMessageW(hwnd, WM_GETICON, which, 0));
}

int iconWidth(HICON icon) {
    ICONINFO info = {};
    if (!GetIconInfo(icon, &info)) return -1;
    BITMAP bitmap = {};
    const int width = GetObjectW(info.hbmColor ? info.hbmColor : info.hbmMask, sizeof(bitmap), &bitmap) ? bitmap.bmWidth : -1;
    if (info.hbmColor) DeleteObject(info.hbmColor);
    if (info.hbmMask) DeleteObject(info.hbmMask);
    return width;
}

void CALLBACK check(HWND, UINT, UINT_PTR timer, DWORD) {
    KillTimer(nullptr, timer);
    if (checked) return;
    checked = true;

    HWND startup = appWindow(1);
    require(startup != nullptr, "the startup window exists");
    const UINT dpi = dpiForWindow(startup);
    startup_large = windowIcon(startup, ICON_BIG);
    startup_small = windowIcon(startup, ICON_SMALL);
    if (!expect_icon) {
        require(startup_large == nullptr && startup_small == nullptr, "a file that cannot be loaded leaves the window without an icon");
    } else {
        require(startup_large != nullptr && startup_small != nullptr, "both icon sizes are set");
        require(iconWidth(startup_large) == systemMetricForDpi(SM_CXICON, dpi), "the large icon has the DPI's large-icon size");
        require(iconWidth(startup_small) == systemMetricForDpi(SM_CXSMICON, dpi), "the small icon has the DPI's small-icon size");

        step.store("dpi");
        SendMessageW(startup, WM_SETICON, ICON_BIG, 0);
        SendMessageW(startup, WM_SETICON, ICON_SMALL, 0);
        require(windowIcon(startup, ICON_BIG) == nullptr && windowIcon(startup, ICON_SMALL) == nullptr, "the icons were cleared");
        RECT frame = {};
        require(GetWindowRect(startup, &frame) != 0, "the startup window's frame");
        SendMessageW(startup, WM_DPICHANGED, MAKEWPARAM(dpi, dpi), reinterpret_cast<LPARAM>(&frame));
        require(windowIcon(startup, ICON_BIG) == startup_large && windowIcon(startup, ICON_SMALL) == startup_small, "a DPI change hands the icons over again");
    }

    step.store("second");
    require(native_sdk_windows_create_window(fixture, 2, "Second", 6, "second", 6, 0, 0, 200, 150, 0, 0, 0, 1, 0, 0, 0, 2, 0) == 1, "a second window opens");
    HWND second = appWindow(2);
    require(second != nullptr, "the second window exists");
    if (!expect_icon) {
        require(windowIcon(second, ICON_BIG) == nullptr && windowIcon(second, ICON_SMALL) == nullptr, "the second window has no icon either");
    } else if (dpiForWindow(second) == dpi) {
        require(windowIcon(second, ICON_BIG) == startup_large && windowIcon(second, ICON_SMALL) == startup_small, "windows at one DPI share the icons");
    } else {
        require(windowIcon(second, ICON_BIG) != nullptr && windowIcon(second, ICON_SMALL) != nullptr, "a window at another DPI gets its own icons");
    }

    step.store("teardown");
    native_sdk_windows_stop(fixture);
}

void event(void *, const WindowsEvent *incoming) {
    if (incoming->kind != kStart) return;
    require(SetTimer(nullptr, 0, 20, check) != 0, "check timer");
}

} // namespace

int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[2], "icon") != 0 && strcmp(argv[2], "none") != 0)) {
        fprintf(stderr, "usage: window-icon-test <icon_path> icon|none\n");
        return 2;
    }
    const char *icon_path = argv[1];
    expect_icon = strcmp(argv[2], "icon") == 0;
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    require(done != nullptr, "watchdog event");
    std::thread watchdog([done] {
        if (WaitForSingleObject(done, 60000) != WAIT_OBJECT_0) {
            fprintf(stderr, "FAIL: stalled in %s\n", step.load());
            TerminateProcess(GetCurrentProcess(), 1);
        }
    });
    fixture = native_sdk_windows_create(
        "window-icon-test", 16, "Window Icon Test", 16,
        "dev.native-sdk.window-icon-test", sizeof("dev.native-sdk.window-icon-test") - 1,
        icon_path, strlen(icon_path), "main", 4, 0, 0, 320, 240,
        0, 0, 0, 1, 0, 0, 0, 2, 0);
    require(fixture != nullptr, "create host");
    native_sdk_windows_run(fixture, event, nullptr);
    require(checked, "the loop ran the checks");

    native_sdk_windows_destroy(fixture);
    if (expect_icon) {
        ICONINFO info = {};
        require(!GetIconInfo(startup_large, &info) && !GetIconInfo(startup_small, &info), "destroying the host releases the icons");
    }

    SetEvent(done);
    watchdog.join();
    CloseHandle(done);
    printf("PASS: Windows window icons (%s)\n", expect_icon ? "icon" : "none");
    return 0;
}
