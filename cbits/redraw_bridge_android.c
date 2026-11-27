/*
 * Android implementation of the redraw bridge.
 *
 * Uses JNI to call the static Activity.requestRedraw(), which runs
 * renderUI() on the main/UI thread for the activity alive then.
 * Compiled by NDK clang, not cabal.
 *
 * request_redraw() may be called from any thread (e.g. a Haskell
 * background thread doing network sync). The Java side ensures
 * the actual rendering happens on the UI thread.
 */

#include <jni.h>
#include "jni_helpers.h"
#include <android/log.h>
#include "RedrawBridge.h"
#include "JniBridge.h"

#define LOG_TAG "RedrawBridge"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* ---- Global state (set on the UI thread during setup) ---- */
static JavaVM   *g_jvm          = NULL;   /* cached JVM for attaching threads */
static jclass    g_activity_class = NULL; /* global ref, kept for good */
static jmethodID g_method_requestRedraw;

/* ---- Redraw bridge implementation ---- */

static void android_request_redraw(void *ctx)
{
    if (!g_jvm || !g_activity_class) {
        LOGE("request_redraw: bridge not initialized");
        return;
    }

    /* Background threads ask too, which the JVM doesn't know yet. */
    int need_detach;
    JNIEnv *env = hatter_attached_env(g_jvm, &need_detach);
    if (env == NULL) {
        return;
    }

    LOGI("request_redraw()");
    (*env)->CallStaticVoidMethod(env, g_activity_class, g_method_requestRedraw);
    hatter_check_exception(env, "request_redraw");
    hatter_detach(g_jvm, need_detach);
}

/* ---- Public API ---- */

/*
 * Set up the Android redraw bridge. Called from jni_bridge.c
 * during renderUI (after the Activity is available).
 * Resolves JNI method IDs and registers callback with the
 * platform-agnostic dispatcher.
 */
void setup_android_redraw_bridge(JNIEnv *env, jobject activity, void *haskellCtx)
{
    /* Cache the JavaVM so background threads can get a JNIEnv */
    if (!g_jvm) {
        (*env)->GetJavaVM(env, &g_jvm);
    }

    /* Only the class: a background thread may be calling through it while
     * a recreated activity sets the bridge up again, so it is never
     * replaced or deleted. */
    if (g_activity_class) {
        return;
    }
    jclass actClass = (*env)->GetObjectClass(env, activity);

    g_method_requestRedraw = (*env)->GetStaticMethodID(env, actClass,
        "requestRedraw", "()V");

    if (!g_method_requestRedraw) {
        LOGE("Failed to resolve requestRedraw JNI method ID — redraw bridge disabled");
        (*env)->ExceptionClear(env);
        (*env)->DeleteLocalRef(env, actClass);
        return;
    }

    /* Set after the method, as other threads take a class as ready. */
    g_activity_class = (jclass)(*env)->NewGlobalRef(env, actClass);

    /* Clean up local reference */
    (*env)->DeleteLocalRef(env, actClass);

    /* Clear any unexpected pending exception before continuing */
    if ((*env)->ExceptionCheck(env)) {
        LOGE("Unexpected JNI exception after redraw method resolution");
        (*env)->ExceptionClear(env);
    }

    redraw_register_impl(android_request_redraw);

    LOGI("Android redraw bridge initialized");
}
