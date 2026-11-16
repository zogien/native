/* Toast activation in the production host, with no toast and no click:
 *
 *  1. parseArguments accepts exactly the arguments the host writes into a
 *     toast ("native-sdk-notification:<body|action>:<lowercase hex>",
 *     where the token may be empty) and rejects every other shape.
 *  2. A click handed to the COM activator reaches the loop window as one
 *     posted Activation carrying the parsed kind and token. Arguments that
 *     are not ours post nothing.
 *  3. A wide-string compare against a literal that sits 2 bytes off
 *     8-byte alignment. The parser's own literals sit wherever the linker
 *     puts them. Under the MSVC ABI this compare goes through the UCRT's
 *     inline wmemcmp, which loads an unaligned 8-byte word (see
 *     ubsan_vendor_ignorelist.txt). Built for MSVC in Debug
 *     (test-windows-msvc-host), the harness therefore fails whenever a host
 *     compile loses the vendor exemption, wherever the linker happens to
 *     place the parser's literals. */
#include "webview2_host.cpp"

#include <cstdio>
#include <string>
#include <vector>

namespace {

constexpr UINT kActivationMessage = WM_APP + 41;

void require(bool condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message);
    ExitProcess(1);
}

bool parses(const wchar_t *arguments, int kind, const char *token) {
    native_sdk_toast::Activation parsed;
    return native_sdk_toast::parseArguments(arguments, &parsed) && parsed.kind == kind && parsed.token == token;
}

bool rejects(const wchar_t *arguments) {
    native_sdk_toast::Activation parsed;
    return !native_sdk_toast::parseArguments(arguments, &parsed);
}

/* The activations the relay posted to `window`, in order; each payload is
 * freed the way the host's loop window frees it. */
std::vector<native_sdk_toast::Activation> takePosted(HWND window) {
    std::vector<native_sdk_toast::Activation> posted;
    MSG message;
    while (PeekMessageW(&message, window, kActivationMessage, kActivationMessage, PM_REMOVE)) {
        auto *payload = reinterpret_cast<native_sdk_toast::Activation *>(message.lParam);
        posted.push_back(*payload);
        delete payload;
    }
    return posted;
}

alignas(8) const wchar_t kShiftedBody[] = L"xbody:";

} // namespace

int main() {
    require(parses(L"native-sdk-notification:body:0123abcd", 0, "0123abcd"), "body click");
    require(parses(L"native-sdk-notification:action:ff00", 1, "ff00"), "action button");
    require(parses(L"native-sdk-notification:body:", 0, ""), "display-only body click");
    require(rejects(L"native-sdk-notification:body:0123ABCD"), "uppercase token");
    require(rejects(L"native-sdk-notification:body:12 34"), "token with a space");
    require(rejects(L"native-sdk-notification:close:00"), "unknown kind");
    require(rejects(L"native-sdk-notification:"), "prefix only");
    require(rejects(L"other-app:body:00"), "foreign prefix");
    require(rejects(L""), "empty arguments");

    HWND window = CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
    require(window != nullptr, "message-only window");
    auto *relay = new native_sdk_toast::Relay(kActivationMessage);
    relay->attach(window);
    auto *activator = new native_sdk_toast::Activator(relay);
    require(SUCCEEDED(activator->Activate(L"dev.native-sdk.toast-test", L"native-sdk-notification:action:00ff", nullptr, 0)), "activator accepts our click");
    require(SUCCEEDED(activator->Activate(L"dev.native-sdk.toast-test", L"someone-else", nullptr, 0)), "activator accepts a foreign click");
    const std::vector<native_sdk_toast::Activation> posted = takePosted(window);
    require(posted.size() == 1, "one activation posted");
    require(posted[0].kind == 1 && posted[0].token == "00ff", "posted activation carries the parsed kind and token");
    relay->detach();
    activator->Release();
    relay->release();
    DestroyWindow(window);

    const std::wstring rest = L"body:0123";
    require(rest.compare(0, 5, kShiftedBody + 1, 5) == 0, "compare against a literal off 8-byte alignment");

    puts("PASS: Windows toast activation");
    return 0;
}
