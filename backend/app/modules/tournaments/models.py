"""Scheduled Swiss tournaments: templates, instances, entries, rounds, pairings and prizes
(``docs/plan.md``, Phase 5).

A tournament moves through its lifecycle one worker step at a time; ``next_action_at`` says
when it next needs one (``lifecycle.py``). Match ids are generated with the pairing, so every
step can run again safely after a crash.
"""

import uuid
from datetime import datetime
from enum import StrEnum

from sqlalchemy import (
    CheckConstraint,
    ForeignKey,
    Index,
    Integer,
    SmallInteger,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk, one_of


class TournamentStatus(StrEnum):
    SCHEDULED = "scheduled"
    REG_OPEN = "reg_open"
    CHECK_IN = "check_in"
    LOCKED = "locked"
    RUNNING = "running"
    FINALIZING = "finalizing"
    FINISHED = "finished"
    CANCELLED = "cancelled"


class Goal(StrEnum):
    NEET = "neet"
    JEE = "jee"
    ANY = "any"


class RoundStatus(StrEnum):
    STARTING = "starting"  # paired and match rows written; the live games are being created
    LIVE = "live"
    CLOSING = "closing"  # past the deadline: unfinished games were ended and are settling
    DONE = "done"


class PairingStatus(StrEnum):
    PENDING = "pending"
    DONE = "done"


ENTRY_FEES = (0, 10, 15, 25, 50)
TERMINAL = frozenset({TournamentStatus.FINISHED, TournamentStatus.CANCELLED})
# Results a pairing records per player (``standings.GameResult`` values).
PAIRING_RESULTS = (
    "win",
    "draw",
    "loss",
    "forfeit_win",
    "forfeit_loss",
    "double_forfeit",
    "bye",
)


class TournamentTemplate(Base):
    """A recurring tournament: an RRULE in IST that the worker expands 7 days ahead."""

    __tablename__ = "tournament_templates"
    __table_args__ = (
        CheckConstraint(one_of("goal", [goal.value for goal in Goal]), name="goal"),
        CheckConstraint("rounds BETWEEN 3 AND 6", name="rounds"),
        CheckConstraint("entry_fee IN (0, 10, 15, 25, 50)", name="entry_fee"),
        CheckConstraint("prize_pool >= 0", name="prize_pool"),
        CheckConstraint("capacity BETWEEN 4 AND 256", name="capacity"),
        CheckConstraint("min_players BETWEEN 4 AND capacity", name="min_players"),
        CheckConstraint("reg_opens_before_min > 15", name="reg_opens_before"),
    )

    id: Mapped[UUIDv7Pk]
    title: Mapped[str]
    description: Mapped[str] = mapped_column(server_default="")
    subject_id: Mapped[int | None] = mapped_column(SmallInteger, ForeignKey("subjects.id"))
    goal: Mapped[str]
    rounds: Mapped[int] = mapped_column(SmallInteger, server_default=text("5"))
    entry_fee: Mapped[int] = mapped_column(server_default=text("0"))
    prize_pool: Mapped[int] = mapped_column(server_default=text("0"))
    capacity: Mapped[int] = mapped_column(SmallInteger, server_default=text("64"))
    min_players: Mapped[int] = mapped_column(SmallInteger, server_default=text("8"))
    # RFC 5545 subset in IST wall-clock time, e.g. "FREQ=DAILY;BYHOUR=19;BYMINUTE=0".
    rrule: Mapped[str]
    reg_opens_before_min: Mapped[int] = mapped_column(Integer, server_default=text("1440"))
    active: Mapped[bool] = mapped_column(server_default=text("true"))
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())

    def __str__(self) -> str:
        return self.title


class Tournament(Base):
    __tablename__ = "tournaments"
    __table_args__ = (
        CheckConstraint(
            one_of("status", [status.value for status in TournamentStatus]), name="status"
        ),
        CheckConstraint(one_of("goal", [goal.value for goal in Goal]), name="goal"),
        CheckConstraint("rounds BETWEEN 3 AND 6", name="rounds"),
        CheckConstraint("entry_fee IN (0, 10, 15, 25, 50)", name="entry_fee"),
        CheckConstraint("prize_pool >= 0", name="prize_pool"),
        CheckConstraint("capacity BETWEEN 4 AND 256", name="capacity"),
        CheckConstraint("min_players BETWEEN 4 AND capacity", name="min_players"),
        CheckConstraint("reg_opens_at < starts_at", name="schedule"),
        UniqueConstraint("template_id", "starts_at"),
        # The worker's scan: due tournaments that still have something to do.
        Index(
            "ix_tournaments_due",
            "next_action_at",
            postgresql_where=text("next_action_at IS NOT NULL"),
        ),
        Index("ix_tournaments_status_starts", "status", "starts_at"),
    )

    id: Mapped[UUIDv7Pk]
    template_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("tournament_templates.id", ondelete="SET NULL")
    )
    title: Mapped[str]
    description: Mapped[str] = mapped_column(server_default="")
    subject_id: Mapped[int | None] = mapped_column(SmallInteger, ForeignKey("subjects.id"))
    goal: Mapped[str]
    rounds: Mapped[int] = mapped_column(SmallInteger, server_default=text("5"))  # configured
    entry_fee: Mapped[int] = mapped_column(server_default=text("0"))
    prize_pool: Mapped[int] = mapped_column(server_default=text("0"))
    capacity: Mapped[int] = mapped_column(SmallInteger, server_default=text("64"))
    min_players: Mapped[int] = mapped_column(SmallInteger, server_default=text("8"))
    reg_opens_at: Mapped[datetime]
    starts_at: Mapped[datetime]
    status: Mapped[str] = mapped_column(server_default=TournamentStatus.SCHEDULED.value)
    # Rounds actually played: min(rounds, players - 1, ceil(log2 players) + 2), set at the start.
    rounds_planned: Mapped[int | None] = mapped_column(SmallInteger)
    current_round: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    players: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))  # registered
    # When the worker next has something to do; NULL once finished or cancelled.
    next_action_at: Mapped[datetime | None]
    at_risk_sent: Mapped[bool] = mapped_column(server_default=text("false"))
    cancel_reason: Mapped[str | None]
    started_at: Mapped[datetime | None]
    finished_at: Mapped[datetime | None]
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())

    def __str__(self) -> str:
        return self.title


