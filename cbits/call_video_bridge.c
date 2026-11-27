/*
 * Platform-agnostic call video bridge dispatcher.
 *
 * Stores the function pointers the platform fills in. Without them, the
 * camera's start and stop are logged, and frames shown are dropped.
 */

#include "CallVideoBridge.h"
#include <stddef.h>

extern void hatterLog(const char *msg);

static void (*g_start_impl)(int, call_video_frame_cb) = NULL;
static void (*g_stop_impl)(void) = NULL;
static void (*g_show_impl)(const char *, int, int, const uint8_t *, int) = NULL;

void call_video_register_impl(
    void (*start_impl)(int, call_video_frame_cb),
    void (*stop_impl)(void),
    void (*show_impl)(const char *, int, int, const uint8_t *, int))
{
    g_start_impl = start_impl;
    g_stop_impl = stop_impl;
    g_show_impl = show_impl;
}

void call_video_camera_start(int front, call_video_frame_cb on_frame)
{
    if (g_start_impl) {
        g_start_impl(front, on_frame);
        return;
    }
    hatterLog(front ? "[CallVideoBridge stub] front camera start" : "[CallVideoBridge stub] back camera start");
}

void call_video_camera_stop(void)
{
    if (g_stop_impl) {
        g_stop_impl();
        return;
    }
    hatterLog("[CallVideoBridge stub] camera stop");
}

void call_video_show(const char *key, int width, int height, const uint8_t *i420, int length)
{
    if (g_show_impl) {
        g_show_impl(key, width, height, i420, length);
    }
}
