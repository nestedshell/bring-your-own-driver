#!/usr/bin/env python3
"""Scan for the S1 over Bluetooth Low Energy and list its GATT services. Writes nothing."""
import asyncio
import sys

from bleak import BleakClient, BleakScanner

PREFIXES = ("PPS1", "S1_")


async def main() -> int:
    print("scanning for 10 s...")
    found = await BleakScanner.discover(timeout=10.0, return_adv=True)
    matches = []
    for device, adv in found.values():
        name = adv.local_name or device.name or ""
        if name.startswith(PREFIXES):
            matches.append((device, adv, name))
    if not matches:
        print(f"no S1 among {len(found)} devices seen")
        return 1
    device, adv, name = matches[0]
    print(f"found: {name} rssi={adv.rssi} services={adv.service_uuids}")
    print(f"manufacturer data: { {k: v.hex() for k, v in adv.manufacturer_data.items()} }")
    async with BleakClient(device) as client:
        print(f"connected, mtu={client.mtu_size}")
        for service in client.services:
            print(f"service {service.uuid}  {service.description}")
            for char in service.characteristics:
                print(f"  char {char.uuid}  {','.join(char.properties)}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
