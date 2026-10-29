"""X11 clipboard and paste. Pastes through the clipboard and restores what was there, pausing CopyQ so transcripts stay out of its history."""

import subprocess
import time

from pynput import keyboard

RESTORABLE_TARGETS = ("image/png", "UTF8_STRING", "text/plain;charset=utf-8", "STRING")
TERMINAL_CLASSES = ("terminal", "kitty", "alacritty", "wezterm", "warp", "xterm", "tilix", "terminator", "konsole")
CLIPBOARD_RESTORE_DELAY = 0.4
COPYQ_RESUME_DELAY = 0.3


def copied_text() -> str:
    try:
        return subprocess.run(["xclip", "-o", "-selection", "clipboard"], capture_output=True, text=True, timeout=1).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def _active_window_class() -> str:
    try:
        window_id = subprocess.run(["xprop", "-root", "_NET_ACTIVE_WINDOW"], capture_output=True, text=True).stdout.split()[-1]
        return subprocess.run(["xprop", "-id", window_id, "WM_CLASS"], capture_output=True, text=True).stdout.lower()
    except (IndexError, OSError):
        return ""


def _read_clipboard() -> tuple[str, bytes] | None:
    targets = subprocess.run(["xclip", "-o", "-selection", "clipboard", "-t", "TARGETS"], capture_output=True, text=True, timeout=1).stdout.split()
    target = next((name for name in RESTORABLE_TARGETS if name in targets), None)
    if not target:
        return None
    data = subprocess.run(["xclip", "-o", "-selection", "clipboard", "-t", target], capture_output=True, timeout=2).stdout
    return target, data


def _write_clipboard(target: str, data: bytes):
    subprocess.run(["xclip", "-selection", "clipboard", "-t", target], input=data, check=True)


def _copyq_recording() -> bool:
    try:
        return subprocess.run(["copyq", "monitoring"], capture_output=True, text=True, timeout=1).stdout.strip() == "true"
    except (OSError, subprocess.TimeoutExpired):
        return False


def _set_copyq_recording(enabled: bool):
    subprocess.run(["copyq", "enable" if enabled else "disable"], capture_output=True, timeout=2)


def paste(text: str, typer: keyboard.Controller):
    pause_copyq = _copyq_recording()
    if pause_copyq:
        _set_copyq_recording(False)
    try:
        saved = _read_clipboard()
        _write_clipboard("UTF8_STRING", text.encode())
        time.sleep(0.05)
        in_terminal = any(name in _active_window_class() for name in TERMINAL_CLASSES)
        modifiers = [keyboard.Key.ctrl, keyboard.Key.shift] if in_terminal else [keyboard.Key.ctrl]
        for key in modifiers:
            typer.press(key)
        typer.tap("v")
        for key in reversed(modifiers):
            typer.release(key)
        time.sleep(CLIPBOARD_RESTORE_DELAY)
        if saved:
            _write_clipboard(*saved)
    finally:
        if pause_copyq:
            time.sleep(COPYQ_RESUME_DELAY)
            _set_copyq_recording(True)
