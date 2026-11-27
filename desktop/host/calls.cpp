// Calls' audio and video (CallAudioBridge.h, CallVideoBridge.h) with Qt
// Multimedia: the microphone in frames, the other side's audio played as it
// comes, the tones around calls, the camera's frames, and frames shown.

#include <QAudioFormat>
#include <QAudioSink>
#include <QAudioSource>
#include <QCamera>
#include <QCameraDevice>
#include <QCoreApplication>
#include <QIODevice>
#include <QMediaCaptureSession>
#include <QMediaDevices>
#include <QMutex>
#include <QThread>
#include <QVideoFrame>
#include <QVideoSink>

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

#include "CallAudioBridge.h"
#include "CallVideoBridge.h"
#include "hatter_qt.h"
#include "host.h"

namespace {

// Runs f on the object's thread and waits for it.
template <typename F> void on(QObject *object, F f)
{
    if (QThread::currentThread() == object->thread()) {
        f();
    } else {
        QMetaObject::invokeMethod(object, f, Qt::BlockingQueuedConnection);
    }
}

QAudioFormat mono16(int rate, int channels = 1)
{
    QAudioFormat format;
    format.setSampleRate(rate);
    format.setChannelCount(channels);
    format.setSampleFormat(QAudioFormat::Int16);
    return format;
}

// A tone's notes, in Hz and seconds, played in turn and again from the
// start, as the browser's: two rising notes coming in, and a second of
// 425 Hz in every five going out, as most of Europe rings back.
struct Note {
    double hz, seconds;
};
const std::vector<Note> ringtone{{659, 0.4}, {880, 0.4}, {0, 2}};
const std::vector<Note> ringback{{425, 1}, {0, 4}};

// Samples of a tone, over and over.
class Loop : public QIODevice {
public:
    Loop(const std::vector<Note> &notes, int rate, QObject *parent) : QIODevice(parent)
    {
        for (const Note &note : notes) {
            const int length = int(note.seconds * rate);
            // Fading in and out over 10 ms, so it doesn't click.
            const double fade = std::min(length / 2.0, rate / 100.0);
            for (int i = 0; i < length; ++i) {
                const double level = note.hz > 0 ? std::min({1.0, i / fade, (length - i) / fade}) : 0;
                samples.push_back(int16_t(0.2 * 32767 * level * std::sin(2 * M_PI * note.hz * i / rate)));
            }
        }
        open(QIODevice::ReadOnly);
    }

protected:
    qint64 readData(char *data, qint64 size) override
    {
        auto *out = reinterpret_cast<int16_t *>(data);
        const qint64 count = size / qint64(sizeof(int16_t));
        for (qint64 i = 0; i < count; ++i) {
            out[i] = samples[at];
            at = (at + 1) % samples.size();
        }
        return count * qint64(sizeof(int16_t));
    }
    qint64 writeData(const char *, qint64) override { return -1; }
    qint64 bytesAvailable() const override { return std::numeric_limits<qint64>::max(); }

private:
    std::vector<int16_t> samples;
    size_t at = 0;
};

// A call's audio, on a thread of its own: the bridge is called from any
// thread, and gives the microphone's frames on its recording thread.
class Voice : public QObject {
public:
    void start(int rate, int frameSamples, call_audio_frame_cb frame, call_audio_routes_cb routes)
    {
        stop();
        onFrame = frame;
        frameBytes = frameSamples * int(sizeof(int16_t));
        source = new QAudioSource(QMediaDevices::defaultAudioInput(), mono16(rate), this);
        recording = source->start();
        if (recording) {
            connect(recording, &QIODevice::readyRead, this, &Voice::recorded);
        }
        // A desktop's audio goes where the desktop sends it.
        if (routes) {
            routes(CALL_AUDIO_SPEAKER, 1 << CALL_AUDIO_SPEAKER);
        }
    }

    void stop()
    {
        delete source;
        source = nullptr;
        recording = nullptr;
        heard.clear();
        onFrame = nullptr;
        delete sink;
        sink = nullptr;
        playing = nullptr;
    }

