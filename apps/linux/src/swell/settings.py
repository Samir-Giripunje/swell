"""Paths and settings shared by the Swell daemon and its control window.

Standard library only: the control window runs on the system Python, which has GTK but none of the daemon's dependencies.
"""

import json
import secrets
from dataclasses import asdict, dataclass, replace
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "swell"
STATE_DIR = Path.home() / ".cache" / "swell"
SETTINGS_FILE = CONFIG_DIR / "settings.json"
TOKEN_FILE = CONFIG_DIR / "server_token"
WRITER_PROMPT_FILE = CONFIG_DIR / "writer_prompt.md"
VOCAB_FILE = CONFIG_DIR / "vocab.txt"
STATUS_FILE = STATE_DIR / "status"
LOCK_FILE = STATE_DIR / "lock"
LOG_FILE = STATE_DIR / "swell.log"
LAUNCHER = Path.home() / ".local" / "bin" / "swell"
AUTOSTART_FILE = Path.home() / ".config" / "autostart" / "swell.desktop"

SERVER_PORT = 8765
MODELS = {"tiny.en": "tiny.en (39M)", "base.en": "base.en (74M)", "small.en": "small.en (244M)", "large-v3-turbo": "large-v3-turbo (809M, GPU)"}
DEVICES = {"cuda": "GPU", "cpu": "CPU"}
DEFAULT_MODEL = "small.en"


@dataclass(frozen=True)
class Settings:
    load_model: str = DEFAULT_MODEL
    startup_model: str = DEFAULT_MODEL
    device: str = "cuda"
    cleanup: bool = True
    serve: bool = False


def load_settings(path: Path = SETTINGS_FILE) -> Settings:
    try:
        stored = json.loads(path.read_text())
    except (OSError, ValueError):
        stored = {}
    defaults = Settings()
    return Settings(
        load_model=_model(stored.get("load_model")),
        startup_model=_model(stored.get("startup_model")),
        device="cpu" if stored.get("device") == "cpu" else "cuda",
        cleanup=stored.get("cleanup", defaults.cleanup) is True,
        serve=stored.get("serve", defaults.serve) is True,
    )


def _model(value: object) -> str:
    return value if isinstance(value, str) and value in MODELS else DEFAULT_MODEL


def save_setting(key: str, value: str | bool, path: Path = SETTINGS_FILE) -> Settings:
    settings = replace(load_settings(path), **{key: value})
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(settings), indent=2))
    return settings


def server_token(path: Path = TOKEN_FILE) -> str:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(mode=0o600)
        path.write_text(secrets.token_urlsafe(32))
    return path.read_text().strip()


def vocab(path: Path = VOCAB_FILE) -> str | None:
    """Terms Whisper and the cleanup model should spell exactly, one per line."""
    try:
        return ", ".join(path.read_text().split()) or None
    except OSError:
        return None
