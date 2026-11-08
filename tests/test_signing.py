import asyncio
import plistlib
import pytest
from virtual_location.signing import SecureTSSRequest
from virtual_location.core import Problem
from types import SimpleNamespace


def test_signing_requires_tls_and_bounded_timeout(monkeypatch):
    seen = {}
    monkeypatch.setattr("virtual_location.signing.verification_bundle", lambda: "/trusted/ca.pem")
    class Response:
        content = b"STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=" + plistlib.dumps({"ApImg4Ticket": b"ticket"})
        def raise_for_status(self): pass
    def post(url, **kw):
        seen.update(url=url, **kw)
        return Response()
    monkeypatch.setattr("virtual_location.signing.requests.post", post)
    result = asyncio.run(SecureTSSRequest().send_receive())
    assert result["ApImg4Ticket"] == b"ticket"
    assert seen["url"] == "https://gs.apple.com/TSS/controller?action=2"
    assert seen["verify"] == "/trusted/ca.pem"
    assert seen["timeout"] == (10, 30)


def test_signing_refusal_has_no_raw_payload(monkeypatch):
    class Response:
        content = b"STATUS=94&MESSAGE=refused-private-device-data"
        def raise_for_status(self): pass
    monkeypatch.setattr("virtual_location.signing.requests.post", lambda *a, **kw: Response())
    with pytest.raises(Problem) as e:
        asyncio.run(SecureTSSRequest().send_receive())
    assert "private-device-data" not in str(e.value)


@pytest.mark.parametrize("requests_ca,curl_ca,platform_ca,expected", [
    ("/explicit.pem", "/curl.pem", "/platform.pem", "/explicit.pem"),
    (None, "/curl.pem", "/platform.pem", "/curl.pem"),
    (None, None, "/platform.pem", "/platform.pem"),
    (None, None, None, True),
])
def test_ca_selection_keeps_verification_enabled(monkeypatch, requests_ca, curl_ca, platform_ca, expected):
    from virtual_location.signing import verification_bundle
    for key, value in (("REQUESTS_CA_BUNDLE", requests_ca), ("CURL_CA_BUNDLE", curl_ca)):
        if value is None:
            monkeypatch.delenv(key, raising=False)
        else:
            monkeypatch.setenv(key, value)
    monkeypatch.setattr("virtual_location.signing.ssl.get_default_verify_paths",
                        lambda: SimpleNamespace(cafile=platform_ca))
    assert verification_bundle() == expected
    assert verification_bundle() is not False
