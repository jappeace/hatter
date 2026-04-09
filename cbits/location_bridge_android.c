/*
 * Android implementation of the location (GPS) bridge callbacks.
 *
 * Uses JNI to call Activity.startLocationUpdates() and
 * Activity.stopLocationUpdates(). Compiled by NDK clang, not cabal.
 *
 * All functions run on the main/UI thread, the same thread that
 * calls haskellRenderUI from Java.
 */

#include <jni.h>
#include <android/log.h>
#include "LocationBridge.h"
#include "JniBridge.h"

#define LOG_TAG "LocationBridge"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Haskell FFI export (dispatches location update back to Haskell callback) */
extern void haskellOnLocationUpdate(void *ctx, double lat, double lon,
                                     double alt, double acc);

/* ---- Global state (valid only on the UI thread) ---- */
static JNIEnv  *g_env          = NULL;
static jobject  g_activity      = NULL;   /* global ref to Activity */
static void    *g_haskell_ctx   = NULL;   /* stored for async JNI callback */

/* Cached JNI method IDs */
static jmethodID g_method_startLocationUpdates;
static jmethodID g_method_stopLocationUpdates;

/* ---- Location bridge implementations ---- */

static void android_location_start_updates(void *ctx)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("location_start_updates: bridge not initialized");
        return;
    }

    g_haskell_ctx = ctx;
    LOGI("location_start_updates()");
    (*env)->CallVoidMethod(env, g_activity, g_method_startLocationUpdates);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("location_start_updates: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
}

static void android_location_stop_updates(void)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("location_stop_updates: bridge not initialized");
        return;
    }

    LOGI("location_stop_updates()");
    (*env)->CallVoidMethod(env, g_activity, g_method_stopLocationUpdates);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("location_stop_updates: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
}

/* ---- Public API ---- */

/*
 * Set up the Android location bridge. Called from jni_bridge.c
 * during renderUI (after the Activity is available).
 * Resolves JNI method IDs and registers callbacks with the
 * platform-agnostic dispatcher.
 */
void setup_android_location_bridge(JNIEnv *env, jobject activity, void *haskellCtx)
{
    g_env = env;
    g_haskell_ctx = haskellCtx;

    if (!g_activity) {
        g_activity = (*env)->NewGlobalRef(env, activity);
    }

    jclass actClass = (*env)->GetObjectClass(env, activity);

    g_method_startLocationUpdates = (*env)->GetMethodID(env, actClass,
        "startLocationUpdates", "()V");
    g_method_stopLocationUpdates = (*env)->GetMethodID(env, actClass,
        "stopLocationUpdates", "()V");

    /* Clean up local reference */
    (*env)->DeleteLocalRef(env, actClass);

    if (!g_method_startLocationUpdates || !g_method_stopLocationUpdates) {
        LOGE("Failed to resolve location JNI method IDs — location bridge disabled");
        (*env)->ExceptionClear(env);
        return;
    }

    /* Clear any unexpected pending exception before continuing */
    if ((*env)->ExceptionCheck(env)) {
        LOGE("Unexpected JNI exception after location method resolution");
        (*env)->ExceptionClear(env);
    }

    location_register_impl(android_location_start_updates,
                           android_location_stop_updates);

    LOGI("Android location bridge initialized");
}

/* ---- JNI callback from Java location result ---- */

JNIEXPORT void JNICALL
JNI_METHOD(onLocationResult)(JNIEnv *env, jobject thiz,
                              jdouble lat, jdouble lon,
                              jdouble alt, jdouble acc)
{
    g_env = env;
    LOGI("onLocationResult(lat=%f, lon=%f, alt=%f, acc=%f)", lat, lon, alt, acc);
    haskellOnLocationUpdate(g_haskell_ctx, (double)lat, (double)lon,
                            (double)alt, (double)acc);
}
