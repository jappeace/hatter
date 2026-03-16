/*
 * JNI bridge between Android Java and Haskell FFI exports.
 *
 * This file is compiled by NDK clang (not cabal), and linked into
 * libhaskellmobile.so alongside the Haskell static library.
 */

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "HsFFI.h"

/* Haskell foreign exports */
extern void haskellInit(void);
extern char* haskellGreet(const char* name);

JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM *vm, void *reserved)
{
    hs_init(NULL, NULL);
    haskellInit();
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL
JNI_OnUnload(JavaVM *vm, void *reserved)
{
    hs_exit();
}

JNIEXPORT jstring JNICALL
Java_me_jappie_haskellmobile_MainActivity_greet(JNIEnv *env, jobject thiz, jstring jname)
{
    const char *cname = (*env)->GetStringUTFChars(env, jname, NULL);
    if (cname == NULL) {
        return NULL; /* OutOfMemoryError already thrown */
    }

    char *cresult = haskellGreet(cname);
    (*env)->ReleaseStringUTFChars(env, jname, cname);

    jstring jresult = (*env)->NewStringUTF(env, cresult);
    free(cresult);

    return jresult;
}
