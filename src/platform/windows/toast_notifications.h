/* Windows toast notifications for the WebView2/CEF host.
 *
 * Toasts are WinRT (Windows.UI.Notifications). The host reaches them
 * without C++/WinRT or the Windows SDK's WinRT headers, because the
 * mingw headers Zig ships for the default gnu ABI have neither: the few
 * interfaces used here are declared by hand, with IIDs and vtable order
 * taken from the Windows SDK 10.0.26100 headers, and combase's WinRT
 * entry points are resolved at runtime. Everything lives in its own
 * namespace so an MSVC build that also sees the SDK headers does not
 * collide with them.
 *
 * Identity: an unpackaged app has no package identity, so the toast
 * notifier is created with the process's AppUserModelID (the host sets it
 * from the bundle id) and that id is registered per user under
 * HKCU\Software\Classes\AppUserModelId\<id> with a display name, an icon
 * and the CLSID of this process's activator. That is how the Windows App
 * SDK registers unpackaged apps; no Start-menu shortcut is needed.
 *
 * Activation: a click reaches the process through the toast's Activated
 * event (raised on a pool thread while the toast object lives here) and
 * through the registered INotificationActivationCallback class object
 * (called on the loop thread). One click can arrive through both:
 * measured on Windows 10 19045, a click in Action Center reached the
 * activator and then the Activated event 4 ms later. Both forward the
 * activation arguments to the loop window. A toast carries only an opaque
 * token (see notification_records.zig), so whichever delivery comes first
 * consumes the binding and the duplicate dispatches nothing. A toast left
 * by an earlier run reaches the current run's activator, whose binding
 * table does not know its token. With no process running, nothing is
 * registered and a click does nothing. */
#pragma once

#include <windows.h>
#include <objbase.h>

#include <atomic>
#include <cstdint>
#include <cwchar>
#include <deque>
#include <string>

namespace native_sdk_toast {

typedef struct HStringOpaque *HString;
struct EventToken {
    int64_t value;
};

struct Inspectable : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE GetIids(ULONG *count, IID **iids) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetRuntimeClassName(HString *name) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetTrustLevel(int *level) = 0;
};

/* Windows.Data.Xml.Dom */
struct XmlDocument : Inspectable {};
struct XmlDocumentIO : Inspectable {
    virtual HRESULT STDMETHODCALLTYPE LoadXml(HString xml) = 0;
};

/* Windows.UI.Notifications */
struct ToastNotification;
struct ToastNotifier : Inspectable {
    virtual HRESULT STDMETHODCALLTYPE Show(ToastNotification *notification) = 0;
    virtual HRESULT STDMETHODCALLTYPE Hide(ToastNotification *notification) = 0;
};
struct ToastNotificationManagerStatics : Inspectable {
    virtual HRESULT STDMETHODCALLTYPE CreateToastNotifier(ToastNotifier **notifier) = 0;
    virtual HRESULT STDMETHODCALLTYPE CreateToastNotifierWithId(HString app_id, ToastNotifier **notifier) = 0;
};
struct ToastNotificationFactory : Inspectable {
    virtual HRESULT STDMETHODCALLTYPE CreateToastNotification(XmlDocument *content, ToastNotification **notification) = 0;
};
/* TypedEventHandler<ToastNotification, IInspectable> */
struct ActivatedEventHandler : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE Invoke(ToastNotification *sender, Inspectable *args) = 0;
};
struct ToastNotification : Inspectable {
    virtual HRESULT STDMETHODCALLTYPE get_Content(XmlDocument **content) = 0;
    virtual HRESULT STDMETHODCALLTYPE put_ExpirationTime(IUnknown *value) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_ExpirationTime(IUnknown **value) = 0;
    virtual HRESULT STDMETHODCALLTYPE add_Dismissed(IUnknown *handler, EventToken *token) = 0;
    virtual HRESULT STDMETHODCALLTYPE remove_Dismissed(EventToken token) = 0;
    virtual HRESULT STDMETHODCALLTYPE add_Activated(ActivatedEventHandler *handler, EventToken *token) = 0;
    virtual HRESULT STDMETHODCALLTYPE remove_Activated(EventToken token) = 0;
};
struct ToastNotification2 : Inspectable {
    virtual HRESULT STDMETHODCALLTYPE put_Tag(HString value) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_Tag(HString *value) = 0;
    virtual HRESULT STDMETHODCALLTYPE put_Group(HString value) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_Group(HString *value) = 0;
};
struct ToastActivatedEventArgs : Inspectable {
    virtual HRESULT STDMETHODCALLTYPE get_Arguments(HString *arguments) = 0;
};

