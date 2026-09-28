"""What the realtime engine needs from features built elsewhere, as small pluggable interfaces.

- ``EscrowPort``: the casual 5-coin entry (hold at ``mm.join``, capture or release at
  settlement, the winner's payout).
- ``SettlementHooks``: side effects of a settled match (XP, missions, streaks, achievements,
  coin rewards, notices, analytics). Every hook runs inside the settlement transaction and
  returns pieces of each player's ``match.settled`` payload. ``progress_hooks`` run before the
  casual escrow touches any wallet, ``hooks`` after it (the lock order: progress rows before
  wallets).
- ``BlockCheck``: whether two players blocked each other (never paired).
- ``ShadowCheck``: whether a player is in the moderation shadow pool (paired only with others
  in it).
- ``WalletReader``: a player's coin balance, for the Battle tab and ``match.settled.coins``.
- ``LeadersReader`` and ``RelationshipReader``: leaderboard leaders for the Battle tab and the
  relationship shown with recent opponents.
- ``PresenceWriter``, ``Tracker`` and ``NoticeWriter``: social presence, analytics funnel
  events and inbox notices for things that happen outside a settlement.

``integrations`` holds the ones in use; ``app.modules.matches.wiring.install`` connects the real
modules at process start. The defaults keep the engine working on its own (tests): holds always
succeed and are refunded in full, nobody is blocked, balances are unknown (``None``), nothing is
tracked, and match XP, missions and streaks come from ``app.modules.matches.rewards``.
"""

import uuid
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Protocol

import structlog
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

log = structlog.stdlib.get_logger(__name__)


class InsufficientCoins(Exception):
    """The player can't pay the entry; ``mm.join`` answers ``INSUFFICIENT_COINS``."""

    def __init__(self, balance: int | None = None) -> None:
        super().__init__("insufficient coins")
        self.balance = balance


class EscrowPort(Protocol):
    """Coin holds for casual entries. Every call carries an idempotency ``key``
    (``m:{mid}:{uid}:{kind}`` or ``mm:{ticket}``): repeating a call with the same key changes
    nothing and returns the same result."""

    async def hold(self, db: AsyncSession, *, user_id: uuid.UUID, amount: int, key: str) -> str:
        """Lock ``amount`` coins; returns the hold id. Raises ``InsufficientCoins``."""
        ...

    async def release(self, db: AsyncSession, *, hold_id: str, key: str) -> int:
        """Give the held coins back; returns how many (0 if already captured or released)."""
        ...

    async def capture(self, db: AsyncSession, *, hold_id: str, key: str) -> int:
        """Keep the held coins (the entry is spent); returns how many."""
        ...

    async def payout(
        self,
        db: AsyncSession,
        *,
        user_id: uuid.UUID,
        amount: int,
        key: str,
        reason: str,
        match_id: uuid.UUID | None = None,
    ) -> None:
        """Credit ``amount`` coins (the casual pot of ``match_id``)."""
        ...


class NoopEscrow:
    """Holds that always succeed and are remembered in memory only (no wallet yet)."""

    def __init__(self) -> None:
        self.holds: dict[str, tuple[uuid.UUID, int, str]] = {}  # id -> (user, amount, state)
        self.payouts: dict[str, tuple[uuid.UUID, int]] = {}

    async def hold(self, db: AsyncSession, *, user_id: uuid.UUID, amount: int, key: str) -> str:
        self.holds.setdefault(key, (user_id, amount, "held"))
        return key

    async def release(self, db: AsyncSession, *, hold_id: str, key: str) -> int:
        return self._close(hold_id, "released")

    async def capture(self, db: AsyncSession, *, hold_id: str, key: str) -> int:
        return self._close(hold_id, "captured")

    async def payout(
        self,
        db: AsyncSession,
        *,
        user_id: uuid.UUID,
        amount: int,
        key: str,
        reason: str,
        match_id: uuid.UUID | None = None,
    ) -> None:
        self.payouts.setdefault(key, (user_id, amount))

    def _close(self, hold_id: str, state: str) -> int:
        entry = self.holds.get(hold_id)
        if entry is None:
            # Unknown here (another process, or a restart): report the usual entry.
            return 0
        user_id, amount, current = entry
        if current != "held":
            return 0
        self.holds[hold_id] = (user_id, amount, state)
        return amount


@dataclass(frozen=True, slots=True)
class SettledPlayer:
    """One human's outcome, as settlement hooks see it."""

    user_id: uuid.UUID
    result: str  # win, loss, draw, aborted or voided
    score: int
    correct: int
    answered: int  # questions answered (right or wrong)
    place: int | None
    forfeited: bool  # left on purpose or stayed away past their grace
    rating_delta: int | None


@dataclass(frozen=True, slots=True)
class SettlementContext:
    """Everything a hook may need. ``db`` is the settlement transaction: write through it only,
    and never commit it."""

    db: AsyncSession
    match_id: uuid.UUID
    kind: str  # quick_rated, quick_casual, bot, ...
    status: str  # settled, aborted or voided
    reason: str
    subject: str  # slug
    players: Sequence[SettledPlayer]
    has_bot: bool
    opponents: Mapping[uuid.UUID, Sequence[uuid.UUID]]  # human opponents of each player
    coins: Mapping[uuid.UUID, int]  # coins moved by the casual escrow (empty for progress hooks)
    questions: int  # questions asked
    finished_at: datetime
    now: datetime


