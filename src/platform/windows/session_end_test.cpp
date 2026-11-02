/* Session end against the production Windows host, across processes:
 * the test runs itself again as the app (--child <scenario>) and plays
 * the sender, the way logoff and Restart Manager reach a GUI process:
 * WM_QUERYENDSESSION, then WM_ENDSESSION, sent to its top-level window.
 * The app's only window is hidden, like one behind a tray icon.
 *
 *  flat    No app dispatch is running. A cancelled end (wParam FALSE)
 *          changes nothing; a confirmed one delivers one shutdown and
 *          ends the process inside the message.
 *  nested  The app is inside a dispatch, in a modal dialog. The dialog
 *          is cancelled and reports no answer instead of a button,
 *          later dialogs are refused, no event follows the shutdown, a
 *          follow-up WM_CLOSE (Restart Manager sends one) is ignored,
 *          and the loop returns into the regular teardown.
 *  quit    No session end: the app quits on its own, through the loop's
 *          exit, which shares the exactly-once shutdown.
 *
 * In every scenario the stop hook raises an event of its own while it
 * runs, and no event may reach the app after its shutdown. The app
 * prints one line per observation and the sender checks them. A
 * watchdog bounds every wait. */
#include "webview2_host.cpp"

#include <cstdarg>
#include <cstring>

namespace {

void say(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vprintf(format, args);
    va_end(args);
    putchar('\n');
    fflush(stdout);
}

/* ------------------------------------------------------------ the app */

Host *app = nullptr;
bool nested = false;
bool quitting = false;
bool shut_down = false;

void appEvent(void *, const WindowsEvent *incoming) {
    if (shut_down) {
        say("FAIL event %d reached the app after its shutdown", static_cast<int>(incoming->kind));
        return;
    }
    switch (incoming->kind) {
        case kStart: {
            auto window = app->windows.find(1);
            say("ready %llu", static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(window->second.hwnd)));
            if (quitting) native_sdk_windows_stop(app);
            if (!nested) break;
            /* A confirmation whose primary button is the destructive
             * one: cancelling it must not read as that button. */
            WindowsMessageDialogOpts confirm = {};
            confirm.title = "Session End Test";
            confirm.title_len = strlen(confirm.title);
            confirm.message = "Delete everything?";
            confirm.message_len = strlen(confirm.message);
            confirm.primary_button = "Delete";
            confirm.primary_button_len = strlen(confirm.primary_button);
            confirm.secondary_button = "Keep";
            confirm.secondary_button_len = strlen(confirm.secondary_button);
            say("dialog %d", native_sdk_windows_show_message_dialog(app, &confirm));
            say("second dialog %d", native_sdk_windows_show_message_dialog(app, &confirm));
            char path[MAX_PATH] = {};
            WindowsOpenDialogOpts open = {};
            say("open dialog %zu", native_sdk_windows_show_open_dialog(app, &open, path, sizeof(path)).count);
            break;
        }
        case kShutdown:
            shut_down = true;
            say("shutdown");
            /* Work in the stop hook can raise an event (here a wake the
             * loop window takes synchronously); it must not reach the
             * app, whose shutdown already ran. */
            SendMessageW(app->loop_window.load(), kWakeMessage, 0, 0);
            break;
        default:
            break;
    }
}

int runApp(const char *scenario) {
    nested = strcmp(scenario, "nested") == 0;
    quitting = strcmp(scenario, "quit") == 0;
    app = native_sdk_windows_create(
        "session-end-test", 16, "Session End Test", 16,
        "dev.native-sdk.session-end-test", sizeof("dev.native-sdk.session-end-test") - 1,
        nullptr, 0, "main", 4, 0, 0, 320, 240,
        0, 0, 0, 1, 0, 0, 0, 2, 0);
    if (!app) {
        say("FAIL create host");
        return 1;
    }
    native_sdk_windows_run(app, appEvent, nullptr);
    say("run returned");
    native_sdk_windows_destroy(app);
    return 0;
}

