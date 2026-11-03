/* Asynchronous dialogs against the production Windows host. Each phase
 * opens real dialogs on their own threads and drives them with window
 * messages only, no input injection:
 *
 *  owned       An open dialog owned by the app window: the request returns
 *              at once, the owner is disabled while it shows, app timers
 *              keep firing, and a cancel reports cancelled on a wake with
 *              the owner enabled again.
 *  early       Dialogs cancelled in the turn that requested them, before
 *              their windows exist, report cancelled.
 *  button      A task dialog's second button reports selected/secondary.
 *  save        Accepting a save dialog reports the chosen path.
 *  close       Destroying a dialog's window cancels the dialog.
 *  parentless  A dialog without a window leaves the app window enabled.
 *  teardown    Destroying the host with a dialog open returns at once, and
 *              the dialog closes on its own thread.
 *
 * Every dialog reports exactly once. A watchdog names the phase that
 * stalled. */
#include "webview2_host.cpp"

namespace {

enum Phase { kPhaseOwned, kPhaseEarly, kPhaseButton, kPhaseSave, kPhaseClose, kPhaseParentless, kPhaseTeardown, kPhaseDone };
const char *const kPhaseNames[] = {
    "owned: an owned open dialog shows, timers fire, and its cancel reports",
    "early: dialogs cancelled before they show report cancelled",
    "button: a task dialog button reports its answer",
    "save: an accepted save dialog reports its path",
    "close: a closing window cancels its dialog",
    "parentless: a dialog without a window leaves the app window enabled",
    "teardown: the host goes away with a dialog open",
    "done",
};
constexpr uint64_t kAppTimerId = 91;

std::atomic<int> phase{kPhaseOwned};
Host *fixture = nullptr;
int timer_ticks = 0;
int ticks_when_shown = -1;
bool cancel_sent = false;
std::map<uint64_t, WindowsDialogResult> results;
std::map<uint64_t, std::string> result_paths;
std::string save_name;
DWORD teardown_thread = 0;

void require(bool condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "FAIL (%s): %s\n", kPhaseNames[phase.load()], message);
    ExitProcess(1);
}

HWND appWindow(uint64_t window_id) {
    auto found = fixture->windows.find(window_id);
    return found == fixture->windows.end() ? nullptr : found->second.hwnd;
}

DWORD dialogThread(uint64_t id) {
    std::lock_guard<std::mutex> lock(fixture->dialog_queue->mutex);
    auto found = fixture->dialogs.find(id);
    return found == fixture->dialogs.end() ? 0 : found->second->thread_id;
}

BOOL CALLBACK findVisibleDialog(HWND hwnd, LPARAM lparam) {
    wchar_t class_name[8] = {};
    if (!IsWindowVisible(hwnd) || GetClassNameW(hwnd, class_name, 8) == 0 || wcscmp(class_name, L"#32770") != 0) return TRUE;
    *reinterpret_cast<HWND *>(lparam) = hwnd;
    return FALSE;
}

BOOL CALLBACK findAnyDialog(HWND hwnd, LPARAM lparam) {
    wchar_t class_name[8] = {};
    if (GetClassNameW(hwnd, class_name, 8) == 0 || wcscmp(class_name, L"#32770") != 0) return TRUE;
    *reinterpret_cast<HWND *>(lparam) = hwnd;
    return FALSE;
}

/* The dialog's window once it is on screen, else null. */
HWND shownDialog(uint64_t id) {
    const DWORD thread_id = dialogThread(id);
    if (thread_id == 0) return nullptr;
    HWND found = nullptr;
    EnumThreadWindows(thread_id, findVisibleDialog, reinterpret_cast<LPARAM>(&found));
    return found;
}

void requestOpen(uint64_t id, uint64_t parent_window_id) {
    WindowsOpenDialogOpts open = {};
    open.title = "Dialog Test";
    open.title_len = strlen(open.title);
    WindowsDialogRequest request = {};
    request.id = id;
    request.parent_window_id = parent_window_id;
    request.kind = kDialogOpen;
    request.open_opts = &open;
    require(native_sdk_windows_request_dialog(fixture, &request) == 1, "open dialog requested");
}

