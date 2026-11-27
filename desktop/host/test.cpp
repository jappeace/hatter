// The host's tests, on Qt's offscreen platform: what the user would see or
// lose, through Hatter's bridge calls where they reach it.

#include <QBuffer>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QImageWriter>
#include <QPair>
#include <QQmlProperty>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScreen>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QThread>

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <vector>

#include "host.h"
#include "node.h"
#include "platform.h"
#ifdef Q_OS_WIN
#include "toasts_win.h"
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

namespace {

int failures = 0;

void check(bool ok, const char *what)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    failures += ok ? 0 : 1;
}

// Waits for Qt's events until done, or a few seconds.
bool waitFor(const std::function<bool()> &done)
{
    QElapsedTimer timer;
    timer.start();
    while (!done() && timer.elapsed() < 5000) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
    }
    return done();
}

QQuickItem *contentOf(int id)
{
    return host->nodes.at(id)->content;
}

// A node of a kind showing some text, as wide as Qt Quick draws it. A text
// input is the one of many lines, as wide as its text (one line isn't).
double textWidth(int type, const QByteArray &text)
{
    UIBridgeCallbacks *ui = hatter_qt_ui();
    const int id = ui->createNode(type);
    if (type == UI_NODE_TEXT_INPUT) {
        ui->setNumProp(id, UI_PROP_INPUT_TYPE, 2);
    }
    ui->setStrProp(id, UI_PROP_TEXT, text.constData());
    return contentOf(id)->implicitWidth();
}

// The item of that name under an item, where a Repeater puts what it makes.
QQuickItem *named(QQuickItem *item, const QString &name)
{
    if (!item || item->objectName() == name) {
        return item;
    }
    for (QQuickItem *child : item->childItems()) {
        if (QQuickItem *found = named(child, name)) {
            return found;
        }
    }
    return nullptr;
}

// Markup in a peer's text is shown as it is, as on Android: its tags add
// to its width.
void plainText()
{
    // Wider than a field is at least, whatever the font.
    const char *name = "a name long enough to be wider than an empty field";
    for (int type : {UI_NODE_TEXT, UI_NODE_BUTTON, UI_NODE_TEXT_INPUT}) {
        const double marked = textWidth(type, QByteArray("<b>").append(name).append("</b>")), plain = textWidth(type, name);
        check(marked - plain > 20,
              qPrintable(QStringLiteral("markup in a node's text shows as text (%1 against %2)").arg(marked).arg(plain)));
    }
    auto width = [](const char *kind, const char *property, const char *text, const char *part) {
        QObject *popup = host->create(kind, {{QStringLiteral("parent"),
                                              QVariant::fromValue(host->window->contentItem())}});
        const QString value = QString::fromUtf8(text);
        popup->setProperty(property, property == QLatin1String("items") ? QVariant(QStringList{value}) : value);
        QCoreApplication::processEvents();
        auto *item = qobject_cast<QQuickItem *>(popup->property(part).value<QObject *>());
        if (!item) {
            item = named(popup->property("contentItem").value<QQuickItem *>(), QString::fromLatin1(part));
        }
        const double width = item ? item->implicitWidth() : 0;
        delete popup;
        return width;
    };
    check(width("Dialog", "title", "<b>name</b>", "header") - width("Dialog", "title", "name", "header") > 20,
          "markup in a dialog's title shows as text");
    check(width("Dialog", "message", "<b>name</b>", "message") - width("Dialog", "message", "name", "message") > 20,
          "markup in a dialog's message shows as text");
    check(width("Sheet", "title", "<b>name</b>", "header") - width("Sheet", "title", "name", "header") > 20,
          "markup in a sheet's title shows as text");
    check(width("Sheet", "items", "<b>name</b>", "item") - width("Sheet", "items", "name", "item") > 20,
          "markup in a sheet's choices shows as text");
}

