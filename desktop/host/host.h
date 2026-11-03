// The host: Hatter's UI bridge calls, answered with Qt Quick items in a
// window.

#pragma once

#include <QHash>
#include <QImage>
#include <QPointer>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickImageProvider>
#include <QQuickWindow>
#include <QUrl>

#include <atomic>
#include <map>
#include <memory>

#include "hatter_qt.h"

class Node;
class Notifications;
class QTimer;

// Pictures the app gives as bytes, for Image items to show.
class Pictures : public QQuickImageProvider {
public:
    Pictures() : QQuickImageProvider(QQuickImageProvider::Image) {}
    QImage requestImage(const QString &id, QSize *size, const QSize &wanted) override;
    QHash<QString, QImage> shown;
    // Streams' latest frames, by key.
    QHash<QString, QImage> streams;
};

class Host {
public:
    explicit Host(QQmlEngine *engine);

    HatterQtApp app{};
    QQmlEngine *engine;
    Pictures *pictures;
    Notifications *notifications = nullptr;
    QPointer<QQuickWindow> window;
    std::map<int, Node *> nodes;
    Node *root = nullptr;
    // Dialogs, sheets and file dialogs open, which take Back first.
    int popups = 0;
    // While measuring, which changes sizes the host asked for itself.
    bool laying = false;
    std::atomic<bool> redrawing{false};
    // What draws the window, as DeviceInfo says it.
    QByteArray graphics;
    // An animation's frames, and the context the app gave for them.
    QTimer *frames = nullptr;
    void *animating = nullptr;

    // A new object of one of the host's QML files (qml/Hatter<kind>.qml),
    // with properties it needs from the start.
    QObject *create(const char *kind, const QVariantMap &properties = {});
    // A new item of a kind of Qt Quick content.
    QQuickItem *make(const char *kind, QQuickItem *parent);
    void show(Node *node, const char *kind);
    // The colour icons are drawn in, as the theme's text.
    QColor tint() const;
    // Draws the icons again, in the theme's colour.
    void retint();

    // A short note for the user, as Android's toast.
    void toast(const QString &text);

    // Shows a frame in the image nodes showing its stream, on the GUI thread.
    void showFrame(const QString &key, const QImage &frame);
    // Where an Image fetches a stream's latest frame, empty before the first.
    QUrl streamUrl(const QString &key) const;

    // Lays the window out again before it's next drawn.
    void relayout();
    void layout();

    void click(int callback);
    void text(int callback, const QString &value);
    void scroll(int callback, int position);

    int createNode(int type);
    void setStrProp(int id, int prop, const char *value);
    void setNumProp(int id, int prop, double value);
    void setImageData(int id, const uint8_t *data, int length);
    void setHandler(int id, int event, int callback);
    void addChild(int parentId, int childId);
    void removeChild(int parentId, int childId);
    void destroyNode(int id);
    void setRoot(int id);
    void clear();

private:
    std::map<std::string, std::unique_ptr<QQmlComponent>> components;
    int nextId = 1;
    int nextPicture = 1;
    // Frames shown, to name each anew so Images fetch it.
    quint64 frameCount = 0;
};

extern Host *host;
