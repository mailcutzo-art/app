"""Pure tournament rules: rounds for a field, the exam rule, the no-show block and the RRULE."""

from datetime import UTC, datetime, timedelta

import pytest

from app.core.clock import IST
from app.modules.tournaments import rules


@pytest.mark.parametrize(
    ("configured", "players", "expected"),
    [(5, 4, 3), (5, 5, 4), (6, 8, 5), (6, 64, 6), (3, 256, 3), (6, 2, 1), (5, 1, 0)],
)
def test_rounds_never_exceed_the_field(configured: int, players: int, expected: int) -> None:
    assert rules.rounds_for(configured, players) == expected


def test_any_exam_only_for_shared_subjects() -> None:
    assert rules.goal_allowed("any", "physics")
    assert rules.goal_allowed("any", "chemistry")
    assert not rules.goal_allowed("any", "biology")
    assert not rules.goal_allowed("any", None)
    assert rules.goal_allowed("neet", None)
    assert rules.exam_allows("any", "jee")
    assert not rules.exam_allows("neet", "jee")


def test_three_no_shows_in_30_days_block_for_7_days() -> None:
    now = datetime(2026, 9, 28, tzinfo=UTC)
    days = [now - timedelta(days=d) for d in (25, 12, 3)]
    assert rules.no_show_blocked(days, now) == days[-1] + timedelta(days=7)
    assert rules.no_show_blocked(days, now + timedelta(days=5)) is None
    spread = [now - timedelta(days=d) for d in (40, 12, 3)]
    assert rules.no_show_blocked(spread, now) is None
    assert rules.no_show_blocked(days[:2], now) is None


def test_rrule_daily_and_weekly_in_ist() -> None:
    start = datetime(2026, 9, 28, 0, 0, tzinfo=IST)  # a Monday
    end = start + timedelta(days=7)
    daily = list(rules.parse_rrule("FREQ=DAILY;BYHOUR=19;BYMINUTE=30").occurrences(start, end))
    assert len(daily) == 7
    assert all((d.hour, d.minute) == (19, 30) for d in daily)
    weekly = rules.parse_rrule("FREQ=WEEKLY;BYDAY=SA,SU;BYHOUR=18")
    found = list(weekly.occurrences(start, end))
    assert [d.weekday() for d in found] == [5, 6]
    fortnightly = rules.parse_rrule("FREQ=WEEKLY;INTERVAL=2;BYDAY=SU;DTSTART=20260928")
    assert len(list(fortnightly.occurrences(start, start + timedelta(days=28)))) == 2
    with pytest.raises(rules.RRuleError):
        rules.parse_rrule("FREQ=MONTHLY")
    with pytest.raises(rules.RRuleError):
        rules.parse_rrule("FREQ=DAILY;BYSECOND=5")