/* --------------------------------------------------------- the sender */

const char *stage = "starting";
HANDLE child_process = nullptr;

void require(bool condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "FAIL (%s): %s\n", stage, message);
    if (child_process) TerminateProcess(child_process, 1);
    ExitProcess(1);
}

struct Child {
    PROCESS_INFORMATION process = {};
    HANDLE output = nullptr;
    std::string lines;
};

Child spawn(const char *scenario) {
    SECURITY_ATTRIBUTES inherit = { sizeof(inherit), nullptr, TRUE };
    HANDLE read_end = nullptr;
    HANDLE write_end = nullptr;
    require(CreatePipe(&read_end, &write_end, &inherit, 0) != 0, "output pipe");
    SetHandleInformation(read_end, HANDLE_FLAG_INHERIT, 0);
    wchar_t exe[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring command = L"\"" + std::wstring(exe) + L"\" --child " + widen(scenario);
    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdOutput = write_end;
    startup.hStdError = write_end;
    Child child;
    require(CreateProcessW(exe, command.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child.process) != 0, "start the app");
    CloseHandle(write_end);
    child.output = read_end;
    child_process = child.process.hProcess;
    return child;
}

/* The app's stdout is in text mode, so lines arrive ending in CRLF. */
void appendOutput(Child &child, const char *bytes, DWORD count) {
    for (DWORD index = 0; index < count; ++index) {
        if (bytes[index] != '\r') child.lines.push_back(bytes[index]);
    }
}

/* Reads until a line starting with `prefix` arrives; returns its rest. */
std::string waitForLine(Child &child, const char *prefix) {
    const std::string wanted = std::string("\n") + prefix;
    for (;;) {
        const std::string text = "\n" + child.lines;
        const size_t at = text.find(wanted);
        if (at != std::string::npos) {
            const size_t end = text.find('\n', at + 1);
            if (end != std::string::npos) return text.substr(at + wanted.size(), end - at - wanted.size());
        }
        char buffer[512];
        DWORD read = 0;
        require(ReadFile(child.output, buffer, sizeof(buffer), &read, nullptr) && read > 0, "the app's output ended early");
        appendOutput(child, buffer, read);
    }
}

/* Waits for the app to exit and collects the rest of its output. */
DWORD finish(Child &child, DWORD timeout_ms) {
    require(WaitForSingleObject(child.process.hProcess, timeout_ms) == WAIT_OBJECT_0, "the app exited");
    char buffer[512];
    DWORD read = 0;
    while (ReadFile(child.output, buffer, sizeof(buffer), &read, nullptr) && read > 0) appendOutput(child, buffer, read);
    DWORD code = 1;
    GetExitCodeProcess(child.process.hProcess, &code);
    CloseHandle(child.output);
    CloseHandle(child.process.hThread);
    CloseHandle(child.process.hProcess);
    child_process = nullptr;
    return code;
}

size_t countLines(const Child &child, const char *line) {
    const std::string text = "\n" + child.lines;
    const std::string wanted = std::string("\n") + line + "\n";
    size_t count = 0;
    for (size_t at = text.find(wanted); at != std::string::npos; at = text.find(wanted, at + 1)) count += 1;
    return count;
}

void requireLine(const Child &child, const char *line) {
    if (countLines(child, line) == 1) return;
    fprintf(stderr, "app output:\n%s\n", child.lines.c_str());
    require(false, line);
}

void requireClean(const Child &child) {
    if (child.lines.find("FAIL") == std::string::npos) return;
    fprintf(stderr, "app output:\n%s\n", child.lines.c_str());
    require(false, "the app reported a failure");
}

LRESULT sendToApp(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    DWORD_PTR answer = 0;
    SendMessageTimeoutW(hwnd, message, wparam, lparam, SMTO_ABORTIFHUNG, 10000, &answer);
    return static_cast<LRESULT>(answer);
}

HWND appWindow(Child &child) {
    const std::string handle = waitForLine(child, "ready ");
    HWND hwnd = reinterpret_cast<HWND>(static_cast<uintptr_t>(std::stoull(handle)));
    require(IsWindow(hwnd) && !IsWindowVisible(hwnd), "the app's window exists, hidden");
    return hwnd;
}

void runFlat() {
    stage = "flat";
    Child child = spawn("flat");
    HWND hwnd = appWindow(child);
    require(sendToApp(hwnd, WM_QUERYENDSESSION, 0, ENDSESSION_LOGOFF) == TRUE, "the query is answered yes");
    sendToApp(hwnd, WM_ENDSESSION, FALSE, ENDSESSION_LOGOFF);
    require(WaitForSingleObject(child.process.hProcess, 300) == WAIT_TIMEOUT, "a cancelled session end leaves the app running");
    require(sendToApp(hwnd, WM_QUERYENDSESSION, 0, ENDSESSION_LOGOFF) == TRUE, "the query is answered yes");
    sendToApp(hwnd, WM_ENDSESSION, TRUE, ENDSESSION_LOGOFF);
    require(finish(child, 2000) == 0, "the app ended with exit code 0");
    requireClean(child);
    requireLine(child, "shutdown");
    require(countLines(child, "run returned") == 0, "the process ended inside WM_ENDSESSION, not through the loop");
}

struct DialogSearch {
    DWORD process_id;
    HWND found;
};

BOOL CALLBACK findDialog(HWND hwnd, LPARAM lparam) {
    auto *search = reinterpret_cast<DialogSearch *>(lparam);
    DWORD process_id = 0;
    GetWindowThreadProcessId(hwnd, &process_id);
    wchar_t class_name[16] = {};
    GetClassNameW(hwnd, class_name, 16);
    if (process_id != search->process_id || !IsWindowVisible(hwnd) || wcscmp(class_name, L"#32770") != 0) return TRUE;
    search->found = hwnd;
    return FALSE;
}

void runNested() {
    stage = "nested";
    Child child = spawn("nested");
    HWND hwnd = appWindow(child);
    DialogSearch search = { child.process.dwProcessId, nullptr };
    for (int attempt = 0; attempt < 200 && !search.found; ++attempt) {
        Sleep(50);
        EnumWindows(findDialog, reinterpret_cast<LPARAM>(&search));
    }
    require(search.found != nullptr, "the app's dialog is open");
    require(sendToApp(hwnd, WM_QUERYENDSESSION, 0, ENDSESSION_CLOSEAPP) == TRUE, "the query is answered yes");
    sendToApp(hwnd, WM_ENDSESSION, TRUE, ENDSESSION_CLOSEAPP);
    sendToApp(hwnd, WM_CLOSE, 0, 0);
    require(finish(child, 10000) == 0, "the app exited with exit code 0");
    requireClean(child);
    requireLine(child, "shutdown");
    requireLine(child, "dialog -1");
    requireLine(child, "second dialog -1");
    requireLine(child, "open dialog 0");
    requireLine(child, "run returned");
}

void runQuit() {
    stage = "quit";
    Child child = spawn("quit");
    appWindow(child);
    require(finish(child, 10000) == 0, "the app exited with exit code 0");
    requireClean(child);
    requireLine(child, "shutdown");
    requireLine(child, "run returned");
}

} // namespace

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--child") == 0) {
        setvbuf(stdout, nullptr, _IONBF, 0);
        return runApp(argv[2]);
    }
    HANDLE finished = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    require(finished != nullptr, "watchdog event");
    std::thread watchdog([finished] {
        if (WaitForSingleObject(finished, 60000) == WAIT_OBJECT_0) return;
        fprintf(stderr, "FAIL: stalled in %s\n", stage);
        if (child_process) TerminateProcess(child_process, 1);
        TerminateProcess(GetCurrentProcess(), 1);
    });
    runFlat();
    runNested();
    runQuit();
    SetEvent(finished);
    watchdog.join();
    CloseHandle(finished);
    puts("PASS: Windows session end");
    return 0;
}
