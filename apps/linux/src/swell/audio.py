"""Microphone capture and Whisper transcription with faster-whisper."""

import collections
import io
import os
import threading
from pathlib import Path

import numpy as np
import sounddevice as sd
from faster_whisper import WhisperModel, decode_audio

SAMPLE_RATE = 16000
BLOCK_SIZE = 800
# ~0.3 s kept from before the hotkey press, so the first word isn't clipped.
PREROLL_BLOCKS = 6
COMPUTE_TYPES = {"cpu": "int8", "cuda": "int8_float16"}
BEAM_SIZE = int(os.environ.get("SWELL_BEAM", "1"))


class Recorder:
    def __init__(self):
        self.preroll = collections.deque(maxlen=PREROLL_BLOCKS)
        self.chunks = []
        self.recording = False
        self.level = 0.0
        self.lock = threading.Lock()
        self.stream = sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32", blocksize=BLOCK_SIZE, callback=self._on_audio)
        self.stream.start()

    def _on_audio(self, data, frames, time_info, status):
        chunk = data[:, 0].copy()
        self.level = float(np.sqrt(np.mean(chunk**2)))
        with self.lock:
            (self.chunks if self.recording else self.preroll).append(chunk)

    def start(self):
        with self.lock:
            self.chunks = list(self.preroll)
            self.recording = True

    def stop(self) -> np.ndarray:
        with self.lock:
            self.recording = False
            chunks, self.chunks = self.chunks, []
        return np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)


def _load_cublas():
    import ctypes

    import nvidia.cublas

    lib_dir = Path(list(nvidia.cublas.__path__)[0]) / "lib"
    for name in ("libcublasLt.so.12", "libcublas.so.12"):
        ctypes.CDLL(str(lib_dir / name), mode=ctypes.RTLD_GLOBAL)


def _whisper_model(name: str, device: str) -> WhisperModel:
    if device == "cuda":
        _load_cublas()
    return WhisperModel(name, device=device, compute_type=COMPUTE_TYPES[device], cpu_threads=min(8, os.cpu_count() or 4))


def decode_wav(data: bytes) -> np.ndarray:
    return decode_audio(io.BytesIO(data), sampling_rate=SAMPLE_RATE)


class Transcriber:
    def __init__(self, model: str, device: str, vocab: str | None):
        self.model_name = model
        self.vocab = vocab
        self.device = device
        try:
            self.model = _whisper_model(model, device)
        except (OSError, RuntimeError, ValueError) as error:
            print(f"GPU load failed, falling back to CPU: {error!r}", flush=True)
            self.device = "cpu"
            self.model = _whisper_model(model, self.device)
        self.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32))

    def transcribe(self, audio: np.ndarray, language: str = "en") -> str:
        if self.model_name.endswith(".en"):
            language = "en"
        segments, _ = self.model.transcribe(
            audio,
            language=None if language == "auto" else language,
            beam_size=BEAM_SIZE,
            vad_filter=True,
            initial_prompt=self.vocab,
            condition_on_previous_text=False,
        )
        return " ".join(segment.text.strip() for segment in segments).strip()