/* notificationactivationcallback.h */
struct UserInputData {
    LPCWSTR key;
    LPCWSTR value;
};
struct NotificationActivationCallback : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE Activate(LPCWSTR app_user_model_id, LPCWSTR invoked_args, const UserInputData *data, ULONG count) = 0;
};

static const IID kIID_XmlDocument = {0xf7f3a506, 0x1e87, 0x42d6, {0xbc, 0xfb, 0xb8, 0xc8, 0x09, 0xfa, 0x54, 0x94}};
static const IID kIID_XmlDocumentIO = {0x6cd0e74e, 0xee65, 0x4489, {0x9e, 0xbf, 0xca, 0x43, 0xe8, 0x7b, 0xa6, 0x37}};
static const IID kIID_ToastNotificationManagerStatics = {0x50ac103f, 0xd235, 0x4598, {0xbb, 0xef, 0x98, 0xfe, 0x4d, 0x1a, 0x3a, 0xd4}};
static const IID kIID_ToastNotificationFactory = {0x04124b20, 0x82c6, 0x4229, {0xb1, 0x09, 0xfd, 0x9e, 0xd4, 0x66, 0x2b, 0x53}};
static const IID kIID_ToastNotification2 = {0x9dfb9fd1, 0x143a, 0x490e, {0x90, 0xbf, 0xb9, 0xfb, 0xa7, 0x13, 0x2d, 0xe7}};
static const IID kIID_ToastActivatedEventArgs = {0xe3bf92f3, 0xc197, 0x436f, {0x82, 0x65, 0x06, 0x25, 0x82, 0x4f, 0x8d, 0xac}};
static const IID kIID_ActivatedEventHandler = {0xab54de2d, 0x97d9, 0x5528, {0xb6, 0xad, 0x10, 0x5a, 0xfe, 0x15, 0x65, 0x30}};
static const IID kIID_NotificationActivationCallback = {0x53e31837, 0x6600, 0x4a81, {0x93, 0x95, 0x75, 0xcf, 0xfe, 0x74, 0x6f, 0x94}};
/* IAgileObject: the WinRT event fires on a pool thread; an agile handler
 * is invoked there directly instead of being marshalled to the STA. */
static const IID kIID_AgileObject = {0x94ea2b94, 0xe9cc, 0x49e0, {0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90}};

/* Activation arguments every toast carries. */
static const wchar_t kArgumentPrefix[] = L"native-sdk-notification:";
static const wchar_t kGroup[] = L"native-sdk";
/* A toast list larger than notification_records' bound buys nothing:
 * past it, a click finds no binding anyway. */
static const size_t kMaxLiveToasts = 64;

struct Api {
    using RoGetActivationFactoryFn = HRESULT(WINAPI *)(HString, REFIID, void **);
    using RoActivateInstanceFn = HRESULT(WINAPI *)(HString, Inspectable **);
    using WindowsCreateStringFn = HRESULT(WINAPI *)(const wchar_t *, UINT32, HString *);
    using WindowsDeleteStringFn = HRESULT(WINAPI *)(HString);
    using WindowsGetStringRawBufferFn = const wchar_t *(WINAPI *)(HString, UINT32 *);
    using RegCreateKeyExWFn = LSTATUS(WINAPI *)(HKEY, LPCWSTR, DWORD, LPWSTR, DWORD, REGSAM, const SECURITY_ATTRIBUTES *, PHKEY, LPDWORD);
    using RegSetValueExWFn = LSTATUS(WINAPI *)(HKEY, LPCWSTR, DWORD, DWORD, const BYTE *, DWORD);
    using RegCloseKeyFn = LSTATUS(WINAPI *)(HKEY);

