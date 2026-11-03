#ifndef CALL_AUDIO_BRIDGE_H
#define CALL_AUDIO_BRIDGE_H

#include <stdint.h>

/*
 * Platform-agnostic bridge for the audio of calls.
 *
 * Records the microphone in frames and plays the other side's audio, both
 * in the platform's voice call mode. Any thread may call these, also while
 * no screen is open. One call's audio at a time.
 *
 * Without a platform's implementation, starting and stopping are logged
 * and no frames come.
 */

/* Called on the platform's recording thread with each frame of mono
 * 16-bit samples. */
typedef void (*call_audio_frame_cb)(const int16_t *samples, int count);

/* Where a call's audio goes. */
enum {
    CALL_AUDIO_EARPIECE = 0,
    CALL_AUDIO_SPEAKER = 1,
    CALL_AUDIO_WIRED = 2,
    CALL_AUDIO_BLUETOOTH = 3,
};

/* Called with the route the audio takes and those there are, as a mask of
 * 1 << route, when they change. On any thread, also during
 * call_audio_start and call_audio_route. */
typedef void (*call_audio_routes_cb)(int route, int available);

/* Without a headset, the audio goes to the loudspeaker if speaker is set,
 * else to the earpiece. A headset that connects takes it. */
void call_audio_start(int rate, int frame_samples, int speaker,
                      call_audio_frame_cb on_frame, call_audio_routes_cb on_routes);

/* Returns once on_frame is no longer called. */
void call_audio_stop(void);

/* Interleaved 16-bit samples, played as they come. Returns the milliseconds
 * of audio waiting to be played, these included (0 where the platform
 * doesn't say). */
int call_audio_play(int rate, int channels, const int16_t *samples, int count);
/* How long after it's played audio is heard, in milliseconds (0 until the
 * platform knows, or where it doesn't say). */
int call_audio_latency(void);

/* The route the user chooses, while it is there or until a headset
 * connects. */
void call_audio_route(int route);

/* What the phone plays outside a call's audio: 0 nothing, 1 the ringtone of
 * a call coming in, 2 the ring-back tone of one going out. */
void call_audio_tone(int tone);

/* Register a platform-specific implementation of call_audio_tone. */
void call_audio_register_tone(void (*tone_impl)(int));
/* Register a platform-specific implementation of call_audio_latency. */
void call_audio_register_latency(int (*latency_impl)(void));

/* Register a platform-specific implementation. */
void call_audio_register_impl(
    void (*start_impl)(int, int, int, call_audio_frame_cb, call_audio_routes_cb),
    void (*stop_impl)(void),
    int (*play_impl)(int, int, const int16_t *, int),
    void (*route_impl)(int));

#endif /* CALL_AUDIO_BRIDGE_H */
