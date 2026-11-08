import asyncio
import json
import math
import pytest
from virtual_location.core import Session, RecoveryStore, Problem, coordinate, device_key
from virtual_location.cli import Server


class Fake:
    def __init__(self):
        self.calls = []
        self.fail_clear = self.fail_set = self.lost = False

    async def prepare(self, key, stage):
        self.calls.append("prepare")
        stage("opening_tunnel")

    async def set_location(self, lat, lon):
        self.calls.append("set")
        if self.fail_set:
            raise ConnectionError()

    async def clear(self):
        self.calls.append("clear")
        if self.fail_clear:
            raise ConnectionError()

    async def close(self):
        self.calls.append("close")

    async def health(self):
        if self.lost:
            raise ConnectionError()


@pytest.mark.parametrize("value,limit", [(math.nan,90),(math.inf,180),(-91,90),(181,180),(True,90),("12",90),(None,90)])
def test_invalid_coordinate(value, limit):
    with pytest.raises(Problem):
        coordinate(value, limit)


def test_lifecycle_and_cleanup(tmp_path):
    async def scenario():
        f = Fake(); store = RecoveryStore(tmp_path); s = Session(f, store)
        key = device_key("private-device-id")
        await s.prepare(key)
        await s.set_location(0, -180)
        assert store.pending(key)
        await s.disconnect()
        assert f.calls == ["prepare", "set", "clear", "close"]
        assert not store.pending(key)
        assert s.state == "disconnected"
    asyncio.run(scenario())


def test_uncertain_write_remains_recoverable(tmp_path):
    async def scenario():
        f = Fake(); f.fail_set = f.fail_clear = True
        store = RecoveryStore(tmp_path); s = Session(f, store); key = device_key("device")
        await s.prepare(key)
        with pytest.raises(ConnectionError):
            await s.set_location(1,2)
        with pytest.raises(ConnectionError):
            await s.disconnect()
        assert store.pending(key) and s.state == "recovery_required"
        f.fail_set = f.fail_clear = False
        await s.prepare(key)
        assert f.calls[-2:] == ["prepare", "clear"]
        assert s.state == "ready" and not store.pending(key)
        await s.disconnect()
    asyncio.run(scenario())


def test_unplug_never_reapplies_location(tmp_path):
    async def scenario():
        f=Fake(); s=Session(f, RecoveryStore(tmp_path)); key=device_key("device")
        await s.prepare(key); await s.set_location(1,2)
        f.lost=True
        with pytest.raises(Problem): await s.health()
        assert s.state == "recovery_required"
        f.lost=False
        await s.prepare(key)
        assert f.calls.count("set") == 1
        assert f.calls[-1] == "clear"
        await s.disconnect()
    asyncio.run(scenario())


def test_requests_reject_stale_duplicate_and_invalid(tmp_path):
    async def scenario():
        f=Fake(); s=Session(f, RecoveryStore(tmp_path)); out=[]; server=Server(s,f,out.append)
        await s.prepare(device_key("device"))
        await server.accept(json.dumps({"requestId":"a","command":"setLocation","sessionId":"stale","latitude":1,"longitude":2}))
        await server.active
        assert out[-1]["errorCode"] == "STALE_SESSION"
        await server.accept('{"requestId":"a","command":"clear"}')
        assert out[-1]["errorCode"] == "DUPLICATE_REQUEST"
        await server.accept('[]')
        assert out[-1]["errorCode"] == "INVALID_REQUEST"
        assert f.calls == ["prepare"]
        await s.disconnect()
    asyncio.run(scenario())


def test_cancel_prepare_releases_resources(tmp_path):
    async def scenario():
        f=Fake(); entered=asyncio.Event()
        async def prepare(key, stage):
            entered.set(); await asyncio.Event().wait()
        f.prepare=prepare
        s=Session(f,RecoveryStore(tmp_path)); task=asyncio.create_task(s.prepare(device_key("device")))
        await entered.wait(); task.cancel()
        with pytest.raises(asyncio.CancelledError): await task
        assert f.calls == ["close"] and s.key is None
    asyncio.run(scenario())


def test_recovery_marker_does_not_affect_another_device(tmp_path):
    async def scenario():
        f=Fake(); store=RecoveryStore(tmp_path); s=Session(f,store)
        first, second = device_key("first"), device_key("second")
        await s.prepare(first); await s.set_location(1,2)
        f.lost=True
        with pytest.raises(Problem): await s.health()
        f.lost=False
        await s.prepare(second)
        assert f.calls.count("clear") == 0
        await s.disconnect()
        assert store.pending(first) and not store.pending(second)
    asyncio.run(scenario())


def test_clear_preempts_inflight_location_write(tmp_path):
    async def scenario():
        f=Fake(); entered=asyncio.Event(); out=[]
        async def stalled_set(lat,lon):
            entered.set(); await asyncio.Event().wait()
        f.set_location=stalled_set
        s=Session(f,RecoveryStore(tmp_path)); server=Server(s,f,out.append)
        key=device_key("device"); await s.prepare(key)
        await server.accept(json.dumps({"requestId":"set","command":"setLocation",
            "sessionId":s.session_id,"latitude":1,"longitude":2}))
        await entered.wait()
        await server.accept('{"requestId":"stop","command":"clear"}')
        await server.active
        assert any(x.get("errorCode")=="CANCELLED" for x in out)
        assert out[-1]["data"]["status"] == "clear_sent"
        assert not s.store.pending(key)
        await s.disconnect()
    asyncio.run(scenario())


def test_transient_tunnel_failure_retries_but_signing_does_not(tmp_path, monkeypatch):
    async def no_sleep(_): pass
    monkeypatch.setattr("virtual_location.core.asyncio.sleep", no_sleep)
    async def scenario(stage_name, expected):
        f=Fake()
        async def fail(key, stage):
            f.calls.append("prepare")
            stage(stage_name)
            raise ConnectionError()
        f.prepare=fail
        s=Session(f,RecoveryStore(tmp_path))
        with pytest.raises(ConnectionError): await s.prepare(device_key("device"))
        assert f.calls.count("prepare") == expected
        assert s.key is None
    asyncio.run(scenario("opening_tunnel",3))
    asyncio.run(scenario("mounting_image",1))