    // Returns the milliseconds of audio waiting to be played.
    int play(int rate, int channels, const int16_t *samples, int count)
    {
        const QAudioFormat format = mono16(rate, channels);
        if (!sink || sink->format() != format) {
            delete sink;
            sink = new QAudioSink(QMediaDevices::defaultAudioOutput(), format, this);
            // Room for a jitter buffer's worth, as the other side's audio comes.
            sink->setBufferSize(format.bytesForDuration(500000));
            playing = sink->start();
        }
        if (!playing) {
            return 0;
        }
        // What doesn't fit is late already, and dropped.
        playing->write(reinterpret_cast<const char *>(samples), qint64(count) * qint64(sizeof(int16_t)));
        return int(format.durationForBytes(sink->bufferSize() - sink->bytesFree()) / 1000);
    }

    void tone(int which)
    {
        delete ringing;
        ringing = nullptr;
        const std::vector<Note> *notes = which == 1 ? &ringtone : which == 2 ? &ringback : nullptr;
        if (!notes) {
            return;
        }
        const QAudioDevice device = QMediaDevices::defaultAudioOutput();
        const int rate = device.preferredFormat().sampleRate() > 0 ? device.preferredFormat().sampleRate() : 48000;
        ringing = new QAudioSink(device, mono16(rate), this);
        ringing->start(new Loop(*notes, rate, ringing));
    }

private:
    QAudioSource *source = nullptr;
    QIODevice *recording = nullptr;
    QByteArray heard;
    int frameBytes = 0;
    call_audio_frame_cb onFrame = nullptr;
    QAudioSink *sink = nullptr;
    QIODevice *playing = nullptr;
    QAudioSink *ringing = nullptr;

