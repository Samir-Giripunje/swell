"""Swell's settings window. Runs on the system Python for GTK, so it imports only standard-library modules from this package."""

import fcntl
import os
import signal
import subprocess

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkX11", "3.0")
from gi.repository import Gdk, GdkX11, GLib, Gtk  # noqa: E402

from swell import cleanup  # noqa: E402
from swell.pairing import this_machine_link  # noqa: E402
from swell.settings import (  # noqa: E402
    AUTOSTART_FILE,
    DEVICES,
    LAUNCHER,
    LOCK_FILE,
    LOG_FILE,
    MODELS,
    STATUS_FILE,
    WRITER_PROMPT_FILE,
    load_settings,
    save_setting,
    server_token,
)

START_GRACE_SECONDS = 30


def autostart_entry(model: str) -> str:
    return f"""[Desktop Entry]
Type=Application
Name=Swell
Comment=Load Whisper and listen for Right Ctrl
Exec=env SWELL_MODEL={model} {LAUNCHER}
Icon=audio-input-microphone
X-GNOME-Autostart-enabled=true
NoDisplay=false
"""


def running_pid() -> int | None:
    if not LOCK_FILE.exists():
        return None
    with LOCK_FILE.open() as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return int(lock.read().strip() or 0) or None
        fcntl.flock(lock, fcntl.LOCK_UN)
    return None


