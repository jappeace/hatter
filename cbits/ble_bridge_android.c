/*
 * Android implementation of the BLE bridge callbacks.
 *
 * Uses JNI to call Activity.checkBleAdapter(), Activity.startBleScan(),
 * Activity.stopBleScan(), Activity.connectBleDevice() and
 * Activity.disconnectBleDevice(). Compiled by NDK clang, not cabal.
 *
 * All functions run on the main/UI thread, the same thread that
 * calls haskellRenderUI from Java.  The Java side posts connection
 * events back on the UI thread as well (runOnUiThread), so g_env
 * stays valid for every callback.
 */

#include <jni.h>
#include <android/log.h>
#include "BleBridge.h"
#include "JniBridge.h"

#define LOG_TAG "BleBridge"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Haskell FFI exports (dispatch results back to Haskell callbacks) */
extern void haskellOnBleScanResult(void *ctx, const char *name, const char *address, int32_t rssi);
extern void haskellOnBleConnectionEvent(void *ctx, int32_t event);

/* ---- Global state (valid only on the UI thread) ---- */
static JNIEnv  *g_env          = NULL;
static jobject  g_activity      = NULL;   /* global ref to Activity */
static void    *g_haskell_ctx   = NULL;   /* stored for async JNI callback */

/* Cached JNI method IDs */
static jmethodID g_method_checkBleAdapter;
static jmethodID g_method_startBleScan;
static jmethodID g_method_stopBleScan;
static jmethodID g_method_connectBleDevice;
static jmethodID g_method_disconnectBleDevice;

/* ---- BLE bridge implementations ---- */

static int32_t android_ble_check_adapter(void)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("ble_check_adapter: bridge not initialized");
        return BLE_ADAPTER_UNSUPPORTED;
    }

    jint result = (*env)->CallIntMethod(env, g_activity, g_method_checkBleAdapter);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("ble_check_adapter: Java exception thrown");
        (*env)->ExceptionClear(env);
        return BLE_ADAPTER_UNSUPPORTED;
    }
    LOGI("ble_check_adapter() -> %d", result);
    return (int32_t)result;
}

static void android_ble_start_scan(void *ctx)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("ble_start_scan: bridge not initialized");
        return;
    }

    g_haskell_ctx = ctx;
    LOGI("ble_start_scan()");
    (*env)->CallVoidMethod(env, g_activity, g_method_startBleScan);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("ble_start_scan: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
}

static void android_ble_stop_scan(void)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("ble_stop_scan: bridge not initialized");
        return;
    }

    LOGI("ble_stop_scan()");
    (*env)->CallVoidMethod(env, g_activity, g_method_stopBleScan);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("ble_stop_scan: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
}

static void android_ble_connect(void *ctx, const char *address)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("ble_connect: bridge not initialized");
        return;
    }

    g_haskell_ctx = ctx;
    LOGI("ble_connect(%s)", address ? address : "(null)");
    jstring jaddress = (*env)->NewStringUTF(env, address ? address : "");
    (*env)->CallVoidMethod(env, g_activity, g_method_connectBleDevice, jaddress);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("ble_connect: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, jaddress);
}

static void android_ble_disconnect(void)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("ble_disconnect: bridge not initialized");
        return;
    }

    LOGI("ble_disconnect()");
    (*env)->CallVoidMethod(env, g_activity, g_method_disconnectBleDevice);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("ble_disconnect: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
}

/* ---- Public API ---- */

/*
 * Set up the Android BLE bridge. Called from jni_bridge.c
 * during renderUI (after the Activity is available).
 * Resolves JNI method IDs and registers callbacks with the
 * platform-agnostic dispatcher.
 */
void setup_android_ble_bridge(JNIEnv *env, jobject activity, void *haskellCtx)
{
    g_env = env;
    g_haskell_ctx = haskellCtx;

    if (!g_activity) {
        g_activity = (*env)->NewGlobalRef(env, activity);
    }

    jclass actClass = (*env)->GetObjectClass(env, activity);

    g_method_checkBleAdapter = (*env)->GetMethodID(env, actClass,
        "checkBleAdapter", "()I");
    g_method_startBleScan = (*env)->GetMethodID(env, actClass,
        "startBleScan", "()V");
    g_method_stopBleScan = (*env)->GetMethodID(env, actClass,
        "stopBleScan", "()V");

    if (!g_method_checkBleAdapter || !g_method_startBleScan || !g_method_stopBleScan) {
        LOGE("Failed to resolve BLE JNI method IDs — BLE bridge disabled");
        (*env)->ExceptionClear(env);
        (*env)->DeleteLocalRef(env, actClass);
        return;
    }

    ble_register_impl(android_ble_check_adapter, android_ble_start_scan, android_ble_stop_scan);

    /* Connect methods are resolved separately: a consumer Activity that
     * predates the connect API keeps working scans, and ble_connect
     * then reports BLE_CONNECTION_FAILED instead of crashing. */
    g_method_connectBleDevice = (*env)->GetMethodID(env, actClass,
        "connectBleDevice", "(Ljava/lang/String;)V");
    g_method_disconnectBleDevice = (*env)->GetMethodID(env, actClass,
        "disconnectBleDevice", "()V");

    if (g_method_connectBleDevice && g_method_disconnectBleDevice) {
        ble_register_connect_impl(android_ble_connect, android_ble_disconnect);
    } else {
        LOGE("BLE connect JNI methods missing, BLE connections disabled"
             " (update the Activity to the current hatter android sources)");
        (*env)->ExceptionClear(env);
    }

    /* Clean up local reference */
    (*env)->DeleteLocalRef(env, actClass);

    /* Clear any unexpected pending exception before continuing */
    if ((*env)->ExceptionCheck(env)) {
        LOGE("Unexpected JNI exception after BLE method resolution");
        (*env)->ExceptionClear(env);
    }

    LOGI("Android BLE bridge initialized");
}

/* ---- JNI callback from Java BLE scan result ---- */

JNIEXPORT void JNICALL
JNI_METHOD(onBleScanResult)(JNIEnv *env, jobject thiz, jstring jname, jstring jaddr, jint rssi)
{
    g_env = env;

    const char *cname = NULL;
    const char *caddr = NULL;

    if (jname) {
        cname = (*env)->GetStringUTFChars(env, jname, NULL);
    }
    if (jaddr) {
        caddr = (*env)->GetStringUTFChars(env, jaddr, NULL);
    }

    LOGI("onBleScanResult(name=%s, addr=%s, rssi=%d)", cname ? cname : "(null)", caddr ? caddr : "(null)", rssi);
    haskellOnBleScanResult(g_haskell_ctx, cname, caddr, (int32_t)rssi);

    if (cname) {
        (*env)->ReleaseStringUTFChars(env, jname, cname);
    }
    if (caddr) {
        (*env)->ReleaseStringUTFChars(env, jaddr, caddr);
    }
}

/* ---- JNI callback from Java BLE connection state change ---- */

JNIEXPORT void JNICALL
JNI_METHOD(onBleConnectionEvent)(JNIEnv *env, jobject thiz, jint event)
{
    g_env = env;

    LOGI("onBleConnectionEvent(event=%d)", event);
    haskellOnBleConnectionEvent(g_haskell_ctx, (int32_t)event);
}