    void recorded()
    {
        heard += recording->readAll();
        qsizetype at = 0;
        for (; onFrame && heard.size() - at >= frameBytes; at += frameBytes) {
            onFrame(reinterpret_cast<const int16_t *>(heard.constData() + at), frameBytes / int(sizeof(int16_t)));
        }
        heard.remove(0, at);
    }
};

Voice *voice()
{
    static Voice *const made = [] {
        auto *thread = new QThread;
        thread->setObjectName(QStringLiteral("hatter call audio"));
        thread->start();
        auto *voice = new Voice;
        voice->moveToThread(thread);
        return voice;
    }();
    return made;
}

uint8_t clamped(int value)
{
    return uint8_t(std::clamp(value, 0, 255));
}

// I420 as RGB, by BT.601 as video codecs give it.
QImage fromI420(const uint8_t *i420, int width, int height)
{
    QImage image(width, height, QImage::Format_RGB32);
    // Its colours each 2 by 2 pixels, rounded up.
    const int across = (width + 1) / 2;
    const uint8_t *ys = i420, *us = ys + width * height, *vs = us + across * ((height + 1) / 2);
    for (int y = 0; y < height; ++y) {
        auto *line = reinterpret_cast<QRgb *>(image.scanLine(y));
        for (int x = 0; x < width; ++x) {
            const int c = ys[y * width + x] - 16, half = (y / 2) * across + x / 2;
            const int d = us[half] - 128, e = vs[half] - 128;
            line[x] = qRgb(clamped((298 * c + 409 * e + 128) >> 8), clamped((298 * c - 100 * d - 208 * e + 128) >> 8),
                           clamped((298 * c + 516 * d + 128) >> 8));
        }
    }
    return image;
}

// A picture as I420, at even sides, its colours each 2 by 2 pixels'
// first.
std::vector<uint8_t> toI420(const QImage &picture)
{
    const QImage image = picture.convertToFormat(QImage::Format_RGB32);
    const int width = image.width() & ~1, height = image.height() & ~1;
    std::vector<uint8_t> i420(size_t(width) * height * 3 / 2);
    uint8_t *ys = i420.data(), *us = ys + width * height, *vs = us + (width / 2) * (height / 2);
    for (int y = 0; y < height; ++y) {
        const auto *line = reinterpret_cast<const QRgb *>(image.constScanLine(y));
        for (int x = 0; x < width; ++x) {
            const int r = qRed(line[x]), g = qGreen(line[x]), b = qBlue(line[x]);
            ys[y * width + x] = uint8_t(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
            if (y % 2 == 0 && x % 2 == 0) {
                const int half = (y / 2) * (width / 2) + x / 2;
                us[half] = uint8_t(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
                vs[half] = uint8_t(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
            }
        }
    }
    return i420;
}

// Frames for the GUI thread to show: only each stream's latest waits, so a
// busy window drops frames rather than falls behind.
QMutex waitingLock;
QHash<QString, QImage> waiting;

void showWaiting()
{
    QHash<QString, QImage> frames;
    {
        QMutexLocker locked(&waitingLock);
        frames.swap(waiting);
    }
    for (auto frame = frames.cbegin(); frame != frames.cend(); ++frame) {
        host->showFrame(frame.key(), frame.value());
    }
}

// The camera's frames for a call, on the GUI thread, which Qt Multimedia's
// objects are made on.
class Camera : public QObject {
public:
    Camera()
    {
        // As it comes, on whichever thread Qt gives it.
        connect(&sink, &QVideoSink::videoFrameChanged, this, [this](const QVideoFrame &frame) {
            QMutexLocker locked(&lock);
            if (onFrame && frame.isValid()) {
                const QImage image = frame.toImage();
                const std::vector<uint8_t> i420 = toI420(image);
                onFrame(i420.data(), int(i420.size()), image.width() & ~1, image.height() & ~1);
            }
        }, Qt::DirectConnection);
    }

    void start(bool front, call_video_frame_cb frame)
    {
        stop();
        QCameraDevice device = QMediaDevices::defaultVideoInput();
        for (const QCameraDevice &each : QMediaDevices::videoInputs()) {
            if (front == (each.position() == QCameraDevice::FrontFace)) {
                device = each;
                break;
            }
        }
        if (device.isNull()) {
            return;
        }
        {
            QMutexLocker locked(&lock);
            onFrame = frame;
        }
        camera = new QCamera(device, this);
        camera->setCameraFormat(callFormat(device));
        session.setCamera(camera);
        session.setVideoSink(&sink);
        camera->start();
    }

    void stop()
    {
        {
            QMutexLocker locked(&lock);
            onFrame = nullptr;
        }
        session.setCamera(nullptr);
        delete camera;
        camera = nullptr;
    }

private:
    QMediaCaptureSession session;
    QVideoSink sink;
    QCamera *camera = nullptr;
    // Held while a frame goes to the app, so none goes once it stops.
    QMutex lock;
    call_video_frame_cb onFrame = nullptr;

    // As near 640 by 480 as it has, at 15 frames a second or more, as
    // calls send.
    static QCameraFormat callFormat(const QCameraDevice &device)
    {
        QCameraFormat best;
        long long bestDistance = std::numeric_limits<long long>::max();
        for (const QCameraFormat &format : device.videoFormats()) {
            const long long distance = std::llabs(1LL * format.resolution().width() * format.resolution().height()
                                                  - 640 * 480);
            if (format.maxFrameRate() >= 15 && distance < bestDistance) {
                best = format;
                bestDistance = distance;
            }
        }
        return best;
    }
};

Camera *camera()
{
    static Camera *const made = new Camera;
    return made;
}

} // namespace

extern "C" {

void hatter_qt_call_video_camera_start(int front, call_video_frame_cb onFrame)
{
    on(qApp, [=] { camera()->start(front != 0, onFrame); });
}

void hatter_qt_call_video_camera_stop(void)
{
    on(qApp, [] { camera()->stop(); });
}

void hatter_qt_call_video_show(const char *key, int width, int height, const uint8_t *i420, int length)
{
    if (width <= 0 || height <= 0 || length < width * height + 2 * ((width + 1) / 2) * ((height + 1) / 2)) {
        return;
    }
    const QImage frame = fromI420(i420, width, height);
    QMutexLocker locked(&waitingLock);
    if (waiting.isEmpty()) {
        QMetaObject::invokeMethod(qApp, showWaiting, Qt::QueuedConnection);
    }
    waiting.insert(QString::fromUtf8(key), frame);
}

void hatter_qt_call_audio_start(int rate, int frameSamples, int, call_audio_frame_cb onFrame,
                                call_audio_routes_cb onRoutes)
{
    on(voice(), [=] { voice()->start(rate, frameSamples, onFrame, onRoutes); });
}

void hatter_qt_call_audio_stop(void)
{
    on(voice(), [] { voice()->stop(); });
}

int hatter_qt_call_audio_play(int rate, int channels, const int16_t *samples, int count)
{
    int waiting = 0;
    on(voice(), [&] { waiting = voice()->play(rate, channels, samples, count); });
    return waiting;
}

// A desktop's audio goes where the desktop sends it.
void hatter_qt_call_audio_route(int)
{
}

void hatter_qt_call_audio_tone(int tone)
{
    on(voice(), [=] { voice()->tone(tone); });
}

} // extern "C"
