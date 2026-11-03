#include "host.h"

#include <QClipboard>
#include <QDesktopServices>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QDir>
#include <QFontDatabase>
#include <QApplication>
#include <QLocale>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QQmlProperty>
#include <QQuickStyle>
#include <QStandardPaths>
#include <QStyleHints>
#include <QTimer>
#include <QUrl>

#include <algorithm>
#include <chrono>

#include "node.h"
#include "platform.h"
#include "rows.h"

Host *host = nullptr;

namespace {

// The value Hatter sends for no limit.
constexpr double unlimited = 2147483647;

QString utf8(const char *value)
{
    return QString::fromUtf8(value ? value : "");
}

// Sets a property by its QML name, grouped ("font.bold") or attached
// ("Material.foreground").
void write(QQuickItem *item, const char *name, const QVariant &value)
{
    QQmlProperty(item, QString::fromLatin1(name), qmlContext(item)).write(value);
}

const char *kindOf(int type, int inputType)
{
    switch (type) {
    case UI_NODE_TEXT:
    case UI_NODE_MAP_VIEW:
    case UI_NODE_WEBVIEW:
        return "Text";
    case UI_NODE_BUTTON:
        return "Button";
    case UI_NODE_SWITCH:
        return "Switch";
    case UI_NODE_TEXT_INPUT:
        return inputType == 2 ? "Area" : "Field";
    case UI_NODE_IMAGE:
        return "Image";
    case UI_NODE_SCROLL_VIEW:
    case UI_NODE_HORIZONTAL_SCROLL_VIEW:
        return "Flickable";
    case UI_NODE_LAZY_COLUMN:
        return "List";
    default:
        return nullptr;
    }
}

// Icons are drawn at this size, and shown smaller.
constexpr int iconSide = 96;

// What Pictures shows of an icon: its name and colour.
QString iconId(const QString &name, const QColor &colour)
{
    return QStringLiteral("icon/") + colour.name(QColor::HexArgb).mid(1) + QLatin1Char('/') + name;
}

// Hatter's lifecycle events (Hatter.h).
enum { Create, Start, Resume, Pause, Stop, Destroy };

// Back, as Escape or the mouse's back button, goes to the app first, after
// any dialog it has open.
class Back : public QObject {
protected:
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        const bool key = event->type() == QEvent::KeyPress
            && (static_cast<QKeyEvent *>(event)->key() == Qt::Key_Escape
                || static_cast<QKeyEvent *>(event)->key() == Qt::Key_Back);
        const bool button = event->type() == QEvent::MouseButtonPress
            && static_cast<QMouseEvent *>(event)->button() == Qt::BackButton;
        if ((key || button) && host->popups == 0) {
            return host->app.back(host->app.ctx) != 0;
        }
        return QObject::eventFilter(watched, event);
    }
};

// What draws the window, as DeviceInfo says it. Drawn by the CPU where Qt
// Quick would use OpenGL and there is no driver for it, as for a program
// from Nix on other Linux systems: else Qt aborts.
QByteArray drawing()
{
    // Qt Quick's software renderer where the user chose it, as where GL
    // fails even to be tried: for the window too, else it's made for GL.
    if (qgetenv("QT_QUICK_BACKEND") == "software") {
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
        return "software";
    }
    switch (QQuickWindow::graphicsApi()) {
    case QSGRendererInterface::OpenGL: {
        QOpenGLContext context;
        if (!context.create()) {
            QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
            return "software";
        }
        QOffscreenSurface surface;
        surface.create();
        if (!context.makeCurrent(&surface)) {
            return "OpenGL";
        }
        // As the driver names itself, which says if it draws with the CPU too.
        const QByteArray renderer = reinterpret_cast<const char *>(context.functions()->glGetString(GL_RENDERER));
        context.doneCurrent();
        return "OpenGL: " + renderer;
    }
    case QSGRendererInterface::Software:
        return "software";
    case QSGRendererInterface::Vulkan:
        return "Vulkan";
    case QSGRendererInterface::Metal:
        return "Metal";
    case QSGRendererInterface::Direct3D11:
        return "Direct3D 11";
    case QSGRendererInterface::Direct3D12:
        return "Direct3D 12";
    // None chosen, nothing drawn (for tests), or one Qt 6 can't draw with.
    case QSGRendererInterface::Unknown:
    case QSGRendererInterface::Null:
    case QSGRendererInterface::OpenVG:
        break;
    }
    return {};
}

} // namespace

