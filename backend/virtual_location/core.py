"""Session lifecycle independent of Apple protocols, shared by CLI and GUI."""
import asyncio
import hashlib
import math
import os
import time
import uuid
from pathlib import Path


class Problem(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def coordinate(value, limit):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise Problem("INVALID_COORDINATE", "坐标必须为数值")
    if not math.isfinite(value) or abs(value) > limit:
        raise Problem("INVALID_COORDINATE", "坐标超出范围或不是有限数")
    return float(value)


def device_key(serial):
    return hashlib.sha256(serial.encode()).hexdigest()[:16]


class RecoveryStore:
    """No coordinates or raw UDID stored. Mark BEFORE any potentially partial write."""
    def __init__(self, directory):
        self.directory = Path(directory)

    def path(self, key):
        if len(key) != 16 or any(c not in "0123456789abcdef" for c in key):
            raise Problem("INVALID_DEVICE", "设备标识无效")
        return self.directory / (key + ".pending-clear")

    def pending(self, key):
        return self.path(key).exists()

    def mark(self, key):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(self.path(key), os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write("clear-required\n")
            f.flush()
            os.fsync(f.fileno())

    def cleared(self, key):
        self.path(key).unlink(missing_ok=True)


class Session:
    def __init__(self, adapter, store, emit=lambda _: None):
        self.adapter, self.store, self.emit = adapter, store, emit
        self.state = "disconnected"
        self.key = self.session_id = None
        self.dirty = False
        self.lock = asyncio.Lock()
        self.started = time.monotonic()

    def stage(self, state):
        self.state = state
        self.emit({"event": "stage", "stage": state,
                   "sessionId": self.session_id,
                   "elapsedMs": round((time.monotonic() - self.started) * 1000)})

    async def prepare(self, key):
        async with self.lock:
            if self.key is not None:
                raise Problem("ALREADY_CONNECTED", "请先断开当前会话")
            self.dirty = self.store.pending(key)
            self.key, self.session_id = key, str(uuid.uuid4())
            self.started = time.monotonic()
            try:
                for attempt in range(3):
                    try:
                        await self.adapter.prepare(key, self.stage)
                        break
                    except (TimeoutError, ConnectionError, OSError):
                        # Only retry transient connection stages. Never automatically
                        # repeat signing, mounting, location writes or recovery commands.
                        if attempt == 2 or self.state not in (
                            "discovering", "opening_tunnel", "opening_location_service"
                        ):
                            raise
                        await self.adapter.close()
                        self.stage("retrying")
                        await asyncio.sleep((1, 3)[attempt])
                if self.store.pending(key):
                    self.dirty = True
                    self.stage("recovering")
                    await self._clear()
                self.stage("ready")
                return {"sessionId": self.session_id}
            except BaseException:
                await self._close()
                raise

    async def set_location(self, lat, lon):
        lat, lon = coordinate(lat, 90), coordinate(lon, 180)
        async with self.lock:
            if self.state not in ("ready", "simulating"):
                raise Problem("NOT_READY", "设备尚未就绪")
            self.store.mark(self.key)
            self.dirty = True
            try:
                await asyncio.wait_for(self.adapter.set_location(lat, lon), 10)
                self.stage("simulating")
                return {"status": "sent", "verification": "请在手机地图核对实际位置"}
            except BaseException:
                self.stage("recovery_required")
                raise

    async def _clear(self):
        await asyncio.wait_for(self.adapter.clear(), 5)
        # Upstream does not await a device acknowledgement: never report verified recovery.
        self.store.cleared(self.key)
        self.dirty = False

    async def clear(self):
        async with self.lock:
            if self.key is None:
                raise Problem("NOT_CONNECTED", "请先连接设备，再发送清除请求")
            self.stage("stopping")
            try:
                await self._clear()
            except BaseException:
                self.stage("recovery_required")
                raise
            self.stage("ready")
            return {"status": "clear_sent", "verification": "清除请求已发送，请在手机地图确认恢复"}

    async def _close(self):
        try:
            await asyncio.wait_for(self.adapter.close(), 8)
        finally:
            self.key = None
            self.session_id = None
            self.stage("recovery_required" if self.dirty else "disconnected")

    async def disconnect(self):
        async with self.lock:
            try:
                if self.key is not None and self.dirty:
                    self.stage("stopping")
                    await self._clear()
            finally:
                await self._close()

    async def health(self):
        async with self.lock:
            if self.key is not None:
                try:
                    await asyncio.wait_for(self.adapter.health(), 5)
                except Exception:
                    await self._close()
                    raise Problem("CONNECTION_LOST", "连接已中断，手机定位状态待确认") from None