// Notification servers show markup in bodies, so a peer's text goes
// escaped.
void notificationText()
{
    check(notificationBody(QStringLiteral("<b>a</b> & b")) == QStringLiteral("&lt;b&gt;a&lt;/b&gt; &amp; b"),
          "a notification's body is escaped");
}

QByteArray contents(const QString &path)
{
    QFile file(path);
    return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray("(none)");
}

void write(const QString &path, const QByteArray &bytes)
{
    QFile file(path);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(bytes);
    }
}

// Saving over a file the user chose keeps it until the new one is whole.
void saving(const QTemporaryDir &dir)
{
    const QString target = dir.filePath(QStringLiteral("saved")), source = dir.filePath(QStringLiteral("new"));
    write(target, "old");
    check(!replaceWith(dir.filePath(QStringLiteral("missing")), target) && contents(target) == "old",
          "a save that can't be made leaves the file it would replace");
    write(source, "new");
    const auto owner = QFileDevice::ReadOwner | QFileDevice::WriteOwner;
    QFile::setPermissions(source, owner);
    check(replaceWith(source, target) && contents(target) == "new", "a save replaces the file");
    // On Windows a file is as private as its folder, which Qt's permissions
    // don't show.
#ifndef Q_OS_WIN
    check((QFile::permissions(target) & ~(owner | QFileDevice::ReadUser | QFileDevice::WriteUser)) == 0,
          "a saved file is as private as the app's");
#endif
}

// Picked files are copied without holding up the window, then handed to
// the app on its thread.
void picking(const QTemporaryDir &dir)
{
    const QString picked = dir.filePath(QStringLiteral("picked file.txt"));
    write(picked, "picked");
    bool called = false, onGuiThread = false;
    QString copy;
    copyPicked({picked}, [&](const QString &path, const QString &name, qint64 size) {
        called = true;
        onGuiThread = QThread::currentThread() == qApp->thread();
        copy = path;
        std::ignore = name;
        std::ignore = size;
    });
    check(!called, "a picked file is copied after the call returns");
    // Nix's macOS builds have no home, where Qt keeps caches whatever $HOME
    // says.
    const QString cache = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    if (!QDir().mkpath(cache)) {
        std::printf("skip the copy reaches the app: %s can't be made\n", qPrintable(cache));
        return;
    }
    check(waitFor([&] { return called; }) && onGuiThread && contents(copy) == "picked",
          "the copy reaches the app on its thread");
}

// The database key is made once, only the user can read it, and once
// kept it's the one used.
void databaseKey()
{
    // Nix's macOS builds have no home, where Qt keeps the app's data.
    const QString dir = QString::fromUtf8(hatter_qt_files_dir());
    if (!QFileInfo(dir).isDir()) {
        std::printf("skip the database key: %s can't be made\n", qPrintable(dir));
        return;
    }
    const QString path = dir + QStringLiteral("/database.key");
    QFile::remove(path);
    uint8_t first[32] = {}, again[32] = {};
    check(hatter_qt_database_key(first) && hatter_qt_database_key(again) && memcmp(first, again, 32) == 0
              && contents(path).size() == 32,
          "the database key is made once");
    // On Windows it's as private as the user's folder it's in.
#ifndef Q_OS_WIN
    check((QFile::permissions(path) & ~(QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ReadUser
                                        | QFileDevice::WriteUser)) == 0,
          "only the user can read the database key");
#endif
    const QByteArray other(32, 'k');
    QFile::remove(path);
    write(path, other);
    check(hatter_qt_database_key(again) && QByteArray(reinterpret_cast<const char *>(again), 32) == other,
          "a kept database key is used, not made again");
}

