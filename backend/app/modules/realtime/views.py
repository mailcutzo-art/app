"""Match state as one player sees it: snapshots, and viewer-specific details of shared events.

Shared events are identical for every player and carry a ``seq``. The gateway adds what depends
on the viewer while forwarding them, without changing the ``seq``: ``result`` in ``match.end``,
and in group battles each player's own option order (a permutation seeded by match, player and
question, so a resend or a snapshot shows the same order).
"""

import random
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


def shuffled(show: dict[str, Any], mid: str, viewer: str) -> dict[str, Any]:
    """A ``q.show`` payload with the options in this viewer's own order."""
    options = list(show.get("options") or [])
    random.Random(f"{mid}:{viewer}:{show.get('q')}").shuffle(options)  # noqa: S311 - display
    return {**show, "options": options}


def for_viewer(envelope: dict[str, Any], viewer: str, *, shuffle: bool = False) -> dict[str, Any]:
    """The shared event with the viewer's details added (the envelope is copied if changed)."""
    event_type = envelope.get("t")
    if event_type == "q.show" and shuffle:
        mid = str(envelope.get("ch", "")).removeprefix("m:")
        return {**envelope, "d": shuffled(dict(envelope.get("d") or {}), mid, viewer)}
    if event_type != "match.end":
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
    question = orjson.loads(show) if show and phase in {"q_open", "q_reveal"} else None
    if question is not None and h["kind"] == "group":
        question = shuffled(question, mid, viewer)
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
        "question": question,
        "reveal": orjson.loads(h["last_reveal"]) if h.get("last_reveal") else None,
        "mine": state["mine"],
        "end": end,
        "settled": h.get("settled") == "1",
    }
    return protocol.frame(
        "match.snapshot", data, ch=protocol.match_channel(mid), ts=ts, seq=int(h["seq"])
    )
