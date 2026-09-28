"""The casual entry on the coin ledger (``ports.EscrowPort`` over ``app.modules.economy``).

- **Hold** at ``mm.join``: ``-5`` "Casual battle entry" and an open ``coin_holds`` row whose
  reference is the search (``Ref(match, "mm:<ticket>")``: no match exists yet).
- **Capture** when the match has a winner (the entry is spent), **release** on a draw, abort,
  void or a search that ends without a match ("Refund: ..." entry and a ``refund`` inbox
  notice), and **payout** of the pot to the winner ("Casual battle won").

Every call is idempotent: capturing or releasing a hold that is already settled returns 0.
The hold reaper asks ``match_hold_live`` before refunding a hold older than 30 minutes: it is
live while the player's queue ticket or unsettled match still carries it.
"""

import uuid

import structlog
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFound
from app.modules.economy import service as economy
from app.modules.economy.jobs import HoldRef
from app.modules.economy.models import CoinHold, CoinReason, HoldStatus, RefKind
from app.modules.matches import ports
from app.modules.matches.models import Match
from app.modules.notifications.service import notify
from app.modules.realtime import keys, rstr

log = structlog.stdlib.get_logger(__name__)

ENTRY_TITLE = "Casual battle entry"
POT_TITLE = "Casual battle won"
SEARCH_REFUND_TITLE = "Refund: search ended"
MATCH_REFUND_TITLE = "Refund: match cancelled"


def _hold_uuid(hold_id: str) -> uuid.UUID | None:
    try:
        return uuid.UUID(hold_id)
    except ValueError:
        return None


class LedgerEscrow:
    """``EscrowPort`` on the real wallet. Runs in the caller's transaction."""

    async def hold(self, db: AsyncSession, *, user_id: uuid.UUID, amount: int, key: str) -> str:
        try:
            result = await economy.hold(
                db,
                user_id,
                amount,
                reason=CoinReason.MATCH_ENTRY,
                title=ENTRY_TITLE,
                key=key,
                ref=economy.Ref(RefKind.MATCH, key),
            )
        except economy.InsufficientCoins as exc:
            balance = (exc.details or {}).get("balance")
            raise ports.InsufficientCoins(balance=balance) from exc
        return str(result.hold.id)

    async def release(self, db: AsyncSession, *, hold_id: str, key: str) -> int:
        record = await self._open(db, hold_id)
        if record is None:
            return 0
        search = key.startswith("mm:")
        await economy.release_hold(
            db, record.id, title=SEARCH_REFUND_TITLE if search else MATCH_REFUND_TITLE
        )
        await notify(
            db,
            record.user_id,
            kind="refund",
            title=f"{record.amount} coins returned",
            body=(
                "Your search ended without a match, so your Casual entry is back in your wallet."
                if search
                else "Your Casual match ended without a winner, so your entry is back in your "
                "wallet."
            ),
            icon="coins",
            action={"route": "/wallet", "params": {}},
            key=f"refund:hold:{record.id}",
        )
        return record.amount

    async def capture(self, db: AsyncSession, *, hold_id: str, key: str) -> int:
        record = await self._open(db, hold_id)
        if record is None:
            return 0
        await economy.capture_hold(db, record.id)
        return record.amount

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
        if amount <= 0:
            return
        await economy.credit(
            db,
            user_id,
            amount,
            reason=CoinReason.MATCH_POT,
            title=POT_TITLE,
            key=key,
            ref=economy.Ref(RefKind.MATCH, str(match_id)) if match_id else None,
        )

    @staticmethod
    async def _open(db: AsyncSession, hold_id: str) -> CoinHold | None:
        """The hold, locked (wallet first), if it is still held; None once settled."""
        hold_uuid = _hold_uuid(hold_id)
        if hold_uuid is None:
            log.warning("escrow.unknown_hold", hold_id=hold_id)
            return None
        try:
            record, _wallet = await economy.locked_hold(db, hold_uuid)
        except NotFound:
            log.warning("escrow.unknown_hold", hold_id=hold_id)
            return None
        return record if record.status == HoldStatus.HELD else None


async def wallet_balance(db: AsyncSession, user_id: uuid.UUID) -> int | None:
    return (await economy.get_wallet(db, user_id)).balance


async def match_hold_live(db: AsyncSession, redis: Redis, ref: HoldRef) -> bool:
    """A casual entry is live while the player's search or unsettled match still carries it
    (a requeue moves the hold to the new ticket)."""
    uid = str(ref.user_id)
    busy = await rstr.get(redis, keys.busy(uid))
    if busy is None:
        return False
    kind, _, ident = busy.partition(":")
    hold_id = str(ref.hold_id)
    if kind == "q":
        return await rstr.hget(redis, keys.ticket(ident), "hold_id") == hold_id
    if kind == "m":
        match_uuid = _hold_uuid(ident)
        match = await db.get(Match, match_uuid) if match_uuid else None
        return (
            match is not None
            and match.settled_at is None
            and match.config.get("holds", {}).get(uid) == hold_id
        )
    return False