#ifdef Q_OS_WIN
// Windows takes a toast from the host, and takes it away again. Where the
// app may not show them, all the rest is still done.
void toasts()
{
    const std::wstring id = L"Hatter.hatter-qt-host-test";
    Toasts toasts(id, L"Hatter's host test");
    const std::string stopped =
        toasts.show(L"test",
                    L"<toast><visual><binding template=\"ToastGeneric\"><text>Test</text><text>a toast</text>"
                    L"</binding></visual></toast>",
                    [] {});
    if (stopped.rfind(Toasts::notAllowed(), 0) == 0) {
        std::printf("skip Windows shows a toast: %s\n", stopped.c_str());
    } else {
        check(stopped.empty(), ("Windows shows a toast" + (stopped.empty() ? "" : ": " + stopped)).c_str());
    }
    toasts.remove(L"test");
    // Not left registered for the user.
    RegDeleteKeyW(HKEY_CURRENT_USER, (L"Software\\Classes\\AppUserModelId\\" + id).c_str());
}
#endif

int screenLongest()
{
    const QScreen *screen = QGuiApplication::primaryScreen();
    return int(std::max(screen->size().width(), screen->size().height()) * screen->devicePixelRatio());
}

// Pictures are decoded at most as big as the screen, as on Android, and
// turned as their camera says.
void pictures(const QTemporaryDir &dir)
{
    UIBridgeCallbacks *ui = hatter_qt_ui();
    const int longest = screenLongest();
    QImage wide(longest * 3, 10, QImage::Format_RGB32);
    wide.fill(Qt::red);
    const QString file = dir.filePath(QStringLiteral("wide.png"));
    wide.save(file);
    int id = ui->createNode(UI_NODE_IMAGE);
    ui->setStrProp(id, UI_PROP_IMAGE_FILE, file.toUtf8().constData());
    check(contentOf(id)->implicitWidth() <= longest, "a picture file is decoded at most as wide as the screen");

    QByteArray png;
    QBuffer buffer(&png);
    buffer.open(QIODevice::WriteOnly);
    wide.save(&buffer, "PNG");
    id = ui->createNode(UI_NODE_IMAGE);
    ui->setImageData(id, reinterpret_cast<const uint8_t *>(png.constData()), int(png.size()));
    QImage shown = host->pictures->shown.value(host->nodes.at(id)->picture);
    check(!shown.isNull() && shown.width() <= longest, "picture bytes are decoded at most as wide as the screen");

    // Bounded by its longest side as it shows, turned.
    const QString big = dir.filePath(QStringLiteral("big turned.jpg"));
    QImageWriter bigWriter(big);
    bigWriter.setTransformation(QImageIOHandler::TransformationRotate90);
    bigWriter.write(wide);
    id = ui->createNode(UI_NODE_IMAGE);
    ui->setStrProp(id, UI_PROP_IMAGE_FILE, big.toUtf8().constData());
    check(contentOf(id)->implicitHeight() <= longest && contentOf(id)->implicitWidth() < contentOf(id)->implicitHeight(),
          "a turned photo is decoded at most as tall as the screen");

    QImage tall(40, 10, QImage::Format_RGB32);
    tall.fill(Qt::blue);
    const QString turned = dir.filePath(QStringLiteral("turned.jpg"));
    QImageWriter writer(turned);
    writer.setTransformation(QImageIOHandler::TransformationRotate90);
    writer.write(tall);
    id = ui->createNode(UI_NODE_IMAGE);
    ui->setStrProp(id, UI_PROP_IMAGE_FILE, turned.toUtf8().constData());
    check(contentOf(id)->implicitWidth() == 10 && contentOf(id)->implicitHeight() == 40,
          "a photo is shown turned as its camera says");

    // Shown with round corners, also where the window is drawn without GL.
    QImage square(40, 40, QImage::Format_RGB32);
    square.fill(Qt::red);
    png.clear();
    buffer.seek(0);
    square.save(&buffer, "PNG");
    id = ui->createNode(UI_NODE_IMAGE);
    ui->setImageData(id, reinterpret_cast<const uint8_t *>(png.constData()), int(png.size()));
    ui->setNumProp(id, UI_PROP_CORNER_RADIUS, 8);
    ui->setRoot(id);
    check(waitFor([] {
              const QImage drawn = host->window->grabWindow();
              return drawn.pixelColor(drawn.rect().center()) == QColor(Qt::red);
          }),
          "a picture with round corners shows");
}

