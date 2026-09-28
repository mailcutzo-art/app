"""Board ids, their Redis keys, weeks (IST) and the score encoding.

**Board ids** (what the API calls a board): ``weekly_xp``, ``weekly:{subject}``, both with a
``:last`` variant for last week, ``rating:overall``, ``rating:{subject}``, ``friends:weekly_xp``,
``friends:rating`` and ``hall_of_fame:{subject}``.

**Exam views.** Every stored board exists once per view: ``all`` (All India), ``neet`` and
``jee``. A player is written to ``all`` and to their own exam's view, so a filtered board is a
plain ZSET read (rank, count and pages stay O(log n)) at the cost of two writes. A view never
holds a subject its exam doesn't include (NEET has no Maths, JEE no Biology).

**Keys** (``{v}`` is the view, ``{week}`` the IST Monday that starts the week, ``2026-09-28``):

- ``lb:{v}:xp:{week}``: weekly XP. ``weekly_xp`` reads this week's key and ``weekly_xp:last``
  last week's, so the Monday rollover moves nothing: the week simply changes. Weekly keys expire
  ``WEEKLY_TTL`` after their week ends (kept a week for ``:last``, plus slack).
- ``lb:{v}:wk:{subject}:{week}``: battle points per subject and week.
- ``lb:{v}:r:{scope}``: ratings (``overall`` or a subject).
- ``{key}:snap``: the board as it stood at the start of the IST day, for ``change_1d``.
- ``{key}:tmp``: a nightly rebuild in progress, renamed over ``{key}`` when complete.

Friends boards are not stored: they are read from ``xp`` and ``r:overall`` with ``ZMSCORE``.

**Scores** put ties in the order players got there: ``value * 2^32 + (2^32 - 1 - t)``, where
``t`` is the Unix second at which the player reached the value. Earlier is higher; values up to
2^21 stay exact in a double.
"""

import math
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from enum import StrEnum

from app.core.clock import IST

VIEWS = ("all", "neet", "jee")
ALL = "all"
TIE = 2**32
WEEKLY_TTL = timedelta(days=9)
TOP = 100
PAGE = 50
AROUND = 10


class Family(StrEnum):
    WEEKLY_XP = "weekly_xp"
    WEEKLY_SUBJECT = "weekly"
    RATING = "rating"
    FRIENDS_WEEKLY = "friends:weekly_xp"
    FRIENDS_RATING = "friends:rating"
    HALL_OF_FAME = "hall_of_fame"


@dataclass(frozen=True, slots=True)
class Board:
    """A parsed board id."""

    family: Family
    subject: str | None = None  # the subject, or the rating scope (``overall`` too)
    last: bool = False  # last week's final standings

    @property
    def id(self) -> str:
        match self.family:
            case Family.WEEKLY_XP:
                base = "weekly_xp"
            case Family.WEEKLY_SUBJECT:
                base = f"weekly:{self.subject}"
            case Family.RATING:
                base = f"rating:{self.subject}"
            case Family.HALL_OF_FAME:
                base = f"hall_of_fame:{self.subject}"
            case _:
                base = self.family.value
        return f"{base}:last" if self.last else base

    @property
    def weekly(self) -> bool:
        return self.family in {Family.WEEKLY_XP, Family.WEEKLY_SUBJECT, Family.FRIENDS_WEEKLY}

    @property
    def rated(self) -> bool:
        return self.family in {Family.RATING, Family.FRIENDS_RATING}

    @property
    def subject_slug(self) -> str | None:
        """The subject the board is about (``None`` for overall, XP and friends boards)."""
        if self.family in {Family.WEEKLY_SUBJECT, Family.HALL_OF_FAME}:
            return self.subject
        if self.family == Family.RATING and self.subject != "overall":
            return self.subject
        return None


def parse_board(board_id: str) -> Board | None:
    """The board an id names, or ``None`` if it isn't one (subjects are checked by the caller)."""
    parts = board_id.split(":")
    last = parts[-1] == "last" and len(parts) > 1
    if last:
        parts = parts[:-1]
    match parts:
        case ["weekly_xp"]:
            return Board(Family.WEEKLY_XP, last=last)
        case ["weekly", subject] if subject:
            return Board(Family.WEEKLY_SUBJECT, subject, last=last)
        case ["rating", scope] if scope and not last:
            return Board(Family.RATING, scope)
        case ["friends", "weekly_xp"] if not last:
            return Board(Family.FRIENDS_WEEKLY)
        case ["friends", "rating"] if not last:
            return Board(Family.FRIENDS_RATING)
        case ["hall_of_fame", subject] if subject and not last:
            return Board(Family.HALL_OF_FAME, subject)
    return None


# --- Weeks (IST, Monday 00:00 to Monday 00:00) ------------------------------------------------


def week_of(moment: datetime | date) -> date:
    """The IST Monday starting the week of ``moment`` (a date is taken as an IST day)."""
    day = moment.astimezone(IST).date() if isinstance(moment, datetime) else moment
    return day - timedelta(days=day.weekday())


def week_start(week: date) -> datetime:
    return datetime.combine(week, time(), tzinfo=IST)


def week_end(week: date) -> datetime:
    """When the week's board resets (UTC)."""
    return week_start(week + timedelta(days=7)).astimezone(UTC)


def week_label(week: date) -> str:
    """``2026-W40``: the ISO week of the IST Monday."""
    year, number, _ = week.isocalendar()
    return f"{year}-W{number:02d}"


def week_number(week: date) -> int:
    return week.isocalendar()[1]


# --- Keys -------------------------------------------------------------------------------------


def views_for(goal: str | None) -> tuple[str, ...]:
    """The views a player with ``goal`` is written to."""
    return (ALL, goal) if goal in VIEWS and goal != ALL else (ALL,)


def xp_key(view: str, week: date) -> str:
    return f"lb:{view}:xp:{week.isoformat()}"


def subject_key(view: str, subject: str, week: date) -> str:
    return f"lb:{view}:wk:{subject}:{week.isoformat()}"


def rating_key(view: str, scope: str) -> str:
    return f"lb:{view}:r:{scope}"


def snap_key(key: str) -> str:
    return f"{key}:snap"


def tmp_key(key: str) -> str:
    return f"{key}:tmp"


def board_key(board: Board, view: str, now: datetime) -> str | None:
    """The stored ZSET behind ``board`` (friends boards read their base board's key)."""
    week = week_of(now) - timedelta(days=7 if board.last else 0)
    match board.family:
        case Family.WEEKLY_XP | Family.FRIENDS_WEEKLY:
            return xp_key(view, week)
        case Family.WEEKLY_SUBJECT if board.subject is not None:
            return subject_key(view, board.subject, week)
        case Family.RATING if board.subject is not None:
            return rating_key(view, board.subject)
        case Family.FRIENDS_RATING:
            return rating_key(view, "overall")
    return None


def weekly_expiry(week: date) -> int:
    """Unix seconds at which a weekly key of ``week`` may go."""
    return int((week_end(week) + WEEKLY_TTL).timestamp())


# --- Scores -----------------------------------------------------------------------------------


def encode(value: int, reached_at: datetime) -> float:
    """The ZSET score of ``value`` reached at ``reached_at`` (earlier wins a tie)."""
    seconds = min(TIE - 1, max(0, int(reached_at.timestamp())))
    return float(value * TIE + (TIE - 1 - seconds))


def decode(score: float) -> int:
    """The value a score stands for."""
    return math.floor(score / TIE)
