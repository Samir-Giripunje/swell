import pytest

from swell import cleanup


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
        (
            "Um, so, can you like check why the build is failing? Uh, the results was good.",
            "low",
            "So, can you like check why the build is failing? The results was good.",
        ),
        ("We need, uhm, the umbrella and the hummus. Hmm. Erm, okay.", "low", "We need the umbrella and the hummus. Okay."),
        ("It fails at the uh test step. Um.", "low", "It fails at the test step."),
    ],
)
def test_off_low_and_short_text_skip_the_model(monkeypatch, text, level, expected):
    monkeypatch.setattr(cleanup, "_chat", lambda *args, **kwargs: pytest.fail("called the model"))
    assert cleanup.cleaned(text, None, level) == expected
