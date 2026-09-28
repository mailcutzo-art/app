"""Moving coins: postings, holds and payouts, exactly once.

Every change runs in the caller's transaction and follows the same steps: lock the wallets
involved ``FOR UPDATE`` (several at once in ``user_id`` order, so concurrent payouts can't
deadlock), return the earlier result if the idempotency key was posted before, check the
balance, then insert the ledger entry (``ON CONFLICT DO NOTHING``) and update the wallet. A
replay therefore changes nothing and never fails for lack of coins, even after they were spent.

Keys are global: callers namespace them (``welcome:{uid}``, ``m:{mid}:{uid}:entry``, ...).
"""

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import func, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import Conflict, NotFound
from app.core.ids import new_id
from app.modules.economy.models import (
    Bucket,
    CoinHold,
    CoinReason,
    HoldStatus,
    LedgerEntry,
    RefKind,
    Wallet,
)

WELCOME_BONUS = 100
WELCOME_TITLE = "Welcome bonus"


class InsufficientCoins(Conflict):
    default_code = "INSUFFICIENT_COINS"
    default_message = "You don't have enough coins for this."


@dataclass(frozen=True, slots=True)
class Ref:
    """What an entry or hold is about: ``Ref(RefKind.MATCH, str(match_id))``."""

    kind: RefKind
    id: str


@dataclass(frozen=True, slots=True)
class Posting:
    entry: LedgerEntry
    replayed: bool  # the key had been posted before; nothing changed


@dataclass(frozen=True, slots=True)
class HoldResult:
    hold: CoinHold
    replayed: bool


@dataclass(frozen=True, slots=True)
class WalletView:
    balance: int
    held: int
    purchased: int


# --- Wallets -------------------------------------------------------------------------------


