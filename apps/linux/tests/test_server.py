import http.client
import ipaddress
import json

import jsonschema
import pytest

from conftest import protocol_fixture
from swell import server

TOKEN = "test-token"
WAV = b"RIFF fake wav"


def transcribe(wav: bytes, language: str, source: str) -> str:
    if wav == b"undecodable":
        raise server.ApiError(400, "bad_request", "Couldn't decode the audio.")
    if wav == b"crash":
        raise RuntimeError("CUDA out of memory")
    return f"{len(wav)} bytes in {language} from {source}"


@pytest.fixture
def host():
    handler = server.make_handler(TOKEN, lambda: protocol_fixture("health.json"), transcribe)
    running = server.serve(0, handler, host="127.0.0.1")
    yield running.server_address[1]
    running.shutdown()
    running.server_close()


def request(port: int, method: str, path: str, body: bytes | None = None, token: str | None = TOKEN, headers: dict[str, str] | None = None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    sent = {"Authorization": f"Bearer {token}"} if token is not None else {}
    connection.request(method, path, body=body, headers=sent | (headers or {}))
    response = connection.getresponse()
    return response.status, json.loads(response.read())


def validate(protocol_schema, body, definition: str):
    jsonschema.validate(body, {**protocol_schema, "$ref": f"#/$defs/{definition}"})


def test_health(host, protocol_schema):
    status, body = request(host, "GET", "/v1/health")
    assert status == 200
    validate(protocol_schema, body, "Health")


@pytest.mark.parametrize(
    ("path", "expected"),
    [
        ("/v1/transcribe", "13 bytes in auto from 127.0.0.1"),
        ("/v1/transcribe?language=en", "13 bytes in en from 127.0.0.1"),
    ],
)
def test_transcribe(host, protocol_schema, path, expected):
    status, body = request(host, "POST", path, WAV, headers={"Content-Type": "audio/wav"})
    assert (status, body) == (200, {"text": expected})
    validate(protocol_schema, body, "Transcription")


@pytest.mark.parametrize(
    ("method", "path", "body", "token", "headers", "status", "code"),
    [
        ("GET", "/v1/health", None, None, None, 401, "unauthorized"),
        ("GET", "/v1/health", None, "wrong", None, 401, "unauthorized"),
        ("GET", "/health", None, TOKEN, None, 404, "not_found"),
        ("POST", "/transcribe", WAV, TOKEN, None, 404, "not_found"),
        ("POST", "/v1/transcribe", b"", TOKEN, None, 400, "bad_request"),
        ("POST", "/v1/transcribe?language=English", WAV, TOKEN, None, 400, "bad_request"),
        ("POST", "/v1/transcribe", b"undecodable", TOKEN, None, 400, "bad_request"),
        ("POST", "/v1/transcribe", None, TOKEN, {"Content-Length": str(server.MAX_BODY_BYTES + 1)}, 413, "too_large"),
        ("POST", "/v1/transcribe", b"crash", TOKEN, None, 500, "internal"),
    ],
)
def test_errors(host, protocol_schema, method, path, body, token, headers, status, code):
    actual_status, actual_body = request(host, method, path, body, token, headers)
    assert (actual_status, actual_body["error"]["code"]) == (status, code)
    validate(protocol_schema, actual_body, "Error")


def test_rejects_callers_off_the_tailnet(protocol_schema):
    handler = server.make_handler(TOKEN, lambda: protocol_fixture("health.json"), transcribe, allowed_networks=(ipaddress.ip_network("100.64.0.0/10"),))
    running = server.serve(0, handler, host="127.0.0.1")
    try:
        status, body = request(running.server_address[1], "GET", "/v1/health")
    finally:
        running.shutdown()
        running.server_close()
    assert (status, body["error"]["code"]) == (403, "forbidden")
    validate(protocol_schema, body, "Error")
