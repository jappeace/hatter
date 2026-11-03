/*
 * A Hatter app's program on Qt. The app's Main module has the same
 * main :: IO (Ptr AppContext) as on Android, and is linked with -no-hs-main:
 * this starts Qt and the app, as Android's activity does, and shows the app.
 */

#include <stdint.h>

#include "CallAudioBridge.h"
#include "CallVideoBridge.h"
#include "PermissionBridge.h"
#include "Rts.h"
#include "hatter_qt.h"

/* Hatter's bridges (cbits/). */
void redraw_register_impl(void (*impl)(void *));
void animation_register_impl(void (*start)(void *), void (*stop)(void));
void dialog_register_impl(void (*show)(void *, int32_t, const char *, const char *, const char *, const char *,
                                       const char *));
void bottom_sheet_register_impl(void (*show)(void *, int32_t, const char *, const char *));
void picture_register_impl(uint8_t *(*pixels)(const char *, int32_t, int32_t *, int32_t *),
                           int32_t (*shrink)(const char *, const char *, int32_t));
void location_register_impl(void (*start)(void *), void (*stop)(void));
void permission_register_impl(void (*request)(void *, int32_t, int32_t), int32_t (*check)(int32_t));
void notification_register_impl(void (*show)(const char *, const char *, const char *, const char *, const char *,
                                             int),
                                void (*cancel)(const char *));
void notification_register_status(void (*status)(const char *));
void notification_register_background(void (*run)(int), void (*stop)(void));
void notification_register_ongoing(void (*ongoing)(const char *, const char *, long long));
void notification_register_lock_screen(void (*over)(int), int (*allowed)(void), void (*allow)(void));
void notification_register_keep_screen_on(void (*keep)(int));
void setAppFilesDir(const char *path);
void setDatabaseKey(const unsigned char *key, size_t length);
void setDatabaseKeyFailed(void);
void setDeviceModel(const char *value);
void setDeviceOsVersion(const char *value);
void setDeviceScreenDensity(const char *value);
void setDeviceScreenWidth(const char *value);
void setDeviceScreenHeight(const char *value);
void setDeviceGraphics(const char *value);

/* Hatter's entry points for platforms (Hatter.hs). */
void haskellRenderUI(void *ctx);
void haskellOnUIEvent(void *ctx, int32_t callbackId);
void haskellOnUITextChange(void *ctx, int32_t callbackId, const char *text);
void haskellOnUIScroll(void *ctx, int32_t callbackId, int32_t position);
int32_t haskellOnLazyBind(void *ctx, int32_t listId, int32_t rowId, int32_t position);
int64_t haskellLazyItemKey(void *ctx, int32_t listId, int32_t position);
void haskellOnLifecycle(void *ctx, int32_t event);
int32_t haskellOnBack(void *ctx);
void haskellOnDialogResult(void *ctx, int32_t requestId, int32_t action);
void haskellOnBottomSheetResult(void *ctx, int32_t requestId, int32_t action);
void haskellOnFilePicked(void *ctx, const char *path, const char *name, int64_t size);
void haskellOnPicturePicked(void *ctx, const uint8_t *png, int32_t length);
void haskellOnNotificationOpened(void *ctx, const char *key);
void haskellOnPermissionResult(void *ctx, int32_t requestId, int32_t status);
void haskellOnAnimationFrame(void *ctx, double timestampMs);

/* The program's Main.main. */
extern StgClosure ZCMain_main_closure;

/* Runs the app's main, for its context, as cbits/run_main.c does. */
static void *start_app(void)
{
    Capability *cap = rts_lock();
    HaskellObj result;
    rts_evalIO(&cap, &ZCMain_main_closure, &result);
    rts_checkSchedStatus("start_app", cap);
    void *ctx = rts_getPtr(result);
    rts_unlock(cap);
    return ctx;
}

/* A desktop has no location to give. */
static int32_t permitted(int32_t code)
{
    return code == PERMISSION_LOCATION ? PERMISSION_DENIED : PERMISSION_GRANTED;
}

static void permit(void *ctx, int32_t code, int32_t requestId)
{
    haskellOnPermissionResult(ctx, requestId, permitted(code));
}

/* A desktop has no location to give. */
static void no_location(void *ctx)
{
    (void)ctx;
}

static void no_updates(void)
{
}

/* A desktop program has no foreground service, its window is how it shows
 * that it runs, and there is no lock screen for calls. */
static void no_status(const char *text)
{
    (void)text;
}

static void no_switch(int on)
{
    (void)on;
}

static void no_ongoing(const char *key, const char *title, long long since)
{
    (void)key;
    (void)title;
    (void)since;
}

static int allowed(void)
{
    return 1;
}

int main(int argc, char *argv[])
{
    /* The runtime takes its options (+RTS ... -RTS) before Qt sees them. */
    RtsConfig conf = defaultRtsConfig;
    conf.rts_opts_enabled = RtsOptsAll;
    hs_init_ghc(&argc, &argv, conf);
    hatter_qt_init(&argc, argv);

    setAppFilesDir(hatter_qt_files_dir());
    HatterQtDevice device = hatter_qt_device();
    setDeviceModel(device.model);
    setDeviceOsVersion(device.osVersion);
    setDeviceScreenDensity(device.density);
    setDeviceScreenWidth(device.width);
    setDeviceScreenHeight(device.height);
    setDeviceGraphics(device.graphics);
    uint8_t key[32];
    if (hatter_qt_database_key(key)) {
        setDatabaseKey(key, sizeof key);
    } else {
        setDatabaseKeyFailed();
    }

    ui_register_callbacks(hatter_qt_ui());
    redraw_register_impl(hatter_qt_redraw);
    animation_register_impl(hatter_qt_animation_start, hatter_qt_animation_stop);
    dialog_register_impl(hatter_qt_dialog);
    bottom_sheet_register_impl(hatter_qt_sheet);
    picture_register_impl(hatter_qt_picture_pixels, hatter_qt_picture_shrink);
    location_register_impl(no_location, no_updates);
    permission_register_impl(permit, permitted);
    notification_register_impl(hatter_qt_notify, hatter_qt_unnotify);
    notification_register_status(no_status);
    notification_register_background(no_switch, no_updates);
    notification_register_ongoing(no_ongoing);
    notification_register_lock_screen(no_switch, allowed, no_updates);
    notification_register_keep_screen_on(no_switch);
    call_audio_register_impl(hatter_qt_call_audio_start, hatter_qt_call_audio_stop, hatter_qt_call_audio_play,
                             hatter_qt_call_audio_route);
    call_audio_register_tone(hatter_qt_call_audio_tone);
    call_video_register_impl(hatter_qt_call_video_camera_start, hatter_qt_call_video_camera_stop,
                             hatter_qt_call_video_show);

    HatterQtApp app = {
        .ctx = start_app(),
        .render = haskellRenderUI,
        .event = haskellOnUIEvent,
        .text = haskellOnUITextChange,
        .scroll = haskellOnUIScroll,
        .bind = haskellOnLazyBind,
        .key = haskellLazyItemKey,
        .lifecycle = haskellOnLifecycle,
        .back = haskellOnBack,
        .dialog = haskellOnDialogResult,
        .sheet = haskellOnBottomSheetResult,
        .picked = haskellOnFilePicked,
        .picture = haskellOnPicturePicked,
        .notified = haskellOnNotificationOpened,
        .frame = haskellOnAnimationFrame,
    };
    int status = hatter_qt_run(&app);
    hs_exit();
    return status;
}
