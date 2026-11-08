"""Explicit UI preview: no Apple imports, USB, network, or device writes."""
import asyncio
from .core import device_key


class DemoAdapter:
    allow_apple_signing = False

    async def discover(self):
        return [{"id": device_key("virtual-location-preview"), "transport": "USB", "name": "iPhone 界面预览"}]

    async def prepare(self, key, stage):
        for state in ("discovering", "trust_and_developer_mode", "checking_image", "opening_tunnel", "opening_location_service"):
            stage(state)
            await asyncio.sleep(0.1)

    async def set_location(self, latitude, longitude):
        await asyncio.sleep(0.05)

    async def clear(self):
        await asyncio.sleep(0.05)

    async def close(self):
        pass

    async def health(self):
        pass