    RoGetActivationFactoryFn get_activation_factory = nullptr;
    RoActivateInstanceFn activate_instance = nullptr;
    WindowsCreateStringFn create_string = nullptr;
    WindowsDeleteStringFn delete_string = nullptr;
    WindowsGetStringRawBufferFn string_buffer = nullptr;
    RegCreateKeyExWFn reg_create_key = nullptr;
    RegSetValueExWFn reg_set_value = nullptr;
    RegCloseKeyFn reg_close_key = nullptr;
    bool ready = false;

    /* Resolved once per process; the modules stay loaded. */
    static const Api &get() {
        static const Api api = [] {
            Api loaded;
            HMODULE combase = LoadLibraryW(L"combase.dll");
            HMODULE advapi = LoadLibraryW(L"advapi32.dll");
            if (!combase || !advapi) return loaded;
            loaded.get_activation_factory = reinterpret_cast<RoGetActivationFactoryFn>(reinterpret_cast<void *>(GetProcAddress(combase, "RoGetActivationFactory")));
            loaded.activate_instance = reinterpret_cast<RoActivateInstanceFn>(reinterpret_cast<void *>(GetProcAddress(combase, "RoActivateInstance")));
            loaded.create_string = reinterpret_cast<WindowsCreateStringFn>(reinterpret_cast<void *>(GetProcAddress(combase, "WindowsCreateString")));
            loaded.delete_string = reinterpret_cast<WindowsDeleteStringFn>(reinterpret_cast<void *>(GetProcAddress(combase, "WindowsDeleteString")));
            loaded.string_buffer = reinterpret_cast<WindowsGetStringRawBufferFn>(reinterpret_cast<void *>(GetProcAddress(combase, "WindowsGetStringRawBuffer")));
            loaded.reg_create_key = reinterpret_cast<RegCreateKeyExWFn>(reinterpret_cast<void *>(GetProcAddress(advapi, "RegCreateKeyExW")));
            loaded.reg_set_value = reinterpret_cast<RegSetValueExWFn>(reinterpret_cast<void *>(GetProcAddress(advapi, "RegSetValueExW")));
            loaded.reg_close_key = reinterpret_cast<RegCloseKeyFn>(reinterpret_cast<void *>(GetProcAddress(advapi, "RegCloseKey")));
            loaded.ready = loaded.get_activation_factory && loaded.activate_instance && loaded.create_string &&
                loaded.delete_string && loaded.string_buffer && loaded.reg_create_key && loaded.reg_set_value && loaded.reg_close_key;
            return loaded;
        }();
        return api;
    }
};

class Str {
public:
    explicit Str(const std::wstring &value) {
        const Api &api = Api::get();
        if (api.ready && FAILED(api.create_string(value.c_str(), static_cast<UINT32>(value.size()), &handle_))) handle_ = nullptr;
    }
    ~Str() {
        if (handle_) Api::get().delete_string(handle_);
    }
    Str(const Str &) = delete;
    Str &operator=(const Str &) = delete;
    HString get() const { return handle_; }

private:
    HString handle_ = nullptr;
};

template <typename T>
static void release(T *&object) {
    if (object) object->Release();
    object = nullptr;
}

