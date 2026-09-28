"""Match state as one player sees it: snapshots, and viewer-specific details of shared events.

Shared events are identical for every player and carry a ``seq``. The gateway adds what depends
on the viewer while forwarding them, without changing the ``seq``: ``result`` in ``match.end``.
"""

from typing import Any

import orjson
from redis.asyncio import Redis

from app.modules.realtime import protocol
from app.modules.realtime.engine import scripts


def viewer_result(end: dict[str, Any], viewer: str) -> str:
    """``win``, ``loss`` or ``draw`` from ``viewer``'s point of view."""
    ranking: list[list[str]] = end.get("ranking") or []
    if end.get("reason") in {"aborted", "voided"} or not ranking:
        return "draw"
    if viewer in ranking[0]:
        return "draw" if len(ranking[0]) > 1 else "win"
    return "loss"


def for_viewer(envelope: dict[str, Any], viewer: str) -> dict[str, Any]:
    """The shared event with the viewer's details added (the envelope is copied if changed)."""
    if envelope.get("t") != "match.end":
        return envelope
    data = dict(envelope.get("d") or {})
    data["result"] = viewer_result(data, viewer)
    return {**envelope, "d": data}


async def snapshot(redis: Redis, mid: str, viewer: str, *, ts: int) -> dict[str, Any] | None:
    """The ``match.snapshot`` frame for ``viewer``; its seq is the channel's current seq."""
    state = await scripts.read_snapshot(redis, mid, viewer)
    if state is None:
        return None
    h: dict[str, str] = state["h"]
    cards: dict[str, dict[str, Any]] = orjson.loads(h["cards"])
    answered: dict[str, bool] = state["answered"] or {}
    players = []
    for uid in orjson.loads(h["players"]):
        player = orjson.loads(state["p"][uid])
        players.append(
            {
                **cards.get(uid, {"uid": uid}),
                "connected": bool(player["connected"]),
                "grace_until": player["grace_until"] or None,
                "score": player["score"],
                "correct": player["correct"],
                "answered": bool(answered.get(uid, False)),
            }
        )
    phase = h["phase"]
    end = orjson.loads(h["end"]) if h.get("end") else None
    if end is not None:
        end["result"] = viewer_result(end, viewer)
    show = state.get("show")
    ends_at = int(h.get("ends_at") or 0)
    data = {
        "match_id": mid,
        "kind": h["kind"],
        "phase": phase,
        "ends_at": ends_at or None,
        "q": int(h["q"]),
        "total": int(h["total"]),
        "limit_ms": state["limit_ms"] or None,
        "players": players,
        "question": orjson.loads(show) if show and phase in {"q_open", "q_reveal"} else None,
        "reveal": orjson.loads(h["last_reveal"]) if h.get("last_reveal") else None,
        "mine": state["mine"],
        "end": end,
        "settled": h.get("settled") == "1",
    }
    return protocol.frame(
        "match.snapshot", data, ch=protocol.match_channel(mid), ts=ts, seq=int(h["seq"])
    )
