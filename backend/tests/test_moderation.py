"""Name moderation: profanity (English, Hinglish, Devanagari) and reserved names."""

import pytest

from app.modules.moderation.names import impersonates_staff, is_reserved_handle
from app.modules.moderation.profanity import contains_profanity, is_profane_handle, normalize


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("\uff26\uff35\uff23\uff2b", "fuck"),  # full-width forms
        ("Crème Brûlée", "creme brulee"),
        ("f\u200bu\u200dck", "fuck"),  # zero-width characters
        ("fu\u0441k", "fuck"),  # Cyrillic es
        ("भोसड़ी", "भोसडी"),  # nukta dropped
    ],
)
def test_normalize(text: str, expected: str) -> None:
    assert normalize(text) == expected


@pytest.mark.parametrize(
    "name",
    [
        "Scunthorpe United",
        "Sussex",
        "Essex Warriors",
        "assassin",
        "Cocktail Queen",
        "Shitij",
        "Kshitij Rao",
        "Dickens Fan",
        "Class Topper",
        "Hancock",
        "Peacock",
        "Arsenal",
        "Cummins",
        "Galaxy A55",
        "Rahul2008",
        "Anal Mehta",
        "Suporna",
        "MC Stan",
        "Hello!",
        "Jean-Luc",
        "राहुल शर्मा",
        "Priya 🌸",
    ],
)
def test_ordinary_names_are_not_flagged(name: str) -> None:
    assert not contains_profanity(name)


@pytest.mark.parametrize(
    "name",
    [
        "fuck",
        "Fuck You",
        "sh1t",
        "a$$hole",
        "B1tch Please",
        "b!tch",
        "5hit",
        "f.u.c.k",
        "f*ck off",
        "sh-it",
        "f u c k",
        "fuuuuuck",
        "fück",
        "\uff26\uff35\uff23\uff2b",  # full-width
        "fu\u200bck",
        "fu\u0441k",  # Cyrillic es
        "phuck",
        "chutiya",
        "ch00tiya",
        "Madarchod",
        "bsdk",
        "चूतिया",
        "भोसड़ीके",
        "Rahul Chutiya Singh",
    ],
)
def test_profane_names_are_flagged(name: str) -> None:
    assert contains_profanity(name)


@pytest.mark.parametrize(
    "handle",
    [
        "scunthorpe_fc",
        "sussex_fan",
        "assassin_99",
        "cocktail_king",
        "shitij_2008",
        "kshitij",
        "classy_topper",
        "galaxy_a55",
        "a55",
        "rahul_2008",
        "neet_2025",
        "suporna",
        "therapist",
        "grape_juice",
        "hancock",
        "bassist",
    ],
)
def test_ordinary_handles_are_not_flagged(handle: str) -> None:
    assert not is_profane_handle(handle)


@pytest.mark.parametrize(
    "handle",
    [
        "fuck",
        "fuck_you",
        "sh1t_head",
        "b1tch99",
        "5hit_lord",
        "f_u_c_k",
        "fuuuck",
        "iamfucked",
        "xx_chutiya_xx",
        "mr_madarchod",
        "nigga420",
        "b00bs",
        "5ex_god",
        "bsdk",
    ],
)
def test_profane_handles_are_flagged(handle: str) -> None:
    assert is_profane_handle(handle)


@pytest.mark.parametrize(
    ("handle", "reserved"),
    [
        ("admin", True),
        ("support", True),
        ("quizarena", True),
        ("official_raj", True),
        ("raj_admin_1", True),
        ("mod_squad", True),
        ("i_support_csk", False),
        ("modi_fan", False),
        ("quiz_master", False),
        ("team_rocket", False),
        ("admiral", False),
    ],
)
def test_reserved_handles(handle: str, reserved: bool) -> None:
    assert is_reserved_handle(handle) is reserved


@pytest.mark.parametrize(
    ("name", "flagged"),
    [
        ("Quiz Admin", True),
        ("Official Rahul", True),
        ("STAFF", True),
        ("Admiral Kumar", False),
        ("Modi Fan", False),
        ("Stafford", False),
    ],
)
def test_staff_impersonation(name: str, flagged: bool) -> None:
    assert impersonates_staff(name) is flagged
