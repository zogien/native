/* Window placement against the production Windows host: the placement
 * cache behind window_placement_fn, the create path that reopens a saved
 * placement, and the content<->outer conversion both share. Each step
 * drives real top-level windows (hidden unless the step is about a show
 * path) and checks what Win32 reports:
 *
 *  sizes      Every titlebar style, resizable or not, with and without a
 *             menu bar, opens with exactly the requested content size at
 *             exactly the requested content origin, the placement query
 *             answers exactly that frame, and the min-size floor stops a
 *             resize at exactly the declared content size. The hidden
 *             styles used to open 2x1 px small and shrink per relaunch.
 *  settle     A programmatic move or resize settles the cache, and the
 *             first frame event it causes already carries the new
 *             placement (a resize that sends no WM_MOVE still gets one).
 *             Inside WM_ENTERSIZEMOVE..WM_EXITSIZEMOVE the cache keeps
 *             the pre-drag answer; the loop's end settles it once.
 *  dpi        A WM_DPICHANGED suggested rect settles like any move.
 *  maximized  A window created with initial_maximized is maximized while
 *             still hidden, answers its normal frame with maximized set,
 *             reports the maximized live frame, and Restore returns it to
 *             exactly the requested frame. A chromeless one fills exactly
 *             the work area.
 *  shows      It stays maximized through every show path: immediate and
 *             deferred to the first-present deadline, each with and
 *             without activation, and hidden then shown (activating,
 *             passive, and through focus).
 *  offscreen  A saved origin 5000 px off every monitor opens reachable on
 *             the nearest one; center_on_primary centers a restored frame
 *             on the primary work area, while an explicit origin keeps its
 *             place under the same policy.
 *  destroy    After the native window is gone the query still answers the
 *             last placement (maximized included), and it answers nothing
 *             for a window the host never created.
 *  answered   Every frame event, the ones a window sends while it is still
 *             being created included (attaching the menu bar moves the
 *             client), finds a placement answer: without one the runtime
 *             would persist the event's live frame.
 *  launcher   The harness relaunches itself the way Explorer and shortcuts
 *             start apps (STARTF_USESHOWWINDOW), where Windows replaces the
 *             process's first SW_SHOW with STARTUPINFO.wShowWindow: under
 *             SW_SHOWNORMAL the startup window still opens maximized, under
 *             a "Run: Minimized" launcher it starts minimized and Restore
 *             returns it to maximized, and under a hidden launcher it stays
 *             hidden (maximized) like any other window would.
 *
 * A watchdog names the step that stalled. */
#include "webview2_host.cpp"

namespace {

std::atomic<const char *> step{"startup"};
Host *fixture = nullptr;
uint64_t next_window_id = 10;
bool finished = false;

/* Frame events seen for the window under observation. */
uint64_t watched_id = 0;
int watched_frame_events = 0;
int watched_events_with_settled = 0;
WindowPlacementCache expected_at_event;

/* Frame events whose window had no placement answer at that moment: the
 * runtime would persist such an event's live frame instead. */
int unanswered_frame_events = 0;

uint64_t deferred_id = 0;
uint64_t deferred_active_id = 0;
ULONGLONG deferred_created_ms = 0;

void require(bool condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "FAIL (%s): %s\n", step.load(), message);
    ExitProcess(1);
}

HWND appWindow(uint64_t window_id) {
    auto found = fixture->windows.find(window_id);
    return found == fixture->windows.end() ? nullptr : found->second.hwnd;
}

constexpr uint32_t kFlagNoActivate = 1u << 3;
constexpr uint32_t kFlagInitialMaximized = 1u << 6;
constexpr int kShowImmediate = 0;
constexpr int kShowFirstPresent = 1;
constexpr int kShowHidden = 2;

uint64_t createWindow(int titlebar_style, bool resizable, double x, double y, double width, double height, int placement, int policy, int show_policy, uint32_t flags, double min_width = 0, double min_height = 0) {
    const uint64_t id = next_window_id++;
    require(native_sdk_windows_create_window(fixture, id, "Placement", 9, "placement", 9, x, y, width, height, 1, placement, policy, resizable ? 1 : 0, titlebar_style, min_width, min_height, show_policy, flags) == 1, "the window opens");
    require(appWindow(id) != nullptr, "the window exists");
    return id;
}

