/*
 * Android implementation of the picture bridge: HatterFiles decodes, on
 * whichever thread asks, attached to the JVM for the call.
 */

#include <jni.h>
#include "jni_helpers.h"
#include <stdlib.h>
#include <string.h>
#include <android/log.h>
#include "PictureBridge.h"

#define LOG_TAG "PictureBridge"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static JavaVM   *g_jvm = NULL;
static jclass    g_class = NULL;
static jmethodID g_pixels = NULL;
static jmethodID g_shrink = NULL;

static uint8_t *android_picture_pixels(const char *path, int32_t max_pixels, int32_t *width, int32_t *height)
{
    int need_detach;
    JNIEnv *env = hatter_attached_env(g_jvm, &need_detach);
    if (env == NULL) {
        return NULL;
    }

    uint8_t *pixels = NULL;
    jbyteArray jpath = hatter_utf8_bytes(env, path);
    /* Width and height, big-endian, then the pixels. */
    jbyteArray result = (*env)->CallStaticObjectMethod(env, g_class, g_pixels, jpath, (jint)max_pixels);
    if (hatter_check_exception(env, "pixels")) {
        result = NULL;
    }
    if (result != NULL) {
        jsize size = (*env)->GetArrayLength(env, result);
        if (size >= 8) {
            uint8_t head[8];
            (*env)->GetByteArrayRegion(env, result, 0, 8, (jbyte *)head);
            *width = (int32_t)((uint32_t)head[0] << 24 | (uint32_t)head[1] << 16 | (uint32_t)head[2] << 8 | head[3]);
            *height = (int32_t)((uint32_t)head[4] << 24 | (uint32_t)head[5] << 16 | (uint32_t)head[6] << 8 | head[7]);
            if ((int64_t)*width * *height * 4 == size - 8) {
                pixels = malloc((size_t)(size - 8));
                if (pixels != NULL) {
                    (*env)->GetByteArrayRegion(env, result, 8, size - 8, (jbyte *)pixels);
                }
            }
        }
        (*env)->DeleteLocalRef(env, result);
    }
    (*env)->DeleteLocalRef(env, jpath);
    hatter_detach(g_jvm, need_detach);
    return pixels;
}

static int32_t android_picture_shrink(const char *path, const char *out, int32_t longest)
{
    int need_detach;
    JNIEnv *env = hatter_attached_env(g_jvm, &need_detach);
    if (env == NULL) {
        return 0;
    }
    jbyteArray jpath = hatter_utf8_bytes(env, path);
    jbyteArray jout = hatter_utf8_bytes(env, out);
    jint kind = (*env)->CallStaticIntMethod(env, g_class, g_shrink, jpath, jout, (jint)longest);
    if (hatter_check_exception(env, "shrink")) {
        kind = 0;
    }
    (*env)->DeleteLocalRef(env, jpath);
    (*env)->DeleteLocalRef(env, jout);
    hatter_detach(g_jvm, need_detach);
    return kind;
}

/* Called from JNI_OnLoad, where the class loader finds Hatter's classes. */
void setup_android_picture_bridge(JavaVM *vm, JNIEnv *env)
{
    g_jvm = vm;
    jclass cls = (*env)->FindClass(env, "me/jappie/hatter/HatterFiles");
    if (cls == NULL) {
        (*env)->ExceptionClear(env);
        return;
    }
    g_class = (*env)->NewGlobalRef(env, cls);
    (*env)->DeleteLocalRef(env, cls);
    g_pixels = (*env)->GetStaticMethodID(env, g_class, "pixels", "([BI)[B");
    g_shrink = (*env)->GetStaticMethodID(env, g_class, "shrink", "([B[BI)I");
    if (g_pixels == NULL || g_shrink == NULL) {
        (*env)->ExceptionClear(env);
        return;
    }
    picture_register_impl(android_picture_pixels, android_picture_shrink);
}