// Copying says so, as Android's system does: the desktop's doesn't.
void copying()
{
    hatter_qt_ui()->copyText("669A6A99");
    const QObject *note = host->window->findChild<QObject *>(QStringLiteral("note"));
    check(note && note->property("visible").toBool() && note->property("text").toString() == QLatin1String("Copied"),
          "copying says so");
}

// Within a step or two of each other, as Qt Quick's blending may draw a
// colour: what isn't the background there is the dimmed window, far off.
bool nearly(const QColor &drawn, const QColor &colour)
{
    return std::abs(drawn.red() - colour.red()) <= 2 && std::abs(drawn.green() - colour.green()) <= 2
        && std::abs(drawn.blue() - colour.blue()) <= 2;
}

// Whether a popup's background shows near its right edge, part of the way
// down it, and what shows there against what should.
QPair<bool, QString> backgroundShows(QObject *popup, double down)
{
    auto *background = popup->property("background").value<QQuickItem *>();
    const QColor colour =
        QQmlProperty::read(popup, QStringLiteral("Material.dialogColor"), qmlContext(popup)).value<QColor>();
    QColor seen;
    const bool shows = background && waitFor([&] {
        const QPointF at = background->mapToScene({background->width() - 10, background->height() * down});
        seen = host->window->grabWindow().pixelColor(at.toPoint());
        return nearly(seen, colour);
    });
    return {shows, QStringLiteral(" (%1 against %2)").arg(seen.name(QColor::HexArgb), colour.name(QColor::HexArgb))};
}

// Material draws these backgrounds with shadows, which need GL: also
// without it they show where they are.
void backgrounds()
{
    const QVariantMap inWindow{{QStringLiteral("parent"), QVariant::fromValue(host->window->contentItem())}};
    QObject *sheet = host->create("Sheet", inWindow);
    sheet->setProperty("items", QStringList{QStringLiteral("a"), QStringLiteral("b")});
    QMetaObject::invokeMethod(sheet, "open");
    const auto [sheetShows, sheetSeen] = backgroundShows(sheet, 0.8);
    check(sheetShows, qPrintable(QStringLiteral("a sheet's background shows behind its choices") + sheetSeen));
    delete sheet;

    QObject *dialog = host->create("Dialog", inWindow);
    dialog->setProperty("message", QStringLiteral("m"));
    QMetaObject::invokeMethod(dialog, "open");
    const auto [dialogShows, dialogSeen] = backgroundShows(dialog, 0.5);
    check(dialogShows, qPrintable(QStringLiteral("a dialog's background shows behind its message") + dialogSeen));
    delete dialog;

    UIBridgeCallbacks *ui = hatter_qt_ui();
    const int id = ui->createNode(UI_NODE_BUTTON);
    ui->setStrProp(id, UI_PROP_BG_COLOR, "#FFFF0000");
    ui->setRoot(id);
    check(waitFor([] {
              const QImage drawn = host->window->grabWindow();
              return drawn.pixelColor(drawn.rect().center()) == QColor(Qt::red);
          }),
          "a button's background shows where it is");
}

} // namespace

// A switch shows what the app says, and tells it only of the user's flips:
// else the app setting it would hear a flip.
int flips = 0;

void switches()
{
    auto *was = host->app.event;
    host->app.event = [](void *, int32_t callback) { flips += callback == 7; };
    UIBridgeCallbacks *ui = hatter_qt_ui();
    const int id = ui->createNode(UI_NODE_SWITCH);
    ui->setHandler(id, UI_EVENT_CLICK, 7);
    ui->setNumProp(id, UI_PROP_CHECKED, 1);
    check(contentOf(id)->property("checked").toBool() && flips == 0, "a switch shows what the app says, quietly");
    QMetaObject::invokeMethod(contentOf(id), "click");
    check(flips == 1, "a switch tells the app when the user flips it");
    host->app.event = was;
}