bool queryPlacement(uint64_t id, WindowPlacementCache *out) {
    int maximized = 0;
    if (!native_sdk_windows_window_placement(fixture, id, &out->x, &out->y, &out->width, &out->height, &maximized)) return false;
    out->maximized = maximized != 0;
    out->valid = true;
    return true;
}

/* The logical size a requested logical extent comes back as at `dpi`:
 * whole physical pixels divided by the scale (the identity at 96). */
double settledExtent(double logical, UINT dpi) {
    const double scale = (double)dpi / 96.0;
    return (double)physicalContentExtent(logical * scale) / scale;
}

bool samePlacement(const WindowPlacementCache &a, const WindowPlacementCache &b) {
    return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height && a.maximized == b.maximized;
}

WindowPlacementCache placementOf(double x, double y, double width, double height, bool maximized, UINT dpi) {
    WindowPlacementCache placement;
    placement.valid = true;
    placement.x = x;
    placement.y = y;
    placement.width = settledExtent(width, dpi);
    placement.height = settledExtent(height, dpi);
    placement.maximized = maximized;
    return placement;
}

void requirePlacement(uint64_t id, const WindowPlacementCache &expected, const char *message) {
    WindowPlacementCache actual;
    require(queryPlacement(id, &actual), "the placement query answers");
    if (!samePlacement(actual, expected)) {
        fprintf(stderr, "  placement (%.3f, %.3f) %.3f x %.3f maximized=%d, expected (%.3f, %.3f) %.3f x %.3f maximized=%d\n",
            actual.x, actual.y, actual.width, actual.height, actual.maximized ? 1 : 0,
            expected.x, expected.y, expected.width, expected.height, expected.maximized ? 1 : 0);
    }
    require(samePlacement(actual, expected), message);
}

/* The client rect in screen coordinates. */
RECT clientOnScreen(HWND hwnd) {
    RECT client = {};
    GetClientRect(hwnd, &client);
    POINT origin = { 0, 0 };
    ClientToScreen(hwnd, &origin);
    OffsetRect(&client, origin.x, origin.y);
    return client;
}

void requireContent(HWND hwnd, LONG x, LONG y, double width, double height, const char *message) {
    const UINT dpi = dpiForWindow(hwnd);
    const double scale = (double)dpi / 96.0;
    const RECT client = clientOnScreen(hwnd);
    const bool match = client.left == x && client.top == y &&
        client.right - client.left == physicalContentExtent(width * scale) &&
        client.bottom - client.top == physicalContentExtent(height * scale);
    if (!match) {
        fprintf(stderr, "  content (%ld, %ld) %ld x %ld, expected (%ld, %ld) %ld x %ld at dpi %u\n",
            client.left, client.top, client.right - client.left, client.bottom - client.top,
            x, y, physicalContentExtent(width * scale), physicalContentExtent(height * scale), dpi);
    }
    require(match, message);
}

void setMenuBar(bool on) {
    const char *title = "File";
    const size_t title_len = 4;
    require(native_sdk_windows_set_menus(fixture, on ? &title : nullptr, on ? &title_len : nullptr, on ? 1 : 0,
        nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, 0) == 1, "menus apply");
}

void closeWindow(uint64_t id) {
    require(native_sdk_windows_close_window(fixture, id) == 1, "the window closes");
    require(appWindow(id) == nullptr, "the native window is gone");
}

