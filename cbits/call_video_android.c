/*
 * Android implementation of the call video bridge.
 *
 * Calls the static methods of HatterCallVideo, so it works from any thread
 * and without an Activity. The class is looked up during JNI_OnLoad, as
 * threads attached later only see the system class loader. Threads
 * attached here stay attached until they exit, as showing frames attaches
 * the same thread for every frame.
 */

#include <jni.h>
#include "jni_helpers.h"
#include <pthread.h>
#include <string.h>
#include <android/log.h>
#include "CallVideoBridge.h"

#define LOG_TAG "CallVideoBridge"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static JavaVM   *g_jvm = NULL;
static jobject   g_app = NULL;
static jclass    g_class = NULL;
static jmethodID g_start = NULL;
static jmethodID g_stop = NULL;
static jmethodID g_show = NULL;
static pthread_key_t g_detach_key;

/* Set before the camera starts and cleared after it stopped. */
static call_video_frame_cb g_on_frame = NULL;

static void android_call_video_start(int front, call_video_frame_cb on_frame)
{
    JNIEnv *env = hatter_thread_env(g_jvm, g_detach_key);
    if (env == NULL) {
        return;
    }
    g_on_frame = on_frame;
    (*env)->CallStaticVoidMethod(env, g_class, g_start, g_app, (jboolean)(front != 0));
    hatter_check_exception(env, "startCamera");
}

static void android_call_video_stop(void)
{
    JNIEnv *env = hatter_thread_env(g_jvm, g_detach_key);
    if (env == NULL) {
        return;
    }
    (*env)->CallStaticVoidMethod(env, g_class, g_stop);
    hatter_check_exception(env, "stopCamera");
    g_on_frame = NULL;
}

static void android_call_video_show(const char *key, int width, int height, const uint8_t *i420, int length)
{
    JNIEnv *env = hatter_thread_env(g_jvm, g_detach_key);
    if (env == NULL) {
        return;
    }
    const jsize key_length = (jsize)strlen(key);
    jbyteArray jkey = (*env)->NewByteArray(env, key_length);
    jbyteArray jframe = (*env)->NewByteArray(env, length);
    if (jkey == NULL || jframe == NULL) {
        hatter_check_exception(env, "show");
        /* This thread stays attached, so nothing frees what it keeps. */
        if (jkey != NULL) {
            (*env)->DeleteLocalRef(env, jkey);
        }
        if (jframe != NULL) {
            (*env)->DeleteLocalRef(env, jframe);
        }
        return;
    }
    (*env)->SetByteArrayRegion(env, jkey, 0, key_length, (const jbyte *)key);
    (*env)->SetByteArrayRegion(env, jframe, 0, length, (const jbyte *)i420);
    (*env)->CallStaticVoidMethod(env, g_class, g_show, jkey, (jint)width, (jint)height, jframe);
    hatter_check_exception(env, "show");
    (*env)->DeleteLocalRef(env, jkey);
    (*env)->DeleteLocalRef(env, jframe);
}

/* Each camera frame, from HatterCallVideo's camera thread. */
JNIEXPORT void JNICALL
Java_me_jappie_hatter_HatterCallVideo_onFrame(JNIEnv *env, jclass cls, jbyteArray i420, jint width, jint height)
{
    (void)cls;
    call_video_frame_cb on_frame = g_on_frame;
    if (on_frame == NULL) {
        return;
    }
    jsize length = (*env)->GetArrayLength(env, i420);
    jbyte *bytes = (*env)->GetByteArrayElements(env, i420, NULL);
    if (bytes == NULL) {
        return;
    }
    on_frame((const uint8_t *)bytes, length, width, height);
    (*env)->ReleaseByteArrayElements(env, i420, bytes, JNI_ABORT);
}

/*
 * Set up the bridge. Called from JNI_OnLoad, where the class loader that
 * loaded the library finds Hatter's classes.
 */
void setup_android_call_video_bridge(JavaVM *vm, JNIEnv *env)
{
    g_jvm = vm;
    pthread_key_create(&g_detach_key, hatter_detach_thread);

    jclass atClass = (*env)->FindClass(env, "android/app/ActivityThread");
    jmethodID currentApp = (*env)->GetStaticMethodID(env, atClass,
        "currentApplication", "()Landroid/app/Application;");
    jobject app = (*env)->CallStaticObjectMethod(env, atClass, currentApp);
    (*env)->DeleteLocalRef(env, atClass);

    jclass cls = (*env)->FindClass(env, "me/jappie/hatter/HatterCallVideo");
    if (app == NULL || cls == NULL) {
        LOGE("No Application or HatterCallVideo: call video disabled");
        (*env)->ExceptionClear(env);
        return;
    }

    g_app = (*env)->NewGlobalRef(env, app);
    g_class = (*env)->NewGlobalRef(env, cls);
    g_start = (*env)->GetStaticMethodID(env, cls, "startCamera", "(Landroid/content/Context;Z)V");
    g_stop = (*env)->GetStaticMethodID(env, cls, "stopCamera", "()V");
    g_show = (*env)->GetStaticMethodID(env, cls, "show", "([BII[B)V");
    (*env)->DeleteLocalRef(env, app);
    (*env)->DeleteLocalRef(env, cls);

    if (g_start == NULL || g_stop == NULL || g_show == NULL) {
        LOGE("HatterCallVideo methods not found: call video disabled");
        (*env)->ExceptionClear(env);
        return;
    }

    call_video_register_impl(android_call_video_start, android_call_video_stop, android_call_video_show);
}