def start_dictation(model: str):
    env = {**os.environ, "SWELL_MODEL": model}
    subprocess.Popen([str(LAUNCHER)], env=env, start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop_dictation():
    pid = running_pid()
    if pid:
        os.kill(pid, signal.SIGTERM)
    STATUS_FILE.unlink(missing_ok=True)
    cleanup.set_loaded(False)


def status_text() -> str:
    if not running_pid():
        return "Stopped"
    status = STATUS_FILE.read_text().strip() if STATUS_FILE.exists() else "starting"
    if status.startswith("ready"):
        return f"Ready · {status.removeprefix('ready ')} · hold Right Ctrl to talk"
    return f"{status.capitalize()}…"


def set_autostart(enabled: bool, model: str):
    if enabled:
        AUTOSTART_FILE.parent.mkdir(parents=True, exist_ok=True)
        AUTOSTART_FILE.write_text(autostart_entry(model))
    else:
        AUTOSTART_FILE.unlink(missing_ok=True)


def picker(options: dict[str, str], selected: str, on_change) -> Gtk.ComboBoxText:
    combo = Gtk.ComboBoxText(valign=Gtk.Align.CENTER)
    for value, label in options.items():
        combo.append(value, label)
    combo.set_active_id(selected)
    combo.connect("changed", lambda combo: on_change(combo.get_active_id()))
    return combo


def row(title: str, subtitle: str, *controls: Gtk.Widget) -> Gtk.Box:
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
    labels = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
    title_label = Gtk.Label(xalign=0)
    title_label.set_markup(f"<b>{GLib.markup_escape_text(title)}</b>")
    subtitle_label = Gtk.Label(label=subtitle, xalign=0, wrap=True)
    subtitle_label.get_style_context().add_class("dim-label")
    labels.pack_start(title_label, False, False, 0)
    labels.pack_start(subtitle_label, False, False, 0)
    box.pack_start(labels, True, True, 0)
    for control in reversed(controls):
        box.pack_end(control, False, False, 0)
    return box


def switch(active: bool, on_toggle) -> Gtk.Switch:
    toggle = Gtk.Switch(active=active, valign=Gtk.Align.CENTER)
    toggle.connect("state-set", lambda _switch, state: on_toggle(state) or False)
    return toggle


def button(label: str, on_click) -> Gtk.Button:
    widget = Gtk.Button(label=label)
    widget.connect("clicked", lambda _button: on_click())
    return widget


class ControlWindow(Gtk.ApplicationWindow):
    def __init__(self, application: Gtk.Application):
        super().__init__(application=application, title="Swell")
        self.set_default_size(560, -1)
        self.set_resizable(False)
        self.set_icon_name("audio-input-microphone")
        self.syncing = False
        self.started_at = 0.0
        self.notice_until = 0.0
        self.settings = load_settings()

        self.load_switch = switch(bool(running_pid()), self._on_load_toggled)
        rows = (
            row(
                "Load model",
                "Load Whisper now. Resets to off after a restart.",
                picker(MODELS, self.settings.load_model, self._on_load_model_changed),
                self.load_switch,
            ),
            row(
                "Load model on startup",
                "Load Whisper automatically every time you log in.",
                picker(MODELS, self.settings.startup_model, self._on_startup_model_changed),
                switch(AUTOSTART_FILE.exists(), self._on_startup_toggled),
            ),
            row("Run Whisper on", "GPU is ~6x faster. Restarts dictation.", picker(DEVICES, self.settings.device, self._on_device_changed)),
            row(
                "Clean up dictation",
                f"Remove fillers and fix grammar with {cleanup.CLEANUP_MODEL} on the GPU. Keeps it loaded (~5 GB VRAM).",
                switch(self.settings.cleanup, self._on_cleanup_toggled),
            ),
            row(
                "Serve other machines",
                "Let Swell on your other machines transcribe here over Tailscale. Restarts dictation.",
                switch(self.settings.serve, self._on_serve_toggled),
            ),
        )
        self.status_label = Gtk.Label(xalign=0, selectable=True, wrap=True)
        hint = Gtk.Label(
            label="Hold Right Ctrl to dictate. Copy text (Ctrl+C), click the input box, then hold Right Alt and say what to write.",
            xalign=0,
            wrap=True,
        )
        hint.get_style_context().add_class("dim-label")
        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        for widget in (
            button("Open log", lambda: subprocess.Popen(["xdg-open", str(LOG_FILE)])),
            button("Edit writer prompt", lambda: subprocess.Popen(["xdg-open", str(WRITER_PROMPT_FILE)])),
            button("Copy pairing link", self._on_copy_pairing_link),
        ):
            buttons.pack_start(widget, False, False, 0)

        layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18, margin=22)
        for widget in (*rows, Gtk.Separator(), self.status_label, hint, buttons):
            layout.pack_start(widget, False, False, 0)
        self.add(layout)
        self._refresh()
        GLib.timeout_add_seconds(1, self._refresh)

    def _now(self) -> float:
        return GLib.get_monotonic_time() / 1e6

    def _on_load_toggled(self, enabled: bool):
        if self.syncing:
            return
        if enabled and not running_pid():
            self.started_at = self._now()
            start_dictation(self.settings.load_model)
        elif not enabled:
            stop_dictation()
        self._refresh()

    def _on_load_model_changed(self, model: str):
        self.settings = save_setting("load_model", model)
        self._restart_if_running()

    def _on_startup_toggled(self, enabled: bool):
        set_autostart(enabled, self.settings.startup_model)

    def _on_startup_model_changed(self, model: str):
        self.settings = save_setting("startup_model", model)
        if AUTOSTART_FILE.exists():
            set_autostart(True, model)

    def _on_device_changed(self, device: str):
        self.settings = save_setting("device", device)
        self._restart_if_running()

    def _on_cleanup_toggled(self, enabled: bool):
        self.settings = save_setting("cleanup", enabled)
        cleanup.set_loaded(enabled and bool(running_pid()))

    def _on_serve_toggled(self, enabled: bool):
        self.settings = save_setting("serve", enabled)
        self._restart_if_running()

    def _restart_if_running(self):
        if running_pid():
            stop_dictation()
            self.started_at = self._now()
            GLib.timeout_add(200, self._start_when_stopped)

    def _start_when_stopped(self) -> bool:
        if running_pid():
            return True
        start_dictation(self.settings.load_model)
        return False

    def _on_copy_pairing_link(self):
        link = this_machine_link(server_token()) if self.settings.serve else None
        if not link:
            return self._notice("Turn on Serve other machines and connect Tailscale first.")
        Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(link, -1)
        self._notice("Pairing link copied. In Swell on your Mac: Engines › Add machine, then paste it. Treat it like a password.")

    def _notice(self, text: str):
        self.notice_until = self._now() + 6
        self.status_label.set_markup(f"<b>{GLib.markup_escape_text(text)}</b>")

    def _refresh(self) -> bool:
        if self._now() > self.notice_until:
            self.status_label.set_markup(f"Status: <b>{GLib.markup_escape_text(status_text())}</b>")
        running = bool(running_pid())
        start_pending = self.load_switch.get_active() and self._now() - self.started_at < START_GRACE_SECONDS
        if self.load_switch.get_active() != running and not start_pending:
            self.syncing = True
            self.load_switch.set_active(running)
            self.syncing = False
        return True


class ControlApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="com.samirgiripunje.Swell")
        self.window: ControlWindow | None = None

    def do_activate(self):
        if self.window:
            self.window.hide()
        else:
            self.window = ControlWindow(self)
        self.window.show_all()
        self.window.deiconify()
        self.window.present_with_time(GdkX11.x11_get_server_time(self.window.get_window()))


if __name__ == "__main__":
    GLib.set_prgname("swell")
    ControlApp().run()
