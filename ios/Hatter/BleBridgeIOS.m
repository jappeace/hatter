/*
 * iOS implementation of the BLE bridge callbacks.
 *
 * Uses CoreBluetooth (CBCentralManager/CBPeripheral) to check adapter
 * state, scan for peripherals, manage GATT connections and perform
 * GATT operations.  Compiled by Xcode, not GHC.
 *
 * All Haskell callbacks are dispatched on the main thread.
 *
 * Note: the iOS simulator does not support CoreBluetooth (the manager
 * reports CBManagerStateUnsupported), so on the simulator scans find
 * nothing and connection attempts / GATT operations fail visibly.
 */

#import <CoreBluetooth/CoreBluetooth.h>
#import <os/log.h>
#include "BleBridge.h"

#define LOG_TAG "BleBridge"
static os_log_t g_log;

#define LOGI(fmt, ...) os_log_info(g_log, fmt, ##__VA_ARGS__)
#define LOGE(fmt, ...) os_log_error(g_log, fmt, ##__VA_ARGS__)

/* Haskell FFI exports (dispatch results back to Haskell callbacks) */
extern void haskellOnBleScanResult(void *ctx, const char *name, const char *address, int32_t rssi,
                                   const uint8_t *advertisement, int32_t advertisement_length);
extern void haskellOnBleConnectionEvent(void *ctx, int32_t event);
extern void haskellOnBleCharacteristicDiscovered(void *ctx, const char *serviceUuid,
                                                 const char *characteristicUuid,
                                                 int32_t properties);
extern void haskellOnBleGattResult(void *ctx, int32_t operation, int32_t status,
                                   const uint8_t *data, int32_t length);
extern void haskellOnBleNotification(void *ctx, const char *serviceUuid,
                                     const char *characteristicUuid,
                                     const uint8_t *data, int32_t length);

/* ---- Module-level state (declared before use in delegate methods) ---- */

static BOOL g_scanning_requested = NO;
/* Service UUID filter for a scan requested before the manager was
 * ready; nil means unfiltered. */
static NSArray<CBUUID *> *g_scan_filter = nil;

/* Generic nonzero status for GATT failures that happen before the
 * platform stack is involved (not connected, characteristic missing,
 * simulator).  Mirrors Android's GATT_FAILURE. */
#define IOS_GATT_FAILURE 0x101

/* ---- Scan + connection + GATT delegate ---- */

@interface BleScanDelegate : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, assign) void *haskellCtx;
@property (nonatomic, strong) CBCentralManager *centralManager;
/* Peripherals seen during scanning, keyed by identifier UUID string.
 * CoreBluetooth can only connect to CBPeripheral instances it handed
 * out earlier, so ble_connect looks the address up here. */
@property (nonatomic, strong) NSMutableDictionary<NSString *, CBPeripheral *> *discoveredPeripherals;
@property (nonatomic, strong) CBPeripheral *connectedPeripheral;
/* Services whose characteristic discovery is still outstanding during
 * a ble_discover_services run. */
@property (nonatomic, assign) NSUInteger pendingServiceDiscoveries;
/* Characteristic with an outstanding read.  didUpdateValueForCharacteristic
 * fires for both reads and notifications; a matching pending read
 * means read completion, anything else is a notification. */
@property (nonatomic, strong) CBCharacteristic *pendingReadCharacteristic;
/* Which operation a pending setNotifyValue belongs to:
 * BLE_GATT_OP_SUBSCRIBE or BLE_GATT_OP_UNSUBSCRIBE. */
@property (nonatomic, assign) int32_t notificationOpInFlight;
/* Dispatch a BLE_CONNECTION_* event to Haskell on the main thread. */
- (void)dispatchConnectionEvent:(int32_t)event;
/* Dispatch a GATT completion to Haskell on the main thread. */
- (void)dispatchGattResult:(int32_t)operation status:(int32_t)status
                      data:(NSData *)data mtu:(int32_t)mtu;
@end

@implementation BleScanDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _discoveredPeripherals = [NSMutableDictionary dictionary];
        _notificationOpInFlight = BLE_GATT_OP_SUBSCRIBE;
    }
    return self;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    LOGI("CBCentralManager state: %ld", (long)central.state);
    /* If scanning was requested before the manager was ready, start now */
    if (central.state == CBManagerStatePoweredOn && g_scanning_requested) {
        [central scanForPeripheralsWithServices:g_scan_filter
                                        options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
        LOGI("BLE scan started (deferred)");
    }
}

