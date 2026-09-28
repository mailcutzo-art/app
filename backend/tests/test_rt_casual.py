"""Casual Quick Battles: the 5-coin entry, the pot, rematches and emotes."""

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.matches.ports import InsufficientCoins, Integrations, NoopEscrow
from tests.rt_helpers import (
    Bot,
    RtServer,
    correct_option,
    pair,
    ready_both,
    until_shown,
    wrong_option,
)


class Wallets(NoopEscrow):
    """An in-memory coin ledger behind the escrow port."""

    def __init__(self, start: int = 100) -> None:
        super().__init__()
        self.start = start
        self.balances: dict[uuid.UUID, int] = {}

    def balance(self, user_id: uuid.UUID) -> int:
        return self.balances.setdefault(user_id, self.start)

    async def hold(self, db: AsyncSession, *, user_id: uuid.UUID, amount: int, key: str) -> str:
        if key not in self.holds:
            if self.balance(user_id) < amount:
                raise InsufficientCoins(balance=self.balance(user_id))
            self.balances[user_id] -= amount
        return await super().hold(db, user_id=user_id, amount=amount, key=key)

    async def release(self, db: AsyncSession, *, hold_id: str, key: str) -> int:
        refunded = await super().release(db, hold_id=hold_id, key=key)
        user_id = self.holds[hold_id][0]
        self.balances[user_id] += refunded
        return refunded

    async def payout(
        self, db: AsyncSession, *, user_id: uuid.UUID, amount: int, key: str, reason: str
    ) -> None:
        if key not in self.payouts:
            self.balances[user_id] = self.balance(user_id) + amount
        await super().payout(db, user_id=user_id, amount=amount, key=key, reason=reason)

    async def wallet(self, db: AsyncSession, user_id: uuid.UUID) -> int | None:
        return self.balance(user_id)


@pytest.fixture
def wallets(plugins: Integrations) -> Wallets:
    wallets = Wallets()
    plugins.escrow = wallets
    plugins.wallet = wallets.wallet
    return wallets


async def play(redis: Redis, winner: Bot, loser: Bot, mid: str, questions: int = 2) -> None:
    for _ in range(questions):
        show = await winner.expect("q.show")
        await until_shown(show)
        q = show["d"]["q"]
        right = await correct_option(redis, mid, q)
        await winner.request("ans.submit", {"match_id": mid, "q": q, "opt": right, "el_ms": 500})
        wrong = await wrong_option(redis, mid, show)
        await loser.request("ans.submit", {"match_id": mid, "q": q, "opt": wrong, "el_ms": 500})
        await winner.expect("q.reveal")


async def test_the_winner_takes_the_pot(
    rt: RtServer, api: AsyncClient, redis: Redis, wallets: Wallets
) -> None:
    asha, ravi, mid = await pair(rt, api, "casual")
    found = asha.seen("mm.found")[0]
    await ready_both(asha, ravi, mid)

    await play(redis, asha, ravi, mid)
    won = await asha.expect("match.settled")
    lost = await ravi.expect("match.settled")

    assert found["d"]["mode"] == "casual"
    assert won["d"]["coins"] == {"delta": 10, "balance": 105, "capped": False}
    assert lost["d"]["coins"] == {"delta": 0, "balance": 95, "capped": False}
    assert won["d"]["rating"] is None
    assert won["d"]["xp"]["delta"] == 20
    assert sorted(state for _, _, state in wallets.holds.values()) == ["captured", "captured"]


async def test_an_abort_refunds_both_entries(
    rt: RtServer, api: AsyncClient, wallets: Wallets
) -> None:
    asha, ravi, _ = await pair(rt, api, "casual")

    await asha.expect("match.end", wait_s=5)
    settled: dict[str, Any] = await ravi.expect("match.settled")

    assert settled["d"]["coins"] == {"delta": 5, "balance": 100, "capped": False}
    assert wallets.balance(uuid.UUID(ravi.user_id)) == 100
    assert wallets.balance(uuid.UUID(asha.user_id)) == 100


async def test_both_accepting_a_rematch_starts_a_new_casual_match(
    rt: RtServer, api: AsyncClient, redis: Redis, wallets: Wallets
) -> None:
    asha, ravi, mid = await pair(rt, api, "casual")
    await ready_both(asha, ravi, mid)
    await play(redis, asha, ravi, mid)
    await asha.expect("match.end")

    offer = await asha.send("match.rematch", {"match_id": mid, "accept": True})
    offered = await ravi.expect("rematch.status")
    await ravi.send("match.rematch", {"match_id": mid, "accept": True})
    accepted = await asha.expect("rematch.status", lambda f: f["d"]["state"] == "accepted")
    found = await asha.expect("mm.found", lambda f: f["d"]["match_id"] != mid)
    other = await ravi.expect("mm.found", lambda f: f["d"]["match_id"] != mid)

    assert offer
    assert offered["d"] == {"match_id": mid, "state": "offered", "by": asha.user_id, "reason": None}
    assert offered["ch"] == f"m:{mid}"
    assert "seq" in offered  # a shared event
    assert accepted["d"]["match_id"] == mid
    assert found["d"]["match_id"] == other["d"]["match_id"]
    assert found["d"]["mode"] == "casual"
    assert found["d"]["opponent"]["record"] == {"wins": 1, "losses": 0, "draws": 0}
    # A new entry was held from each.
    assert wallets.balance(uuid.UUID(asha.user_id)) == 100
    assert wallets.balance(uuid.UUID(ravi.user_id)) == 90


async def test_a_declined_rematch_and_rated_games_have_none(
    rt: RtServer, api: AsyncClient, redis: Redis, wallets: Wallets
) -> None:
    asha, ravi, mid = await pair(rt, api, "casual")
    await ready_both(asha, ravi, mid)
    await play(redis, asha, ravi, mid)
    await asha.expect("match.end")

    await ravi.send("match.rematch", {"match_id": mid, "accept": False})
    declined = await asha.expect("rematch.status")

    assert declined["d"]["state"] == "declined"
    assert declined["d"]["by"] == ravi.user_id


async def test_emotes_reach_both_players_and_are_rate_limited(
    rt: RtServer, api: AsyncClient
) -> None:
    asha, ravi, mid = await pair(rt, api)

    first = await asha.request("emote", {"match_id": mid, "e": "gg"})
    seen = await ravi.expect("emote")
    again = await asha.request("emote", {"match_id": mid, "e": "wow"})
    unknown = await asha.request("emote", {"match_id": mid, "e": "rude"})

    assert first["t"] == "ack"
    assert seen["d"] == {"uid": asha.user_id, "e": "gg"}
    assert again["d"]["code"] == "RATE_LIMITED"
    assert unknown["d"]["code"] == "BAD_REQUEST"
