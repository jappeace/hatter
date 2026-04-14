/*
 * Consumer simulation JNI extras — replicates prrrrrrrrr's
 * cbits/jni_extras.c to stress the binary translation layer.
 *
 * Exercises JNI string marshaling (GetStringUTFChars / ReleaseStringUTFChars)
 * which is the exact pattern that triggers libndk_translation's
 * HandleNoExec path.
 *
 * On hatter's standard APK the Java side does not declare setFilesDir
 * as a native method (it's specific to prrrrrrrrr's MainActivity).
 * The mere presence of this symbol in the .so exercises the dynamic
 * linker's symbol resolution under binary translation — and it IS
 * callable from Haskell via FFI if needed.
 */

#include <jni.h>
#include "JniBridge.h"

extern void set_app_files_dir(const char *path);

/* JNI string marshaling — same pattern as prrrrrrrrr's setFilesDir.
 * Exercises GetStringUTFChars / ReleaseStringUTFChars under binary
 * translation. */
JNIEXPORT void JNICALL
JNI_METHOD(setFilesDir)(JNIEnv *env, jobject thiz, jstring path)
{
    (void)thiz;
    const char *cpath = (*env)->GetStringUTFChars(env, path, NULL);
    if (cpath) {
        set_app_files_dir(cpath);
        (*env)->ReleaseStringUTFChars(env, path, cpath);
    }
}

/* No-op consumer method — originally the only content of this file.
 * Kept to exercise the extraJniBridge build path. */
JNIEXPORT jint JNICALL
JNI_METHOD(dummyConsumerMethod)(JNIEnv *env, jobject thiz) {
    (void)env;
    (void)thiz;
    return 42;
}
