"""What this machine can run. Standard library only, like the other modules the control window imports."""

import functools
import os
import subprocess


@functools.cache
def has_nvidia_gpu() -> bool:
    # SWELL_NO_GPU=1 runs everything as on a machine without one, to test that path on a machine with one.
    if os.environ.get("SWELL_NO_GPU") == "1":
        return False
    try:
        return subprocess.run(["nvidia-smi", "-L"], capture_output=True, timeout=3).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False
