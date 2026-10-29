import json
from pathlib import Path

import pytest

PROTOCOL_DIR = Path(__file__).resolve().parents[3] / "packages" / "protocol"


@pytest.fixture(scope="session")
def protocol_schema() -> dict:
    return json.loads((PROTOCOL_DIR / "schema.json").read_text())


def protocol_fixture(name: str):
    return json.loads((PROTOCOL_DIR / "fixtures" / name).read_text())
