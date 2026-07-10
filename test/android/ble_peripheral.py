#!/usr/bin/env python3
# Virtual BLE peripheral for the Android emulator integration tests.
#
# Connects to the emulator's netsim virtual radio (gRPC packet
# streamer, discovered through netsim.ini in XDG_RUNTIME_DIR/TMPDIR)
# and advertises as a connectable peripheral named "HatterBleSim" with
# a small GATT service.  The emulator's Bluetooth stack receives these
# advertisements exactly as it would from a physical device, so the
# hatter BLE scan and connect paths are exercised end to end.
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
# Prints ADVERTISING_STARTED once the peripheral is on the air and
# PERIPHERAL_CONNECTED when a central connects; the test harness waits
# for these markers.

import asyncio
import sys

from bumble.core import AdvertisingData
from bumble.device import Device
from bumble.gatt import Characteristic, Service
from bumble.hci import Address
from bumble.transport import open_transport

PERIPHERAL_NAME = 'HatterBleSim'
PERIPHERAL_ADDRESS = 'F0:F1:F2:F3:F4:F5'
TEST_SERVICE_UUID = '50DB505C-8AC4-4738-8448-3B1D9CC09CC5'
TEST_CHARACTERISTIC_UUID = '486F64C6-4B5F-4B3B-8AFF-EDE56A8B54F5'


async def run_peripheral(transport_name):
    print(f'Opening transport: {transport_name}', flush=True)
    async with await open_transport(transport_name) as hci_transport:
        device = Device.with_hci(
            PERIPHERAL_NAME,
            Address(PERIPHERAL_ADDRESS),
            hci_transport.source,
            hci_transport.sink,
        )
        device.add_service(
            Service(
                TEST_SERVICE_UUID,
                [
                    Characteristic(
                        TEST_CHARACTERISTIC_UUID,
                        Characteristic.Properties.READ,
                        Characteristic.READABLE,
                        b'hatter',
                    )
                ],
            )
        )
        device.advertising_data = bytes(
            AdvertisingData(
                [
                    (AdvertisingData.FLAGS, bytes([0x06])),
                    (
                        AdvertisingData.COMPLETE_LOCAL_NAME,
                        PERIPHERAL_NAME.encode('utf-8'),
                    ),
                ]
            )
        )
        device.on(
            'connection',
            lambda connection: print(f'PERIPHERAL_CONNECTED: {connection}', flush=True),
        )
        await device.power_on()
        # auto_restart: resume advertising after a central disconnects,
        # so a retried test attempt finds the peripheral again.
        await device.start_advertising(auto_restart=True)
        print('ADVERTISING_STARTED', flush=True)
        await asyncio.get_running_loop().create_future()


def main():
    transport_name = sys.argv[1] if len(sys.argv) > 1 else 'android-netsim'
    asyncio.run(run_peripheral(transport_name))


if __name__ == '__main__':
    main()
