/*
 * The browser's callbacks for Hatter's bridges, which hand each call to the
 * page.
 */

#include <stddef.h>

#include "CallAudioBridge.h"
#include "CallVideoBridge.h"
#include "DialogBridge.h"
#include "UIBridge.h"

static UIBridgeCallbacks g_callbacks;

/* GHC's wasm callbacks take a few arguments at most, so the dialog's texts
 * come as one array: title, message and the three buttons. */
static void (*g_dialog)(int32_t, const char **);

static void show_dialog(void *ctx, int32_t requestId, const char *title,
                        const char *message, const char *button1,
                        const char *button2, const char *button3)
{
    const char *texts[] = {title, message, button1, button2, button3};
    g_dialog(requestId, texts);
}

void hatter_browser_register_dialog(void (*dialog)(int32_t, const char **))
{
    g_dialog = dialog;
    dialog_register_impl(show_dialog);
}

void hatter_browser_register_ui(
    int32_t (*create_node)(int32_t),
    void (*set_str_prop)(int32_t, int32_t, const char *),
    void (*set_num_prop)(int32_t, int32_t, double),
    void (*set_image_data)(int32_t, const uint8_t *, int32_t),
    void (*set_handler)(int32_t, int32_t, int32_t),
    void (*add_child)(int32_t, int32_t),
    void (*remove_child)(int32_t, int32_t),
    void (*destroy_node)(int32_t),
    void (*set_root)(int32_t),
    void (*clear)(void),
    int32_t (*dark_mode)(void),
    int32_t (*clock24)(void),
    void (*copy_text)(const char *),
    void (*open_uri)(const char *),
    void (*pick_file)(const char *),
    void (*pick_files)(const char *),
    void (*capture_picture)(void),
    void (*pick_picture)(const int32_t *, int32_t, int32_t),
    void (*save_file)(const char *, const char *, const char *),
    void (*open_file)(const char *),
    int32_t (*image_size)(const char *, int32_t *, int32_t *))
{
    g_callbacks.createNode = create_node;
    g_callbacks.setStrProp = set_str_prop;
    g_callbacks.setNumProp = set_num_prop;
    g_callbacks.setImageData = set_image_data;
    g_callbacks.setHandler = set_handler;
    g_callbacks.addChild = add_child;
    g_callbacks.removeChild = remove_child;
    g_callbacks.destroyNode = destroy_node;
    g_callbacks.setRoot = set_root;
    g_callbacks.clear = clear;
    g_callbacks.darkMode = dark_mode;
    g_callbacks.clock24 = clock24;
    g_callbacks.copyText = copy_text;
    g_callbacks.openUri = open_uri;
    g_callbacks.pickFile = pick_file;
    g_callbacks.pickFiles = pick_files;
    g_callbacks.capturePicture = capture_picture;
    g_callbacks.pickPicture = pick_picture;
    g_callbacks.saveFile = save_file;
    g_callbacks.openFile = open_file;
    g_callbacks.imageSize = image_size;
    ui_register_callbacks(&g_callbacks);
}

/* A call's audio: the page records and plays it. The frame and route
 * callbacks stay here, as GHC's wasm callbacks take few arguments. */
static call_audio_frame_cb g_on_frame;
static void (*g_audio_start)(int32_t, int32_t);
static void (*g_audio_stop)(void);

static void start_audio(int rate, int frame_samples, int speaker,
                        call_audio_frame_cb on_frame,
                        call_audio_routes_cb on_routes)
{
    (void)speaker;
    g_on_frame = on_frame;
    g_audio_start(rate, frame_samples);
    /* The page plays it where the device plays all its sound. */
    on_routes(CALL_AUDIO_SPEAKER, 1 << CALL_AUDIO_SPEAKER);
}

static void stop_audio(void)
{
    g_audio_stop();
    g_on_frame = NULL;
}

/* Chosen routes are the one there is. */
static void route_audio(int route)
{
    (void)route;
}

void hatter_browser_register_call_audio(
    void (*start)(int32_t, int32_t),
    void (*stop)(void),
    int (*play)(int, int, const int16_t *, int),
    int (*latency)(void),
    void (*tone)(int))
{
    g_audio_start = start;
    g_audio_stop = stop;
    call_audio_register_impl(start_audio, stop_audio, play, route_audio);
    call_audio_register_latency(latency);
    call_audio_register_tone(tone);
}

/* A frame the page recorded, for the call. */
void hatter_browser_call_audio_frame(const int16_t *samples, int count)
{
    if (g_on_frame) {
        g_on_frame(samples, count);
    }
}

/* A call's video: the page films and draws it. The camera's frame callback
 * stays here, and frames to draw come with one argument fewer. */
static call_video_frame_cb g_on_camera_frame;
static void (*g_camera_start)(int32_t);
static void (*g_camera_stop)(void);
static void (*g_show_frame)(const char *, int32_t, int32_t, const uint8_t *);

static void start_camera(int front, call_video_frame_cb on_frame)
{
    g_on_camera_frame = on_frame;
    g_camera_start(front);
}

static void stop_camera(void)
{
    g_camera_stop();
    g_on_camera_frame = NULL;
}

/* Only frames as long as I420 of their size is. */
static void show_frame(const char *key, int width, int height,
                       const uint8_t *i420, int length)
{
    int chroma = ((width + 1) / 2) * ((height + 1) / 2);
    if (width > 0 && height > 0 && length == width * height + 2 * chroma) {
        g_show_frame(key, width, height, i420);
    }
}

void hatter_browser_register_call_video(
    void (*start)(int32_t),
    void (*stop)(void),
    void (*show)(const char *, int32_t, int32_t, const uint8_t *))
{
    g_camera_start = start;
    g_camera_stop = stop;
    g_show_frame = show;
    call_video_register_impl(start_camera, stop_camera, show_frame);
}

/* A frame the page filmed, for the call. */
void hatter_browser_camera_frame(const uint8_t *i420, int length, int width, int height)
{
    if (g_on_camera_frame) {
        g_on_camera_frame(i420, length, width, height);
    }
}
