/*
 * JNI bridge between Android Java and Haskell FFI exports.
 *
 * This file is compiled by NDK clang (not cabal), and linked into
 * libhatter.so alongside the Haskell static library.
 *
 * The Java package name is controlled by -DJNI_PACKAGE at compile time;
 * see include/JniBridge.h for defaults.
 */

#include <jni.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>
#include "HsFFI.h"
#include "JniBridge.h"
#include "PermissionBridge.h"
#include "SecureStorageBridge.h"
#include "BleBridge.h"
#include "DialogBridge.h"
#include "LocationBridge.h"
#include "AuthSessionBridge.h"
#include "CameraBridge.h"
#include "BottomSheetBridge.h"
#include "HttpBridge.h"
#include "NetworkStatusBridge.h"
#include "AnimationBridge.h"
#include "RedrawBridge.h"
#include "PlatformSignInBridge.h"
#include "NotificationBridge.h"

/* Deduplicate registerForeignExports to prevent OOM on armv7a.
 *
 * When --whole-archive pulls in GHC boot libraries, duplicate .init_array
 * entries can cause registerForeignExports to be called twice with the
 * same ForeignExportsList struct.  The second call creates a self-referencing
 * linked list (struct->next = &struct).  processForeignExports then loops
 * infinitely, calling getStablePtr billions of times and doubling
 * enlargeStablePtrTable until the 32-bit address space is exhausted.
 *
 * Linked via -Wl,--wrap=registerForeignExports (unconditional in lib.nix).
 *
 * See: https://github.com/jappeace/hatter/issues/163
 */
struct ForeignExportsList {
    struct ForeignExportsList *next;
    int n_entries;
    void *exports[];
};

extern void __real_registerForeignExports(struct ForeignExportsList *exports);

static struct ForeignExportsList *g_seen_fexports[64];
static int g_seen_fexports_count = 0;

void __wrap_registerForeignExports(struct ForeignExportsList *exports) {
    for (int i = 0; i < g_seen_fexports_count; i++) {
        if (g_seen_fexports[i] == exports) {
            __android_log_print(ANDROID_LOG_WARN, "HatterInit",
                "registerForeignExports: duplicate struct %p — skipping",
                (void*)exports);
            return;
        }
    }
    if (g_seen_fexports_count < 64) {
        g_seen_fexports[g_seen_fexports_count++] = exports;
    }
    __real_registerForeignExports(exports);
}

/* Runs the user's Haskell main via RTS API (cbits/run_main.c).
 * Returns the opaque AppContext pointer. */
extern void *haskellRunMain(void);

/* Locale detection (cbits/locale.c) */
extern void setSystemLocale(const char *locale);

/* Log detected locale from Haskell (Hatter.Locale) */
extern void haskellLogLocale(void);

/* App files directory (cbits/files_dir.c) */
extern void setAppFilesDir(const char *path);
/* Database key (cbits/database_key.c) */
extern void setDatabaseKey(const unsigned char *key, size_t length);
extern void setDatabaseKeyFailed(void);

/* Device info (cbits/device_info.c) */
extern void setDeviceModel(const char *value);
extern void setDeviceOsVersion(const char *value);
extern void setDeviceScreenDensity(const char *value);
extern void setDeviceScreenWidth(const char *value);
extern void setDeviceScreenHeight(const char *value);

/* Log device info from Haskell (Hatter.DeviceInfo) */
extern void haskellLogDeviceInfo(void);

/* Haskell foreign exports */
extern void haskellOnLifecycle(void *ctx, int eventType);
extern int haskellOnBack(void *ctx);
extern void haskellOnNotificationOpened(void *ctx, const char *key);
extern void haskellOnCallButton(void *ctx, const char *key, int button);
extern int haskellOnLazyBind(void *ctx, int listId, int rowId, int position);
extern int64_t haskellLazyItemKey(void *ctx, int listId, int position);
extern void haskellOnUIScroll(void *ctx, int callbackId, int position);
extern void haskellOnFilePicked(void *ctx, const char *path, const char *name, int64_t size);
extern void haskellOnPicturePicked(void *ctx, const uint8_t *bytes, int32_t size);
extern jobject ui_android_node_view(int32_t nodeId);
extern void setup_android_notification_bridge(JavaVM *vm, JNIEnv *env);
extern void setup_android_call_audio_bridge(JavaVM *vm, JNIEnv *env);
extern void setup_android_picture_bridge(JavaVM *vm, JNIEnv *env);
extern void setup_android_call_video_bridge(JavaVM *vm, JNIEnv *env);
extern void haskellRenderUI(void *ctx);
extern void haskellResetUI(void *ctx);
extern void haskellOnUIEvent(void *ctx, int callbackId);
extern void haskellOnUITextChange(void *ctx, int callbackId, const char *text);
extern void haskellOnPermissionResult(void *ctx, int32_t requestId, int32_t statusCode);
extern void haskellOnSecureStorageResult(void *ctx, int32_t requestId,
                                          int32_t statusCode, const char *value);
