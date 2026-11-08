import argparse
import asyncio
import fcntl
import json
import logging
import os
from pathlib import Path
import signal
import sys
import time
from .core import Problem, RecoveryStore, Session
from .device import DeviceAdapter


def emit(value):
    print(json.dumps(value, ensure_ascii=False, allow_nan=False), flush=True)


def error_result(exc):
    # Avoid leaking pairing material, device IDs or coordinates in upstream errors.
    if isinstance(exc, Problem):
        return {"errorCode": exc.code, "message": str(exc)}
    if isinstance(exc, (TimeoutError, asyncio.TimeoutError)):
        return {"errorCode": "TIMEOUT", "message": "操作超时，请解锁手机并检查连接后重试"}
    return {"errorCode": type(exc).__name__, "message": "设备操作失败，请检查连接、信任与开发者模式"}


class Server:
    def __init__(self, session, adapter, output=emit):
        self.session, self.adapter, self.output = session, adapter, output
        self.active = None
        self.seen = set()

    async def execute(self, request):
        rid, command = request["requestId"], request["command"]
        started = time.monotonic()
        try:
            match command:
                case "discover":
                    data = {"devices": await self.adapter.discover()}
                case "prepare":
                    data = await self.session.prepare(request.get("deviceId"))
                case "setLocation":
                    if request.get("sessionId") != self.session.session_id or self.session.session_id is None:
                        raise Problem("STALE_SESSION", "会话已失效，请重新连接")
                    data = await self.session.set_location(request.get("latitude"), request.get("longitude"))
                case "clear":
                    data = await self.session.clear()
                case "disconnect" | "cancel":
                    await self.session.disconnect()
                    data = {"status": self.session.state}
                case "diagnostics":
                    data = {"state": self.session.state, "sessionId": self.session.session_id,
                            "python": sys.version.split()[0], "backend": "0.1.0", "pymobiledevice3": "11.49.0"}
                case _:
                    raise Problem("UNKNOWN_COMMAND", "不支持的命令")
            self.output({"requestId": rid, "ok": True, "data": data,
                         "elapsedMs": round((time.monotonic() - started) * 1000)})
        except asyncio.CancelledError:
            self.output({"requestId": rid, "ok": False, "errorCode": "CANCELLED", "message": "已取消"})
        except Exception as exc:
            self.output({"requestId": rid, "ok": False, **error_result(exc)})

    async def accept(self, line):
        request = None
        try:
            if len(line) > 8192:
                raise Problem("INVALID_REQUEST", "请求过长")
            request = json.loads(line)
            if not isinstance(request, dict) or not isinstance(request.get("requestId"), str):
                raise Problem("INVALID_REQUEST", "缺少请求标识")
            rid = request["requestId"]
            if not rid or len(rid) > 128:
                raise Problem("INVALID_REQUEST", "请求标识无效")
            if rid in self.seen:
                raise Problem("DUPLICATE_REQUEST", "请勿重复提交同一请求")
            if len(self.seen) >= 10000:
                raise Problem("SESSION_LIMIT", "请重启后台进程")
            self.seen.add(rid)
            if self.active and not self.active.done():
                if request.get("command") in ("clear", "disconnect", "cancel"):
                    self.active.cancel()
                    await self.active
                else:
                    raise Problem("BUSY", "当前操作尚未完成，可取消后重试")
            self.active = asyncio.create_task(self.execute(request))
        except (ValueError, Problem) as exc:
            self.output({"requestId": request.get("requestId") if isinstance(request, dict) else None,
                         "ok": False, **error_result(exc)})

    async def monitor(self):
        while True:
            await asyncio.sleep(2)
            if self.active and not self.active.done():
                continue
            try:
                await self.session.health()
            except Exception as exc:
                self.output({"event": "connectionLost", **error_result(exc)})


async def serve(session, adapter):
    server = Server(session, adapter)
    reader = asyncio.StreamReader(limit=8192)
    transport, _ = await asyncio.get_running_loop().connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    stopping = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stopping.set)
    async def read():
        while line := await reader.readline():
            await server.accept(line)
    read_task = asyncio.create_task(read())
    stop_task = asyncio.create_task(stopping.wait())
    monitor = asyncio.create_task(server.monitor())
    try:
        await asyncio.wait([read_task, stop_task], return_when=asyncio.FIRST_COMPLETED)
    finally:
        transport.close()
        for task in (read_task, stop_task, monitor, server.active):
            if task and not task.done():
                task.cancel()
        await asyncio.gather(*(t for t in (read_task, stop_task, monitor, server.active) if t), return_exceptions=True)
        await session.disconnect()


async def run(args):
    # Third-party logs can contain identifiers. Our stage events are the default diagnostics.
    logging.disable(logging.CRITICAL)
    try:
        from loguru import logger
        logger.remove()
    except ImportError:
        pass
    if args.demo:
        from .demo import DemoAdapter
        adapter = DemoAdapter()
    else:
        adapter = DeviceAdapter(allow_apple_signing=args.allow_apple_signing)
    session = Session(adapter, RecoveryStore(args.state_dir), emit)
    if args.command == "serve":
        await serve(session, adapter)
        return
    devices = await adapter.discover()
    if args.command == "doctor":
        emit({"usbDevices": devices, "python": sys.version.split()[0], "pymobiledevice3": "11.49.0"})
        return
    if len(devices) != 1 and args.device is None:
        raise Problem("SELECT_DEVICE", "请仅连接一台 USB 设备，或通过 --device 指定设备标识")
    key = args.device or devices[0]["id"]
    try:
        await session.prepare(key)
        if args.command == "prepare":
            emit({"ok": True, "message": "定位服务已连接；未设置位置"})
        elif args.command == "test-location":
            emit(await session.set_location(args.latitude, args.longitude))
            await asyncio.sleep(args.seconds)
            emit(await session.clear())
        elif args.command == "clear":
            emit(await session.clear())
    finally:
        await session.disconnect()


def main():
    parser = argparse.ArgumentParser(description="虚拟定位 USB 设备验证与后台")
    parser.add_argument("--state-dir", default=str(Path(__file__).resolve().parents[2] / ".state"))
    parser.add_argument("--allow-apple-signing", action="store_true",
                        help="允许向 Apple 官方服务发送设备标识和 nonce 以获取开发镜像签名")
    parser.add_argument("--demo", action="store_true", help="仅模拟后台用于界面预览，不访问设备或 Apple")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("serve")
    sub.add_parser("doctor")
    for name in ("prepare", "clear", "test-location"):
        p = sub.add_parser(name)
        p.add_argument("--device")
        if name == "test-location":
            p.add_argument("latitude", type=float)
            p.add_argument("longitude", type=float)
            p.add_argument("--seconds", type=int, choices=range(1, 301), default=10)
    args = parser.parse_args()
    if args.demo:
        args.state_dir = str(Path(args.state_dir) / "preview")
    lock_file = None
    try:
        if args.command != "doctor":
            directory = Path(args.state_dir)
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            lock_file = (directory / "worker.lock").open("a")
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Problem("BACKEND_ALREADY_RUNNING", "已有本项目的设备会话正在运行，请先退出该会话") from None
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        emit({"ok": False, **error_result(exc)})
        raise SystemExit(1)
    finally:
        if lock_file is not None:
            lock_file.close()


if __name__ == "__main__":
    main()
