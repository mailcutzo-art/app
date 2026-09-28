"""Coins: wallets, the append-only ledger and holds (docs/plan.md, "Coin ledger")."""

import uuid
from datetime import datetime
from enum import StrEnum

from sqlalchemy import BigInteger, CheckConstraint, ForeignKey, Index, func, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, UUIDv7Pk, one_of


class Bucket(StrEnum):
    EARNED = "earned"
    # Reserved for coins bought with money: tracked separately and never spendable in v1.
    PURCHASED = "purchased"


class CoinReason(StrEnum):
    WELCOME = "welcome"
    MATCH_ENTRY = "match_entry"  # casual battle or room fee (a hold)
    MATCH_POT = "match_pot"  # a casual battle won (or split on a draw)
    MATCH_REWARD = "match_reward"  # rated win, draw or loss
    TOURNAMENT_ENTRY = "tournament_entry"
    TOURNAMENT_PRIZE = "tournament_prize"
    REFUND = "refund"
    MISSION_BONUS = "mission_bonus"
    LEVEL_UP = "level_up"
    STREAK_BONUS = "streak_bonus"
    ACHIEVEMENT = "achievement"
    STREAK_FREEZE = "streak_freeze"
    HINT = "hint"
    TRANSFER = "transfer"
    ADJUSTMENT = "adjustment"  # a correction by staff


class RefKind(StrEnum):
    """What a ledger entry links to in the Wallet (docs/api-play.md, "Wallet and XP")."""

    MATCH = "match"
    TOURNAMENT = "tournament"
    MISSION = "mission"
    STREAK = "streak"
    ACHIEVEMENT = "achievement"
    HINT = "hint"
    WELCOME = "welcome"
    LEVEL = "level"
    ROOM = "room"


class HoldStatus(StrEnum):
    HELD = "held"
    CAPTURED = "captured"  # the coins were spent
    RELEASED = "released"  # the coins went back (a refund entry)


class Wallet(Base):
    __tablename__ = "wallets"
    __table_args__ = (
        CheckConstraint("balance >= 0", name="balance"),
        CheckConstraint("held >= 0", name="held"),
        CheckConstraint("purchased >= 0", name="purchased"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    # Spendable (earned) coins. Holds are already taken out of it.
    balance: Mapped[int] = mapped_column(BigInteger, server_default=text("0"))
    # Coins in open holds (a casual entry, a tournament fee), shown as "held" in the Wallet.
    held: Mapped[int] = mapped_column(BigInteger, server_default=text("0"))
    purchased: Mapped[int] = mapped_column(BigInteger, server_default=text("0"))
    # When Home showed the welcome bonus; it is shown once (``pop_welcome``).
    welcome_seen_at: Mapped[datetime | None]
    updated_at: Mapped[datetime] = mapped_column(server_default=func.now(), onupdate=func.now())


class LedgerEntry(Base):
    """One posting. Append-only (a trigger rejects UPDATE, DELETE and TRUNCATE).

    ``user_id`` deliberately has no foreign key: ledger rows outlive an erased account (kept
    under its tombstone id), and cascades must never reach this table.
    """

    __tablename__ = "coin_ledger"
    __table_args__ = (
        CheckConstraint("delta <> 0", name="delta"),
        CheckConstraint("balance_after >= 0", name="balance_after"),
        CheckConstraint(one_of("reason", [reason.value for reason in CoinReason]), name="reason"),
        CheckConstraint(one_of("ref_kind", [kind.value for kind in RefKind]), name="ref_kind"),
        CheckConstraint(one_of("bucket", [bucket.value for bucket in Bucket]), name="bucket"),
        CheckConstraint("(ref_kind IS NULL) = (ref_id IS NULL)", name="ref"),
        Index("ix_coin_ledger_user_created", "user_id", "created_at", "id"),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID]
    delta: Mapped[int] = mapped_column(BigInteger)
    balance_after: Mapped[int] = mapped_column(BigInteger)
    reason: Mapped[str]
    title: Mapped[str]
    ref_kind: Mapped[str | None]
    ref_id: Mapped[str | None]
    bucket: Mapped[str] = mapped_column(server_default=Bucket.EARNED.value)
    idempotency_key: Mapped[str] = mapped_column(unique=True)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())


class CoinHold(Base):
    """Coins set aside for something that may still be refunded (an entry fee).

    Placing a hold posts the ``-amount`` entry at once; capturing it only closes the hold, and
    releasing it posts the refund.
    """

    __tablename__ = "coin_holds"
    __table_args__ = (
        CheckConstraint("amount > 0", name="amount"),
        CheckConstraint(one_of("status", [status.value for status in HoldStatus]), name="status"),
        CheckConstraint(one_of("ref_kind", [kind.value for kind in RefKind]), name="ref_kind"),
        CheckConstraint(one_of("reason", [reason.value for reason in CoinReason]), name="reason"),
        CheckConstraint("(status = 'held') = (settled_at IS NULL)", name="settled"),
        # The reaper's scan: open holds, oldest first.
        Index("ix_coin_holds_open", "created_at", postgresql_where=text("status = 'held'")),
        Index("ix_coin_holds_ref", "ref_kind", "ref_id"),
    )

    id: Mapped[UUIDv7Pk]
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    amount: Mapped[int] = mapped_column(BigInteger)
    reason: Mapped[str]
    ref_kind: Mapped[str]
    ref_id: Mapped[str]
    status: Mapped[str] = mapped_column(server_default=HoldStatus.HELD.value)
    # The idempotency key of the posting that placed the hold; placing it again is a no-op.
    key: Mapped[str] = mapped_column(unique=True)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    settled_at: Mapped[datetime | None]
