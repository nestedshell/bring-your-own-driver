"""BLE transport with the printer's credit-based flow control."""

from __future__ import annotations

import asyncio
from typing import Callable

from bleak import BleakClient, BleakScanner

from .protocol import FLOW_CHAR, NAME_PREFIX, PACKET_SIZE, WRITE_CHAR

# Credits are sometimes not returned right after connecting; after this long
# without one, send a single packet anyway to get the flow going again.
STALL_KICK_S = 2.0


class Printer:
    def __init__(self, address: str | None = None):
        self.address = address
        self.client: BleakClient | None = None
        self._credits = 0
        self._packet = PACKET_SIZE
        self._event = asyncio.Event()

    async def __aenter__(self) -> "Printer":
        await self.connect()
        return self

    async def __aexit__(self, *exc) -> None:
        await self.close()

    async def connect(self, timeout: float = 15) -> None:
        if self.address:
            device = await BleakScanner.find_device_by_address(self.address, timeout=timeout)
        else:
            device = await BleakScanner.find_device_by_filter(
                lambda d, adv: (adv.local_name or d.name or "").startswith(NAME_PREFIX), timeout=timeout
            )
        if device is None:
            raise RuntimeError("XL-P801X not found: is it switched on and not connected to the phone?")
        self.client = BleakClient(device)
        await self.client.connect()
        await self.client.start_notify(FLOW_CHAR, self._on_flow)
        await asyncio.sleep(0.5)  # initial credit grant arrives right after subscribing

    def _on_flow(self, _char, data: bytearray) -> None:
        if len(data) >= 2 and data[0] == 0x01:
            self._credits += data[1]
            self._event.set()
        elif len(data) >= 3 and data[0] == 0x02:
            self._packet = min(PACKET_SIZE, int.from_bytes(data[1:3], "little"))

    async def write(self, data: bytes, progress: Callable[[int, int], None] | None = None) -> None:
        assert self.client
        total = len(data)
        for i in range(0, total, self._packet):
            while self._credits <= 0:
                self._event.clear()
                try:
                    await asyncio.wait_for(self._event.wait(), STALL_KICK_S)
                except TimeoutError:
                    self._credits += 1
            await self.client.write_gatt_char(WRITE_CHAR, data[i : i + self._packet], response=False)
            self._credits -= 1
            if progress:
                progress(min(i + self._packet, total), total)

    async def close(self) -> None:
        if self.client and self.client.is_connected:
            await asyncio.sleep(1.5)  # let the last packets leave the radio
            await self.client.disconnect()
