#include "toasts_win.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <eventtoken.h>
#include <inspectable.h>
#include <objidl.h>
#include <roapi.h>
#include <shobjidl.h>
#include <winstring.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdio>
#include <map>

using Microsoft::WRL::ComPtr;

namespace {

// The few interfaces of Windows.UI.Notifications and Windows.Data.Xml.Dom
// used here, as far as they're called, in Windows' own order: the compiler's
// Windows headers have none of them.
namespace winrt {

struct IXmlDocument : IInspectable {};

struct IXmlDocumentIO : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE LoadXml(HSTRING xml) = 0;
};

struct IToastNotification;

// TypedEventHandler<ToastNotification, Object>.
struct IClicked : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE Invoke(IToastNotification *sender, IInspectable *args) = 0;
};

struct IToastNotification : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE get_Content(IXmlDocument **content) = 0;
    virtual HRESULT STDMETHODCALLTYPE put_ExpirationTime(IUnknown *time) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_ExpirationTime(IUnknown **time) = 0;
    virtual HRESULT STDMETHODCALLTYPE add_Dismissed(IUnknown *handler, EventRegistrationToken *token) = 0;
    virtual HRESULT STDMETHODCALLTYPE remove_Dismissed(EventRegistrationToken token) = 0;
    virtual HRESULT STDMETHODCALLTYPE add_Activated(IClicked *handler, EventRegistrationToken *token) = 0;
};

struct IToastNotification2 : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE put_Tag(HSTRING tag) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_Tag(HSTRING *tag) = 0;
    virtual HRESULT STDMETHODCALLTYPE put_Group(HSTRING group) = 0;
};

struct IToastNotificationFactory : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE CreateToastNotification(IXmlDocument *content, IToastNotification **toast) = 0;
};

struct IToastNotifier : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE Show(IToastNotification *toast) = 0;
    virtual HRESULT STDMETHODCALLTYPE Hide(IToastNotification *toast) = 0;
    // 0 if the user lets the app show them.
    virtual HRESULT STDMETHODCALLTYPE get_Setting(INT32 *setting) = 0;
};

struct IToastNotificationHistory : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE RemoveGroup(HSTRING group) = 0;
    virtual HRESULT STDMETHODCALLTYPE RemoveGroupWithId(HSTRING group, HSTRING id) = 0;
    virtual HRESULT STDMETHODCALLTYPE RemoveGroupedTagWithId(HSTRING tag, HSTRING group, HSTRING id) = 0;
};

struct IToastNotificationManagerStatics : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE CreateToastNotifier(IToastNotifier **notifier) = 0;
    virtual HRESULT STDMETHODCALLTYPE CreateToastNotifierWithId(HSTRING id, IToastNotifier **notifier) = 0;
};

struct IToastNotificationManagerStatics2 : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE get_History(IToastNotificationHistory **history) = 0;
};

const IID unknownId = {0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
const IID agileId = {0x94ea2b94, 0xe9cc, 0x49e0, {0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90}};
const IID xmlDocumentId = {0xf7f3a506, 0x1e87, 0x42d6, {0xbc, 0xfb, 0xb8, 0xc8, 0x09, 0xfa, 0x54, 0x94}};
const IID xmlDocumentIOId = {0x6cd0e74e, 0xee65, 0x4489, {0x9e, 0xbf, 0xca, 0x43, 0xe8, 0x7b, 0xa6, 0x37}};
const IID clickedId = {0xab54de2d, 0x97d9, 0x5528, {0xb6, 0xad, 0x10, 0x5a, 0xfe, 0x15, 0x65, 0x30}};
const IID toastNotification2Id = {0x9dfb9fd1, 0x143a, 0x490e, {0x90, 0xbf, 0xb9, 0xfb, 0xa7, 0x13, 0x2d, 0xe7}};
const IID toastNotificationFactoryId = {0x04124b20, 0x82c6, 0x4229, {0xb1, 0x09, 0xfd, 0x9e, 0xd4, 0x66, 0x2b, 0x53}};
const IID managerId = {0x50ac103f, 0xd235, 0x4598, {0xbb, 0xef, 0x98, 0xfe, 0x4d, 0x1a, 0x3a, 0xd4}};
const IID manager2Id = {0x7ab93c52, 0x0e48, 0x4750, {0xba, 0x9d, 0x1a, 0x41, 0x13, 0x98, 0x18, 0x47}};

} // namespace winrt

// A Windows Runtime string, for as long as it's in scope.
class Text {
public:
    explicit Text(const std::wstring &text) { WindowsCreateString(text.c_str(), UINT32(text.size()), &string); }
    ~Text() { WindowsDeleteString(string); }
    Text(const Text &) = delete;
    Text &operator=(const Text &) = delete;
    operator HSTRING() const { return string; }

private:
    HSTRING string = nullptr;
};

template <typename T>
void **out(ComPtr<T> &pointer)
{
    return reinterpret_cast<void **>(pointer.ReleaseAndGetAddressOf());
}

