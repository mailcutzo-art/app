"""The default settlement hook for match XP: ``xp`` and ``resets_at`` in ``match.settled``.

The amounts and daily caps are progression's (``app.modules.progression.xp.award_game_xp``).
Aborted and voided matches earn nothing, and neither does a player who left or stayed away past
their grace.
"""

import uuid
from collections.abc import Mapping
from typing import Any

from app.modules.matches.ports import SettlementContext
from app.modules.progression.xp import award_game_xp


async def match_xp_hook(ctx: SettlementContext) -> Mapping[uuid.UUID, Mapping[str, Any]]:
    if ctx.status != "settled":
        return {}
    pieces: dict[uuid.UUID, Mapping[str, Any]] = {}
    for player in sorted(ctx.players, key=lambda p: p.user_id):  # lock order
        if player.forfeited or player.result not in {"win", "draw", "loss"}:
            continue
        xp = await award_game_xp(
            ctx.db,
            player.user_id,
            mode=ctx.kind,
            result=player.result,
            match_id=ctx.match_id,
            now=ctx.now,
        )
        piece: dict[str, Any] = {"xp": xp.fragment()}
        if xp.resets_at is not None:
            piece["resets_at"] = int(xp.resets_at.timestamp() * 1000)
        pieces[player.user_id] = piece
    return pieces
