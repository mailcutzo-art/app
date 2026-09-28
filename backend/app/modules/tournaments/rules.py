"""Pure tournament rules: the schedule around the start, rounds for a field, Arena filters and
the recurring templates' RRULE (a small RFC 5545 subset evaluated in IST).
"""

import math
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta

from app.core.clock import IST
from app.modules.tournaments.models import TournamentStatus

S = TournamentStatus

CHECK_IN_OPENS = timedelta(minutes=15)  # T - 15 min
REGISTRATION_CLOSES = timedelta(minutes=5)  # T - 5 min: LOCKED
CHECK_IN_CLOSES = timedelta(minutes=2)  # T - 2 min
AT_RISK_AT = timedelta(minutes=30)  # T - 30 min
NO_SHOW_WINDOW = timedelta(days=30)
NO_SHOW_LIMIT = 3
NO_SHOW_BLOCK = timedelta(days=7)
MIN_PLAYERS_FLOOR = 4
SHARED_SUBJECTS = frozenset({"physics", "chemistry"})

FILTERS: dict[str, tuple[TournamentStatus, ...]] = {
    "open": (S.REG_OPEN, S.CHECK_IN),
    "upcoming": (S.SCHEDULED, S.LOCKED),
    "live": (S.RUNNING, S.FINALIZING),
    "finished": (S.FINISHED, S.CANCELLED),
}
# Registered (not withdrawn) players in these states can't start something that would still
# run at T - 2 min; checked-in players of a running tournament can't start anything.
BUSY_STATES = frozenset({S.REG_OPEN, S.CHECK_IN, S.LOCKED, S.RUNNING, S.FINALIZING})


def rounds_for(configured: int, players: int) -> int:
    """min(configured, players - 1, ceil(log2 players) + 2): no forced rematches in small
    fields."""
    if players < 2:
        return 0
    return max(1, min(configured, players - 1, math.ceil(math.log2(players)) + 2))


def min_players(value: int) -> int:
    return max(MIN_PLAYERS_FLOOR, value)


def goal_allowed(goal: str, subject: str | None) -> bool:
    """``any`` only for the subjects both exams share (never "All")."""
    return goal != "any" or (subject is not None and subject in SHARED_SUBJECTS)


def exam_allows(goal: str, player_goal: str) -> bool:
    return goal == "any" or goal == player_goal


def checkin_opens_at(starts_at: datetime) -> datetime:
    return starts_at - CHECK_IN_OPENS


def checkin_closes_at(starts_at: datetime) -> datetime:
    return starts_at - CHECK_IN_CLOSES


def locks_at(starts_at: datetime) -> datetime:
    return starts_at - REGISTRATION_CLOSES


def at_risk_at(starts_at: datetime) -> datetime:
    return starts_at - AT_RISK_AT


def ends_at_estimate(starts_at: datetime, rounds: int, round_s: int, pause_s: int) -> datetime:
    """The latest the last round can end: each round's deadline plus the pause before the
    next pairing."""
    return starts_at + timedelta(seconds=rounds * round_s + max(0, rounds - 1) * pause_s)


def no_show_blocked(no_show_starts: list[datetime], now: datetime) -> datetime | None:
    """Until when paid registration is blocked: 3 no-shows within 30 days block it for 7 days
    after the third. ``no_show_starts`` are the start times of the player's no-shows."""
    recent = sorted(t for t in no_show_starts if t <= now)
    for i in range(NO_SHOW_LIMIT - 1, len(recent)):
        third = recent[i]
        if third - recent[i - NO_SHOW_LIMIT + 1] <= NO_SHOW_WINDOW and now < third + NO_SHOW_BLOCK:
            return third + NO_SHOW_BLOCK
    return None


# --- RRULE ---------------------------------------------------------------------------------

_DAYS = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}


class RRuleError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class RRule:
    """FREQ=DAILY|WEEKLY with INTERVAL, BYDAY, BYHOUR, BYMINUTE, UNTIL (YYYYMMDD) and a
    DTSTART date (YYYYMMDD, default 2026-01-01) anchoring the interval. Times are IST."""

    freq: str
    interval: int
    days: tuple[int, ...]
    hours: tuple[int, ...]
    minutes: tuple[int, ...]
    start: date
    until: date | None

    def occurrences(self, after: datetime, before: datetime) -> Iterator[datetime]:
        """Occurrences in ``[after, before)`` as aware UTC-comparable datetimes (IST)."""
        day = max(self.start, after.astimezone(IST).date())
        last = before.astimezone(IST).date()
        while day <= last:
            if self.until is not None and day > self.until:
                return
            if self._matches(day):
                for hour in self.hours:
                    for minute in self.minutes:
                        moment = datetime.combine(day, time(hour, minute), tzinfo=IST)
                        if after <= moment < before:
                            yield moment
            day += timedelta(days=1)

    def _matches(self, day: date) -> bool:
        offset = (day - self.start).days
        if self.freq == "DAILY":
            return offset % self.interval == 0 and (not self.days or day.weekday() in self.days)
        weeks = (offset + self.start.weekday()) // 7
        days = self.days or (self.start.weekday(),)
        return weeks % self.interval == 0 and day.weekday() in days


def parse_rrule(value: str) -> RRule:
    parts: dict[str, str] = {}
    for item in value.strip().removeprefix("RRULE:").split(";"):
        if not item:
            continue
        name, sep, raw = item.partition("=")
        if not sep:
            raise RRuleError(f"bad RRULE part {item!r}")
        parts[name.strip().upper()] = raw.strip().upper()
    freq = parts.pop("FREQ", "")
    if freq not in {"DAILY", "WEEKLY"}:
        raise RRuleError("FREQ must be DAILY or WEEKLY")
    try:
        interval = int(parts.pop("INTERVAL", "1"))
        days = tuple(sorted(_DAYS[d] for d in parts.pop("BYDAY", "").split(",") if d))
        hours = tuple(sorted(int(h) for h in parts.pop("BYHOUR", "19").split(",")))
        minutes = tuple(sorted(int(m) for m in parts.pop("BYMINUTE", "0").split(",")))
        start = _date(parts.pop("DTSTART", "20260101"))
        until_raw = parts.pop("UNTIL", "")
        until = _date(until_raw) if until_raw else None
    except (KeyError, ValueError) as exc:
        raise RRuleError(f"bad RRULE value: {exc}") from exc
    if parts:
        raise RRuleError(f"unsupported RRULE parts: {', '.join(sorted(parts))}")
    if interval < 1 or not all(0 <= h < 24 for h in hours) or not all(0 <= m < 60 for m in minutes):
        raise RRuleError("INTERVAL, BYHOUR or BYMINUTE out of range")
    return RRule(freq, interval, days, hours, minutes, start, until)


def _date(raw: str) -> date:
    return datetime.strptime(raw[:8], "%Y%m%d").date()