void checkSizes() {
    step.store("sizes");
    const char *style_names[4] = { "standard", "hidden_inset", "hidden_inset_tall", "chromeless" };
    for (int menu = 0; menu < 2; ++menu) {
        setMenuBar(menu != 0);
        for (int style = 0; style < 4; ++style) {
            for (int resizable = 1; resizable >= 0; --resizable) {
                char label[96];
                snprintf(label, sizeof(label), "sizes %s %s %s", style_names[style], resizable ? "resizable" : "fixed", menu ? "menu" : "no-menu");
                step.store(label);
                const uint64_t id = createWindow(style, resizable != 0, 200, 150, 517, 333, kInitialPlacementRestored, 0, kShowHidden, 0, 300, 200);
                HWND hwnd = appWindow(id);
                require((GetMenu(hwnd) != nullptr) == (menu != 0), "the menu bar is attached exactly when menus are declared");
                const UINT dpi = dpiForWindow(hwnd);
                requireContent(hwnd, 200, 150, 517, 333, "the content opens at the requested size and origin");
                requirePlacement(id, placementOf(200, 150, 517, 333, false, dpi), "the placement is exactly the requested frame");
                if (resizable) {
                    /* SetWindowPos applies the min track size, so a resize far
                     * below the floor lands exactly on the floor. */
                    RECT outer = {};
                    GetWindowRect(hwnd, &outer);
                    SetWindowPos(hwnd, nullptr, outer.left, outer.top, 40, 40, SWP_NOZORDER | SWP_NOACTIVATE);
                    requireContent(hwnd, 200, 150, 300, 200, "the min-size floor stops at exactly the declared content size");
                    requirePlacement(id, placementOf(200, 150, 300, 200, false, dpi), "the floored resize settled");
                }
                closeWindow(id);
                requirePlacement(id, placementOf(200, 150, resizable ? 300 : 517, resizable ? 200 : 333, false, dpi), "the closed window keeps its placement");
            }
        }
    }
    setMenuBar(false);
}

void watch(uint64_t id, const WindowPlacementCache &expected) {
    watched_id = id;
    watched_frame_events = 0;
    watched_events_with_settled = 0;
    expected_at_event = expected;
}

