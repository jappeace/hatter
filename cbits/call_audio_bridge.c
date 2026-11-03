/*
 * Platform-agnostic call audio bridge dispatcher.
 *
 * Stores the function pointers the platform fills in. Without them,
 * starting, stopping and routes are logged, and what is played is dropped.
 */

#include "CallAudioBridge.h"
#include <stdio.h>

extern void hatterLog(const char *msg);

static void (*g_start_impl)(int, int, int, call_audio_frame_cb, call_audio_routes_cb) = NULL;
static void (*g_stop_impl)(void) = NULL;
static int (*g_play_impl)(int, int, const int16_t *, int) = NULL;
static void (*g_route_impl)(int) = NULL;

void call_audio_register_impl(
    void (*start_impl)(int, int, int, call_audio_frame_cb, call_audio_routes_cb),
    void (*stop_impl)(void),
    int (*play_impl)(int, int, const int16_t *, int),
    void (*route_impl)(int))
{
    g_start_impl = start_impl;
    g_stop_impl = stop_impl;
    g_play_impl = play_impl;
    g_route_impl = route_impl;
}

void call_audio_start(int rate, int frame_samples, int speaker,
                      call_audio_frame_cb on_frame, call_audio_routes_cb on_routes)
{
    if (g_start_impl) {
        g_start_impl(rate, frame_samples, speaker, on_frame, on_routes);
        return;
    }
    char buf[128];
    snprintf(buf, sizeof(buf), "[CallAudioBridge stub] start %d Hz, %d samples", rate, frame_samples);
    hatterLog(buf);
}

void call_audio_stop(void)
{
    if (g_stop_impl) {
        g_stop_impl();
        return;
    }
    hatterLog("[CallAudioBridge stub] stop");
}

int call_audio_play(int rate, int channels, const int16_t *samples, int count)
{
    if (g_play_impl) {
        return g_play_impl(rate, channels, samples, count);
    }
    return 0;
}

static void (*g_tone_impl)(int) = NULL;

void call_audio_register_tone(void (*tone_impl)(int))
{
    g_tone_impl = tone_impl;
}

void call_audio_tone(int tone)
{
    if (g_tone_impl) {
        g_tone_impl(tone);
        return;
    }
    char buf[64];
    snprintf(buf, sizeof(buf), "[CallAudioBridge stub] tone %d", tone);
    hatterLog(buf);
}

void call_audio_route(int route)
{
    if (g_route_impl) {
        g_route_impl(route);
        return;
    }
    char buf[64];
    snprintf(buf, sizeof(buf), "[CallAudioBridge stub] route %d", route);
    hatterLog(buf);
}

static int (*g_latency_impl)(void) = NULL;

void call_audio_register_latency(int (*latency_impl)(void))
{
    g_latency_impl = latency_impl;
}

int call_audio_latency(void)
{
    if (g_latency_impl) {
        return g_latency_impl();
    }
    return 0;
}