QImage Pictures::requestImage(const QString &id, QSize *size, const QSize &wanted)
{
    // A stream's latest frame, as stream/<frame>/<key>.
    if (id.startsWith(QLatin1String("stream/"))) {
        const QImage frame = streams.value(id.section(QLatin1Char('/'), 2));
        if (size) {
            *size = frame.size();
        }
        return frame;
    }
    if (id.startsWith(QLatin1String("icon/"))) {
        const QString colour = id.section(QLatin1Char('/'), 1, 1), name = id.section(QLatin1Char('/'), 2);
        const QImage drawn = icon(name, wanted.isValid() ? wanted : QSize(iconSide, iconSide),
                                  QColor(QLatin1Char('#') + colour));
        if (size) {
            *size = drawn.size();
        }
        return drawn;
    }
    const QImage image = shown.value(id);
    if (size) {
        *size = image.size();
    }
    if (wanted.isValid() && !image.isNull()) {
        return image.scaled(wanted, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    }
    return image;
}

Host::Host(QQmlEngine *engine) : engine(engine), pictures(new Pictures)
{
    // The engine owns it.
    engine->addImageProvider(QStringLiteral("hatter"), pictures);
}

QObject *Host::create(const char *kind, const QVariantMap &properties)
{
    std::unique_ptr<QQmlComponent> &component = components[kind];
    if (!component) {
        component = std::make_unique<QQmlComponent>(
            engine, QUrl(QStringLiteral("qrc:/Hatter/Qt/qml/Hatter%1.qml").arg(QLatin1String(kind))));
    }
    QObject *object = component->createWithInitialProperties(properties);
    if (!object) {
        qWarning() << "Hatter: no" << kind << component->errors();
    }
    return object;
}

QQuickItem *Host::make(const char *kind, QQuickItem *parent)
{
    QObject *object = create(kind);
    auto *item = qobject_cast<QQuickItem *>(object);
    if (!item) {
        delete object;
        return nullptr;
    }
    // Gone with its node.
    item->setParent(parent);
    item->setParentItem(parent);
    return item;
}

QColor Host::tint() const
{
    return window ? QQmlProperty::read(window, QStringLiteral("Material.foreground"), qmlContext(window)).value<QColor>()
                  : QColor(Qt::black);
}

void Host::retint()
{
    const QColor colour = tint();
    for (const auto &[id, node] : nodes) {
        if (!node->resource.isEmpty() && node->content) {
            node->content->setProperty("source", QUrl(QStringLiteral("image://hatter/") + iconId(node->resource, colour)));
        }
    }
}

QUrl Host::streamUrl(const QString &key) const
{
    return pictures->streams.contains(key)
        ? QUrl(QStringLiteral("image://hatter/stream/%1/%2").arg(frameCount).arg(key))
        : QUrl();
}

void Host::showFrame(const QString &key, const QImage &frame)
{
    pictures->streams.insert(key, frame);
    ++frameCount;
    for (const auto &[id, node] : nodes) {
        if (node->stream == key && node->content) {
            node->content->setProperty("source", streamUrl(key));
        }
    }
}

void Host::relayout()
{
    if (root && !laying) {
        root->polish();
    }
}

void Host::layout()
{
    if (!root || !window) {
        return;
    }
    laying = true;
    const QQuickItem *area = window->contentItem();
    root->measure({{Extent::Exactly, area->width()}, {Extent::Exactly, area->height()}});
    root->place(0, 0);
    laying = false;
}

void Host::click(int callback)
{
    if (callback >= 0) {
        app.event(app.ctx, callback);
    }
}

void Host::toast(const QString &text)
{
    if (window) {
        QMetaObject::invokeMethod(window, "toast", Q_ARG(QVariant, text));
    }
}

void Host::text(int callback, const QString &value)
{
    if (callback >= 0) {
        app.text(app.ctx, callback, value.toUtf8().constData());
    }
}

void Host::scroll(int callback, int position)
{
    if (callback >= 0) {
        app.scroll(app.ctx, callback, position);
    }
}

// Gives a node what Qt Quick shows for it, and listens to it.
void Host::show(Node *node, const char *kind)
{
    QQuickItem *content = make(kind, node);
    node->content = content;
    if (!content) {
        return;
    }
    auto changed = [this] { relayout(); };
    QObject::connect(content, &QQuickItem::implicitWidthChanged, node, changed);
    QObject::connect(content, &QQuickItem::implicitHeightChanged, node, changed);
    switch (node->type) {
    case UI_NODE_BUTTON:
        QObject::connect(content, SIGNAL(clicked()), node, SLOT(clicked()));
        QObject::connect(content, SIGNAL(pressAndHold()), node, SLOT(pressedLong()));
        break;
    case UI_NODE_TEXT_INPUT:
        QObject::connect(content, SIGNAL(textChanged()), node, SLOT(edited()));
        break;
    case UI_NODE_SWITCH:
        // Only the user's flips, not the app setting it.
        QObject::connect(content, SIGNAL(toggled()), node, SLOT(clicked()));
        break;
    }
}

int Host::createNode(int type)
{
    auto *node = new Node(type, this);
    const int id = nextId++;
    nodes[id] = node;
    if (const char *kind = kindOf(type, 0)) {
        show(node, kind);
    }
    QQuickItem *content = node->content;
    if (!content) {
        return id;
    }
    switch (type) {
    case UI_NODE_MAP_VIEW:
        content->setProperty("text", QStringLiteral("Map"));
        break;
    case UI_NODE_LAZY_COLUMN:
        node->rows = new Rows(this, id, content);
        content->setProperty("rows", QVariant::fromValue<QObject *>(node->rows));
        content->setProperty("model", QVariant::fromValue<QObject *>(node->rows));
        QObject::connect(content, SIGNAL(contentYChanged()), node, SLOT(moved()));
        QObject::connect(content, SIGNAL(contentHeightChanged()), node, SLOT(moved()));
        break;
    case UI_NODE_SCROLL_VIEW:
        content->setProperty("flickableDirection", 2);
        QObject::connect(content, SIGNAL(contentYChanged()), node, SLOT(moved()));
        QObject::connect(content, SIGNAL(contentHeightChanged()), node, SLOT(moved()));
        break;
    case UI_NODE_HORIZONTAL_SCROLL_VIEW:
        content->setProperty("flickableDirection", 1);
        QObject::connect(content, SIGNAL(contentXChanged()), node, SLOT(moved()));
        break;
    }
    return id;
}

void Host::setStrProp(int id, int prop, const char *value)
{
    const auto found = nodes.find(id);
    if (found == nodes.end()) {
        return;
    }
    Node *node = found->second;
    QQuickItem *content = node->content;
    const QString text = utf8(value);
    const bool control = node->type == UI_NODE_BUTTON || node->type == UI_NODE_TEXT_INPUT;
    switch (prop) {
    case UI_PROP_TEXT:
    case UI_PROP_WEBVIEW_URL:
        // Not what the user typed back over what they typed since.
        if (content && content->property("text").toString() != text) {
            node->quiet = true;
            content->setProperty("text", text);
            node->quiet = false;
            // From its start, as Android shows text it's given, unless the
            // user is typing there.
            if (node->type == UI_NODE_TEXT_INPUT && !content->hasActiveFocus()) {
                content->setProperty("cursorPosition", 0);
            }
        }
        break;
    case UI_PROP_COLOR:
        if (content && control) {
            write(content, "Material.foreground", QColor(text));
        } else if (content) {
            content->setProperty("color", QColor(text));
        }
        break;
    case UI_PROP_HINT:
        if (content) {
            content->setProperty("hint", text);
        }
        break;
    case UI_PROP_BG_COLOR:
        if (content && node->type == UI_NODE_BUTTON) {
            write(content, "Material.background", QColor(text));
        } else {
            node->setBackground(QColor(text));
        }
        break;
    case UI_PROP_IMAGE_FILE:
        if (content) {
            node->stream.clear();
            node->resource.clear();
            node->natural = {};
            content->setProperty("sourceSize", shownSize(text));
            content->setProperty("source", QUrl::fromLocalFile(text));
        }
        break;
    case UI_PROP_IMAGE_STREAM:
        if (content) {
            node->resource.clear();
            node->natural = {};
            node->stream = text;
            // Fetched again with each frame.
            content->setProperty("cache", false);
            content->setProperty("source", streamUrl(node->stream));
        }
        break;
    case UI_PROP_IMAGE_RESOURCE:
        if (content) {
            node->stream.clear();
            node->resource = text;
            node->natural = iconSize(text);
            content->setProperty("sourceSize", QSize(iconSide, iconSide));
            content->setProperty("source", QUrl(QStringLiteral("image://hatter/") + iconId(text, tint())));
        }
        break;
    default:
        qInfo("Hatter: no string property %d on Qt yet", prop);
    }
    relayout();
}

void Host::setNumProp(int id, int prop, double value)
{
    const auto found = nodes.find(id);
    if (found == nodes.end()) {
        return;
    }
    Node *node = found->second;
    QQuickItem *content = node->content;
    switch (prop) {
    case UI_PROP_FONT_SIZE:
        if (content) {
            write(content, "font.pixelSize", value);
        }
        break;
    case UI_PROP_FONT_STYLE:
        if (content) {
            const int style = int(value);
            write(content, "font.bold", bool(style & 1));
            write(content, "font.italic", bool(style & 4));
            write(content, "font.family", (style & 2 ? QFontDatabase::systemFont(QFontDatabase::FixedFont)
                                                     : QGuiApplication::font())
                                              .family());
        }
        break;
    case UI_PROP_PADDING:
        node->padding = value;
        node->paddingY = NAN;
        break;
    case UI_PROP_CHECKED:
        if (content && node->type == UI_NODE_SWITCH) {
            content->setProperty("checked", value != 0);
        }
        break;
    case UI_PROP_PADDING_Y:
        node->paddingY = value;
        break;
    case UI_PROP_CORNER_TOP_LEFT:
    case UI_PROP_CORNER_TOP_RIGHT:
    case UI_PROP_CORNER_BOTTOM_RIGHT:
    case UI_PROP_CORNER_BOTTOM_LEFT:
        node->setCorner(prop - UI_PROP_CORNER_TOP_LEFT, value);
        break;
    case UI_PROP_INPUT_TYPE:
        if (node->type == UI_NODE_TEXT_INPUT) {
            const int was = node->inputType;
            node->inputType = int(value);
            // A field of many lines is another item.
            if ((was == 2) != (node->inputType == 2) && content) {
                const QString text = content->property("text").toString();
                const QString hint = content->property("hint").toString();
                delete content;
                show(node, kindOf(node->type, node->inputType));
                content = node->content;
                if (!content) {
                    break;
                }
                node->quiet = true;
                content->setProperty("text", text);
                node->quiet = false;
                content->setProperty("hint", hint);
            }
            if (node->inputType != 2) {
                // TextInput.Password, TextInput.Normal.
                content->setProperty("echoMode", node->inputType == 3 ? 2 : 0);
            }
            content->setProperty("inputMethodHints",
                                 int(node->inputType == 1 ? Qt::ImhFormattedNumbersOnly : Qt::ImhNone));
        }
        break;
    case UI_PROP_GRAVITY:
        node->gravity = int(value);
        if (content && node->type != UI_NODE_IMAGE && !node->scrolling()) {
            const Qt::Alignment along[] = {Qt::AlignLeft, Qt::AlignHCenter, Qt::AlignRight};
            content->setProperty("horizontalAlignment", int(along[std::clamp(int(value), 0, 2)]));
        }
        break;
    case UI_PROP_SCALE_TYPE:
        if (content) {
            // Image.PreserveAspectFit, Image.PreserveAspectCrop, Image.Pad.
            const int fill[] = {1, 2, 6};
            content->setProperty("fillMode", fill[std::clamp(int(value), 0, 2)]);
            content->setClip(int(value) == 1);
        }
        break;
    case UI_PROP_TRANSLATE_X:
        node->translateX = value;
        break;
    case UI_PROP_TRANSLATE_Y:
        node->translateY = value;
        break;
    case UI_PROP_AUTO_FOCUS:
        if (content && value == 1) {
            content->forceActiveFocus();
        }
        break;
    case UI_PROP_WIDTH:
        node->wantWidth = value;
        break;
    case UI_PROP_HEIGHT:
        node->wantHeight = value;
        break;
    case UI_PROP_WEIGHT:
        node->weight = value;
        break;
    case UI_PROP_ALIGN_SELF:
        node->alignSelf = std::isnan(value) ? -1 : int(value);
        break;
    case UI_PROP_MARGIN:
        node->margin = value;
        break;
    case UI_PROP_MAX_WIDTH:
        node->maxWidth = value >= unlimited ? INFINITY : value;
        break;
    case UI_PROP_CORNER_RADIUS:
        node->setRadius(value);
        // A picture's own corners too.
        if (content && node->type == UI_NODE_IMAGE) {
            content->setProperty("radius", value);
        }
        break;
    case UI_PROP_KEEP_AT_END:
        node->keepAtEnd = value == 1;
        break;
    case UI_PROP_MAX_LINES:
        if (content) {
            const bool limited = value < unlimited;
            content->setProperty("maximumLineCount", limited ? int(value) : INT_MAX);
            // Text.ElideRight, Text.ElideNone.
            content->setProperty("elide", limited ? 1 : 3);
        }
        break;
    case UI_PROP_ITEM_COUNT:
        if (node->rows) {
            // Android binds the rows once it lays the list out, after the
            // render that set the count.
            QMetaObject::invokeMethod(node->rows, [this, rows = node->rows, items = int(value)] {
                rows->update(items);
                relayout();
            }, Qt::QueuedConnection);
        }
        break;
    case UI_PROP_SCROLL_TO_END:
        node->pinned = true;
        break;
    default:
        qInfo("Hatter: no number property %d on Qt yet", prop);
    }
    relayout();
}

void Host::setImageData(int id, const uint8_t *data, int length)
{
    const auto found = nodes.find(id);
    if (found == nodes.end() || !found->second->content) {
        return;
    }
    Node *node = found->second;
    pictures->shown.remove(node->picture);
    node->stream.clear();
    node->resource.clear();
    node->natural = {};
    node->picture = QString::number(nextPicture++);
    pictures->shown.insert(node->picture,
                           shownPicture(QByteArray::fromRawData(reinterpret_cast<const char *>(data), length)));
    node->content->setProperty("source", QUrl(QStringLiteral("image://hatter/") + node->picture));
    relayout();
}

void Host::setHandler(int id, int event, int callback)
{
    const auto found = nodes.find(id);
    if (found != nodes.end() && event >= 0 && event < 4) {
        found->second->setHandler(event, callback);
    }
}

void Host::addChild(int parentId, int childId)
{
    const auto parent = nodes.find(parentId), child = nodes.find(childId);
    if (parent == nodes.end() || child == nodes.end()) {
        return;
    }
    child->second->parentNode = parent->second;
    parent->second->kids.push_back(child->second);
    child->second->setParentItem(parent->second->slot());
    relayout();
}

void Host::removeChild(int parentId, int childId)
{
    const auto parent = nodes.find(parentId), child = nodes.find(childId);
    if (parent == nodes.end() || child == nodes.end()) {
        return;
    }
    std::vector<Node *> &kids = parent->second->kids;
    kids.erase(std::remove(kids.begin(), kids.end(), child->second), kids.end());
    child->second->parentNode = nullptr;
    child->second->setParentItem(nullptr);
    relayout();
}

void Host::destroyNode(int id)
{
    const auto found = nodes.find(id);
    if (found == nodes.end()) {
        return;
    }
    Node *node = found->second;
    nodes.erase(found);
    if (Node *parent = node->parentNode) {
        parent->kids.erase(std::remove(parent->kids.begin(), parent->kids.end(), node), parent->kids.end());
    }
    for (Node *kid : node->kids) {
        kid->parentNode = nullptr;
        kid->setParentItem(nullptr);
    }
    node->kids.clear();
    if (node == root) {
        root = nullptr;
    }
    pictures->shown.remove(node->picture);
    node->setParentItem(nullptr);
    // It may be what the user is tapping.
    node->deleteLater();
    relayout();
}

void Host::setRoot(int id)
{
    const auto found = nodes.find(id);
    if (found == nodes.end() || !window) {
        return;
    }
    if (root && root != found->second) {
        root->setParentItem(nullptr);
    }
    root = found->second;
    root->parentNode = nullptr;
    root->setParentItem(window->contentItem());
    relayout();
}

void Host::clear()
{
    while (!nodes.empty()) {
        destroyNode(nodes.begin()->first);
    }
}

extern "C" {

void hatter_qt_init(int *argc, char **argv)
{
    QQuickStyle::setStyle(QStringLiteral("Material"));
    // An application of widgets, for the desktop's file dialogs.
    auto *application = new QApplication(*argc, argv);
    const QByteArray graphics = drawing();
    host = new Host(new QQmlEngine(application));
    host->graphics = graphics;
    host->notifications = new Notifications;
}

const char *hatter_qt_files_dir(void)
{
    static const QByteArray path = [] {
        const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QDir().mkpath(dir);
        return dir.toUtf8();
    }();
    return path.constData();
}

UIBridgeCallbacks *hatter_qt_ui(void)
{
    static UIBridgeCallbacks callbacks{};
    callbacks.createNode = [](int32_t type) { return int32_t(host->createNode(type)); };
    callbacks.setStrProp = [](int32_t id, int32_t prop, const char *value) { host->setStrProp(id, prop, value); };
    callbacks.setNumProp = [](int32_t id, int32_t prop, double value) { host->setNumProp(id, prop, value); };
    callbacks.setImageData = [](int32_t id, const uint8_t *data, int32_t length) {
        host->setImageData(id, data, length);
    };
    callbacks.setHandler = [](int32_t id, int32_t event, int32_t callback) { host->setHandler(id, event, callback); };
    callbacks.addChild = [](int32_t parent, int32_t child) { host->addChild(parent, child); };
    callbacks.removeChild = [](int32_t parent, int32_t child) { host->removeChild(parent, child); };
    callbacks.destroyNode = [](int32_t id) { host->destroyNode(id); };
    callbacks.setRoot = [](int32_t id) { host->setRoot(id); };
    callbacks.clear = [] { host->clear(); };
    callbacks.darkMode = [] {
        return int32_t(QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark);
    };
    // A 12-hour clock's format says where AM or PM goes.
    callbacks.clock24 = [] {
        return int32_t(!QLocale::system().timeFormat(QLocale::ShortFormat).contains(QLatin1Char('a'), Qt::CaseInsensitive));
    };
    callbacks.copyText = [](const char *text) {
        QGuiApplication::clipboard()->setText(utf8(text));
        // As Android's system says so, and desktops don't.
        host->toast(QStringLiteral("Copied"));
    };
    callbacks.openUri = [](const char *uri) {
        if (!QDesktopServices::openUrl(QUrl(utf8(uri)))) {
            host->toast(QStringLiteral("No app opens this link"));
        }
    };
    callbacks.openFile = [](const char *path) {
        if (!QDesktopServices::openUrl(QUrl::fromLocalFile(utf8(path)))) {
            host->toast(QStringLiteral("No app opens this file"));
        }
    };
    callbacks.pickFile = [](const char *mimeType) { pickFiles(utf8(mimeType), false); };
    callbacks.pickFiles = [](const char *mimeType) { pickFiles(utf8(mimeType), true); };
    callbacks.capturePicture = [] { capturePicture(); };
    callbacks.pickPicture = [](const int32_t *sides, int32_t count, int32_t limit) {
        pickPicture(std::vector<int>(sides, sides + count), limit);
    };
    callbacks.saveFile = [](const char *path, const char *name, const char *) { saveFile(utf8(path), utf8(name)); };
    callbacks.imageSize = [](const char *path, int32_t *width, int32_t *height) {
        int w = 0, h = 0;
        if (!imageSize(utf8(path), &w, &h)) {
            return int32_t(0);
        }
        *width = w;
        *height = h;
        return int32_t(1);
    };
    return &callbacks;
}

void hatter_qt_redraw(void *)
{
    if (!host->redrawing.exchange(true)) {
        QMetaObject::invokeMethod(
            qApp,
            [] {
                host->redrawing = false;
                host->app.render(host->app.ctx);
            },
            Qt::QueuedConnection);
    }
}

void hatter_qt_animation_start(void *ctx)
{
    host->animating = ctx;
    if (!host->frames) {
        host->frames = new QTimer(qApp);
        host->frames->setTimerType(Qt::PreciseTimer);
        QObject::connect(host->frames, &QTimer::timeout, qApp, [] {
            const std::chrono::duration<double, std::milli> now = std::chrono::steady_clock::now().time_since_epoch();
            host->app.frame(host->animating, now.count());
        });
    }
    if (!host->frames->isActive()) {
        const QScreen *screen = host->window ? host->window->screen() : QGuiApplication::primaryScreen();
        // As often as the screen shows a frame, or at 60 Hz if it can't say.
        const qreal rate = screen && screen->refreshRate() > 0 ? screen->refreshRate() : 60;
        host->frames->start(qRound(1000 / rate));
    }
}

void hatter_qt_animation_stop(void)
{
    if (host->frames) {
        host->frames->stop();
    }
}

int hatter_qt_run(const HatterQtApp *app)
{
    host->app = *app;
    host->window = qobject_cast<QQuickWindow *>(host->create("Window"));
    if (!host->window) {
        return 1;
    }
    host->window->setTitle(QGuiApplication::applicationDisplayName());
    auto resized = [] { host->relayout(); };
    QObject::connect(host->window, &QQuickWindow::widthChanged, host->window, resized);
    QObject::connect(host->window, &QQuickWindow::heightChanged, host->window, resized);
    // The app chooses its colours for the platform's, and icons follow.
    QObject::connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, host->window, [] {
        host->retint();
        hatter_qt_redraw(host->app.ctx);
    });
    host->window->installEventFilter(new Back);
    // Shown while the window is, as Android's activity between Start and Stop.
    const auto lifecycle = [](int event) { host->app.lifecycle(host->app.ctx, event); };
    QObject::connect(host->window, &QWindow::visibilityChanged, host->window,
                     [lifecycle, shown = true](QWindow::Visibility visibility) mutable {
                         const bool now = visibility != QWindow::Minimized && visibility != QWindow::Hidden;
                         if (now != shown) {
                             shown = now;
                             if (now) {
                                 lifecycle(Start);
                                 lifecycle(Resume);
                             } else {
                                 lifecycle(Pause);
                                 lifecycle(Stop);
                             }
                         }
                     });
    lifecycle(Create);
    lifecycle(Start);
    lifecycle(Resume);
    host->app.render(host->app.ctx);
    const int status = QGuiApplication::exec();
    lifecycle(Pause);
    lifecycle(Stop);
    lifecycle(Destroy);
    return status;
}

} // extern "C"