// What a click calls, from any thread, so agile.
class Clicked final : public winrt::IClicked, public IAgileObject {
public:
    explicit Clicked(std::function<void()> then) : then(std::move(then)) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override
    {
        if (iid == winrt::unknownId || iid == winrt::clickedId) {
            *object = static_cast<winrt::IClicked *>(this);
        } else if (iid == winrt::agileId) {
            *object = static_cast<IAgileObject *>(this);
        } else {
            *object = nullptr;
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++count; }
    ULONG STDMETHODCALLTYPE Release() override
    {
        const ULONG left = --count;
        if (left == 0) {
            delete this;
        }
        return left;
    }
    HRESULT STDMETHODCALLTYPE Invoke(winrt::IToastNotification *, IInspectable *) override
    {
        then();
        return S_OK;
    }

private:
    std::atomic<ULONG> count{1};
    std::function<void()> then;
};

// All the app's toasts are in one group, by their tags.
const std::wstring group = L"hatter";

// What failed, with Windows' code for why.
std::string failed(const char *what, HRESULT result)
{
    char code[16];
    std::snprintf(code, sizeof code, "0x%08lx", static_cast<unsigned long>(result));
    return std::string(what) + " failed (" + code + ")";
}

// NotificationSetting, but Enabled.
const char *const settings[] = {"", "turned off for the app", "turned off for the user", "turned off by policy",
                                "not in the app's manifest"};

} // namespace

struct Toasts::State {
    std::wstring id;
    // Why there's no notifier.
    std::string broken;
    ComPtr<winrt::IToastNotifier> notifier;
    ComPtr<winrt::IToastNotificationFactory> factory;
    ComPtr<winrt::IToastNotificationHistory> history;
    // Kept to hear their clicks, and to take them off the screen.
    std::map<std::wstring, ComPtr<winrt::IToastNotification>> shown;
};

Toasts::Toasts(const std::wstring &id, const std::wstring &name) : state(std::make_unique<State>())
{
    state->id = id;
    HKEY registered;
    const std::wstring key = L"Software\\Classes\\AppUserModelId\\" + id;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &registered, nullptr)
        == ERROR_SUCCESS) {
        RegSetValueExW(registered, L"DisplayName", 0, REG_SZ, reinterpret_cast<const BYTE *>(name.c_str()),
                       DWORD((name.size() + 1) * sizeof(wchar_t)));
        RegCloseKey(registered);
    }
    SetCurrentProcessExplicitAppUserModelID(id.c_str());
    // Already so on the thread of Qt's windows, which is the one this is on.
    RoInitialize(RO_INIT_SINGLETHREADED);
    ComPtr<winrt::IToastNotificationManagerStatics> manager;
    ComPtr<winrt::IToastNotificationManagerStatics2> manager2;
    HRESULT result;
    if (FAILED(result = RoGetActivationFactory(Text(L"Windows.UI.Notifications.ToastNotificationManager"),
                                               winrt::managerId, out(manager)))) {
        state->broken = failed("getting the toast manager", result);
        return;
    }
    if (FAILED(result = manager->CreateToastNotifierWithId(Text(id), state->notifier.ReleaseAndGetAddressOf()))) {
        state->broken = failed("getting a notifier", result);
        return;
    }
    if (FAILED(result = RoGetActivationFactory(Text(L"Windows.UI.Notifications.ToastNotification"),
                                               winrt::toastNotificationFactoryId, out(state->factory)))) {
        state->notifier.Reset();
        state->broken = failed("getting the toast factory", result);
        return;
    }
    if (SUCCEEDED(manager->QueryInterface(winrt::manager2Id, out(manager2)))) {
        manager2->get_History(state->history.ReleaseAndGetAddressOf());
    }
}

Toasts::~Toasts() = default;

const std::string &Toasts::notAllowed()
{
    static const std::string reason = "not allowed: ";
    return reason;
}

std::string Toasts::show(const std::wstring &tag, const std::wstring &xml, std::function<void()> clicked)
{
    if (!state->notifier) {
        return state->broken;
    }
    ComPtr<IInspectable> document;
    ComPtr<winrt::IXmlDocumentIO> loading;
    ComPtr<winrt::IXmlDocument> content;
    ComPtr<winrt::IToastNotification> toast;
    ComPtr<winrt::IToastNotification2> named;
    HRESULT result;
    if (FAILED(result = RoActivateInstance(Text(L"Windows.Data.Xml.Dom.XmlDocument"),
                                           document.ReleaseAndGetAddressOf()))) {
        return failed("making its XML document", result);
    }
    if (FAILED(result = document->QueryInterface(winrt::xmlDocumentIOId, out(loading)))
        || FAILED(result = loading->LoadXml(Text(xml)))
        || FAILED(result = document->QueryInterface(winrt::xmlDocumentId, out(content)))) {
        return failed("reading its XML", result);
    }
    if (FAILED(result = state->factory->CreateToastNotification(content.Get(), toast.ReleaseAndGetAddressOf()))) {
        return failed("making it", result);
    }
    if (FAILED(result = toast->QueryInterface(winrt::toastNotification2Id, out(named)))
        || FAILED(result = named->put_Tag(Text(tag))) || FAILED(result = named->put_Group(Text(group)))) {
        return failed("tagging it", result);
    }
    auto *handler = new Clicked(std::move(clicked));
    EventRegistrationToken token;
    result = toast->add_Activated(handler, &token);
    handler->Release();
    if (FAILED(result)) {
        return failed("hearing its clicks", result);
    }
    // Last, so all the rest is done where the app may not. Windows may not
    // say, for a program that isn't a package's: then it's tried.
    INT32 setting = 0;
    if (SUCCEEDED(state->notifier->get_Setting(&setting)) && setting != 0) {
        return notAllowed() + (setting > 0 && setting < 5 ? settings[setting] : "for a reason of Windows'");
    }
    if (FAILED(result = state->notifier->Show(toast.Get()))) {
        return failed("showing it", result);
    }
    state->shown[tag] = toast;
    return {};
}

void Toasts::remove(const std::wstring &tag)
{
    const auto found = state->shown.find(tag);
    if (found != state->shown.end()) {
        state->notifier->Hide(found->second.Get());
        state->shown.erase(found);
    }
    if (state->history) {
        state->history->RemoveGroupedTagWithId(Text(tag), Text(group), Text(state->id));
    }
}
