/*
 * JNI helpers for the Android bridges, each of which keeps its own JavaVM.
 */
#ifndef HATTER_JNI_HELPERS_H
#define HATTER_JNI_HELPERS_H

#include <android/log.h>
#include <jni.h>
#include <pthread.h>
#include <string.h>

#define HATTER_JNI_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "Hatter", __VA_ARGS__)

/* UTF-8 as bytes, since JNI's own strings take modified UTF-8. */
static inline jbyteArray hatter_utf8_bytes(JNIEnv *env, const char *s)
{
    const jsize length = (jsize)strlen(s);
    jbyteArray bytes = (*env)->NewByteArray(env, length);
    (*env)->SetByteArrayRegion(env, bytes, 0, length, (const jbyte *)s);
    return bytes;
}

/* The current thread's JNIEnv, attaching the thread if need be, in which
 * case *need_detach says to detach it when done. */
static inline JNIEnv *hatter_attached_env(JavaVM *jvm, int *need_detach)
{
    JNIEnv *env = NULL;
    *need_detach = 0;
    jint status = (*jvm)->GetEnv(jvm, (void **)&env, JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if ((*jvm)->AttachCurrentThread(jvm, &env, NULL) != JNI_OK) {
            HATTER_JNI_LOGE("AttachCurrentThread failed");
            return NULL;
        }
        *need_detach = 1;
    } else if (status != JNI_OK) {
        HATTER_JNI_LOGE("GetEnv failed (status=%d)", status);
        return NULL;
    }
    return env;
}

/* A thread-specific key's destructor: detaches the thread its JNIEnv is
 * for, as it ends. */
static inline void hatter_detach_thread(void *env)
{
    JavaVM *jvm = NULL;
    if ((*(JNIEnv *)env)->GetJavaVM((JNIEnv *)env, &jvm) == JNI_OK) {
        (*jvm)->DetachCurrentThread(jvm);
    }
}

/* The current thread's JNIEnv, attaching the thread until it ends, for
 * threads that call Java often, as for each frame of a call. detach_key's
 * destructor is hatter_detach_thread. */
static inline JNIEnv *hatter_thread_env(JavaVM *jvm, pthread_key_t detach_key)
{
    int attached;
    JNIEnv *env = hatter_attached_env(jvm, &attached);
    if (attached) {
        pthread_setspecific(detach_key, env);
    }
    return env;
}

/* Detaches the thread hatter_attached_env attached. */
static inline void hatter_detach(JavaVM *jvm, int need_detach)
{
    if (need_detach) {
        (*jvm)->DetachCurrentThread(jvm);
    }
}

/* Logs and clears a Java exception thrown in what: 1 if there was one. */
static inline int hatter_check_exception(JNIEnv *env, const char *what)
{
    if (!(*env)->ExceptionCheck(env)) {
        return 0;
    }
    HATTER_JNI_LOGE("%s: Java exception thrown", what);
    (*env)->ExceptionDescribe(env);
    (*env)->ExceptionClear(env);
    return 1;
}

#endif /* HATTER_JNI_HELPERS_H */