static std::wstring xmlEscape(const std::wstring &value) {
    std::wstring out;
    out.reserve(value.size());
    for (wchar_t ch : value) {
        switch (ch) {
            case L'&': out += L"&amp;"; break;
            case L'<': out += L"&lt;"; break;
            case L'>': out += L"&gt;"; break;
            case L'"': out += L"&quot;"; break;
            case L'\'': out += L"&apos;"; break;
            default:
                /* XML 1.0 forbids most C0 controls; drop them rather than
                 * fail the whole toast. */
                if (ch < 0x20 && ch != L'\t' && ch != L'\n' && ch != L'\r') break;
                out += ch;
        }
    }
    return out;
}

static uint64_t fnv1a(const std::string &bytes, uint64_t seed) {
    uint64_t hash = seed;
    for (unsigned char byte : bytes) {
        hash ^= byte;
        hash *= 0x100000001b3ull;
    }
    return hash;
}

/* A toast Tag is limited to 64 UTF-16 units and app ids may be 128 bytes,
 * so the tag is a fixed-width digest of the id. */
static std::wstring tagForId(const std::string &id) {
    wchar_t buffer[17];
    swprintf(buffer, 17, L"%016llx", static_cast<unsigned long long>(fnv1a(id, 0xcbf29ce484222325ull)));
    return buffer;
}

/* The activator CLSID is derived from the AppUserModelID, so every run of
 * an app registers the same class and the registry value stays stable. */
static CLSID activatorClsid(const std::string &app_user_model_id) {
    const std::string name = "native-sdk-toast-activator:" + app_user_model_id;
    const uint64_t high = fnv1a(name, 0xcbf29ce484222325ull);
    const uint64_t low = fnv1a(name, 0x84222325cbf29ce4ull);
    CLSID clsid = {};
    clsid.Data1 = static_cast<unsigned long>(high >> 32);
    clsid.Data2 = static_cast<unsigned short>(high >> 16);
    clsid.Data3 = static_cast<unsigned short>((high & 0x0fff) | 0x4000);
    for (int index = 0; index < 8; ++index) clsid.Data4[index] = static_cast<unsigned char>(low >> (56 - index * 8));
    clsid.Data4[0] = static_cast<unsigned char>((clsid.Data4[0] & 0x3f) | 0x80);
    return clsid;
}

/* What a click reports to the loop window. kind: 0 body, 1 action button
 * (notification_records.Activation). */
struct Activation {
    int kind = 0;
    std::string token;
};

/* Parses "native-sdk-notification:<body|action>:<token>". Arguments that
 * do not carry this prefix are not ours and report nothing. */
static bool parseArguments(const std::wstring &arguments, Activation *out) {
    const std::wstring prefix = kArgumentPrefix;
    if (arguments.compare(0, prefix.size(), prefix) != 0) return false;
    std::wstring rest = arguments.substr(prefix.size());
    if (rest.compare(0, 5, L"body:") == 0) {
        out->kind = 0;
        rest = rest.substr(5);
    } else if (rest.compare(0, 7, L"action:") == 0) {
        out->kind = 1;
        rest = rest.substr(7);
    } else {
        return false;
    }
    out->token.clear();
    for (wchar_t ch : rest) {
        /* Tokens are lowercase hex; anything else is not a token. */
        if (!((ch >= L'0' && ch <= L'9') || (ch >= L'a' && ch <= L'f'))) return false;
        out->token.push_back(static_cast<char>(ch));
    }
    return true;
}

/* Shared by the event handlers and the activator, which can outlive the
 * host: they post through it, and the host clears the window on
 * shutdown. */
class Relay {
public:
    explicit Relay(UINT message) : message_(message) {}
    void addRef() { refs_.fetch_add(1, std::memory_order_relaxed); }
    void release() {
        if (refs_.fetch_sub(1, std::memory_order_acq_rel) == 1) delete this;
    }
    void attach(HWND hwnd) { hwnd_.store(hwnd, std::memory_order_release); }
    void detach() { hwnd_.store(nullptr, std::memory_order_release); }
    void post(const std::wstring &arguments) {
        Activation parsed;
        if (!parseArguments(arguments, &parsed)) return;
        HWND hwnd = hwnd_.load(std::memory_order_acquire);
        if (!hwnd) return;
        auto *payload = new Activation(parsed);
        if (!PostMessageW(hwnd, message_, 0, reinterpret_cast<LPARAM>(payload))) delete payload;
    }

private:
    std::atomic<HWND> hwnd_{nullptr};
    std::atomic<ULONG> refs_{1};
    UINT message_;
};

