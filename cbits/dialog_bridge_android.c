/*
 * Android implementation of the dialog bridge callback.
 *
 * Uses JNI to call Activity.showDialog() which presents an AlertDialog.
 * Compiled by NDK clang, not cabal.
 *
 * All functions run on the main/UI thread -- the same thread that
 * calls haskellRenderUI from Java.
 */

#include <jni.h>
#include <android/log.h>
#include "DialogBridge.h"
#include "JniBridge.h"

#define LOG_TAG "DialogBridge"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Haskell FFI export (dispatches result back to Haskell callback) */
extern void haskellOnDialogResult(void *ctx, int32_t requestId, int32_t actionCode);

/* ---- Global state (valid only on the UI thread) ---- */
static JNIEnv  *g_env         = NULL;
static jobject  g_activity     = NULL;   /* global ref to Activity */
static void    *g_haskell_ctx  = NULL;   /* stored per-request for JNI callback */

/* Cached JNI method ID */
static jmethodID g_method_showDialog;

/* ---- Dialog bridge implementation ---- */

static void android_dialog_show(void *ctx, int32_t requestId,
                                 const char *title, const char *message,
                                 const char *button1, const char *button2,
                                 const char *button3)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("dialog_show: bridge not initialized");
        return;
    }

    g_haskell_ctx = ctx;

    jstring jtitle = (*env)->NewStringUTF(env, title);
    jstring jmessage = (*env)->NewStringUTF(env, message);
    jstring jbutton1 = (*env)->NewStringUTF(env, button1);
    jstring jbutton2 = button2 ? (*env)->NewStringUTF(env, button2) : NULL;
    jstring jbutton3 = button3 ? (*env)->NewStringUTF(env, button3) : NULL;

    LOGI("dialog_show(title=\"%s\", id=%d)", title, requestId);
    (*env)->CallVoidMethod(env, g_activity, g_method_showDialog,
                           (jint)requestId, jtitle, jmessage,
                           jbutton1, jbutton2, jbutton3);

    (*env)->DeleteLocalRef(env, jtitle);
    (*env)->DeleteLocalRef(env, jmessage);
    (*env)->DeleteLocalRef(env, jbutton1);
    if (jbutton2) (*env)->DeleteLocalRef(env, jbutton2);
    if (jbutton3) (*env)->DeleteLocalRef(env, jbutton3);
}

/* ---- Public API ---- */

/*
 * Set up the Android dialog bridge. Called from jni_bridge.c
 * during renderUI (after the Activity is available).
 * Resolves JNI method IDs and registers callback with the
 * platform-agnostic dispatcher.
 */
void setup_android_dialog_bridge(JNIEnv *env, jobject activity, void *haskellCtx)
{
    g_env = env;
    g_haskell_ctx = haskellCtx;

    if (!g_activity) {
        g_activity = (*env)->NewGlobalRef(env, activity);
    }

    jclass actClass = (*env)->GetObjectClass(env, activity);

    g_method_showDialog = (*env)->GetMethodID(env, actClass,
        "showDialog",
        "(ILjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V");

    if (!g_method_showDialog) {
        LOGE("Failed to resolve dialog JNI method ID -- bridge disabled");
        (*env)->ExceptionClear(env);
        return;
    }

    dialog_register_impl(android_dialog_show);

    LOGI("Android dialog bridge initialized");
}

/* ---- JNI callback from Java ---- */

JNIEXPORT void JNICALL
JNI_METHOD(onDialogResult)(JNIEnv *env, jobject thiz,
                            jint requestId, jint actionCode)
{
    g_env = env;
    LOGI("onDialogResult(requestId=%d, actionCode=%d)", requestId, actionCode);
    haskellOnDialogResult(g_haskell_ctx, (int32_t)requestId, (int32_t)actionCode);
}
