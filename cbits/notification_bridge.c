/*
 * Platform-agnostic notification bridge dispatcher.
 *
 * Stores the function pointers the platform fills in. Without them, the
 * calls are logged so tests can see them.
 */

#include "NotificationBridge.h"
#include <stdio.h>

static void (*g_show_impl)(const char *, const char *, const char *, const char *, const char *, int) = NULL;
static void (*g_cancel_impl)(const char *) = NULL;

void notification_register_impl(
    void (*show_impl)(const char *, const char *, const char *, const char *, const char *, int),
    void (*cancel_impl)(const char *))
{
    g_show_impl = show_impl;
    g_cancel_impl = cancel_impl;
}

void notification_show(const char *key, const char *channel, const char *icon,
                       const char *title, const char *text, int kind)
{
    if (g_show_impl) {
        g_show_impl(key, channel, icon, title, text, kind);
        return;
    }
    char buf[256];
    snprintf(buf, sizeof(buf), "[NotificationBridge stub] show %s: %s%s\n%s", key, title,
             kind == NOTIFICATION_RINGING_CALL ? " (ringing)" : kind == NOTIFICATION_MISSED_CALL ? " (missed call)" : "",
             text);
    fprintf(stderr, "%s\n", buf);
}

static void (*g_ongoing_impl)(const char *, const char *, long long) = NULL;

void notification_register_ongoing(void (*ongoing_impl)(const char *, const char *, long long))
{
    g_ongoing_impl = ongoing_impl;
}

void notification_ongoing(const char *key, const char *title, long long since)
{
    if (g_ongoing_impl) {
        g_ongoing_impl(key, title, since);
        return;
    }
    char buf[256];
    snprintf(buf, sizeof(buf), "[NotificationBridge stub] ongoing %s: %s", key, title);
    fprintf(stderr, "%s\n", buf);
}

static void (*g_status_impl)(const char *) = NULL;

void notification_register_status(void (*status_impl)(const char *))
{
    g_status_impl = status_impl;
}

void notification_status(const char *text)
{
    if (g_status_impl) {
        g_status_impl(text);
        return;
    }
    char buf[256];
    snprintf(buf, sizeof(buf), "[NotificationBridge stub] status %s", text);
    fprintf(stderr, "%s\n", buf);
}

static void (*g_run_impl)(int) = NULL;
static void (*g_stop_impl)(void) = NULL;

void notification_register_background(void (*run_impl)(int), void (*stop_impl)(void))
{
    g_run_impl = run_impl;
    g_stop_impl = stop_impl;
}

void notification_run_in_background(int on)
{
    if (g_run_impl) {
        g_run_impl(on);
        return;
    }
    fprintf(stderr, "%s\n", on ? "[NotificationBridge stub] run in background" : "[NotificationBridge stub] not in background");
}

void notification_stop_background(void)
{
    if (g_stop_impl) {
        g_stop_impl();
        return;
    }
    fprintf(stderr, "[NotificationBridge stub] stop background\n");
}

static void (*g_over_impl)(int) = NULL;
static int (*g_allowed_impl)(void) = NULL;
static void (*g_allow_impl)(void) = NULL;

void notification_register_lock_screen(void (*over_impl)(int), int (*allowed_impl)(void),
                                       void (*allow_impl)(void))
{
    g_over_impl = over_impl;
    g_allowed_impl = allowed_impl;
    g_allow_impl = allow_impl;
}

void notification_over_lock_screen(int on)
{
    if (g_over_impl) {
        g_over_impl(on);
        return;
    }
    fprintf(stderr, "%s\n", on ? "[NotificationBridge stub] over lock screen" : "[NotificationBridge stub] not over lock screen");
}

static void (*g_keep_impl)(int) = NULL;

void notification_register_keep_screen_on(void (*keep_impl)(int))
{
    g_keep_impl = keep_impl;
}

void notification_keep_screen_on(int on)
{
    if (g_keep_impl) {
        g_keep_impl(on);
        return;
    }
    fprintf(stderr, "%s\n", on ? "[NotificationBridge stub] keep screen on" : "[NotificationBridge stub] screen may turn off");
}

int notification_full_screen_allowed(void)
{
    return g_allowed_impl ? g_allowed_impl() : 1;
}

void notification_allow_full_screen(void)
{
    if (g_allow_impl) {
        g_allow_impl();
        return;
    }
    fprintf(stderr, "[NotificationBridge stub] allow full screen\n");
}

void notification_cancel(const char *key)
{
    if (g_cancel_impl) {
        g_cancel_impl(key);
        return;
    }
    char buf[256];
    snprintf(buf, sizeof(buf), "[NotificationBridge stub] cancel %s", key);
    fprintf(stderr, "%s\n", buf);
}