class ActivatedHandler final : public ActivatedEventHandler {
public:
    explicit ActivatedHandler(Relay *relay) : relay_(relay) { relay_->addRef(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (!out) return E_POINTER;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, kIID_ActivatedEventHandler) || IsEqualIID(riid, kIID_AgileObject)) {
            *out = static_cast<ActivatedEventHandler *>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return refs_.fetch_add(1, std::memory_order_relaxed) + 1; }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG remaining = refs_.fetch_sub(1, std::memory_order_acq_rel) - 1;
        if (remaining == 0) delete this;
        return remaining;
    }
    HRESULT STDMETHODCALLTYPE Invoke(ToastNotification *, Inspectable *args) override {
        ToastActivatedEventArgs *activated = nullptr;
        if (!args || FAILED(args->QueryInterface(kIID_ToastActivatedEventArgs, reinterpret_cast<void **>(&activated)))) return S_OK;
        HString arguments = nullptr;
        if (SUCCEEDED(activated->get_Arguments(&arguments)) && arguments) {
            const Api &api = Api::get();
            UINT32 length = 0;
            const wchar_t *raw = api.string_buffer(arguments, &length);
            relay_->post(std::wstring(raw ? raw : L"", length));
            api.delete_string(arguments);
        }
        activated->Release();
        return S_OK;
    }

private:
    ~ActivatedHandler() { relay_->release(); }
    std::atomic<ULONG> refs_{1};
    Relay *relay_;
};

/* The class object COM hands Action Center activations to. It serves its
 * own interface too, so CreateInstance can return itself. */
class Activator final : public NotificationActivationCallback, public IClassFactory {
public:
    explicit Activator(Relay *relay) : relay_(relay) { relay_->addRef(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (!out) return E_POINTER;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IClassFactory)) {
            *out = static_cast<IClassFactory *>(this);
        } else if (IsEqualIID(riid, kIID_NotificationActivationCallback)) {
            *out = static_cast<NotificationActivationCallback *>(this);
        } else {
            *out = nullptr;
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return refs_.fetch_add(1, std::memory_order_relaxed) + 1; }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG remaining = refs_.fetch_sub(1, std::memory_order_acq_rel) - 1;
        if (remaining == 0) delete this;
        return remaining;
    }
    HRESULT STDMETHODCALLTYPE Activate(LPCWSTR, LPCWSTR invoked_args, const UserInputData *, ULONG) override {
        relay_->post(invoked_args ? std::wstring(invoked_args) : std::wstring());
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown *outer, REFIID riid, void **out) override {
        if (outer) return CLASS_E_NOAGGREGATION;
        return QueryInterface(riid, out);
    }
    HRESULT STDMETHODCALLTYPE LockServer(BOOL) override { return S_OK; }

private:
    ~Activator() { relay_->release(); }
    std::atomic<ULONG> refs_{1};
    Relay *relay_;
};

struct LiveToast {
    ToastNotification *toast = nullptr;
    EventToken activated = {};
    std::wstring tag;
};

/* Per-host toast state, created on the first notification. Owned and
 * used on the loop thread only. */
struct Center {
    bool attempted = false;
    bool ready = false;
    ToastNotifier *notifier = nullptr;
    ToastNotificationFactory *factory = nullptr;
    Relay *relay = nullptr;
    Activator *activator = nullptr;
    DWORD activator_cookie = 0;
    std::deque<LiveToast> live;
};

