"""Pairing links hand this machine's address and token to a Swell client. See packages/protocol/README.md."""

import socket
import subprocess
from urllib.parse import quote, urlencode

from swell.settings import SERVER_PORT


def pairing_link(name: str, url: str, token: str) -> str:
    return "swell://pair?" + urlencode({"name": name, "url": url, "token": token}, quote_via=quote, safe="")


def tailscale_ip() -> str | None:
    try:
        return subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=3).stdout.split()[0]
    except (OSError, IndexError, subprocess.TimeoutExpired):
        return None


def this_machine_link(token: str) -> str | None:
    address = tailscale_ip()
    return pairing_link(socket.gethostname(), f"http://{address}:{SERVER_PORT}", token) if address else None