/* Re-encode CoreBluetooth's parsed advertisement dictionary into the
 * raw AD structure format (length : type : payload) that Android
 * delivers as-is, so the Haskell side (Hatter.BleAdvertisement) has a
 * single decoding path for both platforms. CoreBluetooth never
 * exposes the original bytes, only parsed fields; the two fields
 * Haskell surfaces are encoded back: service data (AD 0x16/0x20/0x21
 * by UUID width, UUID little-endian like on air) and manufacturer
 * data (AD 0xFF, whose NSData already starts with the little-endian
 * company id). */
static NSData *encodeAdvertisementData(NSDictionary<NSString *, id> *advertisementData)
{
    NSMutableData *encoded = [NSMutableData data];

    NSDictionary<CBUUID *, NSData *> *serviceData =
        advertisementData[CBAdvertisementDataServiceDataKey];
    for (CBUUID *uuid in serviceData) {
        NSData *payload = serviceData[uuid];
        NSData *uuidBytes = uuid.data; /* big-endian */
        uint8_t adType;
        if (uuidBytes.length == 2) {
            adType = 0x16;
        } else if (uuidBytes.length == 4) {
            adType = 0x20;
        } else if (uuidBytes.length == 16) {
            adType = 0x21;
        } else {
            continue;
        }
        NSUInteger bodyLength = 1 + uuidBytes.length + payload.length;
        if (bodyLength > 0xFF) {
            continue;
        }
        uint8_t lengthByte = (uint8_t)bodyLength;
        [encoded appendBytes:&lengthByte length:1];
        [encoded appendBytes:&adType length:1];
        const uint8_t *bigEndian = uuidBytes.bytes;
        for (NSUInteger i = uuidBytes.length; i > 0; i--) {
            [encoded appendBytes:&bigEndian[i - 1] length:1];
        }
        [encoded appendData:payload];
    }

    NSData *manufacturerData =
        advertisementData[CBAdvertisementDataManufacturerDataKey];
    if (manufacturerData.length >= 2 && manufacturerData.length + 1 <= 0xFF) {
        uint8_t lengthByte = (uint8_t)(manufacturerData.length + 1);
        uint8_t adType = 0xFF;
        [encoded appendBytes:&lengthByte length:1];
        [encoded appendBytes:&adType length:1];
        [encoded appendData:manufacturerData];
    }

    return encoded;
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    NSString *identifier = [peripheral.identifier UUIDString];
    self.discoveredPeripherals[identifier] = peripheral;

    const char *name = peripheral.name ? [peripheral.name UTF8String] : NULL;
    const char *address = [identifier UTF8String];
    int32_t rssi = [RSSI intValue];
    NSData *advertisement = encodeAdvertisementData(advertisementData);

    dispatch_async(dispatch_get_main_queue(), ^{
        haskellOnBleScanResult(self.haskellCtx, name, address, rssi,
                               advertisement.length ? (const uint8_t *)advertisement.bytes : NULL,
                               (int32_t)advertisement.length);
    });
}

- (void)dispatchConnectionEvent:(int32_t)event {
    dispatch_async(dispatch_get_main_queue(), ^{
        haskellOnBleConnectionEvent(self.haskellCtx, event);
    });
}

- (void)dispatchGattResult:(int32_t)operation status:(int32_t)status
                      data:(NSData *)data mtu:(int32_t)mtu {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (data) {
            haskellOnBleGattResult(self.haskellCtx, operation, status,
                                   (const uint8_t *)data.bytes, (int32_t)data.length);
        } else {
            haskellOnBleGattResult(self.haskellCtx, operation, status, NULL, mtu);
        }
    });
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {
    LOGI("didConnectPeripheral: %@", peripheral.identifier);
    self.connectedPeripheral = peripheral;
    peripheral.delegate = self;
    [self dispatchConnectionEvent:BLE_CONNECTION_ESTABLISHED];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    LOGE("didFailToConnectPeripheral: %@", error);
    self.connectedPeripheral = nil;
    [self dispatchConnectionEvent:BLE_CONNECTION_FAILED];
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    LOGI("didDisconnectPeripheral: %@", error);
    self.connectedPeripheral = nil;
    [self dispatchConnectionEvent:error == nil ? BLE_CONNECTION_CLOSED
                                               : BLE_CONNECTION_FAILED];
}

