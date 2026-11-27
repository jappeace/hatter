// What Hatter asks of the platform besides showing nodes: dialogs, sheets,
// files, pictures, icons, and where the app's data is.

#pragma once

#include <QColor>
#include <QHash>
#include <QImage>
#include <QObject>
#include <QSizeF>
#include <QString>
#include <QStringList>

#include <functional>
#include <memory>

#include "NotificationBridge.h"

// Hands on what a dialog or sheet answers.
class Answer : public QObject {
    Q_OBJECT

public:
    Answer(std::function<void(int)> then, QObject *parent) : QObject(parent), then(std::move(then)) {}

public slots:
    void answered(int action) { then(action); }

private:
    std::function<void(int)> then;
};

class Toasts;

// The desktop's notifications, one for each of the app's keys, where
// clicking one opens the app at its key: org.freedesktop.Notifications's
// on Linux, the user notification centre's on macOS (only in an app's
// bundle, else logged), and toasts on Windows.
class Notifications : public QObject {
    Q_OBJECT

public:
    Notifications();
    ~Notifications() override;
    void show(const QString &key, const QString &title, const QString &text, int kind);
    void cancel(const QString &key);

#ifdef HATTER_QT_DBUS
private slots:
    void invoked(uint id, const QString &action);
    void closed(uint id, uint reason);

private:
    QHash<QString, uint> ids;
#elif defined(Q_OS_MACOS)
private:
    // Its delegate, kept; null outside a bundle.
    void *centre = nullptr;
#elif defined(Q_OS_WIN)
private:
    std::unique_ptr<Toasts> toasts;
#endif
};

// The window shown and the app told it was opened at a notification's
// key. On the window's thread.
void notificationOpened(const QString &key);

void pickFiles(const QString &mimeType, bool several);
// A notification's body, which servers show markup in, some (as dunst)
// without saying so: the app's text, escaped.
QString notificationBody(const QString &text);
// Picked files, copied off the window's thread where the app may move or
// delete them, each then handed on on it, with its name and size.
void copyPicked(const QStringList &paths, std::function<void(const QString &, const QString &, qint64)> each);
// A file over another, which stays until the new one is whole.
bool replaceWith(const QString &source, const QString &target);
void pickPicture(const std::vector<int> &sides, int limit);
// A picture taken with the camera, handed on as a picked file, as
// Android's camera app's.
void capturePicture();
void saveFile(const QString &path, const QString &name);

// A picture file's size as it shows, turned as its camera says, from its
// header alone.
bool imageSize(const QString &path, int *width, int *height);

// Pictures are decoded at most as big as the screen, as on Android, and
// turned as their camera says: the size to load a file at (empty for as it
// is), and one from its bytes (null if it isn't one or is too large).
QSize shownSize(const QString &path);
QImage shownPicture(const QByteArray &bytes);
// An icon: one of the app's Android vector drawables, its size in
// density-independent pixels, and drawn at a size in a colour.
QSizeF iconSize(const QString &name);
QImage icon(const QString &name, const QSize &size, const QColor &colour);