async def lock_wallets(db: AsyncSession, user_ids: Sequence[uuid.UUID]) -> dict[uuid.UUID, Wallet]:
    """Create any missing wallets and lock them all, in ``user_id`` order."""
    ordered = sorted(set(user_ids))
    if not ordered:
        return {}
    await db.execute(
        insert(Wallet)
        .values([{"user_id": user_id} for user_id in ordered])
        .on_conflict_do_nothing()
    )
    wallets = await db.scalars(
        select(Wallet)
        .where(Wallet.user_id.in_(ordered))
        .order_by(Wallet.user_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    return {wallet.user_id: wallet for wallet in wallets}


async def get_wallet(db: AsyncSession, user_id: uuid.UUID) -> WalletView:
    """The user's balances (zero before their first posting). Reads without locking."""
    wallet = await db.get(Wallet, user_id, populate_existing=True)
    if wallet is None:
        return WalletView(balance=0, held=0, purchased=0)
    return WalletView(balance=wallet.balance, held=wallet.held, purchased=wallet.purchased)


# --- Postings ------------------------------------------------------------------------------


async def credit(
    db: AsyncSession,
    user_id: uuid.UUID,
    amount: int,
    *,
    reason: CoinReason,
    title: str,
    key: str,
    ref: Ref | None = None,
) -> Posting:
    """Add ``amount`` (> 0) coins."""
    _check_amount(amount)
    wallets = await lock_wallets(db, [user_id])
    return await _post(db, wallets[user_id], amount, reason=reason, title=title, key=key, ref=ref)


async def debit(
    db: AsyncSession,
    user_id: uuid.UUID,
    amount: int,
    *,
    reason: CoinReason,
    title: str,
    key: str,
    ref: Ref | None = None,
) -> Posting:
    """Take ``amount`` (> 0) coins; 409 ``INSUFFICIENT_COINS`` if the balance is short."""
    _check_amount(amount)
    wallets = await lock_wallets(db, [user_id])
    return await _post(db, wallets[user_id], -amount, reason=reason, title=title, key=key, ref=ref)


async def transfer(
    db: AsyncSession,
    from_user: uuid.UUID,
    to_user: uuid.UUID,
    amount: int,
    *,
    reason: CoinReason,
    title_from: str,
    title_to: str,
    key: str,
    ref: Ref | None = None,
) -> tuple[Posting, Posting]:
    """Move ``amount`` coins between two players (keys ``{key}:from`` and ``{key}:to``)."""
    _check_amount(amount)
    if from_user == to_user:
        raise ValueError("a transfer needs two different users")
    wallets = await lock_wallets(db, [from_user, to_user])
    out = await _post(
        db, wallets[from_user], -amount, reason=reason, title=title_from, key=f"{key}:from", ref=ref
    )
    into = await _post(
        db, wallets[to_user], amount, reason=reason, title=title_to, key=f"{key}:to", ref=ref
    )
    return out, into


async def _post(
    db: AsyncSession,
    wallet: Wallet,
    delta: int,
    *,
    reason: CoinReason,
    title: str,
    key: str,
    ref: Ref | None,
) -> Posting:
    """Write one entry against a wallet this transaction has locked."""
    existing = await _entry_by_key(db, key)
    if existing is not None:
        return Posting(_owned(existing, wallet.user_id, key), replayed=True)
    balance_after = wallet.balance + delta
    if balance_after < 0:
        raise InsufficientCoins(details={"needed": -delta, "balance": wallet.balance})
    entry_id = await db.scalar(
        insert(LedgerEntry)
        .values(
            id=new_id(),
            user_id=wallet.user_id,
            delta=delta,
            balance_after=balance_after,
            reason=reason.value,
            title=title,
            ref_kind=ref.kind.value if ref else None,
            ref_id=ref.id if ref else None,
            bucket=Bucket.EARNED.value,
            idempotency_key=key,
        )
        .on_conflict_do_nothing(index_elements=[LedgerEntry.idempotency_key])
        .returning(LedgerEntry.id)
    )
    if entry_id is None:
        # Only another user's posting can take the key while this wallet is locked.
        replay = await _entry_by_key(db, key)
        if replay is None:  # pragma: no cover - the conflicting row is committed and visible
            raise RuntimeError(f"ledger key {key!r} conflicted but can't be read")
        return Posting(_owned(replay, wallet.user_id, key), replayed=True)
    wallet.balance = balance_after
    await db.flush()
    return Posting(await db.get_one(LedgerEntry, entry_id), replayed=False)


async def _entry_by_key(db: AsyncSession, key: str) -> LedgerEntry | None:
    return await db.scalar(select(LedgerEntry).where(LedgerEntry.idempotency_key == key))


def _owned(entry: LedgerEntry, user_id: uuid.UUID, key: str) -> LedgerEntry:
    if entry.user_id != user_id:
        raise ValueError(f"ledger key {key!r} belongs to another user")
    return entry


def _check_amount(amount: int) -> None:
    if amount <= 0:
        raise ValueError("amount must be positive")


# --- Holds ---------------------------------------------------------------------------------


async def hold(
    db: AsyncSession,
    user_id: uuid.UUID,
    amount: int,
    *,
    reason: CoinReason,
    title: str,
    key: str,
    ref: Ref,
) -> HoldResult:
    """Set ``amount`` coins aside: posts ``-amount`` now and records an open hold.

    409 ``INSUFFICIENT_COINS`` if the balance is short. The same ``key`` returns the same hold.
    """
    _check_amount(amount)
    wallets = await lock_wallets(db, [user_id])
    wallet = wallets[user_id]
    existing = await db.scalar(select(CoinHold).where(CoinHold.key == key))
    if existing is not None:
        if existing.user_id != user_id:
            raise ValueError(f"hold key {key!r} belongs to another user")
        return HoldResult(existing, replayed=True)
    await _post(db, wallet, -amount, reason=reason, title=title, key=key, ref=ref)
    record = CoinHold(
        user_id=user_id,
        amount=amount,
        reason=reason.value,
        ref_kind=ref.kind.value,
        ref_id=ref.id,
        key=key,
    )
    db.add(record)
    wallet.held += amount
    await db.flush()
    return HoldResult(record, replayed=False)


async def capture_hold(db: AsyncSession, hold_id: uuid.UUID) -> CoinHold:
    """The held coins are spent. Idempotent; 409 ``HOLD_SETTLED`` if it was released."""
    record, wallet = await locked_hold(db, hold_id)
    if record.status == HoldStatus.CAPTURED:
        return record
    if record.status == HoldStatus.RELEASED:
        raise Conflict("These coins were already returned.", code="HOLD_SETTLED")
    record.status = HoldStatus.CAPTURED.value
    record.settled_at = func.now()
    wallet.held -= record.amount
    await db.flush()
    await db.refresh(record)
    return record


async def release_hold(
    db: AsyncSession, hold_id: uuid.UUID, *, title: str = "Refund: entry returned"
) -> CoinHold:
    """Give the held coins back (a refund entry, key ``hold:{id}:release``). Idempotent;
    409 ``HOLD_SETTLED`` if the hold was captured."""
    record, wallet = await locked_hold(db, hold_id)
    if record.status == HoldStatus.RELEASED:
        return record
    if record.status == HoldStatus.CAPTURED:
        raise Conflict("These coins were already spent.", code="HOLD_SETTLED")
    await _post(
        db,
        wallet,
        record.amount,
        reason=CoinReason.REFUND,
        title=title,
        key=f"hold:{record.id}:release",
        ref=Ref(RefKind(record.ref_kind), record.ref_id),
    )
    record.status = HoldStatus.RELEASED.value
    record.settled_at = func.now()
    wallet.held -= record.amount
    await db.flush()
    await db.refresh(record)
    return record


async def locked_hold(db: AsyncSession, hold_id: uuid.UUID) -> tuple[CoinHold, Wallet]:
    """The hold and its wallet, locked wallet first (the order every posting uses)."""
    user_id = await db.scalar(select(CoinHold.user_id).where(CoinHold.id == hold_id))
    if user_id is None:
        raise NotFound("That hold doesn't exist.", code="HOLD_NOT_FOUND")
    wallet = (await lock_wallets(db, [user_id]))[user_id]
    record = await db.get_one(CoinHold, hold_id, with_for_update=True, populate_existing=True)
    return record, wallet


@dataclass(frozen=True, slots=True)
class PotResult:
    pot: int
    payouts: dict[uuid.UUID, int]  # winner -> coins credited (empty when refunded)
    refunded: bool


async def settle_pot(
    db: AsyncSession,
    hold_ids: Sequence[uuid.UUID],
    winners: Sequence[uuid.UUID],
    *,
    title: str,
    key: str,
    ref: Ref,
    refund_title: str = "Refund: match cancelled",
) -> PotResult:
    """Settle a casual game's entry holds: capture them all and pay the pot to the winners
    (split evenly on a draw, any odd coin to the lowest user id), or, with no winners
    (aborted), release every hold. Keys ``{key}:{winner}``; safe to call again."""
    held = list(await db.scalars(select(CoinHold).where(CoinHold.id.in_(list(hold_ids)))))
    if len(held) != len(set(hold_ids)):
        raise NotFound("A hold in this pot doesn't exist.", code="HOLD_NOT_FOUND")
    await lock_wallets(db, [record.user_id for record in held] + list(winners))
    pot = sum(record.amount for record in held)
    if not winners:
        for record in held:
            await release_hold(db, record.id, title=refund_title)
        return PotResult(pot=pot, payouts={}, refunded=True)
    for record in held:
        await capture_hold(db, record.id)
    ordered = sorted(set(winners))
    share, extra = divmod(pot, len(ordered))
    payouts: dict[uuid.UUID, int] = {}
    for index, winner in enumerate(ordered):
        amount = share + (1 if index < extra else 0)
        if amount > 0:
            await credit(
                db,
                winner,
                amount,
                reason=CoinReason.MATCH_POT,
                title=title,
                key=f"{key}:{winner}",
                ref=ref,
            )
        payouts[winner] = amount
    return PotResult(pot=pot, payouts=payouts, refunded=False)


# --- Welcome bonus -------------------------------------------------------------------------


def welcome_key(user_id: uuid.UUID) -> str:
    return f"welcome:{user_id}"


async def grant_welcome_bonus(db: AsyncSession, user_id: uuid.UUID) -> Posting:
    """The one-time 100 coins for finishing onboarding."""
    return await credit(
        db,
        user_id,
        WELCOME_BONUS,
        reason=CoinReason.WELCOME,
        title=WELCOME_TITLE,
        key=welcome_key(user_id),
        ref=Ref(RefKind.WELCOME, str(user_id)),
    )


async def pop_welcome(db: AsyncSession, user_id: uuid.UUID, *, now: datetime) -> int | None:
    """The welcome bonus to show on Home, once: its amount the first time, then ``None``."""
    shown = await db.scalar(
        update(Wallet)
        .where(
            Wallet.user_id == user_id,
            Wallet.welcome_seen_at.is_(None),
            select(LedgerEntry.id)
            .where(LedgerEntry.idempotency_key == welcome_key(user_id))
            .exists(),
        )
        .values(welcome_seen_at=now)
        .returning(Wallet.user_id)
    )
    if shown is None:
        return None
    amount = await db.scalar(
        select(LedgerEntry.delta).where(LedgerEntry.idempotency_key == welcome_key(user_id))
    )
    return int(amount) if amount is not None else None
