/* Compile the production host and exercise its real WebMessageReceived path.
 * A command may join a worker that posts a wake before it exits. */
#include "webview2_host.cpp"

static std::atomic<bool> command_entered{false};
static bool command_completed = false;
static bool wake_received = false;
static bool frame_received = false;

static void require(bool condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message);
    ExitProcess(1);
}

static void bridge(void *context, uint64_t window_id,
                   const char *label, size_t label_len,
                   const char *message, size_t message_len,
                   const char *origin, size_t origin_len) {
    Host *host = static_cast<Host *>(context);
    require(window_id == 1, "window identity");
    require(std::string(label, label_len) == "main", "view identity");
    require(std::string(message, message_len) == "join-worker", "message");
    require(std::string(origin, origin_len) == "zero://inline", "origin");
    command_entered.store(true);
    std::thread worker([host] {
        native_sdk_windows_wake(host);
        native_sdk_windows_request_frame(host);
    });
    worker.join();
    command_completed = true;
}

static Host *fixture_host = nullptr;
static void CALLBACK postCommand(HWND hwnd, UINT, UINT_PTR timer, DWORD) {
    auto found = fixture_host->webviews.find(webViewKey(1, "main"));
    if (found == fixture_host->webviews.end() || !found->second.webview) return;
    KillTimer(hwnd, timer);
    require(SUCCEEDED(found->second.webview->ExecuteScript(
        L"chrome.webview.postMessage('join-worker')", nullptr)), "post command");
}
static void event(void *context, const WindowsEvent *incoming) {
    Host *host = static_cast<Host *>(context);
    if (incoming->kind == kStart) {
        const char html[] = "<!doctype html><title>Bridge Wake Test</title>";
        require(native_sdk_windows_load_window_webview(
            host, 1, html, sizeof(html) - 1, 0,
            nullptr, 0, nullptr, 0, nullptr, 0, 0) == 1, "load WebView");
        require(SetTimer(parentWindow(host), 0, 100, postCommand) != 0, "command timer");
    } else if (incoming->kind == kWake) {
        require(command_completed, "wake must be delivered after command returns");
        wake_received = true;
    } else if (incoming->kind == kFrame && command_completed) {
        frame_received = true;
    }
    if (wake_received && frame_received) native_sdk_windows_stop(host);
}

int main() {
    HANDLE finished = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    require(finished != nullptr, "watchdog event");
    std::thread watchdog([finished] {
        if (WaitForSingleObject(finished, 15000) != WAIT_OBJECT_0) {
            fprintf(stderr, "FAIL: %s\n", command_entered.load() ? "Bridge callback blocked worker wake/join" : "WebView never delivered the Bridge command");
            TerminateProcess(GetCurrentProcess(), 1);
        }
    });
    Host *host = native_sdk_windows_create(
        "bridge-wake-test", 16, "Bridge Wake Test", 16,
        "dev.native-sdk.bridge-wake-test", sizeof("dev.native-sdk.bridge-wake-test") - 1,
        nullptr, 0, "main", 4, 0, 0, 320, 240,
        0, 0, 0, 1, 0, 0, 0, 2, 0);
    require(host != nullptr, "create host");
    native_sdk_windows_set_bridge_callback(host, bridge, host);
    fixture_host = host;
    native_sdk_windows_run(host, event, host);
    require(command_completed && wake_received && frame_received,
            "command, wake and frame completed");
    native_sdk_windows_destroy(host);
    SetEvent(finished);
    watchdog.join();
    CloseHandle(finished);
    puts("PASS: real WebView Bridge command joins worker wake and frame");
    return 0;
}
