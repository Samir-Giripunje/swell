"""The on-screen pill shown while you dictate, on the monitor under the pointer."""

import collections
import re
import subprocess
import tkinter as tk

from swell.audio import Recorder

WIDTH, HEIGHT = 300, 46
WRITER_WIDTH, WRITER_HEIGHT = 440, 70
WRITER_STEPS = ("Listening", "Transcribing", "Generating", "Pasted")
BAR_COUNT = 24
COLORS = {
    "bg": "#16161a",
    "text": "#e6e6e6",
    "recording": "#ff4d4f",
    "transcribing": "#f5a623",
    "cleaning": "#4da3ff",
    "writing": "#b37feb",
    "ready": "#3ecf8e",
    "failed": "#ff4d4f",
    "bar": "#8a8aff",
    "writer_bar": "#b37feb",
}
LABELS = {
    "transcribing": "Transcribing…",
    "cleaning": "Cleaning…",
    "ready": "Ready · Right Ctrl dictate · Right Alt write",
    "loading": "Loading model…",
    "empty": "Didn't catch that",
}


def _monitor_under_pointer(root: tk.Tk) -> tuple[int, int, int, int]:
    pointer_x, pointer_y = root.winfo_pointerxy()
    output = subprocess.run(["xrandr", "--current", "--listactivemonitors"], capture_output=True, text=True).stdout
    for width, height, left, top in re.findall(r"(\d+)/\d+x(\d+)/\d+\+(\d+)\+(\d+)", output):
        width, height, left, top = int(width), int(height), int(left), int(top)
        if left <= pointer_x < left + width and top <= pointer_y < top + height:
            return width, height, left, top
    return root.winfo_screenwidth(), root.winfo_screenheight(), 0, 0


class Overlay:
    def __init__(self, root: tk.Tk, recorder: Recorder):
        self.root = root
        self.recorder = recorder
        self.levels = collections.deque([0.0] * BAR_COUNT, maxlen=BAR_COUNT)
        self.status = "idle"
        self.mode = "dictate"
        self.context_chars = 0
        self.detail = ""
        root.overrideredirect(True)
        root.attributes("-topmost", True)
        root.configure(bg=COLORS["bg"])
        self.canvas = tk.Canvas(root, width=WRITER_WIDTH, height=WRITER_HEIGHT, bg=COLORS["bg"], highlightthickness=0)
        self.canvas.pack()
        root.withdraw()
        self._tick()

    def show(self, status: str, hide_after_ms: int | None = None):
        self.status = status
        overlay_width, overlay_height = (WRITER_WIDTH, WRITER_HEIGHT) if self.mode == "write" else (WIDTH, HEIGHT)
        width, height, left, top = _monitor_under_pointer(self.root)
        self.root.geometry(f"{overlay_width}x{overlay_height}+{left + (width - overlay_width) // 2}+{top + height - overlay_height - 90}")
        self.root.deiconify()
        self.root.lift()
        if hide_after_ms:
            self.root.after(hide_after_ms, lambda: self.status == status and self.hide())

    def hide(self):
        self.status = "idle"
        self.root.withdraw()

    def _tick(self):
        if self.status != "idle":
            self.levels.append(self.recorder.level if self.status == "recording" else 0.0)
            self._draw()
        self.root.after(40, self._tick)

    def _draw(self):
        if self.mode == "write" and self.status in ("recording", "transcribing", "writing", "pasted", "failed", "empty"):
            self._draw_writer()
            return
        canvas = self.canvas
        canvas.delete("all")
        canvas.create_oval(14, 17, 26, 29, fill=COLORS.get(self.status, COLORS["ready"]), outline="")
        if self.status == "recording":
            for index, level in enumerate(self.levels):
                bar_height = max(2, min(30, level * 400))
                x = 40 + index * 8
                canvas.create_rectangle(x, HEIGHT / 2 - bar_height / 2, x + 4, HEIGHT / 2 + bar_height / 2, fill=COLORS["bar"], outline="")
        else:
            canvas.create_text(38, HEIGHT / 2, text=LABELS.get(self.status, ""), fill=COLORS["text"], anchor="w", font=("Sans", 10))

    def _draw_writer(self):
        canvas = self.canvas
        canvas.delete("all")
        current = {"recording": 0, "transcribing": 1, "writing": 2, "pasted": 3}.get(self.status, -1)
        x = 16
        for index, step in enumerate(WRITER_STEPS):
            done, active = index < current, index == current
            color = COLORS["ready"] if done else COLORS["writing"] if active else "#55555f"
            canvas.create_oval(x, 13, x + 10, 23, fill=color if done or active else "", outline=color, width=2)
            label = canvas.create_text(
                x + 16,
                18,
                text=step,
                fill=COLORS["text"] if done or active else "#77777f",
                anchor="w",
                font=("Sans", 9, "bold" if active else "normal"),
            )
            x = canvas.bbox(label)[2] + 10
            if index < len(WRITER_STEPS) - 1:
                canvas.create_text(x, 18, text="›", fill="#55555f", anchor="w", font=("Sans", 10))
                x += 16
        if self.status == "recording":
            for index, level in enumerate(list(self.levels)[-16:]):
                bar_height = max(2, min(22, level * 300))
                canvas.create_rectangle(16 + index * 7, 48 - bar_height / 2, 20 + index * 7, 48 + bar_height / 2, fill=COLORS["writer_bar"], outline="")
            detail = f"{self.context_chars:,} chars copied" if self.context_chars else "Clipboard empty"
            canvas.create_text(136, 48, text=detail, fill=COLORS["text"], anchor="w", font=("Sans", 9))
        else:
            details = {"failed": "Generation failed · open the log", "empty": "Didn't catch that"}
            canvas.create_text(
                16,
                48,
                text=details.get(self.status, self.detail),
                fill=COLORS["failed"] if self.status == "failed" else COLORS["text"],
                anchor="w",
                font=("Sans", 9),
                width=WRITER_WIDTH - 32,
            )
