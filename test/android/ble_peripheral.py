#!/usr/bin/env python3
# Virtual BLE peripheral for the Android emulator integration tests.
#
# Connects to the emulator's netsim virtual radio (gRPC packet
# streamer, discovered through netsim.ini in XDG_RUNTIME_DIR/TMPDIR)
# and advertises as a connectable peripheral named "HatterBleSim".
# The emulator's Bluetooth stack receives these advertisements exactly
# as it would from a physical device, so the hatter BLE scan, connect
# and GATT paths are exercised end to end.
#
# GATT layout (UUIDs mirrored in test/BleDemoMain.hs):
#   service 50DB505C-...:
#     486F64C6-... : readable, value b'hatter'
#     8CB7C0F4-... : write + notify; written bytes are echoed back as
#                    a notification (exercises write and subscribe in
#                    one round trip)
#
# The advertisement carries the service UUID (so service-UUID scan
# filters match) and the device name travels in the scan response:
# both together exceed the 31-byte legacy advertising limit.
#
# Decision: Google's bumble Python stack + the emulator's netsim
# virtual controller were chosen to simulate BLE traffic.
# Alternatives considered: a second emulator running an advertiser app
# (heavy: another system image boot per CI run) and netsimd's built-in
# --test-beacons (advertise-only, cannot accept GATT connections, and
# not controllable per test).  bumble is packaged in nixpkgs, connects
# to the same netsimd instance the emulator spawns, and gives us a
# named, connectable peripheral with a scriptable GATT server.
#
# Usage: ble_peripheral.py [transport]   (default: android-netsim)
#
# Prints ADVERTISING_STARTED once the peripheral is on the air,
# PERIPHERAL_CONNECTED when a central connects, and ECHO_WRITE for
# every write to the echo characteristic; the test harness waits for
# these markers.

import asyncio
import sys

from bumble.core import UUID, AdvertisingData
from bumble.device import Device
from bumble.gatt import Characteristic, CharacteristicValue, Service
from bumble.hci import Address
from bumble.transport import open_transport

PERIPHERAL_NAME = 'HatterBleSim'
PERIPHERAL_ADDRESS = 'F0:F1:F2:F3:F4:F5'
TEST_SERVICE_UUID = '50DB505C-8AC4-4738-8448-3B1D9CC09CC5'
TEST_READ_CHARACTERISTIC_UUID = '486F64C6-4B5F-4B3B-8AFF-EDE56A8B54F5'
TEST_ECHO_CHARACTERISTIC_UUID = '8CB7C0F4-3B97-4653-9E4F-6F02BF97C7FB'


async def run_peripheral(transport_name):
    print(f'Opening transport: {transport_name}', flush=True)
    async with await open_transport(transport_name) as hci_transport:
        device = Device.with_hci(
            PERIPHERAL_NAME,
            Address(PERIPHERAL_ADDRESS),
            hci_transport.source,
            hci_transport.sink,
        )

        echo_characteristic = Characteristic(
            TEST_ECHO_CHARACTERISTIC_UUID,
            Characteristic.Properties.WRITE | Characteristic.Properties.NOTIFY,
            Characteristic.WRITEABLE,
        )

        async def on_echo_write(connection, value):
            print(f'ECHO_WRITE: {value.hex()}', flush=True)
            # Echo the written bytes back as a notification so the
            # test covers write and notify in one round trip.
            await device.gatt_server.notify_subscribers(echo_characteristic, value)

        echo_characteristic.value = CharacteristicValue(write=on_echo_write)

        device.add_service(
            Service(
                TEST_SERVICE_UUID,
                [
                    Characteristic(
                        TEST_READ_CHARACTERISTIC_UUID,
                        Characteristic.Properties.READ,
                        Characteristic.READABLE,
                        b'hatter',
                    ),
                    echo_characteristic,
                ],
            )
        )
        device.advertising_data = bytes(
            AdvertisingData(
                [
                    (AdvertisingData.FLAGS, bytes([0x06])),
                    (
                        AdvertisingData.COMPLETE_LIST_OF_128_BIT_SERVICE_CLASS_UUIDS,
                        UUID(TEST_SERVICE_UUID).to_bytes(),
                    ),
                ]
            )
        )
        # The name travels in the scan response: it does not fit in the
        # 31-byte advertisement next to a 128-bit service UUID list.
        scan_response = bytes(
            AdvertisingData(
                [
                    (
                        AdvertisingData.COMPLETE_LOCAL_NAME,
                        PERIPHERAL_NAME.encode('utf-8'),
                    )
                ]
            )
        )
        device.scan_response_data = scan_response
        device.on(
            'connection',
            lambda connection: print(f'PERIPHERAL_CONNECTED: {connection}', flush=True),
        )
        await device.power_on()
        # auto_restart: resume advertising after a central disconnects,
        # so a retried test attempt finds the peripheral again.
        await device.start_advertising(
            auto_restart=True,
            scan_response_data=scan_response,
        )
        print('ADVERTISING_STARTED', flush=True)
        await asyncio.get_running_loop().create_future()


def main():
    transport_name = sys.argv[1] if len(sys.argv) > 1 else 'android-netsim'
    asyncio.run(run_peripheral(transport_name))


if __name__ == '__main__':
    main()