/* ---- CBPeripheralDelegate: GATT operations ---- */

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) {
        LOGE("didDiscoverServices: %@", error);
        [self dispatchGattResult:BLE_GATT_OP_DISCOVER status:(int32_t)error.code
                            data:nil mtu:0];
        return;
    }
    if (peripheral.services.count == 0) {
        [self dispatchGattResult:BLE_GATT_OP_DISCOVER status:BLE_GATT_STATUS_SUCCESS
                            data:nil mtu:0];
        return;
    }
    self.pendingServiceDiscoveries = peripheral.services.count;
    for (CBService *service in peripheral.services) {
        [peripheral discoverCharacteristics:nil forService:service];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    if (error) {
        LOGE("didDiscoverCharacteristicsForService: %@", error);
    } else {
        for (CBCharacteristic *characteristic in service.characteristics) {
            int32_t properties = 0;
            if (characteristic.properties & CBCharacteristicPropertyRead) {
                properties |= BLE_CHAR_PROP_READ;
            }
            if (characteristic.properties & CBCharacteristicPropertyWrite) {
                properties |= BLE_CHAR_PROP_WRITE;
            }
            if (characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse) {
                properties |= BLE_CHAR_PROP_WRITE_NO_RESPONSE;
            }
            if (characteristic.properties & CBCharacteristicPropertyNotify) {
                properties |= BLE_CHAR_PROP_NOTIFY;
            }
            /* Capture the objects, not their UTF8String pointers: the
             * C pointers do not outlive the autorelease pool, the
             * block does. */
            NSString *serviceUuidString = [service.UUID UUIDString];
            NSString *characteristicUuidString = [characteristic.UUID UUIDString];
            const int32_t propertyBits = properties;
            dispatch_async(dispatch_get_main_queue(), ^{
                haskellOnBleCharacteristicDiscovered(self.haskellCtx,
                                                     [serviceUuidString UTF8String],
                                                     [characteristicUuidString UTF8String],
                                                     propertyBits);
            });
        }
    }
    if (self.pendingServiceDiscoveries > 0) {
        self.pendingServiceDiscoveries -= 1;
    }
    if (self.pendingServiceDiscoveries == 0) {
        [self dispatchGattResult:BLE_GATT_OP_DISCOVER status:BLE_GATT_STATUS_SUCCESS
                            data:nil mtu:0];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    /* Fires for both read completions and notifications; a matching
     * pending read means this is the read result. */
    if (self.pendingReadCharacteristic == characteristic) {
        self.pendingReadCharacteristic = nil;
        if (error) {
            [self dispatchGattResult:BLE_GATT_OP_READ status:(int32_t)error.code
                                data:nil mtu:0];
        } else {
            [self dispatchGattResult:BLE_GATT_OP_READ status:BLE_GATT_STATUS_SUCCESS
                                data:(characteristic.value ?: [NSData data]) mtu:0];
        }
        return;
    }

    if (error) {
        LOGE("notification error: %@", error);
        return;
    }
    /* Capture the objects, not their inner pointers (see discovery). */
    NSData *value = characteristic.value ?: [NSData data];
    NSString *serviceUuidString = [characteristic.service.UUID UUIDString];
    NSString *characteristicUuidString = [characteristic.UUID UUIDString];
    dispatch_async(dispatch_get_main_queue(), ^{
        haskellOnBleNotification(self.haskellCtx,
                                 [serviceUuidString UTF8String],
                                 [characteristicUuidString UTF8String],
                                 (const uint8_t *)value.bytes, (int32_t)value.length);
    });
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    [self dispatchGattResult:BLE_GATT_OP_WRITE
                      status:(error ? (int32_t)error.code : BLE_GATT_STATUS_SUCCESS)
                        data:nil mtu:0];
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    [self dispatchGattResult:self.notificationOpInFlight
                      status:(error ? (int32_t)error.code : BLE_GATT_STATUS_SUCCESS)
                        data:nil mtu:0];
}

@end

static BleScanDelegate *g_delegate = nil;

/* ---- BLE bridge implementations ---- */

static int32_t ios_ble_check_adapter(void)
{
    if (!g_delegate || !g_delegate.centralManager) {
        return BLE_ADAPTER_UNSUPPORTED;
    }

    switch (g_delegate.centralManager.state) {
    case CBManagerStatePoweredOn:
        return BLE_ADAPTER_ON;
    case CBManagerStatePoweredOff:
        return BLE_ADAPTER_OFF;
    case CBManagerStateUnauthorized:
        return BLE_ADAPTER_UNAUTHORIZED;
    case CBManagerStateUnsupported:
        return BLE_ADAPTER_UNSUPPORTED;
    case CBManagerStateResetting:
        return BLE_ADAPTER_OFF;
    case CBManagerStateUnknown:
        return BLE_ADAPTER_OFF;
    }
    return BLE_ADAPTER_UNSUPPORTED;
}

/* Create the central manager on first use, remembering the Haskell
 * context for callbacks. */
static void ios_ble_ensure_manager(void *ctx)
{
    if (!g_delegate) {
        g_delegate = [[BleScanDelegate alloc] init];
    }
    g_delegate.haskellCtx = ctx;

    if (!g_delegate.centralManager) {
        g_delegate.centralManager = [[CBCentralManager alloc]
            initWithDelegate:g_delegate
                       queue:dispatch_get_main_queue()];
    }
}

static void ios_ble_start_scan(void *ctx, const char *service_uuid_filter)
{
    LOGI("ios_ble_start_scan(filter=%s)",
         service_uuid_filter ? service_uuid_filter : "(none)");

    g_scan_filter = service_uuid_filter
        ? @[[CBUUID UUIDWithString:[NSString stringWithUTF8String:service_uuid_filter]]]
        : nil;

    BOOL managerExisted = g_delegate && g_delegate.centralManager;
    ios_ble_ensure_manager(ctx);
    if (!managerExisted) {
        g_scanning_requested = YES;
        return;
    }

    if (g_delegate.centralManager.state == CBManagerStatePoweredOn) {
        g_scanning_requested = NO;
        [g_delegate.centralManager scanForPeripheralsWithServices:g_scan_filter
                                                         options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
        LOGI("BLE scan started");
    } else {
        g_scanning_requested = YES;
        LOGI("BLE adapter not ready (state=%ld), scan deferred", (long)g_delegate.centralManager.state);
    }
}

static void ios_ble_stop_scan(void)
{
    LOGI("ios_ble_stop_scan()");
    g_scanning_requested = NO;

    if (g_delegate && g_delegate.centralManager) {
        [g_delegate.centralManager stopScan];
    }
}

static void ios_ble_connect(void *ctx, const char *address)
{
    LOGI("ios_ble_connect(%s)", address ? address : "(null)");

    ios_ble_ensure_manager(ctx);

    NSString *identifier = address ? [NSString stringWithUTF8String:address] : @"";
    CBPeripheral *peripheral = g_delegate.discoveredPeripherals[identifier];

    if (!peripheral || g_delegate.centralManager.state != CBManagerStatePoweredOn) {
        LOGE("ios_ble_connect: peripheral unknown or adapter not powered on");
        [g_delegate dispatchConnectionEvent:BLE_CONNECTION_FAILED];
        return;
    }

    [g_delegate.centralManager connectPeripheral:peripheral options:nil];
}

static void ios_ble_disconnect(void)
{
    LOGI("ios_ble_disconnect()");

    if (g_delegate && g_delegate.centralManager && g_delegate.connectedPeripheral) {
        [g_delegate.centralManager cancelPeripheralConnection:g_delegate.connectedPeripheral];
    }
}

/* ---- GATT operations ---- */

/* Fail a GATT operation before it reaches CoreBluetooth (no
 * connection, unknown characteristic, simulator). */
static void ios_ble_gatt_fail_early(void *ctx, int32_t operation, const char *reason)
{
    LOGE("GATT operation %d failed: %s", operation, reason);
    ios_ble_ensure_manager(ctx);
    [g_delegate dispatchGattResult:operation status:IOS_GATT_FAILURE data:nil mtu:0];
}

/* Look up a characteristic on the connected peripheral.  Requires a
 * prior successful ble_discover_services run. Returns nil after
 * reporting failure when not found. */
static CBCharacteristic *ios_ble_find_characteristic(void *ctx, int32_t operation,
                                                     const char *service_uuid,
                                                     const char *characteristic_uuid)
{
    ios_ble_ensure_manager(ctx);
    CBPeripheral *peripheral = g_delegate.connectedPeripheral;
    if (!peripheral) {
        ios_ble_gatt_fail_early(ctx, operation, "not connected");
        return nil;
    }
    CBUUID *serviceUuid =
        [CBUUID UUIDWithString:[NSString stringWithUTF8String:service_uuid]];
    CBUUID *characteristicUuid =
        [CBUUID UUIDWithString:[NSString stringWithUTF8String:characteristic_uuid]];
    for (CBService *service in peripheral.services) {
        if (![service.UUID isEqual:serviceUuid]) {
            continue;
        }
        for (CBCharacteristic *characteristic in service.characteristics) {
            if ([characteristic.UUID isEqual:characteristicUuid]) {
                return characteristic;
            }
        }
    }
    ios_ble_gatt_fail_early(ctx, operation, "characteristic not found (discover first)");
    return nil;
}

static void ios_ble_discover_services(void *ctx)
{
    LOGI("ios_ble_discover_services()");
    ios_ble_ensure_manager(ctx);
    CBPeripheral *peripheral = g_delegate.connectedPeripheral;
    if (!peripheral) {
        ios_ble_gatt_fail_early(ctx, BLE_GATT_OP_DISCOVER, "not connected");
        return;
    }
    [peripheral discoverServices:nil];
}

static void ios_ble_read_characteristic(void *ctx, const char *service_uuid,
                                        const char *characteristic_uuid)
{
    LOGI("ios_ble_read_characteristic(%s, %s)", service_uuid, characteristic_uuid);
    CBCharacteristic *characteristic =
        ios_ble_find_characteristic(ctx, BLE_GATT_OP_READ, service_uuid, characteristic_uuid);
    if (!characteristic) {
        return;
    }
    g_delegate.pendingReadCharacteristic = characteristic;
    [g_delegate.connectedPeripheral readValueForCharacteristic:characteristic];
}

static void ios_ble_write_characteristic(void *ctx, const char *service_uuid,
                                         const char *characteristic_uuid,
                                         const uint8_t *data, int32_t length,
                                         int32_t write_mode)
{
    LOGI("ios_ble_write_characteristic(%s, %s, %d bytes, mode=%d)",
         service_uuid, characteristic_uuid, length, write_mode);
    CBCharacteristic *characteristic =
        ios_ble_find_characteristic(ctx, BLE_GATT_OP_WRITE, service_uuid, characteristic_uuid);
    if (!characteristic) {
        return;
    }
    NSData *payload = [NSData dataWithBytes:data length:(NSUInteger)length];
    if (write_mode == BLE_WRITE_WITH_RESPONSE) {
        [g_delegate.connectedPeripheral writeValue:payload
                                 forCharacteristic:characteristic
                                              type:CBCharacteristicWriteWithResponse];
        /* Completion arrives via didWriteValueForCharacteristic. */
    } else {
        [g_delegate.connectedPeripheral writeValue:payload
                                 forCharacteristic:characteristic
                                              type:CBCharacteristicWriteWithoutResponse];
        /* CoreBluetooth has no completion callback for unacknowledged
         * writes; report success as soon as the write is queued. */
        [g_delegate dispatchGattResult:BLE_GATT_OP_WRITE status:BLE_GATT_STATUS_SUCCESS
                                  data:nil mtu:0];
    }
}

static void ios_ble_set_characteristic_notification(void *ctx, const char *service_uuid,
                                                    const char *characteristic_uuid,
                                                    int32_t enable)
{
    LOGI("ios_ble_set_characteristic_notification(%s, %s, %d)",
         service_uuid, characteristic_uuid, enable);
    int32_t operation = enable ? BLE_GATT_OP_SUBSCRIBE : BLE_GATT_OP_UNSUBSCRIBE;
    CBCharacteristic *characteristic =
        ios_ble_find_characteristic(ctx, operation, service_uuid, characteristic_uuid);
    if (!characteristic) {
        return;
    }
    g_delegate.notificationOpInFlight = operation;
    [g_delegate.connectedPeripheral setNotifyValue:(enable != 0)
                                 forCharacteristic:characteristic];
    /* Completion arrives via didUpdateNotificationStateForCharacteristic. */
}

static void ios_ble_request_mtu(void *ctx, int32_t mtu)
{
    LOGI("ios_ble_request_mtu(%d)", mtu);
    ios_ble_ensure_manager(ctx);
    CBPeripheral *peripheral = g_delegate.connectedPeripheral;
    if (!peripheral) {
        ios_ble_gatt_fail_early(ctx, BLE_GATT_OP_MTU, "not connected");
        return;
    }
    /* iOS negotiates the MTU itself; report the usable value.  The
     * +3 converts the write payload limit back to the ATT MTU
     * convention Android uses. */
    int32_t granted = (int32_t)[peripheral
        maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse] + 3;
    [g_delegate dispatchGattResult:BLE_GATT_OP_MTU status:BLE_GATT_STATUS_SUCCESS
                              data:nil mtu:granted];
}

/* ---- Public API ---- */

/*
 * Set up the iOS BLE bridge. Called from Swift during initialisation.
 * Registers callbacks with the platform-agnostic dispatcher.
 */
void setup_ios_ble_bridge(void *haskellCtx)
{
    g_log = os_log_create("me.jappie.hatter", LOG_TAG);

    ble_register_impl(ios_ble_check_adapter, ios_ble_start_scan, ios_ble_stop_scan);
    ble_register_connect_impl(ios_ble_connect, ios_ble_disconnect);
    ble_register_gatt_impl(ios_ble_discover_services,
                           ios_ble_read_characteristic,
                           ios_ble_write_characteristic,
                           ios_ble_set_characteristic_notification,
                           ios_ble_request_mtu);

    LOGI("iOS BLE bridge initialized");
}