extern void haskellOnBleScanResult(void *ctx, const char *name, const char *address, int32_t rssi,
                                   const uint8_t *advertisement, int32_t advertisement_length);
extern void haskellOnDialogResult(void *ctx, int32_t requestId, int32_t actionCode);
extern void haskellOnLocationUpdate(void *ctx, double lat, double lon, double alt, double acc);
extern void haskellOnAuthSessionResult(void *ctx, int32_t requestId,
                                        int32_t statusCode,
                                        const char *redirectUrl,
                                        const char *errorMessage);
extern void haskellOnCameraResult(void *ctx, int32_t requestId,
                                   int32_t statusCode,
                                   const uint8_t *imageData, int32_t imageDataLen,
                                   int32_t width, int32_t height);
extern void haskellOnBottomSheetResult(void *ctx, int32_t requestId, int32_t actionCode);
extern void haskellOnHttpResult(void *ctx, int32_t requestId,
                                 int32_t resultCode, int32_t httpStatus,
                                 const char *headers,
                                 const char *body, int32_t bodyLen);
extern void haskellOnNetworkStatusChange(void *ctx, int connected, int transport);
extern void haskellOnAnimationFrame(void *ctx, double timestampMs);
extern void haskellOnPlatformSignInResult(void *ctx, int32_t requestId,
                                           int32_t statusCode,
                                           const char *identityToken,
                                           const char *userId,
                                           const char *email,
                                           const char *fullName,
                                           int32_t provider);

/* Android UI bridge (from ui_bridge_android.c) */
extern void setup_android_ui_bridge(JNIEnv *env, jobject activity, void *haskellCtx);
extern void android_handle_click(JNIEnv *env, jobject view, void *haskellCtx);
extern void android_handle_text_change(JNIEnv *env, jobject view, jstring text, void *haskellCtx);

/* Android permission bridge (from permission_bridge_android.c) */
extern void setup_android_permission_bridge(JNIEnv *env, jobject activity, void *haskellCtx);

/* Android secure storage bridge (from secure_storage_android.c) */
extern void setup_android_secure_storage_bridge(JNIEnv *env, jobject activity, void *haskellCtx);

/* Android BLE bridge (from ble_bridge_android.c) */
extern void setup_android_ble_bridge(JNIEnv *env, jobject activity, void *haskellCtx);

/* Android dialog bridge (from dialog_bridge_android.c) */
extern void setup_android_dialog_bridge(JNIEnv *env, jobject activity, void *haskellCtx);

/* Android location bridge (from location_bridge_android.c) */
extern void setup_android_location_bridge(JNIEnv *env, jobject activity, void *haskellCtx);

/* Android auth session bridge (from auth_session_android.c) */
extern void setup_android_auth_session_bridge(JNIEnv *env, jobject activity, void *haskellCtx);

/* Android camera bridge (from camera_bridge_android.c) */
extern void setup_android_camera_bridge(JNIEnv *env, jobject activity, void *haskellCtx);
/* Android bottom sheet bridge (from bottom_sheet_android.c) */
extern void setup_android_bottom_sheet_bridge(JNIEnv *env, jobject activity, void *haskellCtx);

/* Android HTTP bridge (from http_bridge_android.c) */
extern void setup_android_http_bridge(JNIEnv *env, jobject activity, void *haskellCtx);

/* Android network status bridge (from network_status_android.c) */
extern void setup_android_network_status_bridge(JNIEnv *env, jobject activity, void *haskellCtx);

/* Android animation bridge (from animation_bridge_android.c) */
extern void setup_android_animation_bridge(JNIEnv *env, jobject activity, void *haskellCtx);

/* Android redraw bridge (from redraw_bridge_android.c) */
extern void setup_android_redraw_bridge(JNIEnv *env, jobject activity, void *haskellCtx);

