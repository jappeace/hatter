/*
 * Android implementation of the network connectivity status bridge.
 *
 * Uses JNI to call Activity.startNetworkMonitoring() and
 * Activity.stopNetworkMonitoring(). Compiled by NDK clang, not cabal.
 *
 * All functions run on the main/UI thread, the same thread that
 * calls haskellRenderUI from Java.
 */

#include <jni.h>
#include <android/log.h>
#include "NetworkStatusBridge.h"
#include "JniBridge.h"

#define LOG_TAG "NetworkStatusBridge"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Haskell FFI export (dispatches network status change back to Haskell callback) */
extern void haskellOnNetworkStatusChange(void *ctx, int connected, int transport);

/* ---- Global state (valid only on the UI thread) ---- */
static JNIEnv  *g_env          = NULL;
static jobject  g_activity      = NULL;   /* global ref to Activity */
static void    *g_haskell_ctx   = NULL;   /* stored for async JNI callback */

/* Cached JNI method IDs */
static jmethodID g_method_startNetworkMonitoring;
static jmethodID g_method_stopNetworkMonitoring;

/* ---- Network status bridge implementations ---- */

static void android_network_status_start_monitoring(void *ctx)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("network_status_start_monitoring: bridge not initialized");
        return;
    }

    g_haskell_ctx = ctx;
    LOGI("network_status_start_monitoring()");
    (*env)->CallVoidMethod(env, g_activity, g_method_startNetworkMonitoring);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("network_status_start_monitoring: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
}

static void android_network_status_stop_monitoring(void)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("network_status_stop_monitoring: bridge not initialized");
        return;
    }

    LOGI("network_status_stop_monitoring()");
    (*env)->CallVoidMethod(env, g_activity, g_method_stopNetworkMonitoring);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("network_status_stop_monitoring: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
}

/* ---- Public API ---- */

/*
 * Set up the Android network status bridge. Called from jni_bridge.c
 * during renderUI (after the Activity is available).
 * Resolves JNI method IDs and registers callbacks with the
 * platform-agnostic dispatcher.
 */
void setup_android_network_status_bridge(JNIEnv *env, jobject activity, void *haskellCtx)
{
    g_env = env;
    g_haskell_ctx = haskellCtx;

    if (!g_activity) {
        g_activity = (*env)->NewGlobalRef(env, activity);
    }

    jclass actClass = (*env)->GetObjectClass(env, activity);

    g_method_startNetworkMonitoring = (*env)->GetMethodID(env, actClass,
        "startNetworkMonitoring", "()V");
    g_method_stopNetworkMonitoring = (*env)->GetMethodID(env, actClass,
        "stopNetworkMonitoring", "()V");

    /* Clean up local reference */
    (*env)->DeleteLocalRef(env, actClass);

    if (!g_method_startNetworkMonitoring || !g_method_stopNetworkMonitoring) {
        LOGE("Failed to resolve network status JNI method IDs — network status bridge disabled");
        (*env)->ExceptionClear(env);
        return;
    }

    /* Clear any unexpected pending exception before continuing */
    if ((*env)->ExceptionCheck(env)) {
        LOGE("Unexpected JNI exception after network status method resolution");
        (*env)->ExceptionClear(env);
    }

    network_status_register_impl(android_network_status_start_monitoring,
                                  android_network_status_stop_monitoring);

    LOGI("Android network status bridge initialized");
}

/* ---- JNI callback from Java network status change ---- */

JNIEXPORT void JNICALL
JNI_METHOD(onNetworkStatusChange)(JNIEnv *env, jobject thiz,
                                    jint connected, jint transport)
{
    g_env = env;
    LOGI("onNetworkStatusChange(connected=%d, transport=%d)", connected, transport);
    haskellOnNetworkStatusChange(g_haskell_ctx, (int)connected, (int)transport);
}
