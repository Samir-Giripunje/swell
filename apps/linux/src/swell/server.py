"""Serves transcription to other Swell apps over the tailnet. The wire format is defined in packages/protocol."""

import hmac
import ipaddress
import json
import re
import threading
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

TAILNET_AND_LOOPBACK = (ipaddress.ip_network("100.64.0.0/10"), ipaddress.ip_network("127.0.0.0/8"))
MAX_BODY_BYTES = 50 * 1024 * 1024
LANGUAGE = re.compile(r"auto|[a-z]{2,3}")

Health = Callable[[], dict[str, object]]
Transcribe = Callable[[bytes, str, str], str]
"""Takes WAV bytes, a language (`auto` or a Whisper code) and the caller's address; returns the final text."""


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def make_handler(token: str, health: Health, transcribe: Transcribe, allowed_networks=TAILNET_AND_LOOPBACK) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self._respond(self._get)

        def do_POST(self):
            self._respond(self._post)

        def _get(self) -> dict[str, object]:
            if urlsplit(self.path).path != "/v1/health":
                raise ApiError(404, "not_found", f"No route for GET {urlsplit(self.path).path}.")
            return health()

        def _post(self) -> dict[str, object]:
            url = urlsplit(self.path)
            if url.path != "/v1/transcribe":
                raise ApiError(404, "not_found", f"No route for POST {url.path}.")
            language = parse_qs(url.query).get("language", ["auto"])[0]
            if not LANGUAGE.fullmatch(language):
                raise ApiError(400, "bad_request", f"Unknown language {language!r}.")
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY_BYTES:
                raise ApiError(413, "too_large", "Audio is over 50 MB.")
            if length <= 0:
                raise ApiError(400, "bad_request", "Send the audio as a WAV request body.")
            return {"text": transcribe(self.rfile.read(length), language, self.client_address[0])}

        def _respond(self, route: Callable[[], dict[str, object]]):
            try:
                self._authorize()
                status, body = 200, route()
            except ApiError as error:
                status, body = error.status, {"error": {"code": error.code, "message": error.message}}
            except Exception as error:  # noqa: BLE001 - a host bug must still answer in the protocol's error shape
                print(f"request {self.command} {self.path} failed: {error!r}", flush=True)
                status, body = 500, {"error": {"code": "internal", "message": "Transcription failed on the host. Check its log."}}
            payload = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            if status >= 400:
                self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)

        def _authorize(self):
            client = ipaddress.ip_address(self.client_address[0])
            if not any(client in network for network in allowed_networks):
                raise ApiError(403, "forbidden", "Only machines on your Tailscale network can connect.")
            supplied = self.headers.get("Authorization", "").removeprefix("Bearer ")
            if not hmac.compare_digest(supplied.encode(), token.encode()):
                raise ApiError(401, "unauthorized", "Wrong or missing token.")

        def log_message(self, format, *args):
            pass

    return Handler


def serve(port: int, handler: type[BaseHTTPRequestHandler], host: str = "0.0.0.0") -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((host, port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server