/* Android platform sign-in bridge (from platform_sign_in_android.c) */
extern void setup_android_platform_sign_in_bridge(JNIEnv *env, jobject activity, void *haskellCtx);

/* Lifecycle event codes (must match Hatter.h) */
#define LIFECYCLE_CREATE     0
#define LIFECYCLE_START      1
#define LIFECYCLE_RESUME     2
#define LIFECYCLE_PAUSE      3
#define LIFECYCLE_STOP       4
#define LIFECYCLE_DESTROY    5
#define LIFECYCLE_LOW_MEMORY 6

/* The runtime's messages, as an uncaught exception's, which it writes to
 * stderr, where Android keeps nothing of an app's. */
typedef void RtsMsgFunction(const char *format, va_list args);
extern RtsMsgFunction *errorMsgFn;
extern RtsMsgFunction *fatalInternalErrorFn;

static void log_rts_error(const char *format, va_list args)
{
    __android_log_vprint(ANDROID_LOG_ERROR, "Hatter", format, args);
}

/* In run_main.c. */
extern void hatter_hs_init(const char *rts_opts);

/* Set by the app's build, like iOS passes its own to hatter_hs_init. */
#ifndef HATTER_RTS_OPTS
#define HATTER_RTS_OPTS NULL
#endif

/* Opaque Haskell context pointer, created during JNI_OnLoad */
static void *g_haskell_ctx = NULL;

JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM *vm, void *reserved)
{
    errorMsgFn = log_rts_error;
    fatalInternalErrorFn = log_rts_error;
    hatter_hs_init(HATTER_RTS_OPTS);

    /* Pre-haskellRunMain platform init: set globals that Haskell code may
       read immediately (e.g. in startMobileApp callbacks). */
    {
        JNIEnv *env;
        (*vm)->GetEnv(vm, (void**)&env, JNI_VERSION_1_6);

        /* Locale: Locale.getDefault().toLanguageTag() (static, no context needed) */
        jclass localeClass = (*env)->FindClass(env, "java/util/Locale");
        jmethodID getDefault = (*env)->GetStaticMethodID(env, localeClass,
            "getDefault", "()Ljava/util/Locale;");
        jobject locale = (*env)->CallStaticObjectMethod(env, localeClass, getDefault);
        jmethodID toLanguageTag = (*env)->GetMethodID(env, localeClass,
            "toLanguageTag", "()Ljava/lang/String;");
        jstring jtag = (*env)->CallObjectMethod(env, locale, toLanguageTag);
        const char *ctag = (*env)->GetStringUTFChars(env, jtag, NULL);
        setSystemLocale(strdup(ctag));
        (*env)->ReleaseStringUTFChars(env, jtag, ctag);

        /* Files dir: ActivityThread.currentApplication().getFilesDir().
           The Application exists before any Activity, so this is available
           during JNI_OnLoad (called from System.loadLibrary). */
        jclass atClass = (*env)->FindClass(env, "android/app/ActivityThread");
        jmethodID currentApp = (*env)->GetStaticMethodID(env, atClass,
            "currentApplication", "()Landroid/app/Application;");
        jobject app = (*env)->CallStaticObjectMethod(env, atClass, currentApp);
        /* Android has a keystore: no key from it is a failure. */
        setDatabaseKeyFailed();
        if (app) {
            jclass ctxClass = (*env)->FindClass(env, "android/content/Context");
            jmethodID getFilesDir = (*env)->GetMethodID(env, ctxClass,
                "getFilesDir", "()Ljava/io/File;");
            jobject filesDir = (*env)->CallObjectMethod(env, app, getFilesDir);
            if (filesDir) {
                jclass fileClass = (*env)->FindClass(env, "java/io/File");
                jmethodID getAbsPath = (*env)->GetMethodID(env, fileClass,
                    "getAbsolutePath", "()Ljava/lang/String;");
                jstring jpath = (*env)->CallObjectMethod(env, filesDir, getAbsPath);
                const char *cpath = (*env)->GetStringUTFChars(env, jpath, NULL);
                setAppFilesDir(strdup(cpath));
                (*env)->ReleaseStringUTFChars(env, jpath, cpath);
            }

            /* Database key: from the keystore, for the activity and for a
               service started alone alike. */
            jclass keyClass = (*env)->FindClass(env, "me/jappie/hatter/HatterDatabaseKey");
            jmethodID getKey = keyClass ? (*env)->GetStaticMethodID(env, keyClass,
                "get", "(Landroid/content/Context;)[B") : NULL;
            jbyteArray jkey = getKey ? (*env)->CallStaticObjectMethod(env, keyClass, getKey, app) : NULL;
            if ((*env)->ExceptionCheck(env)) {
                (*env)->ExceptionClear(env);
                jkey = NULL;
            }
            if (jkey) {
                jsize length = (*env)->GetArrayLength(env, jkey);
                jbyte *bytes = (*env)->GetByteArrayElements(env, jkey, NULL);
                setDatabaseKey((const unsigned char *)bytes, (size_t)length);
                (*env)->ReleaseByteArrayElements(env, jkey, bytes, JNI_ABORT);
            } else {
                setDatabaseKeyFailed();
            }
        }

        /* Device info: Build.MODEL */
        {
            jclass buildClass = (*env)->FindClass(env, "android/os/Build");
            jfieldID modelField = (*env)->GetStaticFieldID(env, buildClass,
                "MODEL", "Ljava/lang/String;");
            jstring jmodel = (*env)->GetStaticObjectField(env, buildClass, modelField);
            const char *cmodel = (*env)->GetStringUTFChars(env, jmodel, NULL);
            setDeviceModel(strdup(cmodel));
            (*env)->ReleaseStringUTFChars(env, jmodel, cmodel);
        }

        /* Device info: Build.VERSION.RELEASE */
        {
            jclass versionClass = (*env)->FindClass(env, "android/os/Build$VERSION");
            jfieldID releaseField = (*env)->GetStaticFieldID(env, versionClass,
                "RELEASE", "Ljava/lang/String;");
            jstring jrelease = (*env)->GetStaticObjectField(env, versionClass, releaseField);
            const char *crelease = (*env)->GetStringUTFChars(env, jrelease, NULL);
            setDeviceOsVersion(strdup(crelease));
            (*env)->ReleaseStringUTFChars(env, jrelease, crelease);
        }

        /* Device info: DisplayMetrics (density, width, height) */
        {
            jclass resourcesClass = (*env)->FindClass(env, "android/content/res/Resources");
            jmethodID getSystem = (*env)->GetStaticMethodID(env, resourcesClass,
                "getSystem", "()Landroid/content/res/Resources;");
            jobject resources = (*env)->CallStaticObjectMethod(env, resourcesClass, getSystem);
            jmethodID getDisplayMetrics = (*env)->GetMethodID(env, resourcesClass,
                "getDisplayMetrics", "()Landroid/util/DisplayMetrics;");
            jobject metrics = (*env)->CallObjectMethod(env, resources, getDisplayMetrics);

            jclass dmClass = (*env)->FindClass(env, "android/util/DisplayMetrics");

            jfieldID densityField = (*env)->GetFieldID(env, dmClass, "density", "F");
            float density = (*env)->GetFloatField(env, metrics, densityField);
            char densityBuf[32];
            snprintf(densityBuf, sizeof(densityBuf), "%.2f", density);
            setDeviceScreenDensity(strdup(densityBuf));

            jfieldID widthField = (*env)->GetFieldID(env, dmClass, "widthPixels", "I");
            int width = (*env)->GetIntField(env, metrics, widthField);
            char widthBuf[32];
            snprintf(widthBuf, sizeof(widthBuf), "%d", width);
            setDeviceScreenWidth(strdup(widthBuf));

            jfieldID heightField = (*env)->GetFieldID(env, dmClass, "heightPixels", "I");
            int height = (*env)->GetIntField(env, metrics, heightField);
            char heightBuf[32];
            snprintf(heightBuf, sizeof(heightBuf), "%d", height);
            setDeviceScreenHeight(strdup(heightBuf));
        }
    }

    {
        JNIEnv *env;
        (*vm)->GetEnv(vm, (void**)&env, JNI_VERSION_1_6);
        setup_android_notification_bridge(vm, env);
        setup_android_call_audio_bridge(vm, env);
        setup_android_picture_bridge(vm, env);
        setup_android_call_video_bridge(vm, env);
    }

    g_haskell_ctx = haskellRunMain();
    haskellLogLocale();
    haskellLogDeviceInfo();

    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL
JNI_OnUnload(JavaVM *vm, void *reserved)
{
    hs_exit();
}

/* --- UI bridge JNI methods --- */

JNIEXPORT void JNICALL
JNI_METHOD(renderUI)(JNIEnv *env, jobject thiz)
{
    /* The bridge setups run once per activity: they resolve JNI method
     * IDs, cache the activity, register callbacks, and (in
     * setup_android_ui_bridge) release the node pool.
     *
     * renderUI() is called both for the initial render and for every
     * subsequent redraw (Activity.requestRedraw -> renderUI). Re-running setup
     * on each redraw wiped the native node pool while the Haskell render state
     * kept the old node IDs, so setStrProp/addChild targeted freed nodes and
     * callback-driven redraws never reached the screen.
     *
     * Android recreates the activity in the same process after Back or a
     * rotation, and the views went with the old one. The bridges then take
     * the new activity, and Haskell forgets its views to create them all
     * again. */
    static jobject g_bridges_activity = NULL;
    if (!g_bridges_activity || !(*env)->IsSameObject(env, thiz, g_bridges_activity)) {
        if (g_bridges_activity) {
            (*env)->DeleteGlobalRef(env, g_bridges_activity);
            haskellResetUI(g_haskell_ctx);
        }
        g_bridges_activity = (*env)->NewGlobalRef(env, thiz);
        setup_android_ui_bridge(env, thiz, g_haskell_ctx);
        setup_android_permission_bridge(env, thiz, g_haskell_ctx);
        setup_android_secure_storage_bridge(env, thiz, g_haskell_ctx);
        setup_android_ble_bridge(env, thiz, g_haskell_ctx);
        setup_android_dialog_bridge(env, thiz, g_haskell_ctx);
        setup_android_location_bridge(env, thiz, g_haskell_ctx);
        setup_android_auth_session_bridge(env, thiz, g_haskell_ctx);
        setup_android_camera_bridge(env, thiz, g_haskell_ctx);
        setup_android_bottom_sheet_bridge(env, thiz, g_haskell_ctx);
        setup_android_http_bridge(env, thiz, g_haskell_ctx);
        setup_android_network_status_bridge(env, thiz, g_haskell_ctx);
        setup_android_animation_bridge(env, thiz, g_haskell_ctx);
        setup_android_redraw_bridge(env, thiz, g_haskell_ctx);
        setup_android_platform_sign_in_bridge(env, thiz, g_haskell_ctx);
    }
    haskellRenderUI(g_haskell_ctx);
}

JNIEXPORT void JNICALL
JNI_METHOD(onButtonClick)(JNIEnv *env, jobject thiz, jobject view)
{
    android_handle_click(env, view, g_haskell_ctx);
}

/* Where a list is, by Hatter.Action.ListPosition's number. */
JNIEXPORT void JNICALL
JNI_METHOD(onScrolled)(JNIEnv *env, jobject thiz, jint callbackId, jint position)
{
    haskellOnUIScroll(g_haskell_ctx, callbackId, position);
}

JNIEXPORT void JNICALL
JNI_METHOD(onLongPress)(JNIEnv *env, jobject thiz, jint callbackId)
{
    haskellOnUIEvent(g_haskell_ctx, callbackId);
}

JNIEXPORT void JNICALL
JNI_METHOD(onTextChange)(JNIEnv *env, jobject thiz, jobject view, jstring text)
{
    android_handle_text_change(env, view, text, g_haskell_ctx);
}

/* Lifecycle JNI callbacks */
JNIEXPORT void JNICALL
JNI_METHOD(onLifecycleCreate)(JNIEnv *env, jobject thiz)
{
    haskellOnLifecycle(g_haskell_ctx, LIFECYCLE_CREATE);
}

JNIEXPORT void JNICALL
JNI_METHOD(onLifecycleStart)(JNIEnv *env, jobject thiz)
{
    haskellOnLifecycle(g_haskell_ctx, LIFECYCLE_START);
}

JNIEXPORT void JNICALL
JNI_METHOD(onLifecycleResume)(JNIEnv *env, jobject thiz)
{
    haskellOnLifecycle(g_haskell_ctx, LIFECYCLE_RESUME);
}

JNIEXPORT void JNICALL
JNI_METHOD(onLifecyclePause)(JNIEnv *env, jobject thiz)
{
    haskellOnLifecycle(g_haskell_ctx, LIFECYCLE_PAUSE);
}

JNIEXPORT void JNICALL
JNI_METHOD(onLifecycleStop)(JNIEnv *env, jobject thiz)
{
    haskellOnLifecycle(g_haskell_ctx, LIFECYCLE_STOP);
}

JNIEXPORT void JNICALL
JNI_METHOD(onLifecycleDestroy)(JNIEnv *env, jobject thiz)
{
    haskellOnLifecycle(g_haskell_ctx, LIFECYCLE_DESTROY);
}

JNIEXPORT jboolean JNICALL
JNI_METHOD(onBackPressedNative)(JNIEnv *env, jobject thiz)
{
    return haskellOnBack(g_haskell_ctx) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
JNI_METHOD(onNotificationOpenedNative)(JNIEnv *env, jobject thiz, jbyteArray jkey)
{
    /* UTF-8, with a NUL after it. */
    const jsize length = (*env)->GetArrayLength(env, jkey);
    char *key = malloc((size_t)length + 1);
    if (key == NULL) {
        return;
    }
    (*env)->GetByteArrayRegion(env, jkey, 0, length, (jbyte *)key);
    key[length] = '\0';
    haskellOnNotificationOpened(g_haskell_ctx, key);
    free(key);
}

/* A button of a ringing notification, from any thread: 0 answers, 1 declines. */
JNIEXPORT void JNICALL
JNI_METHOD_NAME2(JNI_PACKAGE, HatterNotifications, onCallButton)(JNIEnv *env, jclass clazz, jbyteArray jkey, jint button)
{
    /* UTF-8, with a NUL after it. */
    const jsize length = (*env)->GetArrayLength(env, jkey);
    char *key = malloc((size_t)length + 1);
    if (key == NULL) {
        return;
    }
    (*env)->GetByteArrayRegion(env, jkey, 0, length, (jbyte *)key);
    key[length] = '\0';
    haskellOnCallButton(g_haskell_ctx, key, button);
    free(key);
}

/* Render a lazy column's item at the position into a row: the row given
 * (0 for none) or a new one, or 0 for nothing to show. */
JNIEXPORT jint JNICALL
JNI_METHOD(onLazyBindNative)(JNIEnv *env, jobject thiz, jint listId, jint rowId, jint position)
{
    return haskellOnLazyBind(g_haskell_ctx, listId, rowId, position);
}

/* The key of a lazy column's item, as the adapter's stable ID for it. */
JNIEXPORT jlong JNICALL
JNI_METHOD(lazyItemKeyNative)(JNIEnv *env, jobject thiz, jint listId, jint position)
{
    return haskellLazyItemKey(g_haskell_ctx, listId, position);
}

/* A copy of the file the user picked, with its name: UTF-8 in byte arrays. */
JNIEXPORT void JNICALL
JNI_METHOD(onPicturePickedNative)(JNIEnv *env, jobject thiz, jbyteArray jpng)
{
    const jsize length = (*env)->GetArrayLength(env, jpng);
    jbyte *png = (*env)->GetByteArrayElements(env, jpng, NULL);
    if (png != NULL) {
        haskellOnPicturePicked(g_haskell_ctx, (const uint8_t *)png, (int32_t)length);
        (*env)->ReleaseByteArrayElements(env, jpng, png, JNI_ABORT);
    }
}

JNIEXPORT void JNICALL
JNI_METHOD(onFilePickedNative)(JNIEnv *env, jobject thiz, jbyteArray jpath, jbyteArray jname, jlong size)
{
    const jsize pathLength = (*env)->GetArrayLength(env, jpath);
    const jsize nameLength = (*env)->GetArrayLength(env, jname);
    char *path = malloc((size_t)pathLength + 1);
    char *name = malloc((size_t)nameLength + 1);
    if (path != NULL && name != NULL) {
        (*env)->GetByteArrayRegion(env, jpath, 0, pathLength, (jbyte *)path);
        (*env)->GetByteArrayRegion(env, jname, 0, nameLength, (jbyte *)name);
        path[pathLength] = '\0';
        name[nameLength] = '\0';
        haskellOnFilePicked(g_haskell_ctx, path, name, (int64_t)size);
    }
    free(path);
    free(name);
}

/* The view of a node, or null. */
JNIEXPORT jobject JNICALL
JNI_METHOD(nodeViewNative)(JNIEnv *env, jobject thiz, jint nodeId)
{
    jobject view = ui_android_node_view(nodeId);
    return view != NULL ? (*env)->NewLocalRef(env, view) : NULL;
}

JNIEXPORT void JNICALL
JNI_METHOD(onLifecycleLowMemory)(JNIEnv *env, jobject thiz)
{
    haskellOnLifecycle(g_haskell_ctx, LIFECYCLE_LOW_MEMORY);
}
