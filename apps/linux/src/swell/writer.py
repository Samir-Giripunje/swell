"""Writer mode: turns a spoken instruction plus copied text into a written reply with OpenAI."""

import json
import os
import re
import urllib.request
from pathlib import Path

from swell.settings import WRITER_PROMPT_FILE

MODEL = "gpt-5.6-luna"
EFFORT = "low"


def _api_key() -> str:
    if os.environ.get("OPENAI_API_KEY"):
        return os.environ["OPENAI_API_KEY"]
    # Autostarted apps don't see the shell environment, so read the export the user keeps in ~/.zshrc.
    match = re.search(r'^export OPENAI_API_KEY="?([^"\n]+)"?$', (Path.home() / ".zshrc").read_text(), re.MULTILINE)
    if not match:
        raise RuntimeError("OPENAI_API_KEY not found in the environment or ~/.zshrc")
    return match.group(1)


def write(context: str, instruction: str) -> str:
    sections = [f"<context>\n{context}\n</context>" if context else "", f"<instruction>\n{instruction}\n</instruction>" if instruction else ""]
    body = {
        "model": MODEL,
        "reasoning_effort": EFFORT,
        "messages": [
            {"role": "system", "content": WRITER_PROMPT_FILE.read_text()},
            {"role": "user", "content": "\n\n".join(section for section in sections if section)},
        ],
    }
    request = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {_api_key()}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)["choices"][0]["message"]["content"].strip()
