"""Adapter for pinned pymobiledevice3 11.49.0; no protocol reimplementation."""
import asyncio
from contextlib import AsyncExitStack
import hashlib
import json
from pathlib import Path
import sys
from .core import Problem, device_key


class DeviceAdapter:
    def __init__(self, allow_apple_signing=False):
        self.stack = AsyncExitStack()
        self.serial = self.lockdown = self.location = None
        self.allow_apple_signing = allow_apple_signing

    @staticmethod
    def download_ddi():
        """Project-owned cache; never repair or overwrite a pre-existing global cache."""
        import requests
        import plistlib
        from pymobiledevice3.services.mobile_image_mounter import LATEST_DDI_BUILD_ID
        cache = Path(__file__).resolve().parents[2] / ".state" / "ddi"
        cache.mkdir(parents=True, exist_ok=True, mode=0o700)
        files = {"Image.dmg": "Image.dmg", "BuildManifest.plist": "BuildManifest.plist",
                 "Image.trustcache": "Image.dmg.trustcache"}
        receipt = cache / "sha256.json"
        if receipt.exists():
            hashes = json.loads(receipt.read_text())
            if all((cache / name).is_file() and hashlib.sha256((cache / name).read_bytes()).hexdigest() == hashes.get(name)
                   for name in files):
                manifest = plistlib.loads((cache / "BuildManifest.plist").read_bytes())
                if manifest.get("ProductBuildVersion") == LATEST_DDI_BUILD_ID:
                    return tuple(cache / name for name in files)
        hashes = {}
        for name, remote in files.items():
            url = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/" + remote
            temporary = cache / (name + ".part")
            try:
                with requests.get(url, stream=True, timeout=(10, 30)) as response:
                    response.raise_for_status()
                    size = 0
                    digest = hashlib.sha256()
                    with temporary.open("wb") as f:
                        for chunk in response.iter_content(1024 * 1024):
                            size += len(chunk)
                            if size > 1024 * 1024 * 1024:
                                raise Problem("IMAGE_TOO_LARGE", "开发镜像下载超出限制")
                            digest.update(chunk)
                            f.write(chunk)
                temporary.replace(cache / name)
                hashes[name] = digest.hexdigest()
            finally:
                temporary.unlink(missing_ok=True)
        manifest = plistlib.loads((cache / "BuildManifest.plist").read_bytes())
        if manifest.get("ProductBuildVersion") != LATEST_DDI_BUILD_ID:
            raise Problem("DDI_VERSION_MISMATCH", "开发镜像版本与固定依赖不一致")
        receipt.write_text(json.dumps(hashes))
        return tuple(cache / name for name in files)

    async def discover(self):
        from pymobiledevice3.usbmux import list_devices
        devices = await asyncio.wait_for(list_devices(), 5)
        return [{"id": device_key(d.serial), "transport": "USB"}
                for d in devices if d.is_usb]

    async def prepare(self, key, stage):
        from pymobiledevice3.usbmux import list_devices
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.mobile_image_mounter import (
            MobileImageMounterService, PersonalizedImageMounter)
        from pymobiledevice3.remote.rsd_tunnel import PreferredRsdTunnel
        from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
        from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
        stage("discovering")
        devices = await asyncio.wait_for(list_devices(), 5)
        found = [d for d in devices if d.is_usb and device_key(d.serial) == key]
        if len(found) != 1:
            raise Problem("DEVICE_NOT_FOUND", "未找到所选 USB 设备，请重新连接并刷新")
        self.serial = found[0].serial
        stage("trust_and_developer_mode")
        self.lockdown = await asyncio.wait_for(create_using_usbmux(
            serial=self.serial, connection_type="USB", pair_timeout=30), 35)
        self.stack.push_async_callback(self.lockdown.close)
        if not self.lockdown.product_version.startswith("26."):
            raise Problem("UNVERIFIED_IOS", "此验证版本仅启用 iOS 26，请先做兼容性评估")
        if not await self.lockdown.get_developer_mode_status():
            raise Problem("DEVELOPER_MODE_OFF", "请在手机隐私与安全性中开启开发者模式并按提示重启")
        stage("checking_image")
        async with MobileImageMounterService(self.lockdown) as mounter:
            mounted = await asyncio.wait_for(mounter.is_image_mounted("Personalized"), 10)
        if not mounted:
            if not self.allow_apple_signing:
                raise Problem("APPLE_SIGNING_CONSENT_REQUIRED", "首次准备需发送设备标识到 Apple，请明确允许后重试")
            stage("preparing_image")
            # A subprocess makes synchronous upstream downloads genuinely cancellable.
            process = await asyncio.create_subprocess_exec(
                sys.executable, "-m", "virtual_location.ddi",
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            try:
                if await asyncio.wait_for(process.wait(), 600):
                    raise Problem("IMAGE_DOWNLOAD_FAILED", "开发镜像下载或校验失败，请检查网络后重试")
            finally:
                if process.returncode is None:
                    process.terminate()
                    try:
                        await asyncio.wait_for(process.wait(), 3)
                    except TimeoutError:
                        process.kill()
                        await process.wait()
            cache = Path(__file__).resolve().parents[2] / ".state" / "ddi"
            image, manifest, trustcache = (cache / name for name in
                                         ("Image.dmg", "BuildManifest.plist", "Image.trustcache"))
            stage("mounting_image")
            from .signing import SecureTSSRequest
            import pymobiledevice3.services.mobile_image_mounter as mounter_module
            mounter_module.TSSRequest = SecureTSSRequest
            async with PersonalizedImageMounter(self.lockdown) as mounter:
                await asyncio.wait_for(mounter.mount(image, manifest, trustcache), 60)
        stage("opening_tunnel")
        rsd = await asyncio.wait_for(self.stack.enter_async_context(
            PreferredRsdTunnel(serial=self.serial)), 30)
        stage("opening_location_service")
        dvt = await asyncio.wait_for(self.stack.enter_async_context(DvtProvider(rsd)), 30)
        self.location = await asyncio.wait_for(self.stack.enter_async_context(LocationSimulation(dvt)), 15)

    async def set_location(self, lat, lon):
        await self.location.set(lat, lon)

    async def clear(self):
        await self.location.clear()

    async def health(self):
        from pymobiledevice3.usbmux import list_devices
        if not any(d.is_usb and d.serial == self.serial for d in await list_devices()):
            raise ConnectionError("USB disconnected")
        # Probe a live device service as well as cable presence.
        await self.lockdown.get_value(key="ProductVersion")

    async def close(self):
        try:
            await self.stack.aclose()
        finally:
            self.stack = AsyncExitStack()
            self.serial = self.lockdown = self.location = None