void checkSettle() {
    step.store("settle");
    const uint64_t id = createWindow(1, true, 300, 200, 400, 300, kInitialPlacementRestored, 0, kShowHidden, 0);
    HWND hwnd = appWindow(id);
    const UINT dpi = dpiForWindow(hwnd);
    RECT outer = {};
    GetWindowRect(hwnd, &outer);
    const LONG inset_left = 300 - outer.left;
    const LONG inset_top = 200 - outer.top;

    step.store("settle move");
    WindowPlacementCache moved = placementOf(350, 260, 400, 300, false, dpi);
    watch(id, moved);
    SetWindowPos(hwnd, nullptr, 350 - inset_left, 260 - inset_top, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    requirePlacement(id, moved, "a programmatic move settles");
    require(watched_frame_events >= 1 && watched_events_with_settled == watched_frame_events, "every frame event of the move carries the settled placement");

    step.store("settle resize");
    GetWindowRect(hwnd, &outer);
    const double scale = (double)dpi / 96.0;
    const LONG extra_width = (LONG)std::lround(40 * scale);
    const LONG extra_height = (LONG)std::lround(30 * scale);
    WindowPlacementCache resized = moved;
    resized.width = (double)(physicalContentExtent(400 * scale) + extra_width) / scale;
    resized.height = (double)(physicalContentExtent(300 * scale) + extra_height) / scale;
    watch(id, resized);
    SetWindowPos(hwnd, nullptr, 0, 0, outer.right - outer.left + extra_width, outer.bottom - outer.top + extra_height, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    requirePlacement(id, resized, "a resize settles");
    require(watched_frame_events == 1 && watched_events_with_settled == 1, "a resize that does not move emits exactly one frame event, carrying the new placement");

    step.store("settle drag");
    watch(id, resized);
    SendMessageW(hwnd, WM_ENTERSIZEMOVE, 0, 0);
    for (int index = 1; index <= 5; ++index) {
        SetWindowPos(hwnd, nullptr, 360 + index * 10 - inset_left, 270 + index * 5 - inset_top, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        requirePlacement(id, resized, "a drag in progress keeps the pre-drag placement");
    }
    require(watched_frame_events == 5 && watched_events_with_settled == 5, "the drag's frame events report the live frame over the pre-drag placement");
    WindowPlacementCache dropped = resized;
    dropped.x = 410;
    dropped.y = 295;
    watch(id, dropped);
    SendMessageW(hwnd, WM_EXITSIZEMOVE, 0, 0);
    requirePlacement(id, dropped, "the end of the drag settles once");
    require(watched_frame_events == 1 && watched_events_with_settled == 1, "the end of the drag emits one frame event carrying the new placement");

    step.store("dpi");
    /* WM_DPICHANGED at the window's own DPI (a scale change cannot be
     * staged here): the suggested rect settles like any other move. */
    GetWindowRect(hwnd, &outer);
    OffsetRect(&outer, 25, 15);
    WindowPlacementCache suggested = dropped;
    suggested.x += 25;
    suggested.y += 15;
    watch(id, suggested);
    SendMessageW(hwnd, WM_DPICHANGED, MAKEWPARAM(dpi, dpi), reinterpret_cast<LPARAM>(&outer));
    requirePlacement(id, suggested, "a DPI change's suggested rect settles");
    require(watched_frame_events >= 1 && watched_events_with_settled == watched_frame_events, "the DPI change's frame events carry the new placement");
    watched_id = 0;
    closeWindow(id);
    requirePlacement(id, suggested, "the placement outlives the window");
}

void requireMaximizedOn(HWND hwnd, const char *message) {
    require(IsWindowVisible(hwnd) != FALSE, message);
    require(IsZoomed(hwnd) != FALSE, message);
}

void checkMaximized() {
    step.store("maximized hidden");
    const uint64_t id = createWindow(0, true, 240, 180, 600, 400, kInitialPlacementRestored, 0, kShowHidden, kFlagInitialMaximized);
    HWND hwnd = appWindow(id);
    const UINT dpi = dpiForWindow(hwnd);
    require(!IsWindowVisible(hwnd) && IsZoomed(hwnd), "the window is maximized while still hidden");
    requirePlacement(id, placementOf(240, 180, 600, 400, true, dpi), "the placement is the requested normal frame, maximized");
    double x = 0, y = 0, width = 0, height = 0, scale = 0;
    int maximized = 0;
    require(native_sdk_windows_window_frame(fixture, id, &x, &y, &width, &height, &scale, &maximized) == 1 && maximized == 1, "the live frame reports maximized");
    RECT work = {};
    require(monitorWorkArea(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &work), "the work area");
    require(width * scale >= (double)(work.right - work.left) - 1, "the live frame is the maximized frame");

    step.store("maximized shown");
    require(native_sdk_windows_show_window(fixture, id) == 1, "show");
    requireMaximizedOn(hwnd, "an activating show keeps it maximized");
    step.store("maximized restore");
    require(native_sdk_windows_unmaximize_window(fixture, id) == 1, "restore");
    require(!IsZoomed(hwnd), "restored");
    requireContent(hwnd, 240, 180, 600, 400, "Restore returns to exactly the requested frame");
    requirePlacement(id, placementOf(240, 180, 600, 400, false, dpi), "the restored placement");
    step.store("maximized again");
    require(native_sdk_windows_maximize_window(fixture, id) == 1, "maximize");
    requirePlacement(id, placementOf(240, 180, 600, 400, true, dpi), "maximize settles maximized over the normal frame");
    step.store("restore that keeps the rect");
    /* A maximized window can be given its normal rect while it stays
     * maximized (SetWindowPos on a zoomed window). Restore then changes
     * only the mode: nothing moves or resizes. The transition is still a
     * settle point, and a frame event carries it to the runtime. */
    WINDOWPLACEMENT native = {};
    native.length = sizeof(native);
    require(GetWindowPlacement(hwnd, &native) != FALSE, "the native placement");
    const RECT normal = screenRectFromWorkspace(hwnd, native.rcNormalPosition);
    SetWindowPos(hwnd, nullptr, normal.left, normal.top, normal.right - normal.left, normal.bottom - normal.top, SWP_NOZORDER | SWP_NOACTIVATE);
    require(IsZoomed(hwnd) != FALSE, "the window stays maximized over its normal rect");
    requirePlacement(id, placementOf(240, 180, 600, 400, true, dpi), "still maximized over the normal frame");
    RECT before_restore = {};
    GetWindowRect(hwnd, &before_restore);
    watch(id, placementOf(240, 180, 600, 400, false, dpi));
    require(native_sdk_windows_unmaximize_window(fixture, id) == 1, "restore");
    RECT after_restore = {};
    GetWindowRect(hwnd, &after_restore);
    require(!IsZoomed(hwnd) && EqualRect(&before_restore, &after_restore) != FALSE, "Restore changed the mode and left the rect as it was");
    requirePlacement(id, placementOf(240, 180, 600, 400, false, dpi), "a Restore that keeps the rect still settles");
    require(watched_frame_events >= 1 && watched_events_with_settled >= 1, "a frame event carries the restored placement");
    watched_id = 0;
    require(native_sdk_windows_maximize_window(fixture, id) == 1, "maximize again");
    requirePlacement(id, placementOf(240, 180, 600, 400, true, dpi), "maximized again");
    step.store("minimized from maximized");
    require(native_sdk_windows_minimize_window(fixture, id) == 1, "minimize");
    require(IsIconic(hwnd) != FALSE, "minimized");
    requirePlacement(id, placementOf(240, 180, 600, 400, true, dpi), "minimized from maximized stays maximized over the normal frame");
    closeWindow(id);
    requirePlacement(id, placementOf(240, 180, 600, 400, true, dpi), "closing while minimized from maximized keeps maximized");

    step.store("maximized chromeless");
    const uint64_t chromeless = createWindow(3, true, 260, 190, 500, 320, kInitialPlacementRestored, 0, kShowImmediate, kFlagInitialMaximized | kFlagNoActivate);
    HWND chromeless_hwnd = appWindow(chromeless);
    requireMaximizedOn(chromeless_hwnd, "a chromeless window opens maximized");
    require(monitorWorkArea(MonitorFromWindow(chromeless_hwnd, MONITOR_DEFAULTTONEAREST), &work), "the work area");
    const RECT client = clientOnScreen(chromeless_hwnd);
    require(EqualRect(&client, &work) != FALSE, "a maximized chromeless window fills exactly the work area");
    require(native_sdk_windows_unmaximize_window(fixture, chromeless) == 1, "restore");
    requireContent(chromeless_hwnd, 260, 190, 500, 320, "the chromeless Restore returns to exactly the requested frame");
    closeWindow(chromeless);

    step.store("maximized hidden_inset_tall");
    const uint64_t tall = createWindow(2, true, 280, 200, 520, 340, kInitialPlacementRestored, 0, kShowImmediate, kFlagInitialMaximized | kFlagNoActivate);
    HWND tall_hwnd = appWindow(tall);
    requireMaximizedOn(tall_hwnd, "a hidden-titlebar window opens maximized");
    require(monitorWorkArea(MonitorFromWindow(tall_hwnd, MONITOR_DEFAULTTONEAREST), &work), "the work area");
    const RECT tall_client = clientOnScreen(tall_hwnd);
    require(EqualRect(&tall_client, &work) != FALSE, "a maximized hidden-titlebar window's content fills exactly the work area");
    require(native_sdk_windows_unmaximize_window(fixture, tall) == 1, "restore");
    requireContent(tall_hwnd, 280, 200, 520, 340, "the hidden-titlebar Restore returns to exactly the requested frame");
    closeWindow(tall);
}

void checkShows() {
    step.store("shows immediate");
    uint64_t id = createWindow(0, true, 220, 160, 500, 300, kInitialPlacementRestored, 0, kShowImmediate, kFlagInitialMaximized);
    requireMaximizedOn(appWindow(id), "an immediate activating show opens maximized");
    closeWindow(id);

    step.store("shows immediate passive");
    id = createWindow(0, true, 220, 160, 500, 300, kInitialPlacementRestored, 0, kShowImmediate, kFlagInitialMaximized | kFlagNoActivate);
    HWND passive = appWindow(id);
    requireMaximizedOn(passive, "an immediate passive show opens maximized");
    require(GetForegroundWindow() != passive || GetForegroundWindow() == nullptr, "the passive show does not take the foreground");
    closeWindow(id);

    step.store("shows hidden then shown");
    id = createWindow(0, true, 220, 160, 500, 300, kInitialPlacementRestored, 0, kShowHidden, kFlagInitialMaximized);
    require(native_sdk_windows_show_window(fixture, id) == 1, "show");
    requireMaximizedOn(appWindow(id), "a hidden window opens maximized when shown");
    closeWindow(id);

    step.store("shows hidden then shown passively");
    id = createWindow(0, true, 220, 160, 500, 300, kInitialPlacementRestored, 0, kShowHidden, kFlagInitialMaximized | kFlagNoActivate);
    require(native_sdk_windows_show_window(fixture, id) == 1, "show");
    requireMaximizedOn(appWindow(id), "a passive hidden window opens maximized when shown");
    require(native_sdk_windows_hide_window(fixture, id) == 1, "hide");
    require(native_sdk_windows_show_window(fixture, id) == 1, "show again");
    requireMaximizedOn(appWindow(id), "a maximized window a hide took off the glass comes back maximized");
    closeWindow(id);

    step.store("shows hidden then focused");
    id = createWindow(0, true, 220, 160, 500, 300, kInitialPlacementRestored, 0, kShowHidden, kFlagInitialMaximized);
    require(native_sdk_windows_focus_window(fixture, id) == 1, "focus");
    requireMaximizedOn(appWindow(id), "a hidden window opens maximized when focused");
    closeWindow(id);

    step.store("shows deferred");
    deferred_id = createWindow(0, true, 220, 160, 500, 300, kInitialPlacementRestored, 0, kShowFirstPresent, kFlagInitialMaximized | kFlagNoActivate);
    deferred_active_id = createWindow(0, true, 240, 180, 500, 300, kInitialPlacementRestored, 0, kShowFirstPresent, kFlagInitialMaximized);
    deferred_created_ms = GetTickCount64();
    require(!IsWindowVisible(appWindow(deferred_id)) && IsZoomed(appWindow(deferred_id)), "a passive deferred window waits hidden, already maximized");
    require(!IsWindowVisible(appWindow(deferred_active_id)) && IsZoomed(appWindow(deferred_active_id)), "an activating deferred window waits hidden, already maximized");
}

void checkOffscreen() {
    step.store("offscreen clamp");
    uint64_t id = createWindow(0, true, -5000, 200, 400, 300, kInitialPlacementRestored, 0, kShowHidden, 0);
    HWND hwnd = appWindow(id);
    RECT outer = {};
    GetWindowRect(hwnd, &outer);
    RECT work = {};
    require(monitorWorkArea(MonitorFromRect(&outer, MONITOR_DEFAULTTONULL), &work), "the window landed on a monitor");
    require(outer.left >= work.left && outer.top >= work.top && outer.right <= work.right && outer.bottom <= work.bottom, "the window lies inside that monitor's work area");
    WindowPlacementCache placement;
    require(queryPlacement(id, &placement) && placement.x > -5000, "the placement is where the window landed");
    closeWindow(id);

    step.store("offscreen caption above the work area");
    /* A content origin 5 px below the work area's top puts a standard
     * caption above it (the shape of every record saved before origins
     * were, at (0, 0)): the window moves down onto the work area. A
     * hidden-titlebar window's header is its content, so the same origin
     * stays exactly where it was saved. */
    const POINT primary_origin = { 0, 0 };
    RECT primary_work = {};
    require(monitorWorkArea(MonitorFromPoint(primary_origin, MONITOR_DEFAULTTOPRIMARY), &primary_work), "the primary work area");
    id = createWindow(0, true, primary_work.left + 300, primary_work.top + 5, 400, 300, kInitialPlacementRestored, 0, kShowHidden, 0);
    hwnd = appWindow(id);
    GetWindowRect(hwnd, &outer);
    require(outer.top == primary_work.top && clientOnScreen(hwnd).left == primary_work.left + 300, "a caption above the work area moves straight down onto it");
    closeWindow(id);
    id = createWindow(1, true, primary_work.left + 300, primary_work.top + 5, 400, 300, kInitialPlacementRestored, 0, kShowHidden, 0);
    requireContent(appWindow(id), primary_work.left + 300, primary_work.top + 5, 400, 300, "a hidden-titlebar header at the same origin stays put");
    closeWindow(id);

    step.store("offscreen center_on_primary");
    id = createWindow(0, true, 3000, 600, 400, 300, kInitialPlacementRestored, kRestorePolicyCenterOnPrimary, kShowHidden, 0);
    hwnd = appWindow(id);
    GetWindowRect(hwnd, &outer);
    const POINT zero = { 0, 0 };
    require(monitorWorkArea(MonitorFromPoint(zero, MONITOR_DEFAULTTOPRIMARY), &work), "the primary work area");
    const LONG center_dx = (outer.left + outer.right) - (work.left + work.right);
    const LONG center_dy = (outer.top + outer.bottom) - (work.top + work.bottom);
    require(center_dx >= -1 && center_dx <= 1 && center_dy >= -1 && center_dy <= 1, "center_on_primary centers a restored frame on the primary work area");
    requireContent(hwnd, clientOnScreen(hwnd).left, clientOnScreen(hwnd).top, 400, 300, "the centered window keeps the saved size");
    closeWindow(id);

    step.store("explicit under center_on_primary");
    id = createWindow(0, true, 210, 170, 400, 300, kInitialPlacementExplicit, kRestorePolicyCenterOnPrimary, kShowHidden, 0);
    requireContent(appWindow(id), 210, 170, 400, 300, "an explicit origin keeps its place");
    closeWindow(id);

    step.store("default placement");
    id = createWindow(0, true, 0, 0, 400, 300, kInitialPlacementDefault, 0, kShowHidden, 0);
    hwnd = appWindow(id);
    const RECT client = clientOnScreen(hwnd);
    const double scale = (double)dpiForWindow(hwnd) / 96.0;
    require(client.right - client.left == physicalContentExtent(400 * scale) && client.bottom - client.top == physicalContentExtent(300 * scale), "a default-placed window opens at the requested size");
    require(queryPlacement(id, &placement) && placement.x == (double)client.left && placement.y == (double)client.top, "its placement is where the OS put it");
    closeWindow(id);

    step.store("never created");
    require(!queryPlacement(987654, &placement), "no answer for a window the host never created");
}

void CALLBACK deferredCheck(HWND, UINT, UINT_PTR timer, DWORD) {
    HWND deferred = appWindow(deferred_id);
    HWND deferred_active = appWindow(deferred_active_id);
    require(deferred != nullptr && deferred_active != nullptr, "the deferred windows exist");
    if (!IsWindowVisible(deferred) || !IsWindowVisible(deferred_active)) {
        require(GetTickCount64() - deferred_created_ms < kDeferredShowDeadlineMs + 5000, "the deferred windows are shown at their deadline");
        return;
    }
    KillTimer(nullptr, timer);
    step.store("shows deferred reveal");
    requireMaximizedOn(deferred, "a passive deferred window opens maximized at its reveal");
    requireMaximizedOn(deferred_active, "an activating deferred window opens maximized at its reveal");
    closeWindow(deferred_id);
    closeWindow(deferred_active_id);
    step.store("answered frame events");
    require(unanswered_frame_events == 0, "every frame event, creation included, finds a placement answer");
    finished = true;
    step.store("teardown");
    native_sdk_windows_stop(fixture);
}

void CALLBACK check(HWND, UINT, UINT_PTR timer, DWORD) {
    KillTimer(nullptr, timer);
    checkSizes();
    checkSettle();
    checkMaximized();
    checkOffscreen();
    checkShows();
    step.store("shows deferred wait");
    require(SetTimer(nullptr, 0, 50, deferredCheck) != 0, "deferred check timer");
}

void event(void *, const WindowsEvent *incoming) {
    if (incoming->kind == kStart) {
        require(SetTimer(nullptr, 0, 20, check) != 0, "check timer");
        return;
    }
    if (incoming->kind != kWindowFrame) return;
    WindowPlacementCache answered;
    if (!queryPlacement(incoming->window_id, &answered)) {
        fprintf(stderr, "  frame event for window %llu with no placement answer (step %s)\n", (unsigned long long)incoming->window_id, step.load());
        ++unanswered_frame_events;
    }
    if (watched_id == 0 || incoming->window_id != watched_id) return;
    ++watched_frame_events;
    WindowPlacementCache at_event;
    if (queryPlacement(watched_id, &at_event) && samePlacement(at_event, expected_at_event)) ++watched_events_with_settled;
}

/* Launcher child: the startup window itself opens maximized and shows at
 * once with activation, the first show of this process. Exit 0 when it
 * is in the state the launcher's show command calls for. */
bool expect_minimized = false;
bool expect_hidden = false;
int child_result = 1;

void childEvent(void *, const WindowsEvent *incoming) {
    if (incoming->kind != kStart) return;
    HWND hwnd = appWindow(1);
    if (hwnd && expect_hidden) {
        if (!IsWindowVisible(hwnd) && IsZoomed(hwnd)) child_result = 0;
        else fprintf(stderr, "FAIL (launcher): a hidden launch did not keep the maximized startup window hidden\n");
    } else if (!hwnd || !IsWindowVisible(hwnd)) {
        fprintf(stderr, "FAIL (launcher): the startup window is not shown\n");
    } else if (!expect_minimized) {
        if (IsZoomed(hwnd)) child_result = 0;
        else fprintf(stderr, "FAIL (launcher): a SW_SHOWNORMAL launch restored the maximized startup window\n");
    } else if (!IsIconic(hwnd)) {
        fprintf(stderr, "FAIL (launcher): a minimized launch did not start minimized\n");
    } else {
        ShowWindow(hwnd, SW_RESTORE);
        if (IsZoomed(hwnd)) child_result = 0;
        else fprintf(stderr, "FAIL (launcher): Restore after a minimized launch did not return to maximized\n");
    }
    native_sdk_windows_stop(fixture);
}

int runLauncherChild(const char *mode) {
    expect_minimized = strcmp(mode, "minimized") == 0;
    expect_hidden = strcmp(mode, "hidden") == 0;
    fixture = native_sdk_windows_create(
        "window-placement-test", 21, "Window Placement Test", 21,
        "dev.native-sdk.window-placement-test", sizeof("dev.native-sdk.window-placement-test") - 1,
        nullptr, 0, "main", 4, 240, 180, 600, 400,
        1, kInitialPlacementRestored, 0, 1, 0, 0, 0, kShowImmediate, kFlagInitialMaximized);
    if (!fixture) return 1;
    native_sdk_windows_run(fixture, childEvent, nullptr);
    native_sdk_windows_destroy(fixture);
    return child_result;
}

void runLauncher(const char *mode, WORD show_command) {
    step.store(mode);
    wchar_t self[MAX_PATH] = {};
    require(GetModuleFileNameW(nullptr, self, MAX_PATH) > 0, "the harness path");
    std::wstring command = std::wstring(L"\"") + self + L"\" --launcher " + widen(mode);
    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = show_command;
    PROCESS_INFORMATION process = {};
    require(CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup, &process) != FALSE, "the launcher child starts");
    if (WaitForSingleObject(process.hProcess, 20000) != WAIT_OBJECT_0) {
        TerminateProcess(process.hProcess, 1);
        WaitForSingleObject(process.hProcess, 5000);
        require(false, "the launcher child finishes");
    }
    DWORD exit_code = 1;
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    require(exit_code == 0, "the startup window opens in the state the launcher calls for");
}

} // namespace

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--launcher") == 0) return runLauncherChild(argv[2]);
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    require(done != nullptr, "watchdog event");
    std::thread watchdog([done] {
        if (WaitForSingleObject(done, 60000) != WAIT_OBJECT_0) {
            fprintf(stderr, "FAIL: stalled in %s\n", step.load());
            TerminateProcess(GetCurrentProcess(), 1);
        }
    });
    fixture = native_sdk_windows_create(
        "window-placement-test", 21, "Window Placement Test", 21,
        "dev.native-sdk.window-placement-test", sizeof("dev.native-sdk.window-placement-test") - 1,
        nullptr, 0, "main", 4, 0, 0, 320, 240,
        0, 0, 0, 1, 0, 0, 0, 2, 0);
    require(fixture != nullptr, "create host");
    native_sdk_windows_run(fixture, event, nullptr);
    require(finished, "the loop ran every step");
    native_sdk_windows_destroy(fixture);
    runLauncher("normal", SW_SHOWNORMAL);
    runLauncher("minimized", SW_SHOWMINNOACTIVE);
    runLauncher("hidden", SW_HIDE);
    SetEvent(done);
    watchdog.join();
    CloseHandle(done);
    puts("PASS: Windows window placement");
    return 0;
}
