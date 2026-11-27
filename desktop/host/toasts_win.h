// Windows' toast notifications, for a program that isn't installed as a
// package: named by an application user model ID, registered for the user
// as Windows asks of such programs. Without Qt, so it's built on its own.

#pragma once

#include <functional>
#include <memory>
#include <string>

class Toasts {
public:
    // Under the ID, shown with the name.
    Toasts(const std::wstring &id, const std::wstring &name);
    ~Toasts();

    // A toast from its XML, in place of the one with the same tag. Clicked
    // calls back on a thread of Windows'. What stopped it, if it isn't
    // shown, which starts with notAllowed() if the user or the system
    // doesn't let the app show them.
    std::string show(const std::wstring &tag, const std::wstring &xml, std::function<void()> clicked);
    static const std::string &notAllowed();
    // Off the screen and out of the notification centre.
    void remove(const std::wstring &tag);

private:
    struct State;
    std::unique_ptr<State> state;
};
