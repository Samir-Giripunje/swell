from urllib.parse import parse_qs, urlsplit

import pytest

from conftest import protocol_fixture
from swell.pairing import pairing_link

VALID = protocol_fixture("pairing-links.json")["valid"]


def test_link_matches_the_canonical_encoding():
    case = VALID[0]
    assert pairing_link(case["name"], case["url"], case["token"]) == case["link"]


@pytest.mark.parametrize("case", VALID, ids=lambda case: case["name"])
def test_link_round_trips(case):
    link = urlsplit(pairing_link(case["name"], case["url"], case["token"]))
    assert (link.scheme, link.netloc) == ("swell", "pair")
    assert {key: values[0] for key, values in parse_qs(link.query).items()} == {"name": case["name"], "url": case["url"], "token": case["token"]}