// The fake app's items by key, the text node each row shows its key in,
// and how many rows it was asked to fill.
std::vector<qint64> keys;
std::map<int, int> texts;
int binds = 0;

// Whether a row of the list shows the item, where the user sees it.
bool shows(int list, qint64 key)
{
    const QQuickItem *view = host->nodes.at(list);
    const QRectF seen = view->mapRectToScene(view->boundingRect());
    for (const auto &[row, id] : texts) {
        const QQuickItem *text = host->nodes.at(id);
        if (contentOf(id)->property("text").toString() == QString::number(key) && text->isVisible()
            && seen.intersects(text->mapRectToScene(text->boundingRect()))) {
            return true;
        }
    }
    return false;
}

// A long lazy list makes rows only for the items that show, as Android's:
// else a long chat takes the time and memory of all of them to open, and
// to render again.
void lists()
{
    host->app.key = [](void *, int32_t, int32_t position) -> int64_t { return keys.at(position); };
    host->app.bind = [](void *, int32_t, int32_t row, int32_t position) -> int32_t {
        UIBridgeCallbacks *ui = hatter_qt_ui();
        ++binds;
        if (row == 0) {
            row = ui->createNode(UI_NODE_COLUMN);
            texts[row] = ui->createNode(UI_NODE_TEXT);
            ui->addChild(row, texts[row]);
        }
        ui->setStrProp(texts[row], UI_PROP_TEXT, QByteArray::number(keys.at(position)).constData());
        return row;
    };
    for (qint64 key = 0; key < 10000; ++key) {
        keys.push_back(key);
    }
    UIBridgeCallbacks *ui = hatter_qt_ui();
    const int list = ui->createNode(UI_NODE_LAZY_COLUMN);
    ui->setNumProp(list, UI_PROP_KEEP_AT_END, 1);
    ui->setNumProp(list, UI_PROP_ITEM_COUNT, double(keys.size()));
    ui->setRoot(list);
    check(waitFor([list] { return shows(list, 9999); }) && binds < 100,
          "a long list kept at its end shows its last item, with rows for few");
    binds = 0;
    keys.push_back(10000);
    ui->setNumProp(list, UI_PROP_ITEM_COUNT, double(keys.size()));
    check(waitFor([list] { return shows(list, 10000); }) && binds < 100,
          "an item added shows at its end, again with rows for few");
}

// The other side's video shows in the image nodes showing its stream.
void callVideo()
{
    UIBridgeCallbacks *ui = hatter_qt_ui();
    const int id = ui->createNode(UI_NODE_IMAGE);
    ui->setStrProp(id, UI_PROP_IMAGE_STREAM, "far");
    ui->setRoot(id);
    // Red, in BT.601's Y, U and V.
    const int width = 64, height = 48, pixels = width * height;
    std::vector<uint8_t> frame(pixels * 3 / 2, 81);
    std::fill(frame.begin() + pixels, frame.begin() + pixels * 5 / 4, 90);
    std::fill(frame.begin() + pixels * 5 / 4, frame.end(), 240);
    hatter_qt_call_video_show("far", width, height, frame.data(), int(frame.size()));
    check(waitFor([] {
              const QImage drawn = host->window->grabWindow();
              const QColor middle = drawn.pixelColor(drawn.rect().center());
              return middle.red() > 200 && middle.green() < 40 && middle.blue() < 40;
          }),
          "a call's video shows where its stream is");
}

// The camera opens over the window for a picture, and closing it hands
// the app nothing.
bool capturedAny = false;

void capturing()
{
    host->app.picked = [](void *, const char *, const char *, int64_t) { capturedAny = true; };
    hatter_qt_ui()->capturePicture();
    check(waitFor([] { return host->popups == 1; }), "the camera opens for a picture");
    QObject *camera = host->window->findChild<QObject *>(QStringLiteral("camera"));
    check(camera && QMetaObject::invokeMethod(camera, "close") && waitFor([] { return host->popups == 0; })
              && !capturedAny,
          "the camera closed hands on no picture");
}