void requestMessage(uint64_t id, uint64_t parent_window_id) {
    WindowsMessageDialogOpts message = {};
    message.title = "Dialog Test";
    message.title_len = strlen(message.title);
    message.message = "Pick the second button";
    message.message_len = strlen(message.message);
    message.primary_button = "First";
    message.primary_button_len = strlen(message.primary_button);
    message.secondary_button = "Second";
    message.secondary_button_len = strlen(message.secondary_button);
    message.tertiary_button = "Third";
    message.tertiary_button_len = strlen(message.tertiary_button);
    WindowsDialogRequest request = {};
    request.id = id;
    request.parent_window_id = parent_window_id;
    request.kind = kDialogMessage;
    request.message_opts = &message;
    require(native_sdk_windows_request_dialog(fixture, &request) == 1, "message dialog requested");
}

void requestSave(uint64_t id) {
    wchar_t temp[MAX_PATH] = {};
    require(GetTempPathW(MAX_PATH, temp) > 0, "temp directory");
    std::string folder = narrow(std::wstring(temp));
    save_name = "native-sdk-dialog-test-" + std::to_string(GetCurrentProcessId()) + ".txt";
    WindowsSaveDialogOpts save = {};
    save.title = "Dialog Test";
    save.title_len = strlen(save.title);
    save.default_path = folder.data();
    save.default_path_len = folder.size();
    save.default_name = save_name.data();
    save.default_name_len = save_name.size();
    WindowsDialogRequest request = {};
    request.id = id;
    request.parent_window_id = 1;
    request.kind = kDialogSave;
    request.save_opts = &save;
    require(native_sdk_windows_request_dialog(fixture, &request) == 1, "save dialog requested");
}

bool finished(uint64_t id) { return results.count(id) != 0; }

void requireResult(uint64_t id, int outcome, const char *message) {
    require(finished(id), message);
    require(results[id].outcome == outcome, message);
}

/* One step of the current phase, every 20 ms. */
void CALLBACK advance(HWND, UINT, UINT_PTR, DWORD) {
    switch (phase.load()) {
        case kPhaseOwned: {
            if (finished(1)) {
                requireResult(1, kDialogCancelled, "the cancelled dialog reports cancelled");
                require(IsWindowEnabled(appWindow(1)), "the owner is enabled again once the dialog is gone");
                phase.store(kPhaseEarly);
                requestMessage(2, 1);
                native_sdk_windows_cancel_dialog(fixture, 2);
                requestOpen(3, 0);
                native_sdk_windows_cancel_dialog(fixture, 3);
                return;
            }
            if (cancel_sent || !shownDialog(1)) return;
            if (ticks_when_shown < 0) {
                ticks_when_shown = timer_ticks;
                require(!IsWindowEnabled(appWindow(1)), "the owner is disabled while its dialog shows");
                return;
            }
            if (timer_ticks < ticks_when_shown + 3) return;
            cancel_sent = true;
            native_sdk_windows_cancel_dialog(fixture, 1);
            return;
        }
        case kPhaseEarly:
            if (!finished(2) || !finished(3)) return;
            requireResult(2, kDialogCancelled, "a message dialog cancelled before it showed reports cancelled");
            requireResult(3, kDialogCancelled, "an open dialog cancelled before it showed reports cancelled");
            phase.store(kPhaseButton);
            requestMessage(4, 1);
            return;
        case kPhaseButton: {
            if (finished(4)) {
                requireResult(4, kDialogSelected, "a pressed button reports selected");
                require(results[4].button == 1, "the second button");
                phase.store(kPhaseSave);
                requestSave(5);
                return;
            }
            HWND dialog = shownDialog(4);
            if (dialog) PostMessageW(dialog, TDM_CLICK_BUTTON, 101, 0);
            return;
        }
        case kPhaseSave: {
            if (finished(5)) {
                requireResult(5, kDialogSelected, "an accepted save dialog reports selected");
                require(results[5].count == 1, "one path");
                const std::string &path = result_paths[5];
                require(path.size() > save_name.size() && path.compare(path.size() - save_name.size(), save_name.size(), save_name) == 0, "the default name was chosen");
                phase.store(kPhaseClose);
                require(native_sdk_windows_create_window(fixture, 2, "Second", 6, "second", 6, 0, 0, 200, 150, 0, 0, 0, 1, 0, 0, 0, 2, 0) == 1, "second window");
                requestOpen(6, 2);
                return;
            }
            HWND dialog = shownDialog(5);
            if (dialog) PostMessageW(dialog, WM_COMMAND, IDOK, 0);
            return;
        }
        case kPhaseClose: {
            if (finished(6)) {
                requireResult(6, kDialogCancelled, "a closed window's dialog reports cancelled");
                phase.store(kPhaseParentless);
                cancel_sent = false;
                requestOpen(7, 0);
                return;
            }
            HWND second = appWindow(2);
            if (second && shownDialog(6)) DestroyWindow(second);
            return;
        }
        case kPhaseParentless:
            if (finished(7)) {
                requireResult(7, kDialogCancelled, "the parentless dialog reports cancelled");
                phase.store(kPhaseTeardown);
                requestOpen(8, 1);
                return;
            }
            if (cancel_sent || !shownDialog(7)) return;
            require(IsWindowEnabled(appWindow(1)), "a parentless dialog leaves the app window enabled");
            cancel_sent = true;
            native_sdk_windows_cancel_dialog(fixture, 7);
            return;
        case kPhaseTeardown:
            if (teardown_thread != 0 || !shownDialog(8)) return;
            teardown_thread = dialogThread(8);
            native_sdk_windows_stop(fixture);
            return;
        default:
            return;
    }
}

