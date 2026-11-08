"""Exercise the real stdio server in a subprocess with an explicitly simulated device."""
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import pytest


@pytest.fixture
def demo(tmp_path):
    process = subprocess.Popen([sys.executable, "-m", "virtual_location.cli", "--demo",
        "--state-dir", str(tmp_path), "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True)
    responses = queue.Queue()
    def read():
        for line in process.stdout:
            responses.put(json.loads(line))
    thread = threading.Thread(target=read, daemon=True); thread.start()
    count = 0
    def request(command, **values):
        nonlocal count
        count += 1
        rid = str(count)
        process.stdin.write(json.dumps({"requestId": rid, "command": command, **values}) + "\n")
        process.stdin.flush()
        while True:
            response = responses.get(timeout=10)
            if response.get("requestId") == rid:
                return response
    yield request, process, tmp_path
    if not process.stdin.closed:
        process.stdin.close()
    try:
        process.wait(timeout=15)
    finally:
        if process.poll() is None:
            process.kill(); process.wait()


def test_full_preview_protocol_and_stale_session(demo):
    send, process, state = demo
    device = send("discover")["data"]["devices"][0]
    assert device["name"] == "iPhone 界面预览"
    session = send("prepare", deviceId=device["id"])["data"]["sessionId"]
    assert send("setLocation", sessionId=session, latitude=-33.8568, longitude=151.2153)["ok"]
    assert list((state / "preview").glob("*.pending-clear"))
    assert send("clear")["data"]["status"] == "clear_sent"
    assert not list((state / "preview").glob("*.pending-clear"))
    assert send("disconnect")["ok"]
    assert send("setLocation", sessionId=session, latitude=0, longitude=0)["errorCode"] == "STALE_SESSION"


def test_eof_cleans_simulated_active_session(demo):
    send, process, state = demo
    device = send("discover")["data"]["devices"][0]
    session = send("prepare", deviceId=device["id"])["data"]["sessionId"]
    assert send("setLocation", sessionId=session, latitude=0, longitude=0)["ok"]
    process.stdin.close()
    assert process.wait(timeout=15) == 0
    assert not list((state / "preview").glob("*.pending-clear"))
