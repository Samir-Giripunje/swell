import pytest

from conftest import protocol_fixture
from swell import cleanup


def test_shared_fixture_matches_the_prompts():
    # The Mac rephrases on-device from this fixture; regenerate it with `python -m swell.cleanup` after editing a prompt.
    assert protocol_fixture("rephrasing.json") == cleanup.exported()


@pytest.mark.parametrize(
    ("level", "result", "accepted"),
    [
        ("medium", "Can you check why the build fails?", True),
        ("high", "Please check the build.", True),
        (
            "high",
            "Sure! Here is a polished version of your message. I can also help you investigate why the build keeps failing on the staging environment if you share the logs.",
            False,
        ),
        ("medium", "", False),
    ],
)
def test_rejects_results_that_stray_from_the_transcript(level, result, accepted):
    original = "um so can you check why the the build is failing on stage"
    assert cleanup.accepted(original, result, level) is accepted


@pytest.mark.parametrize("level", ["medium", "high"])
def test_each_level_has_its_own_instructions_and_examples(level):
    conversation = cleanup.messages("raw text here please", "Needl, Kubernetes", level)
    assert cleanup.PROMPTS[level].instructions in conversation[0]["content"]
    assert "Spell these terms exactly: Needl, Kubernetes" in conversation[0]["content"]
    assert len(conversation) == 2 + 2 * len(cleanup.PROMPTS[level].examples)
    assert conversation[-1] == {"role": "user", "content": "<transcript>raw text here please</transcript>"}


@pytest.mark.parametrize(
    ("text", "level", "expected"),
    [
        ("um yes the build passed", "off", "um yes the build passed"),
        ("Um yes", "high", "Um yes"),
        *[(text, "low", expected) for text, expected in cleanup.exported()["low_cases"]],
    ],
)
def test_off_low_and_short_text_skip_the_model(monkeypatch, text, level, expected):
    monkeypatch.setattr(cleanup, "_chat", lambda *args, **kwargs: pytest.fail("called the model"))
    assert cleanup.cleaned(text, None, level) == expected


@pytest.mark.parametrize(
    ("reply", "error"),
    [
        ("I received the report yesterday, will check it tomorrow.", None),
        (OSError("connection refused"), "didn't answer"),
        ("Sure! I can help you with that report. Here is a corrected version of what you wrote for your team today.", "strayed"),
        ("", "strayed"),
    ],
)
def test_corrected_reports_failures(monkeypatch, reply, error):
    def chat(*args, **kwargs):
        if isinstance(reply, Exception):
            raise reply
        return reply

    monkeypatch.setattr(cleanup, "_chat", chat)
    text = "i recieved the reprot yesterday , will check it tommorow"
    if error is None:
        assert cleanup.corrected(text, None, "low") == reply
    else:
        with pytest.raises(cleanup.CorrectionError, match=error):
            cleanup.corrected(text, None, "low")