class TournamentEntry(Base):
    """A registration. After the start, the checked-in players are the field; withdrawn ones
    stay in the standings (for tie-breaks) but win no prize."""

    __tablename__ = "tournament_entries"
    __table_args__ = (
        Index("ix_tournament_entries_user", "user_id", "tournament_id"),
        CheckConstraint("byes >= 0 AND absences >= 0", name="counts"),
    )

    tournament_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("tournaments.id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    registered_at: Mapped[datetime] = mapped_column(server_default=func.now())
    hold_id: Mapped[uuid.UUID | None]  # the held entry fee
    seed: Mapped[int | None] = mapped_column(SmallInteger)
    checked_in: Mapped[bool] = mapped_column(server_default=text("false"))
    checked_in_at: Mapped[datetime | None]
    withdrawn: Mapped[bool] = mapped_column(server_default=text("false"))
    withdrawn_at: Mapped[datetime | None]
    # withdrew, cant_make_it, absent (two missed rounds), banned, deleted, no_show
    withdraw_reason: Mapped[str | None]
    # Registered but never checked in (counts toward the paid-registration block).
    no_show: Mapped[bool] = mapped_column(server_default=text("false"))
    points: Mapped[float] = mapped_column(server_default=text("0"))
    bh: Mapped[float] = mapped_column(server_default=text("0"))
    bh_c1: Mapped[float] = mapped_column(server_default=text("0"))
    sb: Mapped[float] = mapped_column(server_default=text("0"))
    quiz_points: Mapped[int] = mapped_column(server_default=text("0"))
    correct_count: Mapped[int] = mapped_column(server_default=text("0"))
    correct_time_ms: Mapped[int] = mapped_column(server_default=text("0"))
    wins: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    draws: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    losses: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    byes: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    # Rounds missed in a row; two withdraw the player.
    absences: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    rank: Mapped[int | None] = mapped_column(SmallInteger)  # live position
    final_rank: Mapped[int | None] = mapped_column(SmallInteger)


class TournamentRound(Base):
    __tablename__ = "tournament_rounds"
    __table_args__ = (
        CheckConstraint(one_of("status", [status.value for status in RoundStatus]), name="status"),
    )

    tournament_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("tournaments.id", ondelete="CASCADE"), primary_key=True
    )
    number: Mapped[int] = mapped_column(SmallInteger, primary_key=True)
    subject_id: Mapped[int] = mapped_column(SmallInteger, ForeignKey("subjects.id"))
    status: Mapped[str] = mapped_column(server_default=RoundStatus.STARTING.value)
    # Rules the pairing had to break (swiss_pairing.Relaxation values).
    relaxations: Mapped[list[str]] = mapped_column(JSONB, server_default=text("'[]'"))
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    started_at: Mapped[datetime | None]
    deadline_at: Mapped[datetime | None]
    finished_at: Mapped[datetime | None]


class TournamentPairing(Base):
    """One board of a round: ``a`` against ``b``, or ``a``'s bye (no ``b``, no match)."""

    __tablename__ = "tournament_pairings"
    __table_args__ = (
        UniqueConstraint("tournament_id", "round", "a_id"),
        UniqueConstraint("tournament_id", "round", "b_id"),
        UniqueConstraint("match_id"),
        CheckConstraint("a_id <> b_id", name="distinct"),
        CheckConstraint("(b_id IS NULL) = (match_id IS NULL)", name="bye"),
        CheckConstraint(
            one_of("status", [status.value for status in PairingStatus]), name="status"
        ),
        CheckConstraint(one_of("result_a", PAIRING_RESULTS), name="result_a"),
        CheckConstraint(one_of("result_b", PAIRING_RESULTS), name="result_b"),
        Index("ix_tournament_pairings_b", "tournament_id", "b_id"),
    )

    id: Mapped[UUIDv7Pk]
    tournament_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("tournaments.id", ondelete="CASCADE")
    )
    round: Mapped[int] = mapped_column(SmallInteger)
    board: Mapped[int] = mapped_column(SmallInteger)
    a_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    b_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    match_id: Mapped[uuid.UUID | None]  # pre-generated with the pairing
    status: Mapped[str] = mapped_column(server_default=PairingStatus.PENDING.value)
    result_a: Mapped[str | None]
    result_b: Mapped[str | None]
    score_a: Mapped[int] = mapped_column(server_default=text("0"))
    score_b: Mapped[int] = mapped_column(server_default=text("0"))
    finished_at: Mapped[datetime | None]


class TournamentPrize(Base):
    __tablename__ = "tournament_prizes"
    __table_args__ = (
        CheckConstraint("amount > 0", name="amount"),
        UniqueConstraint("tournament_id", "place"),
    )

    tournament_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("tournaments.id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    place: Mapped[int] = mapped_column(SmallInteger)
    amount: Mapped[int]
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
