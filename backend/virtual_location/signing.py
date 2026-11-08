"""Scoped compatibility adapter for upstream's HTTP TSS transport.

Uses the same Apple signing service via HTTPS, certificate verification and bounded timeouts.
Only installed in this backend process; no global settings or dependency files are edited.
"""
import asyncio
import os
import plistlib
import requests
import ssl
from pymobiledevice3.restore.tss import TSSRequest, TSSResponse
from .core import Problem


def verification_bundle():
    # Apple's signing CA may be trusted by Python's platform bundle but absent
    # from Requests' certifi bundle. Keep verification on and honor explicit CAs.
    return (os.environ.get("REQUESTS_CA_BUNDLE") or os.environ.get("CURL_CA_BUNDLE")
            or ssl.get_default_verify_paths().cafile or True)


class SecureTSSRequest(TSSRequest):
    async def send_receive(self):
        payload = plistlib.dumps(self._request)

        def post():
            response = requests.post(
                "https://gs.apple.com/TSS/controller?action=2", data=payload,
                headers={"Content-Type": 'text/xml; charset="utf-8"', "User-Agent": "InetURL/1.0"},
                timeout=(10, 30), verify=verification_bundle())
            response.raise_for_status()
            return response.content

        content = await asyncio.to_thread(post)
        if b"MESSAGE=SUCCESS" not in content or b"REQUEST_STRING=" not in content:
            raise Problem("APPLE_SIGNING_REFUSED", "Apple 未返回成功的开发镜像签名，请稍后重试")
        return TSSResponse(plistlib.loads(content.split(b"REQUEST_STRING=", 1)[1]))