void event(void *, const WindowsEvent *incoming) {
    switch (incoming->kind) {
        case kStart:
            KillTimer(appWindow(1), kFrameTimerId);
            native_sdk_windows_start_timer(fixture, kAppTimerId, 50ull * 1000000ull, 1);
            require(SetTimer(nullptr, 0, 20, advance) != 0, "phase timer");
            requestOpen(1, 1);
            break;
        case kTimer:
            if (incoming->timer_id == kAppTimerId) timer_ticks += 1;
            break;
        case kWake: {
            char buffer[4096];
            WindowsDialogResult result = {};
            while (native_sdk_windows_poll_dialog_result(fixture, buffer, sizeof(buffer), &result) == 1) {
                require(results.count(result.id) == 0, "each dialog reports once");
                results[result.id] = result;
                result_paths[result.id] = std::string(buffer, result.bytes_written);
            }
            break;
        }
        default:
            break;
    }
}

} // namespace

int main() {
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    require(done != nullptr, "watchdog event");
    std::thread watchdog([done] {
        if (WaitForSingleObject(done, 60000) != WAIT_OBJECT_0) {
            fprintf(stderr, "FAIL: stalled in %s\n", kPhaseNames[phase.load()]);
            TerminateProcess(GetCurrentProcess(), 1);
        }
    });
    fixture = native_sdk_windows_create(
        "dialog-test", 11, "Dialog Test", 11,
        "dev.native-sdk.dialog-test", sizeof("dev.native-sdk.dialog-test") - 1,
        nullptr, 0, "main", 4, 0, 0, 320, 240,
        0, 0, 0, 1, 0, 0, 0, 2, 0);
    require(fixture != nullptr, "create host");
    native_sdk_windows_run(fixture, event, nullptr);
    require(phase.load() == kPhaseTeardown && teardown_thread != 0, "the loop reached teardown with a dialog open");

    const ULONGLONG destroy_started = GetTickCount64();
    native_sdk_windows_destroy(fixture);
    require(GetTickCount64() - destroy_started < 1000, "destroying the host does not wait for its dialogs");
    HWND left = nullptr;
    for (int attempt = 0; attempt < 250; ++attempt) {
        left = nullptr;
        EnumThreadWindows(teardown_thread, findAnyDialog, reinterpret_cast<LPARAM>(&left));
        if (!left) break;
        Sleep(20);
    }
    require(left == nullptr, "the open dialog closed after the host went away");
    phase.store(kPhaseDone);

    SetEvent(done);
    watchdog.join();
    CloseHandle(done);
    puts("PASS: Windows asynchronous dialogs");
    return 0;
}
