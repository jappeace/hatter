#ifndef NOTIFICATION_BRIDGE_H
#define NOTIFICATION_BRIDGE_H

/*
 * Platform-agnostic notification bridge.
 *
 * Shows and cancels notifications from any thread, also while no screen
 * is open. A notification replaces the earlier one with the same key, and
 * tapping it reports the key to the app.
 *
 * Without a platform's implementation, the calls are logged.
 */

/* What a notification is about. A ringing one is a call, whose channel plays the ringtone
 * until it is cancelled or tapped. */
enum {
    NOTIFICATION_MESSAGE = 0,
    NOTIFICATION_RINGING_CALL = 1,
    NOTIFICATION_MISSED_CALL = 2,
};

/* text may hold several lines, the newest last. kind is one of the above. */
void notification_show(const char *key, const char *channel, const char *icon,
                       const char *title, const char *text, int kind);

void notification_cancel(const char *key);

/* The call going on, with the key of its buttons, whom it is with and since
 * when in Unix milliseconds, for an app's foreground service to show. An
 * empty title: none. */
void notification_ongoing(const char *key, const char *title, long long since);

/* While set, the app shows over the lock screen and turns the screen on,
 * as while a call rings or goes on. */
void notification_over_lock_screen(int on);

/* Whether a call may ring over the lock screen, which the user may forbid. */
int notification_full_screen_allowed(void);

/* Opens where the user lets calls ring over the lock screen. */
void notification_allow_full_screen(void);

/* Register platform-specific implementations of the three above. */
void notification_register_lock_screen(void (*over_impl)(int), int (*allowed_impl)(void),
                                       void (*allow_impl)(void));

/* While set, the screen doesn't turn off by itself while the app shows, as
 * during a call. */
void notification_keep_screen_on(int on);

/* Register a platform-specific implementation of notification_keep_screen_on. */
void notification_register_keep_screen_on(void (*keep_impl)(int));

/* What the app's background service says it is doing. */
void notification_status(const char *text);

/* Register a platform-specific implementation of notification_status. */
void notification_register_status(void (*status_impl)(const char *));

/* Whether the app runs in the background, also from when the phone starts. */
void notification_run_in_background(int on);

/* Asks the app's background service to stop, which ends the process. */
void notification_stop_background(void);

/* Register platform-specific implementations of the two above. */
void notification_register_background(void (*run_impl)(int), void (*stop_impl)(void));

/* Register a platform-specific implementation of notification_ongoing. */
void notification_register_ongoing(void (*ongoing_impl)(const char *, const char *, long long));

/* Register a platform-specific implementation. */
void notification_register_impl(
    void (*show_impl)(const char *, const char *, const char *, const char *, const char *, int),
    void (*cancel_impl)(const char *));

#endif /* NOTIFICATION_BRIDGE_H */
