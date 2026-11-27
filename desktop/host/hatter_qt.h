/*
 * Hatter's Qt Quick platform: the host shows an app's widgets as Qt Quick
 * items in a window. It doesn't link against the app: it calls the app
 * through the functions in HatterQtApp.
 */
#ifndef HATTER_QT_H
#define HATTER_QT_H

#include <stdint.h>

#include "CallAudioBridge.h"
#include "CallVideoBridge.h"
#include "UIBridge.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Hatter's entry points for platforms (the haskell* exports), and the
 * app's context to call them with. */
typedef struct HatterQtApp {
    void *ctx;
    void (*render)(void *ctx);
    void (*event)(void *ctx, int32_t callbackId);
    void (*text)(void *ctx, int32_t callbackId, const char *text);
    void (*scroll)(void *ctx, int32_t callbackId, int32_t position);
    int32_t (*bind)(void *ctx, int32_t listId, int32_t rowId, int32_t position);
    int64_t (*key)(void *ctx, int32_t listId, int32_t position);
    void (*lifecycle)(void *ctx, int32_t event);
    int32_t (*back)(void *ctx);
    void (*dialog)(void *ctx, int32_t requestId, int32_t action);
    void (*sheet)(void *ctx, int32_t requestId, int32_t action);
    void (*picked)(void *ctx, const char *path, const char *name, int64_t size);
    void (*picture)(void *ctx, const uint8_t *png, int32_t length);
    void (*notified)(void *ctx, const char *key);
    void (*frame)(void *ctx, double timestampMs);
} HatterQtApp;

/* What Hatter's DeviceInfo says, in its strings. */
typedef struct HatterQtDevice {
    const char *model;
    const char *osVersion;
    const char *density;
    const char *width;
    const char *height;
    const char *graphics;
} HatterQtDevice;

/* Starts Qt. Before the app starts, as it may ask about the platform then. */
void hatter_qt_init(int *argc, char **argv);

/* Where the app keeps its files, made if it wasn't there, in UTF-8. */
const char *hatter_qt_files_dir(void);

/* The device, and the window's size when it opens. */
HatterQtDevice hatter_qt_device(void);

/* The app's 32-byte database key, from a file only the user can read,
 * made the first time. 0 if there is none. */
int hatter_qt_database_key(uint8_t key[32]);

/* Where the app's icons are, its Android vector drawables (<name>.xml). */
void hatter_qt_set_resources(const char *dir);

/* The UI bridge's callbacks, for ui_register_callbacks. */
UIBridgeCallbacks *hatter_qt_ui(void);

/* For redraw_register_impl: renders on the UI thread, from any thread. */
void hatter_qt_redraw(void *ctx);

/* For dialog_register_impl and bottom_sheet_register_impl. */
void hatter_qt_dialog(void *ctx, int32_t requestId, const char *title, const char *message,
                      const char *button1, const char *button2, const char *button3);
void hatter_qt_sheet(void *ctx, int32_t requestId, const char *title, const char *items);

/* For picture_register_impl: a picture's RGBA pixels, halved until there
 * are at most so many (malloc'd), and a picture written again no longer
 * than so many pixels, 1 as JPEG, 2 as PNG, 0 if it isn't one. */
uint8_t *hatter_qt_picture_pixels(const char *path, int32_t most, int32_t *width, int32_t *height);
int32_t hatter_qt_picture_shrink(const char *path, const char *out, int32_t longest);

/* For notification_register_impl: from any thread. */
void hatter_qt_notify(const char *key, const char *channel, const char *icon, const char *title,
                      const char *text, int kind);
void hatter_qt_unnotify(const char *key);

/* For animation_register_impl: the app's frames at the screen's rate, on
 * the GUI thread, from the next one until stopped. */
void hatter_qt_animation_start(void *ctx);
void hatter_qt_animation_stop(void);

/* For call_audio_register_impl and call_audio_register_tone: a call's
 * audio from and to the desktop's default devices, from any thread. */
void hatter_qt_call_audio_start(int rate, int frameSamples, int speaker, call_audio_frame_cb onFrame,
                                call_audio_routes_cb onRoutes);
void hatter_qt_call_audio_stop(void);
int hatter_qt_call_audio_play(int rate, int channels, const int16_t *samples, int count);
void hatter_qt_call_audio_route(int route);
void hatter_qt_call_audio_tone(int tone);

/* For call_video_register_impl: the desktop's camera, upright, and frames
 * shown in the image nodes showing their stream, from any thread. */
void hatter_qt_call_video_camera_start(int front, call_video_frame_cb onFrame);
void hatter_qt_call_video_camera_stop(void);
void hatter_qt_call_video_show(const char *key, int width, int height, const uint8_t *i420, int length);

/* Shows the app, and runs until its window closes. */
int hatter_qt_run(const HatterQtApp *app);

#ifdef __cplusplus
}
#endif

#endif /* HATTER_QT_H */
