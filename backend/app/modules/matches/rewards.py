"""What a settled match gives each player: the settlement hooks (``ports.SettlementHooks``).

- ``progression_hook`` (a progress hook, before any wallet is locked): XP within the daily
  caps (``progression.xp.award_game_xp``: ``xp``, and ``resets_at`` when capped), then missions,
  the streak and achievements (``progression.service.settlement_progress``).
- ``rated_coins_hook``: rated games pay 10 / 4 / 1 coins for a win, draw or loss, at most 150 a
  day (IST); ``coins`` in ``match.settled``. Casual coins are the escrow's pot instead; bot,
  friend and group games pay none.
- ``notices_hook``: inbox notices a player may miss on screen: ``match_forfeit`` for a player who
  left or stayed away past their grace, ``match_settled`` when rewards arrive late.
- ``analytics_hook``: ``match_finished`` per player, ``first_battle``, and ``settle_lag_ms``.

Aborted and voided matches earn nothing, and neither does a player who forfeited (their
opponent gets the win rewards).
"""

import uuid
from collections.abc import Mapping
from datetime import datetime, time, timedelta
from typing import Any

from sqlalchemy import exists, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.modules.analytics.service import track
from app.modules.economy.models import CoinReason, LedgerEntry, RefKind
from app.modules.economy.service import Ref, credit, lock_wallets
from app.modules.matches.models import MatchKind, MatchParticipant
from app.modules.matches.ports import SettledPlayer, SettlementContext
from app.modules.notifications.service import notify
from app.modules.progression.service import settlement_progress
from app.modules.progression.xp import award_game_xp

Pieces = Mapping[uuid.UUID, Mapping[str, Any]]

GAME_RESULTS = frozenset({"win", "draw", "loss"})
RATED_COINS: Mapping[str, int] = {"win": 10, "draw": 4, "loss": 1}
RATED_COINS_DAILY_CAP = 150
_RATED_TITLES = {
    "win": "Rated battle won",
    "draw": "Rated battle drawn",
    "loss": "Rated battle played",
}
# Rewards shown on the result screen after this long also get an inbox item.
LATE_SETTLEMENT = timedelta(seconds=20)


def rewarded(ctx: SettlementContext) -> list[SettledPlayer]:
    """The players a finished match rewards (not a forfeit), in user order (the lock order)."""
    if ctx.status != "settled":
        return []
    return sorted(
        (p for p in ctx.players if not p.forfeited and p.result in GAME_RESULTS),
        key=lambda p: p.user_id,
    )


async def progression_hook(ctx: SettlementContext) -> Pieces:
    pieces: dict[uuid.UUID, Mapping[str, Any]] = {}
    for player in rewarded(ctx):
        xp = await award_game_xp(
            ctx.db,
            player.user_id,
            mode=ctx.kind,
            result=player.result,
            match_id=ctx.match_id,
            now=ctx.now,
        )
        progress = await settlement_progress(
            ctx.db,
            player.user_id,
            mode=ctx.kind,
            result=player.result,
            match_id=ctx.match_id,
            now=ctx.now,
            answered=player.answered,
            perfect=player.answered > 0 and player.correct >= ctx.questions,
        )
        piece: dict[str, Any] = {"xp": xp.fragment(), **progress.fragment()}
        if xp.resets_at is not None:
            piece["resets_at"] = int(xp.resets_at.timestamp() * 1000)
        pieces[player.user_id] = piece
    return pieces


def _ist_day_start(now: datetime) -> datetime:
    return datetime.combine(now.astimezone(IST).date(), time(), tzinfo=IST)


async def rated_coins_today(db: AsyncSession, user_id: uuid.UUID, now: datetime) -> int:
    earned = await db.scalar(
        select(func.coalesce(func.sum(LedgerEntry.delta), 0)).where(
            LedgerEntry.user_id == user_id,
            LedgerEntry.reason == CoinReason.MATCH_REWARD.value,
            LedgerEntry.created_at >= _ist_day_start(now),
        )
    )
    return int(earned or 0)


async def rated_coins_hook(ctx: SettlementContext) -> Pieces:
    if ctx.kind != MatchKind.QUICK_RATED:
        return {}
    pieces: dict[uuid.UUID, Mapping[str, Any]] = {}
    for player in rewarded(ctx):
        wallet = (await lock_wallets(ctx.db, [player.user_id]))[player.user_id]
        requested = RATED_COINS[player.result]
        already = await rated_coins_today(ctx.db, player.user_id, ctx.now)
        amount = max(0, min(requested, RATED_COINS_DAILY_CAP - already))
        if amount > 0:
            await credit(
                ctx.db,
                player.user_id,
                amount,
                reason=CoinReason.MATCH_REWARD,
                title=_RATED_TITLES[player.result],
                key=f"m:{ctx.match_id}:{player.user_id}:reward",
                ref=Ref(RefKind.MATCH, str(ctx.match_id)),
            )
        if amount < requested:
            await track(ctx.db, "cap_reached", player.user_id, {"kind": "coins_rated"}, now=ctx.now)
        pieces[player.user_id] = {
            "coins": {"delta": amount, "balance": wallet.balance, "capped": amount < requested}
        }
    return pieces


def _match_action(match_id: uuid.UUID) -> dict[str, Any]:
    return {"route": f"/battle/match/{match_id}", "params": {}}


async def notices_hook(ctx: SettlementContext) -> Pieces:
    for player in ctx.players:
        if ctx.status == "settled" and player.forfeited:
            away = ctx.reason == "disconnected"
            await notify(
                ctx.db,
                player.user_id,
                kind="match_forfeit",
                title="Match lost",
                body=(
                    "You were away too long, so the match counted as a loss."
                    if away
                    else "You left the match, so it counted as a loss."
                ),
                icon="battle",
                action=_match_action(ctx.match_id),
                key=f"match_forfeit:{ctx.match_id}",
            )
    if ctx.status == "settled" and ctx.now - ctx.finished_at > LATE_SETTLEMENT:
        for player in rewarded(ctx):
            await notify(
                ctx.db,
                player.user_id,
                kind="match_settled",
                title="Rewards added",
                body="Your last battle's XP and rewards are now in your profile.",
                icon="battle",
                action=_match_action(ctx.match_id),
                key=f"match_settled:{ctx.match_id}",
            )
    return {}


async def _first_battle(db: AsyncSession, user_id: uuid.UUID, match_id: uuid.UUID) -> bool:
    played_before = await db.scalar(
        select(
            exists().where(
                MatchParticipant.user_id == user_id,
                MatchParticipant.match_id != match_id,
                MatchParticipant.settlement.is_not(None),
            )
        )
    )
    return not played_before


async def analytics_hook(ctx: SettlementContext) -> Pieces:
    for player in ctx.players:
        await track(
            ctx.db,
            "match_finished",
            player.user_id,
            {"kind": ctx.kind, "result": player.result, "reason": ctx.reason},
            now=ctx.now,
        )
        if ctx.status == "settled" and await _first_battle(ctx.db, player.user_id, ctx.match_id):
            await track(ctx.db, "first_battle", player.user_id, {"kind": ctx.kind}, now=ctx.now)
    lag_ms = max(0, round((ctx.now - ctx.finished_at).total_seconds() * 1000))
    await track(ctx.db, "settle_lag_ms", None, {"ms": lag_ms, "kind": ctx.kind}, now=ctx.now)
    return {}
