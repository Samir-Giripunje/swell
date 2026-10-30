"""Swell for Linux: hold Right Ctrl to dictate, hold Right Alt to write, and optionally transcribe for other machines."""

import queue
import socket
import threading
import time
import tkinter as tk

from pynput import keyboard

from swell import cleanup, server, writer
from swell.audio import SAMPLE_RATE, Recorder, Transcriber, decode_wav
from swell.desktop import copied_text, paste
from swell.hardware import has_nvidia_gpu
from swell.overlay import Overlay
from swell.settings import SERVER_PORT, STATUS_FILE, load_settings, server_token, vocab

HOTKEY_MODES = {keyboard.Key.ctrl_r: "dictate", keyboard.Key.alt_r: "write"}
MASK_KEYS = {keyboard.Key.ctrl, keyboard.Key.ctrl_l}
MASK_WINDOW_SECONDS = 0.15
MIN_SECONDS = 0.4


class App:
    def __init__(self, model: str):
        self.model = model
        self.root = tk.Tk()
        self.recorder = Recorder()
        self.overlay = Overlay(self.root, self.recorder)
        self.events: queue.Queue[str] = queue.Queue()
        self.typer = keyboard.Controller()
        self.transcriber = None
        self.state = "loading"
        self.active_hotkey = None
        self.mask_until = 0.0
        self.mode = "dictate"
        self.context = ""
        self.recording_started_at = 0.0
        self.dictation_lock = threading.Lock()
        self.overlay.show("loading")
        threading.Thread(target=self._load_model, daemon=True).start()
        keyboard.Listener(on_press=self._on_press, on_release=self._on_release, daemon=True).start()
        self.root.after(20, self._drain_events)

    def _load_model(self):
        settings = load_settings()
        started = time.time()
        device = settings.device if has_nvidia_gpu() else "cpu"
        STATUS_FILE.write_text(f"loading {self.model} on {device}")
        self.transcriber = Transcriber(self.model, device, vocab())
        if cleanup.uses_model(settings.cleanup):
            cleanup.set_loaded(True)
        if settings.serve:
            self._serve()
        device = self.transcriber.device
        print(f"loaded {self.model} on {device} in {time.time() - started:.1f}s", flush=True)
        STATUS_FILE.write_text(f"ready {self.model} on {'GPU' if device == 'cuda' else 'CPU'}")
        self.events.put("loaded")

    def _serve(self):
        def health() -> dict[str, object]:
            assert self.transcriber
            return {"protocol": 1, "name": socket.gethostname(), "model": self.model, "device": self.transcriber.device, "cleanup": load_settings().cleanup}

        handler = server.make_handler(server_token(), health, self._remote_text, self._corrected_text)
        server.serve(SERVER_PORT, handler)
        print(f"serving other machines on port {SERVER_PORT}", flush=True)

    def _remote_text(self, wav: bytes, language: str, level: str | None, source: str) -> str:
        try:
            audio = decode_wav(wav)
        except Exception as error:  # noqa: BLE001 - PyAV raises many types for unreadable audio
            raise server.ApiError(400, "bad_request", "Couldn't decode the audio; send a WAV file.") from error
        return self._dictation_text(audio, language=language, level=level, source=source)

    def _corrected_text(self, text: str, level: str) -> str:
        assert self.transcriber
        started = time.time()
        try:
            result = cleanup.corrected(text, self.transcriber.vocab, level)
        except cleanup.CorrectionError as error:
            print(f"correction ({level}) of {len(text)} chars failed: {error}", flush=True)
            raise server.ApiError(503, "unavailable", str(error)) from error
        print(f"corrected ({level}) {len(text)} chars in {time.time() - started:.2f}s", flush=True)
        return result

    def _on_press(self, key):
        if self._is_mask_echo(key):
            return
        if key in HOTKEY_MODES and self.active_hotkey is None:
            self.active_hotkey = key
            if HOTKEY_MODES[key] == "write":
                self._mask_lone_alt()
            self.events.put(f"start:{HOTKEY_MODES[key]}")
        elif self.active_hotkey is not None and key != self.active_hotkey:
            self.events.put("cancel")

    def _on_release(self, key):
        if self._is_mask_echo(key):
            return
        if key == self.active_hotkey:
            self.active_hotkey = None
            self.events.put("stop")

    def _mask_lone_alt(self):
        # A lone Alt press and release opens the menu bar in Electron apps (Slack, T3 Code), so tap a modifier while Alt is held.
        self.mask_until = time.monotonic() + MASK_WINDOW_SECONDS
        self.typer.tap(keyboard.Key.ctrl_l)

    def _is_mask_echo(self, key) -> bool:
        return key in MASK_KEYS and time.monotonic() < self.mask_until

    def _drain_events(self):
        while not self.events.empty():
            self._handle(self.events.get())
        self.root.after(20, self._drain_events)

    def _handle(self, event: str):
        if event == "loaded":
            self.state = "idle"
            self.overlay.show("ready", hide_after_ms=1800)
        elif event.startswith("start:") and self.state == "idle":
            self.state = "recording"
            self.mode = event.removeprefix("start:")
            self.context = copied_text() if self.mode == "write" else ""
            self.overlay.mode = self.mode
            self.overlay.context_chars = len(self.context)
            self.overlay.detail = ""
            self.recording_started_at = time.time()
            self.recorder.start()
            self.overlay.show("recording")
        elif event == "cancel" and self.state == "recording":
            self.state = "idle"
            self.recorder.stop()
            self.overlay.hide()
        elif event == "stop" and self.state == "recording":
            audio = self.recorder.stop()
            if time.time() - self.recording_started_at < MIN_SECONDS:
                self.state = "idle"
                self.overlay.hide()
                return
            self.state = "transcribing"
            self.overlay.detail = "Turning your speech into an instruction…"
            self.overlay.show("transcribing")
            target = self._write_and_paste if self.mode == "write" else self._transcribe_and_paste
            threading.Thread(target=target, args=(audio,), daemon=True).start()
        elif event == "cleaning" and self.state == "transcribing":
            self.overlay.show("cleaning")
        elif event.startswith("writing:"):
            instruction = event.removeprefix("writing:")
            self.overlay.detail = f"“{instruction[:70]}{'…' if len(instruction) > 70 else ''}”" if instruction else "Replying to the copied text"
            self.overlay.show("writing")
        elif event.startswith("pasted:"):
            self.state = "idle"
            self.overlay.detail = f"Reply pasted · {event.removeprefix('pasted:')} chars"
            self.overlay.show("pasted", hide_after_ms=1500)
        elif event == "failed":
            self.state = "idle"
            self.overlay.show("failed", hide_after_ms=2500)
        elif event == "done":
            self.state = "idle"
            self.overlay.hide()
        elif event == "empty":
            self.state = "idle"
            self.overlay.show("empty", hide_after_ms=1200)

    def _dictation_text(self, audio, language: str = "en", level: str | None = None, source: str = "local") -> str:
        assert self.transcriber
        # One GPU: local and remote dictations take turns.
        with self.dictation_lock:
            started = time.time()
            text = self.transcriber.transcribe(audio, language)
            prefix = "" if source == "local" else f"[{source}] "
            print(f"{prefix}{len(audio) / SAMPLE_RATE:.1f}s audio -> {time.time() - started:.2f}s: {text!r}", flush=True)
            level = level or load_settings().cleanup
            if level != "off":
                if source == "local" and cleanup.uses_model(level):
                    self.events.put("cleaning")
                started = time.time()
                text = cleanup.cleaned(text, self.transcriber.vocab, level)
                print(f"  cleaned ({level}) -> {time.time() - started:.2f}s: {text!r}", flush=True)
            return text

    def _transcribe_and_paste(self, audio):
        text = self._dictation_text(audio)
        if text:
            paste(text, self.typer)
        self.events.put("done" if text else "empty")

    def _write_and_paste(self, audio):
        assert self.transcriber
        instruction = self.transcriber.transcribe(audio)
        if not instruction and not self.context:
            self.events.put("empty")
            return
        self.events.put(f"writing:{instruction}")
        started = time.time()
        try:
            response = writer.write(self.context, instruction)
        except Exception as error:  # noqa: BLE001 - any writer failure shows the same "failed" pill
            print(f"writer failed: {error!r}", flush=True)
            self.events.put("failed")
            return
        print(f"write: {len(self.context)} chars context, instruction {instruction!r} -> {time.time() - started:.2f}s, {len(response)} chars", flush=True)
        paste(response, self.typer)
        self.events.put(f"pasted:{len(response)}")

    def run(self):
        try:
            self.root.mainloop()
        except KeyboardInterrupt:
            pass
        finally:
            STATUS_FILE.unlink(missing_ok=True)