// What the microphone gave a call: frames, their sizes, how loud, and any
// after the call stopped.
std::atomic<int> heard{0}, wrongSize{0}, loudest{0}, late{0};
std::atomic<bool> stopped{false};

// A call's audio played is heard back, in frames of the call's size. The
// tests' audio server records what it plays.
void callAudio()
{
    const int rate = 48000, frame = 960;
    hatter_qt_call_audio_start(rate, frame, 0, [](const int16_t *samples, int count) {
        late += stopped ? 1 : 0;
        heard += 1;
        wrongSize += count == 960 ? 0 : 1;
        for (int i = 0; i < count; ++i) {
            loudest = std::max(loudest.load(), std::abs(int(samples[i])));
        }
    }, nullptr);
    std::vector<int16_t> tone(frame);
    for (int i = 0; i < frame; ++i) {
        tone[i] = int16_t(8000 * std::sin(2 * M_PI * 400 * i / rate));
    }
    // Played until it's heard a while, as the audio server may be slow to
    // start.
    QElapsedTimer timer;
    timer.start();
    while ((heard < 50 || loudest <= 4000) && timer.elapsed() < 10000) {
        if (hatter_qt_call_audio_play(rate, 1, tone.data(), frame) < 100) {
            continue;
        }
        QThread::msleep(20);
    }
    hatter_qt_call_audio_stop();
    stopped = true;
    QThread::msleep(200);
    check(heard >= 50 && wrongSize == 0, "a call's microphone comes in frames of the call's size");
    check(loudest > 4000, "what a call plays is heard");
    check(late == 0, "no frame comes once a call's audio stops");
}

std::vector<double> frames;

// An animation's frames come one after another as the screen shows them,
// not all at once, and none once the app stops it in one.
void animation()
{
    host->app.frame = [](void *, double timestampMs) {
        frames.push_back(timestampMs);
        if (frames.size() == 3) {
            hatter_qt_animation_stop();
        }
    };
    hatter_qt_animation_start(nullptr);
    check(frames.empty(), "an animation's frames come after it starts");
    check(waitFor([] { return frames.size() >= 3; }) && frames[0] < frames[1] && frames[1] < frames[2],
          "its frames come one after another");
    QElapsedTimer timer;
    timer.start();
    while (timer.elapsed() < 200) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
    }
    check(frames.size() == 3, "no frames come once it stops");
}

// The window draws, also on a system with no GL driver for Qt to find.
void drawn()
{
    bool swapped = false;
    const QMetaObject::Connection drawing =
        QObject::connect(host->window, &QQuickWindow::frameSwapped, host->window, [&swapped] { swapped = true; });
    host->window->update();
    check(waitFor([&swapped] { return swapped; }), "the window draws");
    QObject::disconnect(drawing);
    // Here by the CPU where the tests have no GL driver, as in Nix's Linux
    // builds; on macOS and Windows by the system's own.
    const QByteArray graphics = hatter_qt_device().graphics;
    check(qEnvironmentVariableIsSet("HATTER_TEST_NO_GL") ? graphics == "software" : !graphics.isEmpty(),
          "the device says what draws the window");
}

int main(int argc, char *argv[])
{
    // The app's folders in test ones, not the user's.
    QStandardPaths::setTestModeEnabled(true);
    hatter_qt_init(&argc, argv);
    host->window = qobject_cast<QQuickWindow *>(host->create("Window"));
    drawn();
    QTemporaryDir dir;
    plainText();
    notificationText();
    saving(dir);
    databaseKey();
#ifdef Q_OS_WIN
    toasts();
#endif
    picking(dir);
    pictures(dir);
    backgrounds();
    copying();
    lists();
    switches();
    callVideo();
    capturing();
    // Only with an audio server that records what it plays, as the tests'.
    if (qEnvironmentVariableIsSet("HATTER_TEST_AUDIO")) {
        callAudio();
    }
    animation();
    std::printf("%d failed\n", failures);
    return failures == 0 ? 0 : 1;
}
