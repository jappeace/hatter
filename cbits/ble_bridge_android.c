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
extern void haskellOnBleCharacteristicDiscovered(void *ctx, const char *serviceUuid,
                                                 const char *characteristicUuid,
                                                 int32_t properties);
extern void haskellOnBleGattResult(void *ctx, int32_t operation, int32_t status,
                                   const uint8_t *data, int32_t length);
extern void haskellOnBleNotification(void *ctx, const char *serviceUuid,
                                     const char *characteristicUuid,
                                     const uint8_t *data, int32_t length);

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
static jmethodID g_method_discoverBleServices;
static jmethodID g_method_readBleCharacteristic;
static jmethodID g_method_writeBleCharacteristic;
static jmethodID g_method_setBleCharacteristicNotification;
static jmethodID g_method_requestBleMtu;

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

static void android_ble_start_scan(void *ctx, const char *service_uuid_filter)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("ble_start_scan: bridge not initialized");
        return;
    }

    g_haskell_ctx = ctx;
    LOGI("ble_start_scan(filter=%s)", service_uuid_filter ? service_uuid_filter : "(none)");
    jstring jfilter = service_uuid_filter
        ? (*env)->NewStringUTF(env, service_uuid_filter)
        : NULL;
    (*env)->CallVoidMethod(env, g_activity, g_method_startBleScan, jfilter);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("ble_start_scan: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
    if (jfilter) {
        (*env)->DeleteLocalRef(env, jfilter);
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

static void android_ble_discover_services(void *ctx)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("ble_discover_services: bridge not initialized");
        return;
    }

    g_haskell_ctx = ctx;
    LOGI("ble_discover_services()");
    (*env)->CallVoidMethod(env, g_activity, g_method_discoverBleServices);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("ble_discover_services: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
}

static void android_ble_read_characteristic(void *ctx, const char *service_uuid,
                                            const char *characteristic_uuid)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("ble_read_characteristic: bridge not initialized");
        return;
    }

    g_haskell_ctx = ctx;
    LOGI("ble_read_characteristic(%s, %s)", service_uuid, characteristic_uuid);
    jstring jservice = (*env)->NewStringUTF(env, service_uuid);
    jstring jcharacteristic = (*env)->NewStringUTF(env, characteristic_uuid);
    (*env)->CallVoidMethod(env, g_activity, g_method_readBleCharacteristic,
                           jservice, jcharacteristic);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("ble_read_characteristic: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, jservice);
    (*env)->DeleteLocalRef(env, jcharacteristic);
}

static void android_ble_write_characteristic(void *ctx, const char *service_uuid,
                                             const char *characteristic_uuid,
                                             const uint8_t *data, int32_t length,
                                             int32_t write_mode)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("ble_write_characteristic: bridge not initialized");
        return;
    }

    g_haskell_ctx = ctx;
    LOGI("ble_write_characteristic(%s, %s, %d bytes, mode=%d)",
         service_uuid, characteristic_uuid, length, write_mode);
    jstring jservice = (*env)->NewStringUTF(env, service_uuid);
    jstring jcharacteristic = (*env)->NewStringUTF(env, characteristic_uuid);
    jbyteArray jdata = (*env)->NewByteArray(env, length);
    (*env)->SetByteArrayRegion(env, jdata, 0, length, (const jbyte *)data);
    (*env)->CallVoidMethod(env, g_activity, g_method_writeBleCharacteristic,
                           jservice, jcharacteristic, jdata, (jint)write_mode);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("ble_write_characteristic: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, jservice);
    (*env)->DeleteLocalRef(env, jcharacteristic);
    (*env)->DeleteLocalRef(env, jdata);
}

static void android_ble_set_characteristic_notification(void *ctx,
                                                        const char *service_uuid,
                                                        const char *characteristic_uuid,
                                                        int32_t enable)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("ble_set_characteristic_notification: bridge not initialized");
        return;
    }

    g_haskell_ctx = ctx;
    LOGI("ble_set_characteristic_notification(%s, %s, %d)",
         service_uuid, characteristic_uuid, enable);
    jstring jservice = (*env)->NewStringUTF(env, service_uuid);
    jstring jcharacteristic = (*env)->NewStringUTF(env, characteristic_uuid);
    (*env)->CallVoidMethod(env, g_activity,
                           g_method_setBleCharacteristicNotification,
                           jservice, jcharacteristic, (jint)enable);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("ble_set_characteristic_notification: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, jservice);
    (*env)->DeleteLocalRef(env, jcharacteristic);
}

