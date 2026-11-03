/*
 * Android implementation of the call audio bridge.
 *
 * Calls the static methods of HatterCallAudio with the Application, so it
 * works from any thread and without an Activity. The class is looked up
 * during JNI_OnLoad, as threads attached later only see the system class
 * loader. Threads attached here stay attached until they exit, as playing
 * attaches the same thread for every frame.
 */

#include <jni.h>
#include "jni_helpers.h"
#include <pthread.h>
#include <android/log.h>
#include "CallAudioBridge.h"

#define LOG_TAG "CallAudioBridge"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static JavaVM   *g_jvm = NULL;
static jobject   g_app = NULL;
static jclass    g_class = NULL;
static jmethodID g_start = NULL;
static jmethodID g_stop = NULL;
static jmethodID g_play = NULL;
static jmethodID g_route = NULL;
static jmethodID g_tone = NULL;
static jmethodID g_latency = NULL;
static pthread_key_t g_detach_key;

/* Set before recording starts and cleared after it stopped. */
static call_audio_frame_cb g_on_frame = NULL;
static call_audio_routes_cb g_on_routes = NULL;

static void android_call_audio_start(int rate, int frame_samples, int speaker,
                                     call_audio_frame_cb on_frame, call_audio_routes_cb on_routes)
{
    JNIEnv *env = hatter_thread_env(g_jvm, g_detach_key);
    if (env == NULL) {
        return;
    }
    g_on_frame = on_frame;
    g_on_routes = on_routes;
    (*env)->CallStaticVoidMethod(env, g_class, g_start, g_app, (jint)rate, (jint)frame_samples,
                                 (jboolean)(speaker != 0));
    hatter_check_exception(env, "start");
}

static void android_call_audio_stop(void)
{
    JNIEnv *env = hatter_thread_env(g_jvm, g_detach_key);
    if (env == NULL) {
        return;
    }
    (*env)->CallStaticVoidMethod(env, g_class, g_stop, g_app);
    hatter_check_exception(env, "stop");
    g_on_frame = NULL;
    g_on_routes = NULL;
}

static int android_call_audio_play(int rate, int channels, const int16_t *samples, int count)
{
    JNIEnv *env = hatter_thread_env(g_jvm, g_detach_key);
    if (env == NULL) {
        return 0;
    }
    jshortArray pcm = (*env)->NewShortArray(env, count);
    if (pcm == NULL) {
        hatter_check_exception(env, "play");
        return 0;
    }
    (*env)->SetShortArrayRegion(env, pcm, 0, count, samples);
    jint waiting = (*env)->CallStaticIntMethod(env, g_class, g_play, (jint)rate, (jint)channels, pcm);
    hatter_check_exception(env, "play");
    (*env)->DeleteLocalRef(env, pcm);
    return waiting;
}

static int android_call_audio_latency(void)
{
    JNIEnv *env = hatter_thread_env(g_jvm, g_detach_key);
    if (env == NULL) {
        return 0;
    }
    jint latency = (*env)->CallStaticIntMethod(env, g_class, g_latency);
    hatter_check_exception(env, "latency");
    return latency;
}

static void android_call_audio_route(int route)
{
    JNIEnv *env = hatter_thread_env(g_jvm, g_detach_key);
    if (env == NULL) {
        return;
    }
    (*env)->CallStaticVoidMethod(env, g_class, g_route, g_app, (jint)route);
    hatter_check_exception(env, "route");
}

static void android_call_audio_tone(int tone)
{
    JNIEnv *env = hatter_thread_env(g_jvm, g_detach_key);
    if (env == NULL) {
        return;
    }
    (*env)->CallStaticVoidMethod(env, g_class, g_tone, g_app, (jint)tone);
    hatter_check_exception(env, "tone");
}

/* Each recorded frame, from HatterCallAudio's recording thread. */
JNIEXPORT void JNICALL
Java_me_jappie_hatter_HatterCallAudio_onFrame(JNIEnv *env, jclass cls, jshortArray pcm, jint count)
{
    (void)cls;
    call_audio_frame_cb on_frame = g_on_frame;
    if (on_frame == NULL) {
        return;
    }
    jshort *samples = (*env)->GetShortArrayElements(env, pcm, NULL);
    if (samples == NULL) {
        return;
    }
    on_frame(samples, count);
    (*env)->ReleaseShortArrayElements(env, pcm, samples, JNI_ABORT);
}

/* The routes, from HatterCallAudio while the call's audio goes. */
JNIEXPORT void JNICALL
Java_me_jappie_hatter_HatterCallAudio_onRoutes(JNIEnv *env, jclass cls, jint route, jint available)
{
    (void)env;
    (void)cls;
    call_audio_routes_cb on_routes = g_on_routes;
    if (on_routes != NULL) {
        on_routes(route, available);
    }
}

/*
 * Set up the bridge. Called from JNI_OnLoad, where the class loader that
 * loaded the library finds Hatter's classes.
 */
void setup_android_call_audio_bridge(JavaVM *vm, JNIEnv *env)
{
    g_jvm = vm;
    pthread_key_create(&g_detach_key, hatter_detach_thread);

    jclass atClass = (*env)->FindClass(env, "android/app/ActivityThread");
    jmethodID currentApp = (*env)->GetStaticMethodID(env, atClass,
        "currentApplication", "()Landroid/app/Application;");
    jobject app = (*env)->CallStaticObjectMethod(env, atClass, currentApp);
    (*env)->DeleteLocalRef(env, atClass);

    jclass cls = (*env)->FindClass(env, "me/jappie/hatter/HatterCallAudio");
    if (app == NULL || cls == NULL) {
        LOGE("No Application or HatterCallAudio: call audio disabled");
        (*env)->ExceptionClear(env);
        return;
    }

    g_app = (*env)->NewGlobalRef(env, app);
    g_class = (*env)->NewGlobalRef(env, cls);
    g_start = (*env)->GetStaticMethodID(env, cls, "start", "(Landroid/content/Context;IIZ)V");
    g_stop = (*env)->GetStaticMethodID(env, cls, "stop", "(Landroid/content/Context;)V");
    g_play = (*env)->GetStaticMethodID(env, cls, "play", "(II[S)I");
    g_route = (*env)->GetStaticMethodID(env, cls, "route", "(Landroid/content/Context;I)V");
    (*env)->DeleteLocalRef(env, app);
    (*env)->DeleteLocalRef(env, cls);

    if (g_start == NULL || g_stop == NULL || g_play == NULL || g_route == NULL) {
        LOGE("HatterCallAudio methods not found: call audio disabled");
        (*env)->ExceptionClear(env);
        return;
    }

    call_audio_register_impl(android_call_audio_start, android_call_audio_stop,
                             android_call_audio_play, android_call_audio_route);
    g_latency = (*env)->GetStaticMethodID(env, g_class, "latency", "()I");
    if (g_latency == NULL) {
        (*env)->ExceptionClear(env);
    } else {
        call_audio_register_latency(android_call_audio_latency);
    }
    g_tone = (*env)->GetStaticMethodID(env, g_class, "tone", "(Landroid/content/Context;I)V");
    if (g_tone == NULL) {
        (*env)->ExceptionClear(env);
    } else {
        call_audio_register_tone(android_call_audio_tone);
    }
}
