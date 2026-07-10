/*
 * iOS implementation of the BLE bridge callbacks.
 *
 * Uses CoreBluetooth (CBCentralManager) to check adapter state,
 * scan for peripherals and manage GATT connections.
 * Compiled by Xcode, not GHC.
 *
 * All Haskell callbacks are dispatched on the main thread.
 *
 * Note: the iOS simulator does not support CoreBluetooth (the manager
 * reports CBManagerStateUnsupported), so on the simulator scans find
 * nothing and connection attempts fail with BLE_CONNECTION_FAILED.
 */

#import <CoreBluetooth/CoreBluetooth.h>
#import <os/log.h>
#include "BleBridge.h"

#define LOG_TAG "BleBridge"
static os_log_t g_log;

#define LOGI(fmt, ...) os_log_info(g_log, fmt, ##__VA_ARGS__)
#define LOGE(fmt, ...) os_log_error(g_log, fmt, ##__VA_ARGS__)

/* Haskell FFI exports (dispatch results back to Haskell callbacks) */
extern void haskellOnBleScanResult(void *ctx, const char *name, const char *address, int32_t rssi);
extern void haskellOnBleConnectionEvent(void *ctx, int32_t event);

/* ---- Module-level state (declared before use in delegate methods) ---- */

static BOOL g_scanning_requested = NO;

/* ---- Scan + connection delegate ---- */

@interface BleScanDelegate : NSObject <CBCentralManagerDelegate>
@property (nonatomic, assign) void *haskellCtx;
@property (nonatomic, strong) CBCentralManager *centralManager;
/* Peripherals seen during scanning, keyed by identifier UUID string.
 * CoreBluetooth can only connect to CBPeripheral instances it handed
 * out earlier, so ble_connect looks the address up here. */
@property (nonatomic, strong) NSMutableDictionary<NSString *, CBPeripheral *> *discoveredPeripherals;
@property (nonatomic, strong) CBPeripheral *connectedPeripheral;
@end

@implementation BleScanDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _discoveredPeripherals = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    LOGI("CBCentralManager state: %ld", (long)central.state);
    /* If scanning was requested before the manager was ready, start now */
    if (central.state == CBManagerStatePoweredOn && g_scanning_requested) {
        [central scanForPeripheralsWithServices:nil
                                        options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
        LOGI("BLE scan started (deferred)");
    }
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

    dispatch_async(dispatch_get_main_queue(), ^{
        haskellOnBleScanResult(self.haskellCtx, name, address, rssi);
    });
}

- (void)dispatchConnectionEvent:(int32_t)event {
    dispatch_async(dispatch_get_main_queue(), ^{
        haskellOnBleConnectionEvent(self.haskellCtx, event);
    });
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {
    LOGI("didConnectPeripheral: %@", peripheral.identifier);
    self.connectedPeripheral = peripheral;
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

static void ios_ble_start_scan(void *ctx)
{
    LOGI("ios_ble_start_scan()");

    BOOL managerExisted = g_delegate && g_delegate.centralManager;
    ios_ble_ensure_manager(ctx);
    if (!managerExisted) {
        g_scanning_requested = YES;
        return;
    }

    if (g_delegate.centralManager.state == CBManagerStatePoweredOn) {
        g_scanning_requested = NO;
        [g_delegate.centralManager scanForPeripheralsWithServices:nil
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

    LOGI("iOS BLE bridge initialized");
}
