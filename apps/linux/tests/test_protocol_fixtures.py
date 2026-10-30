import jsonschema
import pytest

from conftest import protocol_fixture


@pytest.mark.parametrize(
    ("fixture", "definition"),
    [("health.json", "Health"), ("transcription.json", "Transcription"), ("error.json", "Error"), ("rephrase-request.json", "RephraseRequest")],
)
def test_fixtures_match_the_schema(protocol_schema, fixture, definition):
    jsonschema.validate(protocol_fixture(fixture), {**protocol_schema, "$ref": f"#/$defs/{definition}"})
