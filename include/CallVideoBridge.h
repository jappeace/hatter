#ifndef CALL_VIDEO_BRIDGE_H
#define CALL_VIDEO_BRIDGE_H

#include <stdint.h>

/*
 * Platform-agnostic bridge for the video of calls.
 *
 * Frames are I420: the Y plane, then U and V at half the width and height.
 * The camera's go to a callback, upright, and frames are drawn into the
 * image views that show a stream by its key. Any thread may call these.
 * One camera at a time.
 *
 * Without a platform's implementation, the camera's start and stop are
 * logged, no frames come, and frames shown are dropped.
 */

/* Called on the platform's camera thread with each frame. */
typedef void (*call_video_frame_cb)(const uint8_t *i420, int length, int width, int height);

void call_video_camera_start(int front, call_video_frame_cb on_frame);

/* Returns once on_frame is no longer called. */
void call_video_camera_stop(void);

void call_video_show(const char *key, int width, int height, const uint8_t *i420, int length);

/* Register a platform-specific implementation. */
void call_video_register_impl(
    void (*start_impl)(int, call_video_frame_cb),
    void (*stop_impl)(void),
    void (*show_impl)(const char *, int, int, const uint8_t *, int));

#endif /* CALL_VIDEO_BRIDGE_H */
