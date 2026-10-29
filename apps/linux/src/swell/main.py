"""Entry point. Takes the single-instance lock before importing the app, so a second launch exits without loading numpy, CUDA or Whisper."""

import fcntl
import os
import sys

from swell.settings import LOCK_FILE, MODELS, STATE_DIR, load_settings


def main():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with LOCK_FILE.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("swell is already running", flush=True)
            sys.exit(0)
        lock.truncate(0)
        lock.write(str(os.getpid()))
        lock.flush()

        from swell.app import App

        model = os.environ.get("SWELL_MODEL", "")
        App(model if model in MODELS else load_settings().load_model).run()


if __name__ == "__main__":
    main()
