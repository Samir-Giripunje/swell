"""Checks that Medium and High keep only what the speaker meant when they correct themselves: packages/protocol/fixtures/correction-evals.json.

Run on the host: uv run --only-group dev python scripts/eval_rephrasing.py [level ...]

Needs Ollama running with the cleanup model. Prints every failure and a pass count per mode.
"""

import json
import re
import sys
from pathlib import Path

from swell import cleanup

EVALS = Path(__file__).resolve().parents[3] / "packages" / "protocol" / "fixtures" / "correction-evals.json"


def failures(case: dict, result: str) -> list[str]:
    problems = [f"missing /{pattern}/" for pattern in case["include"] if not re.search(pattern, result, re.IGNORECASE)]
    return problems + [f"kept /{pattern}/" for pattern in case["exclude"] if re.search(pattern, result, re.IGNORECASE)]


def main(modes: list[str]):
    cases = json.loads(EVALS.read_text())["cases"]
    for mode in modes:
        passed = 0
        for case in cases:
            result = cleanup.cleaned(case["text"], None, mode)
            problems = failures(case, result)
            passed += not problems
            if problems:
                print(f"[{mode}] FAIL {case['text']!r}\n        -> {result!r}\n        {'; '.join(problems)}")
        print(f"{mode}: {passed}/{len(cases)} passed")


if __name__ == "__main__":
    main(sys.argv[1:] or ["medium", "high"])