static bool setRegistryString(const Api &api, HKEY key, const wchar_t *name, const std::wstring &value) {
    return api.reg_set_value(key, name, 0, REG_SZ, reinterpret_cast<const BYTE *>(value.c_str()),
        static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
}

static bool registerIdentity(const std::wstring &app_user_model_id, const std::wstring &display_name, const std::wstring &icon_path, const CLSID &activator) {
    const Api &api = Api::get();
    wchar_t clsid_text[64] = {};
    if (!StringFromGUID2(activator, clsid_text, 64)) return false;
    const std::wstring path = L"Software\\Classes\\AppUserModelId\\" + app_user_model_id;
    HKEY key = nullptr;
    if (api.reg_create_key(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
    bool ok = setRegistryString(api, key, L"DisplayName", display_name.empty() ? app_user_model_id : display_name) &&
        setRegistryString(api, key, L"CustomActivator", clsid_text);
    if (ok && !icon_path.empty() && GetFileAttributesW(icon_path.c_str()) != INVALID_FILE_ATTRIBUTES) {
        ok = setRegistryString(api, key, L"IconUri", icon_path);
    }
    api.reg_close_key(key);
    return ok;
}

/* First use: register the identity and the activator, then create the
 * notifier. A failure is remembered; the host reports notifications as
 * unavailable rather than retrying every request. */
static bool ensureReady(Center &center, HWND loop_window, UINT message, const std::wstring &app_user_model_id, const std::string &app_user_model_id_utf8, const std::wstring &display_name, const std::wstring &icon_path) {
    if (center.attempted) return center.ready;
    center.attempted = true;
    const Api &api = Api::get();
    if (!api.ready || app_user_model_id.empty() || !loop_window) return false;
    const CLSID clsid = activatorClsid(app_user_model_id_utf8);
    if (!registerIdentity(app_user_model_id, display_name, icon_path, clsid)) return false;

    center.relay = new Relay(message);
    center.relay->attach(loop_window);
    center.activator = new Activator(center.relay);
    if (FAILED(CoRegisterClassObject(clsid, static_cast<IClassFactory *>(center.activator), CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE, &center.activator_cookie))) {
        center.activator_cookie = 0;
    }

    ToastNotificationManagerStatics *manager = nullptr;
    {
        Str name(L"Windows.UI.Notifications.ToastNotificationManager");
        if (!name.get() || FAILED(api.get_activation_factory(name.get(), kIID_ToastNotificationManagerStatics, reinterpret_cast<void **>(&manager)))) return false;
    }
    {
        Str id(app_user_model_id);
        HRESULT hr = id.get() ? manager->CreateToastNotifierWithId(id.get(), &center.notifier) : E_OUTOFMEMORY;
        manager->Release();
        if (FAILED(hr)) return false;
    }
    {
        Str name(L"Windows.UI.Notifications.ToastNotification");
        if (!name.get() || FAILED(api.get_activation_factory(name.get(), kIID_ToastNotificationFactory, reinterpret_cast<void **>(&center.factory)))) return false;
    }
    center.ready = true;
    return true;
}

static void dropLive(LiveToast &entry) {
    if (!entry.toast) return;
    entry.toast->remove_Activated(entry.activated);
    release(entry.toast);
}

static XmlDocument *loadXml(const std::wstring &xml) {
    const Api &api = Api::get();
    Inspectable *instance = nullptr;
    {
        Str name(L"Windows.Data.Xml.Dom.XmlDocument");
        if (!name.get() || FAILED(api.activate_instance(name.get(), &instance))) return nullptr;
    }
    XmlDocumentIO *io = nullptr;
    XmlDocument *document = nullptr;
    if (SUCCEEDED(instance->QueryInterface(kIID_XmlDocumentIO, reinterpret_cast<void **>(&io)))) {
        Str text(xml);
        if (text.get() && SUCCEEDED(io->LoadXml(text.get()))) {
            if (FAILED(instance->QueryInterface(kIID_XmlDocument, reinterpret_cast<void **>(&document)))) document = nullptr;
        }
    }
    release(io);
    release(instance);
    return document;
}

/* token: empty for a notification without commands; its body click still
 * routes to the app (and brings it forward) but dispatches nothing. */
static bool show(Center &center, HWND loop_window, UINT message, const std::wstring &app_user_model_id, const std::string &app_user_model_id_utf8,
    const std::wstring &display_name, const std::wstring &icon_path, const std::wstring &title, const std::wstring &subtitle,
    const std::wstring &body, const std::string &id, const std::wstring &action_label, const std::string &token) {
    if (!ensureReady(center, loop_window, message, app_user_model_id, app_user_model_id_utf8, display_name, icon_path)) return false;

    const std::wstring wide_token(token.begin(), token.end());
    std::wstring xml = L"<toast launch=\"";
    xml += kArgumentPrefix;
    xml += L"body:" + wide_token + L"\"><visual><binding template=\"ToastGeneric\"><text>" + xmlEscape(title) + L"</text>";
    if (!subtitle.empty()) xml += L"<text>" + xmlEscape(subtitle) + L"</text>";
    if (!body.empty()) xml += L"<text>" + xmlEscape(body) + L"</text>";
    xml += L"</binding></visual>";
    if (!action_label.empty() && !token.empty()) {
        xml += L"<actions><action content=\"" + xmlEscape(action_label) + L"\" arguments=\"";
        xml += kArgumentPrefix;
        xml += L"action:" + wide_token + L"\" activationType=\"foreground\"/></actions>";
    }
    xml += L"</toast>";

    XmlDocument *document = loadXml(xml);
    if (!document) return false;
    ToastNotification *toast = nullptr;
    HRESULT hr = center.factory->CreateToastNotification(document, &toast);
    release(document);
    if (FAILED(hr) || !toast) return false;

    std::wstring tag;
    if (!id.empty()) {
        tag = tagForId(id);
        ToastNotification2 *tagged = nullptr;
        if (SUCCEEDED(toast->QueryInterface(kIID_ToastNotification2, reinterpret_cast<void **>(&tagged)))) {
            Str tag_text(tag);
            Str group_text(kGroup);
            if (tag_text.get()) tagged->put_Tag(tag_text.get());
            if (group_text.get()) tagged->put_Group(group_text.get());
            release(tagged);
        }
    }

    LiveToast entry;
    entry.toast = toast;
    entry.tag = tag;
    auto *handler = new ActivatedHandler(center.relay);
    if (FAILED(toast->add_Activated(handler, &entry.activated))) entry.activated = {};
    handler->Release();

    hr = center.notifier->Show(toast);
    if (FAILED(hr)) {
        dropLive(entry);
        return false;
    }
    /* The replaced toast's handler can no longer fire for a live binding;
     * keep the list bounded either way. */
    if (!tag.empty()) {
        for (auto it = center.live.begin(); it != center.live.end(); ++it) {
            if (it->tag == tag) {
                dropLive(*it);
                center.live.erase(it);
                break;
            }
        }
    }
    center.live.push_back(entry);
    while (center.live.size() > kMaxLiveToasts) {
        dropLive(center.live.front());
        center.live.pop_front();
    }
    return true;
}

/* Host teardown, on the loop thread before COM is uninitialized. Toasts
 * already in Action Center stay there; clicking them later does nothing
 * because no activator is registered any more. */
static void shutdown(Center &center) {
    for (auto &entry : center.live) dropLive(entry);
    center.live.clear();
    if (center.activator_cookie) CoRevokeClassObject(center.activator_cookie);
    center.activator_cookie = 0;
    if (center.relay) center.relay->detach();
    if (center.activator) center.activator->Release();
    center.activator = nullptr;
    release(center.factory);
    release(center.notifier);
    if (center.relay) center.relay->release();
    center.relay = nullptr;
    center.ready = false;
}

} // namespace native_sdk_toast
