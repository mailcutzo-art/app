"""The default settlement hook for match XP: ``xp`` in ``match.settled``.

Win/draw/loss XP by game kind (``progression.levels.game_xp``), half for the Practice Bot and at
most 60 a day there. Aborted and voided matches earn nothing, and neither does a player who
left or stayed away past their grace.
"""

import uuid
from collections.abc import Mapping
from typing import Any

from app.modules.matches.ports import SettlementContext
from app.modules.progression import levels
from app.modules.progression.xp import award_game_xp

_OUTCOMES = {
    "win": levels.GameOutcome.WIN,
    "draw": levels.GameOutcome.DRAW,
    "loss": levels.GameOutcome.LOSS,
}


async def match_xp_hook(ctx: SettlementContext) -> Mapping[uuid.UUID, Mapping[str, Any]]:
    if ctx.status != "settled":
        return {}
    kind = levels.GameKind(ctx.kind)
    pieces: dict[uuid.UUID, Mapping[str, Any]] = {}
    for player in sorted(ctx.players, key=lambda p: p.user_id):  # lock order
        outcome = None if player.forfeited else _OUTCOMES.get(player.result)
        xp = await award_game_xp(
            ctx.db, player.user_id, match_id=ctx.match_id, kind=kind, outcome=outcome, now=ctx.now
        )
        pieces[player.user_id] = {
            "xp": {
                "delta": xp.delta,
                "level": xp.level,
                "into_level": xp.into_level,
                "for_next": xp.for_next,
                "level_up": xp.level_up,
                "capped": xp.capped,
            }
        }
    return pieces
