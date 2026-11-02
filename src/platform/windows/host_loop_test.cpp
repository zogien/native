/* The Windows host's loop model, against a real (hidden) WebView. The
 * production host is compiled in, so this drives the same code apps run:
 *
 *  1. A Bridge command reaches the app outside every WebView2 callback
 *     and can join a worker that wakes the loop and requests frames; the
 *     wake and the frame arrive once the command returns, and two frame
 *     requests made while one is queued produce one frame.
 *  2. After the first app window closes, a wake posted just before it
 *     closed still arrives, and an app timer keeps firing.
 *
 * No app callback may run while a WebView2 callback is on the stack. A
 * watchdog names the phase that stalled. */
#include "webview2_host.cpp"

namespace {

enum Phase { kPhaseWebView, kPhaseCommand, kPhaseAfterCommand, kPhaseSecondWindow, kPhaseDone };
const char *const kPhaseNames[] = {
    "waiting for the WebView to load",
    "waiting for the Bridge command",
    "waiting for the wake and frame the command's worker requested",
    "waiting for a wake and app timer after the first window closed",
    "done",
};
constexpr uint64_t kAppTimerId = 77;

std::atomic<int> phase{kPhaseWebView};
Host *fixture = nullptr;
UINT_PTR poll_timer = 0;
int wakes = 0;
int frames = 0;
int timer_ticks = 0;
int wakes_before_close = 0;

void require(bool condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "FAIL (%s): %s\n", kPhaseNames[phase.load()], message);
    ExitProcess(1);
}

void requireOutsideWebViewCallbacks() {
    require(fixture->webview_callback_depth == 0, "an app callback ran inside a WebView2 callback");
}

/* The per-window 16 ms frame pump would bury the frames the test counts,
 * so the test windows run without it. */
void stopFramePump(uint64_t window_id) {
    auto found = fixture->windows.find(window_id);
    require(found != fixture->windows.end() && found->second.hwnd, "window exists");
    KillTimer(found->second.hwnd, kFrameTimerId);
}

void wakeFromWorker(int expected_frames_requested) {
    std::thread worker([expected_frames_requested] {
        require(native_sdk_windows_wake(fixture) == 1, "wake posted");
        for (int index = 0; index < expected_frames_requested; ++index) {
            require(native_sdk_windows_request_frame(fixture) == 1, "frame request accepted");
        }
    });
    worker.join();
}

void CALLBACK closeFirstWindow(HWND, UINT, UINT_PTR timer, DWORD) {
    KillTimer(nullptr, timer);
    require(native_sdk_windows_create_window(fixture, 2, "Second", 6, "second", 6, 0, 0, 200, 150, 0, 0, 0, 1, 0, 0, 0, 2, 0) == 1, "second window");
    stopFramePump(2);
    native_sdk_windows_start_timer(fixture, kAppTimerId, 50ull * 1000000ull, 1);
    wakes_before_close = wakes;
    phase.store(kPhaseSecondWindow);
    /* Posted while window 1 is still the first app window, then window 1
     * goes away before the loop takes the wake. */
    wakeFromWorker(0);
    auto first = fixture->windows.find(1);
    require(first != fixture->windows.end() && first->second.hwnd, "first window open");
    DestroyWindow(first->second.hwnd);
}

void CALLBACK checkCommandResults(HWND, UINT, UINT_PTR timer, DWORD) {
    if (wakes < 1 || frames < 1) return;
    KillTimer(nullptr, timer);
    require(wakes == 1, "exactly one wake after the command");
    require(frames == 1, "the two frame requests coalesced into one frame");
    SetTimer(nullptr, 0, 10, closeFirstWindow);
}

void CALLBACK postCommand(HWND, UINT, UINT_PTR timer, DWORD) {
    auto found = fixture->webviews.find(webViewKey(1, "main"));
    if (found == fixture->webviews.end() || !found->second.webview) return;
    KillTimer(nullptr, timer);
    phase.store(kPhaseCommand);
    require(SUCCEEDED(found->second.webview->ExecuteScript(
        L"chrome.webview.postMessage('join-worker')", nullptr)), "post command");
}

void bridge(void *, uint64_t window_id,
            const char *label, size_t label_len,
            const char *message, size_t message_len,
            const char *origin, size_t origin_len) {
    requireOutsideWebViewCallbacks();
    require(phase.load() == kPhaseCommand, "one Bridge command");
    require(window_id == 1, "window identity");
    require(std::string(label, label_len) == "main", "view identity");
    require(std::string(message, message_len) == "join-worker", "message");
    require(std::string(origin, origin_len) == "zero://inline", "origin");
    wakeFromWorker(2);
    require(wakes == 0 && frames == 0, "wake and frame wait for the command to return");
    phase.store(kPhaseAfterCommand);
    SetTimer(nullptr, 0, 20, checkCommandResults);
}

void event(void *, const WindowsEvent *incoming) {
    requireOutsideWebViewCallbacks();
    switch (incoming->kind) {
        case kStart: {
            stopFramePump(1);
            const char html[] = "<!doctype html><title>Host Loop Test</title>";
            require(native_sdk_windows_load_window_webview(
                fixture, 1, html, sizeof(html) - 1, 0,
                nullptr, 0, nullptr, 0, nullptr, 0, 0) == 1, "load WebView");
            poll_timer = SetTimer(nullptr, 0, 50, postCommand);
            require(poll_timer != 0, "command timer");
            break;
        }
        case kWake:
            wakes += 1;
            break;
        case kFrame:
            frames += 1;
            break;
        case kTimer:
            if (incoming->timer_id == kAppTimerId) timer_ticks += 1;
            break;
        default:
            break;
    }
    if (phase.load() == kPhaseSecondWindow && wakes > wakes_before_close && timer_ticks >= 2) {
        require(fixture->windows.find(1)->second.hwnd == nullptr, "first window closed");
        phase.store(kPhaseDone);
        native_sdk_windows_stop(fixture);
    }
}

} // namespace

int main() {
    HANDLE finished = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    require(finished != nullptr, "watchdog event");
    std::thread watchdog([finished] {
        if (WaitForSingleObject(finished, 30000) != WAIT_OBJECT_0) {
            fprintf(stderr, "FAIL: stalled %s\n", kPhaseNames[phase.load()]);
            TerminateProcess(GetCurrentProcess(), 1);
        }
    });
    fixture = native_sdk_windows_create(
        "host-loop-test", 14, "Host Loop Test", 14,
        "dev.native-sdk.host-loop-test", sizeof("dev.native-sdk.host-loop-test") - 1,
        nullptr, 0, "main", 4, 0, 0, 320, 240,
        0, 0, 0, 1, 0, 0, 0, 2, 0);
    require(fixture != nullptr, "create host");
    native_sdk_windows_set_bridge_callback(fixture, bridge, nullptr);
    native_sdk_windows_run(fixture, event, nullptr);
    require(phase.load() == kPhaseDone, "the loop finished every phase");
    native_sdk_windows_destroy(fixture);
    SetEvent(finished);
    watchdog.join();
    CloseHandle(finished);
    puts("PASS: Windows host loop model");
    return 0;
}