static void android_ble_request_mtu(void *ctx, int32_t mtu)
{
    JNIEnv *env = g_env;
    if (!env || !g_activity) {
        LOGE("ble_request_mtu: bridge not initialized");
        return;
    }

    g_haskell_ctx = ctx;
    LOGI("ble_request_mtu(%d)", mtu);
    (*env)->CallVoidMethod(env, g_activity, g_method_requestBleMtu, (jint)mtu);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("ble_request_mtu: Java exception thrown");
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
        "startBleScan", "(Ljava/lang/String;)V");
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

    /* GATT operation methods, resolved with the same grace as connect:
     * missing methods disable GATT (operations then fail visibly with
     * BLE_GATT_STATUS_NO_IMPL) without breaking scanning. */
    g_method_discoverBleServices = (*env)->GetMethodID(env, actClass,
        "discoverBleServices", "()V");
    g_method_readBleCharacteristic = (*env)->GetMethodID(env, actClass,
        "readBleCharacteristic", "(Ljava/lang/String;Ljava/lang/String;)V");
    g_method_writeBleCharacteristic = (*env)->GetMethodID(env, actClass,
        "writeBleCharacteristic", "(Ljava/lang/String;Ljava/lang/String;[BI)V");
    g_method_setBleCharacteristicNotification = (*env)->GetMethodID(env, actClass,
        "setBleCharacteristicNotification", "(Ljava/lang/String;Ljava/lang/String;I)V");
    g_method_requestBleMtu = (*env)->GetMethodID(env, actClass,
        "requestBleMtu", "(I)V");

    if (g_method_discoverBleServices && g_method_readBleCharacteristic
        && g_method_writeBleCharacteristic
        && g_method_setBleCharacteristicNotification && g_method_requestBleMtu) {
        ble_register_gatt_impl(android_ble_discover_services,
                               android_ble_read_characteristic,
                               android_ble_write_characteristic,
                               android_ble_set_characteristic_notification,
                               android_ble_request_mtu);
    } else {
        LOGE("BLE GATT JNI methods missing, GATT operations disabled"
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

/* ---- JNI callback: one discovered characteristic (streamed) ---- */

JNIEXPORT void JNICALL
JNI_METHOD(onBleCharacteristicDiscovered)(JNIEnv *env, jobject thiz,
                                          jstring jservice, jstring jcharacteristic,
                                          jint properties)
{
    g_env = env;

    const char *service = (*env)->GetStringUTFChars(env, jservice, NULL);
    const char *characteristic = (*env)->GetStringUTFChars(env, jcharacteristic, NULL);

    haskellOnBleCharacteristicDiscovered(g_haskell_ctx, service, characteristic,
                                         (int32_t)properties);

    (*env)->ReleaseStringUTFChars(env, jservice, service);
    (*env)->ReleaseStringUTFChars(env, jcharacteristic, characteristic);
}

/* ---- JNI callback: GATT operation completion ---- */

JNIEXPORT void JNICALL
JNI_METHOD(onBleGattResult)(JNIEnv *env, jobject thiz, jint operation,
                            jint status, jbyteArray jdata, jint mtu)
{
    g_env = env;

    LOGI("onBleGattResult(operation=%d, status=%d)", operation, status);

    if (jdata) {
        jsize length = (*env)->GetArrayLength(env, jdata);
        jbyte *bytes = (*env)->GetByteArrayElements(env, jdata, NULL);
        haskellOnBleGattResult(g_haskell_ctx, (int32_t)operation, (int32_t)status,
                               (const uint8_t *)bytes, (int32_t)length);
        (*env)->ReleaseByteArrayElements(env, jdata, bytes, JNI_ABORT);
    } else {
        /* No payload; the length field carries the granted MTU for
         * BLE_GATT_OP_MTU completions and is 0 otherwise. */
        haskellOnBleGattResult(g_haskell_ctx, (int32_t)operation, (int32_t)status,
                               NULL, (int32_t)mtu);
    }
}

/* ---- JNI callback: characteristic notification data ---- */

JNIEXPORT void JNICALL
JNI_METHOD(onBleNotification)(JNIEnv *env, jobject thiz, jstring jservice,
                              jstring jcharacteristic, jbyteArray jdata)
{
    g_env = env;

    const char *service = (*env)->GetStringUTFChars(env, jservice, NULL);
    const char *characteristic = (*env)->GetStringUTFChars(env, jcharacteristic, NULL);
    jsize length = (*env)->GetArrayLength(env, jdata);
    jbyte *bytes = (*env)->GetByteArrayElements(env, jdata, NULL);

    haskellOnBleNotification(g_haskell_ctx, service, characteristic,
                             (const uint8_t *)bytes, (int32_t)length);

    (*env)->ReleaseByteArrayElements(env, jdata, bytes, JNI_ABORT);
    (*env)->ReleaseStringUTFChars(env, jservice, service);
    (*env)->ReleaseStringUTFChars(env, jcharacteristic, characteristic);
}