SettlementHook = Callable[[SettlementContext], Awaitable[Mapping[uuid.UUID, Mapping[str, Any]]]]
BlockCheck = Callable[[AsyncSession, uuid.UUID, uuid.UUID], Awaitable[bool]]
WalletReader = Callable[[AsyncSession, uuid.UUID], Awaitable[int | None]]
# (db, viewer, subject slugs) -> {subject: {"leader": row | None, "me": {...}}}
LeadersReader = Callable[
    [AsyncSession, uuid.UUID, Sequence[str]], Awaitable[Mapping[str, Mapping[str, Any]]]
]
# (db, viewer, others) -> {other: "none" | "friend" | "requested" | "blocked"}
RelationshipReader = Callable[
    [AsyncSession, uuid.UUID, Sequence[uuid.UUID]], Awaitable[Mapping[uuid.UUID, str]]
]
ShadowCheck = Callable[[AsyncSession, uuid.UUID], Awaitable[bool]]
# (redis, user, "online" | "in_battle" | None to clear, ttl_s)
PresenceWriter = Callable[[Redis, uuid.UUID, str | None, int], Awaitable[None]]
# (db, event name, user, props): an analytics funnel event in the caller's transaction.
Tracker = Callable[[AsyncSession, str, uuid.UUID | None, Mapping[str, Any]], Awaitable[None]]
# (db, user, what happened, details): an inbox notice in the caller's transaction. ``what`` is
# ``abort_strike`` ({"match_id", "cooldown_until": ms | None}).
NoticeWriter = Callable[[AsyncSession, uuid.UUID, str, Mapping[str, Any]], Awaitable[None]]

# Payload keys whose values are lists: pieces from several hooks are concatenated.
LIST_KEYS = frozenset({"missions", "achievements"})


class SettlementHooks:
    """Named hooks run in registration order; a later hook's scalar keys win."""

    def __init__(self) -> None:
        self._hooks: dict[str, SettlementHook] = {}

    def register(self, name: str, hook: SettlementHook) -> None:
        """Add ``hook``, or replace the one registered under ``name``."""
        self._hooks[name] = hook

    def unregister(self, name: str) -> None:
        self._hooks.pop(name, None)

    @property
    def names(self) -> list[str]:
        return list(self._hooks)

    async def run(self, ctx: SettlementContext) -> dict[uuid.UUID, dict[str, Any]]:
        merged: dict[uuid.UUID, dict[str, Any]] = {p.user_id: {} for p in ctx.players}
        for name, hook in self._hooks.items():
            pieces = await hook(ctx)
            for user_id, piece in pieces.items():
                target = merged.setdefault(user_id, {})
                for key, value in piece.items():
                    if key in LIST_KEYS:
                        target[key] = [*target.get(key, []), *value]
                    else:
                        target[key] = value
            log.debug("settlement.hook_ran", hook=name, match_id=str(ctx.match_id))
        return merged


async def never_blocked(_db: AsyncSession, _a: uuid.UUID, _b: uuid.UUID) -> bool:
    return False


async def never_shadowed(_db: AsyncSession, _user_id: uuid.UUID) -> bool:
    return False


async def no_presence(_redis: Redis, _user_id: uuid.UUID, _state: str | None, _ttl_s: int) -> None:
    return None


async def no_tracking(
    _db: AsyncSession, _name: str, _user_id: uuid.UUID | None, _props: Mapping[str, Any]
) -> None:
    return None


async def no_notices(
    _db: AsyncSession, _user_id: uuid.UUID, _what: str, _details: Mapping[str, Any]
) -> None:
    return None


async def unknown_balance(_db: AsyncSession, _user_id: uuid.UUID) -> int | None:
    return None


async def no_leaders(
    _db: AsyncSession, _viewer: uuid.UUID, _subjects: Sequence[str]
) -> Mapping[str, Mapping[str, Any]]:
    return {}


async def no_relationships(
    _db: AsyncSession, _viewer: uuid.UUID, others: Sequence[uuid.UUID]
) -> Mapping[uuid.UUID, str]:
    return dict.fromkeys(others, "none")


@dataclass(slots=True)
class Integrations:
    escrow: EscrowPort = field(default_factory=NoopEscrow)
    progress_hooks: SettlementHooks = field(default_factory=SettlementHooks)
    hooks: SettlementHooks = field(default_factory=SettlementHooks)
    are_blocked: BlockCheck = never_blocked
    shadow_pool: ShadowCheck = never_shadowed
    wallet: WalletReader = unknown_balance
    leaders: LeadersReader = no_leaders
    relationships: RelationshipReader = no_relationships
    presence: PresenceWriter = no_presence
    track: Tracker = no_tracking
    notices: NoticeWriter = no_notices


def default_integrations() -> Integrations:
    """The defaults, with XP, missions and streaks as the progress hook."""
    # Imported here: rewards imports this module.
    from app.modules.matches.rewards import progression_hook

    integrations = Integrations()
    integrations.progress_hooks.register("progression", progression_hook)
    return integrations


integrations = default_integrations()
