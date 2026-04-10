/*
 * Android implementation of the bottom sheet bridge callback.
 *
 * Uses JNI to call Activity.showBottomSheet() which presents a BottomSheetDialog.
 * Compiled by NDK clang, not cabal.
 *
 * All functions run on the main/UI thread -- the same thread that
 * calls haskellRenderUI from Java.
 */

#include <jni.h>
#include <android/log.h>
#include "BottomSheetBridge.h"
#include "JniBridge.h"

#define LOG_TAG "BottomSheetBridge"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Haskell FFI export (dispatches result back to Haskell callback) */
extern void haskellOnBottomSheetResult(void *ctx, int32_t requestId, int32_t actionCode);

/* ---- Global state (valid only on the UI thread) ---- */
static JNIEnv  *g_env         = NULL;
static jobject  g_activity     = NULL;   /* global ref to Activity */
static void    *g_haskell_ctx  = NULL;   /* stored per-request for JNI callback */

/* Cached JNI method ID */
static jmethodID g_method_showBottomSheet;

/* ---- Bottom sheet bridge implementation ---- */

static void android_bottom_sheet_show(void *ctx, int32_t requestId,
                                       const char *title, const char *items)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("bottom_sheet_show: bridge not initialized");
        return;
    }

    g_haskell_ctx = ctx;

    jstring jtitle = (*env)->NewStringUTF(env, title);
    jstring jitems = (*env)->NewStringUTF(env, items);

    LOGI("bottom_sheet_show(title=\"%s\", id=%d)", title, requestId);
    (*env)->CallVoidMethod(env, g_activity, g_method_showBottomSheet,
                           (jint)requestId, jtitle, jitems);

    (*env)->DeleteLocalRef(env, jtitle);
    (*env)->DeleteLocalRef(env, jitems);
}

/* ---- Public API ---- */

/*
 * Set up the Android bottom sheet bridge. Called from jni_bridge.c
 * during renderUI (after the Activity is available).
 * Resolves JNI method IDs and registers callback with the
 * platform-agnostic dispatcher.
 */
void setup_android_bottom_sheet_bridge(JNIEnv *env, jobject activity, void *haskellCtx)
{
    g_env = env;
    g_haskell_ctx = haskellCtx;

    if (!g_activity) {
        g_activity = (*env)->NewGlobalRef(env, activity);
    }

    jclass actClass = (*env)->GetObjectClass(env, activity);

    g_method_showBottomSheet = (*env)->GetMethodID(env, actClass,
        "showBottomSheet",
        "(ILjava/lang/String;Ljava/lang/String;)V");

    if (!g_method_showBottomSheet) {
        LOGE("Failed to resolve bottom sheet JNI method ID -- bridge disabled");
        (*env)->ExceptionClear(env);
        return;
    }

    bottom_sheet_register_impl(android_bottom_sheet_show);

    LOGI("Android bottom sheet bridge initialized");
}

/* ---- JNI callback from Java ---- */

JNIEXPORT void JNICALL
JNI_METHOD(onBottomSheetResult)(JNIEnv *env, jobject thiz,
                                 jint requestId, jint actionCode)
{
    g_env = env;
    LOGI("onBottomSheetResult(requestId=%d, actionCode=%d)", requestId, actionCode);
    haskellOnBottomSheetResult(g_haskell_ctx, (int32_t)requestId, (int32_t)actionCode);
}
