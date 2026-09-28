"""The engine wired to the real modules (``app.modules.matches.wiring``): coins on the ledger,
progression, rated rewards, refunds and notices, blocks, the shadow pool, bans and presence."""

import uuid
from collections.abc import Sequence
from datetime import timedelta
from typing import Any

import httpx
import orjson
import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select

from app.core.clock import utc_now
from app.core.config import Settings
from app.modules.economy.jobs import HoldRef
from app.modules.economy.models import CoinHold, CoinReason, LedgerEntry, RefKind
from app.modules.economy.service import Ref, credit, get_wallet
from app.modules.matches import rewards
from app.modules.matches.escrow import LedgerEscrow, match_hold_live
from app.modules.matches.models import MatchKind
from app.modules.matches.ports import Integrations
from app.modules.matches.settlement import settle_match
from app.modules.matches.wiring import production_integrations
from app.modules.moderation.service import apply_moderation
from app.modules.notifications.models import Notification
from app.modules.outbox.service import dispatch_due
from app.modules.realtime import keys
from app.modules.realtime.engine import scripts
from app.modules.social.presence import presence_key
from tests.helpers import bearer
from tests.platform_helpers import onboarded
from tests.rt_helpers import (
    LockedSessions,
    RtServer,
    connect_bot,
    no_frame,
    pair,
    ready_both,
    search,
    sign_in,
    ticket_key,
)
from tests.test_match_settlement import deps, new_match, play_rated, two_users
from tests.test_rt_casual import play


@pytest.fixture
def plugins() -> Integrations:
    """The production wiring, fresh per test (the rt server and settlement use it)."""
    return production_integrations()


async def fund(sessions: LockedSessions, user_id: uuid.UUID | str, coins: int = 100) -> None:
    async with sessions() as db:
        await credit(
            db,
            uuid.UUID(str(user_id)),
            coins,
            reason=CoinReason.ADJUSTMENT,
            title="Test coins",
            key=f"test:{user_id}",
        )
        await db.commit()


MATCH_REASONS = ("match_entry", "match_pot", "match_reward", "refund")


async def ledger(sessions: LockedSessions, user_id: uuid.UUID | str) -> list[tuple[int, str]]:
    """The player's match entries (achievements and level-ups pay coins too)."""
    async with sessions() as db:
        rows = await db.execute(
            select(LedgerEntry.delta, LedgerEntry.reason)
            .where(
                LedgerEntry.user_id == uuid.UUID(str(user_id)),
                LedgerEntry.reason.in_(MATCH_REASONS),
            )
            .order_by(LedgerEntry.created_at, LedgerEntry.id)
        )
        return [(int(delta), str(reason)) for delta, reason in rows]


async def balance(sessions: LockedSessions, user_id: uuid.UUID | str) -> int:
    async with sessions() as db:
        return (await get_wallet(db, uuid.UUID(str(user_id)))).balance


async def inbox(sessions: LockedSessions, user_id: uuid.UUID | str) -> list[str]:
    async with sessions() as db:
        kinds = await db.scalars(
            select(Notification.kind)
            .where(Notification.user_id == uuid.UUID(str(user_id)))
            .order_by(Notification.id)
        )
        return list(kinds)


async def hold_states(sessions: LockedSessions, user_ids: Sequence[str]) -> list[str]:
    async with sessions() as db:
        states = await db.scalars(
            select(CoinHold.status).where(CoinHold.user_id.in_([uuid.UUID(u) for u in user_ids]))
        )
        return sorted(states)


async def deliver(sessions: LockedSessions, redis: Redis, settings: Settings) -> None:
    """One outbox pass, as the worker runs it (the withdrawal after a ban)."""
    async with sessions() as db, httpx.AsyncClient() as http:
        await dispatch_due(db, redis=redis, http=http, settings=settings, now=utc_now())


# Casual games on the ledger


async def test_a_casual_game_moves_real_coins_and_settles_every_reward(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    for email in ("asha@example.com", "ravi@example.com"):
        await fund(sessions, (await sign_in(api, email))["user"]["id"])
    asha, ravi, mid = await pair(rt, api, "casual")
    in_battle = await redis.get(presence_key(uuid.UUID(asha.user_id)))
    await ready_both(asha, ravi, mid)

    await play(redis, asha, ravi, mid)
    won: dict[str, Any] = (await asha.expect("match.settled"))["d"]
    lost: dict[str, Any] = (await ravi.expect("match.settled"))["d"]

    assert in_battle == "in_battle"
    # Balances include any coins the first battle's achievements paid.
    assert won["coins"] == {
        "delta": 10,
        "balance": await balance(sessions, asha.user_id),
        "capped": False,
    }
    assert lost["coins"] == {
        "delta": 0,
        "balance": await balance(sessions, ravi.user_id),
        "capped": False,
    }
    assert await ledger(sessions, asha.user_id) == [(-5, "match_entry"), (10, "match_pot")]
    assert await ledger(sessions, ravi.user_id) == [(-5, "match_entry")]
    assert await hold_states(sessions, [asha.user_id, ravi.user_id]) == ["captured", "captured"]
    assert won["xp"]["delta"] == 20
    assert lost["xp"]["delta"] == 8
    assert won["missions"], "today's missions come with the result"
    assert all({"id", "title", "progress", "target", "done"} <= set(m) for m in won["missions"])
    assert won["streak"]["days"] >= 0
    assert isinstance(won["achievements"], list)
    assert won["rating"] is None


async def test_an_aborted_casual_match_refunds_both_entries_on_the_ledger(
    rt: RtServer, api: AsyncClient, sessions: LockedSessions
) -> None:
    for email in ("asha@example.com", "ravi@example.com"):
        await fund(sessions, (await sign_in(api, email))["user"]["id"])
    asha, ravi, _ = await pair(rt, api, "casual")

    await asha.expect("match.end", wait_s=5)
    settled: dict[str, Any] = (await ravi.expect("match.settled"))["d"]

    assert settled["coins"] == {"delta": 5, "balance": 100, "capped": False}
    assert settled["xp"] is None
    assert await ledger(sessions, ravi.user_id) == [(-5, "match_entry"), (5, "refund")]
    assert await hold_states(sessions, [asha.user_id, ravi.user_id]) == ["released", "released"]
    assert await inbox(sessions, ravi.user_id) == ["refund"]


async def test_casual_needs_coins_on_the_wallet(rt: RtServer, api: AsyncClient) -> None:
    bot = await connect_bot(rt.url, api, await sign_in(api, "asha@example.com"), name="asha")

    reply = await bot.request(
        "mm.join",
        {"mode": "casual", "subject": "physics", "chapter": None, "idem": uuid.uuid4().hex},
    )

    assert reply["d"]["code"] == "INSUFFICIENT_COINS"
    assert reply["d"]["details"] == {"balance": 0, "needed": 5}


async def test_leaving_before_the_first_question_refunds_and_explains_the_strike(
    api: AsyncClient,
    redis: Redis,
    sessions: LockedSessions,
    rt_settings: Settings,
    plugins: Integrations,
) -> None:
    asha, ravi = await two_users(api)
    escrow = LedgerEscrow()
    holds = {}
    for user in (asha, ravi):
        await fund(sessions, user)
        async with sessions() as db:
            holds[user] = await escrow.hold(db, user_id=user, amount=5, key=f"mm:t-{user}")
            await db.commit()
    mid = await new_match(
        sessions, redis, rt_settings, (asha, ravi), kind=MatchKind.QUICK_CASUAL, holds=holds
    )

    await scripts.forfeit(redis, mid, str(asha))
    await settle_match(deps(redis, sessions, rt_settings, plugins), mid)

    for user in (asha, ravi):
        assert await ledger(sessions, user) == [(-5, "match_entry"), (5, "refund")]
    assert await inbox(sessions, asha) == ["refund", "match_aborted"]
    assert await inbox(sessions, ravi) == ["refund"]
    # Settled holds stay settled: a second release or capture moves nothing.
    async with sessions() as db:
        assert await escrow.release(db, hold_id=holds[asha], key="again") == 0
        assert await escrow.capture(db, hold_id=holds[asha], key="again") == 0


# Rated games


async def test_a_rated_game_pays_rating_xp_and_coins(
    api: AsyncClient,
    redis: Redis,
    sessions: LockedSessions,
    rt_settings: Settings,
    plugins: Integrations,
) -> None:
    asha, ravi = await two_users(api)
    mid = await new_match(sessions, redis, rt_settings, (asha, ravi))
    await play_rated(redis, mid, asha, ravi)
    published = redis.pubsub()
    await published.subscribe(keys.user_events(str(asha)))

    await settle_match(deps(redis, sessions, rt_settings, plugins), mid)
    message = None
    for _ in range(20):
        message = await published.get_message(ignore_subscribe_messages=True, timeout=0.5)
        if message is not None:
            break
    await published.aclose()

    assert message is not None
    won = orjson.loads(message["data"])["d"]
    assert won["rating"]["scope"] == "physics"
    assert won["rating"]["delta"] > 0
    assert won["coins"] == {"delta": 10, "balance": await balance(sessions, asha), "capped": False}
    assert won["xp"]["delta"] == 30
    assert won["missions"]
    assert won["streak"] is not None
    assert await ledger(sessions, asha) == [(10, "match_reward")]
    assert await ledger(sessions, ravi) == [(1, "match_reward")]


async def test_rated_coins_stop_at_150_a_day(
    api: AsyncClient,
    redis: Redis,
    sessions: LockedSessions,
    rt_settings: Settings,
    plugins: Integrations,
) -> None:
    asha, ravi = await two_users(api)
    async with sessions() as db:
        await credit(
            db,
            asha,
            145,
            reason=CoinReason.MATCH_REWARD,
            title="Earlier rated games",
            key="earlier",
            ref=Ref(RefKind.MATCH, "earlier"),
        )
        await db.commit()
    mid = await new_match(sessions, redis, rt_settings, (asha, ravi))
    await play_rated(redis, mid, asha, ravi)

    await settle_match(deps(redis, sessions, rt_settings, plugins), mid)
    async with sessions() as db:
        today = await rewards.rated_coins_today(db, asha, utc_now())

    assert today == rewards.RATED_COINS_DAILY_CAP
    assert await ledger(sessions, asha) == [(145, "match_reward"), (5, "match_reward")]


# Social and moderation guards


async def test_players_who_blocked_each_other_are_never_paired(
    rt: RtServer, api: AsyncClient
) -> None:
    asha_login = await sign_in(api, "asha@example.com")
    ravi_login = await sign_in(api, "ravi@example.com")
    blocked = await api.post(
        "/v1/blocks",
        json={"user_id": ravi_login["user"]["id"]},
        headers=bearer(asha_login["access_token"]),
    )
    asha = await connect_bot(rt.url, api, asha_login, name="asha")
    ravi = await connect_bot(rt.url, api, ravi_login, name="ravi")

    await search(asha)
    await search(ravi)

    assert blocked.status_code == 204
    await no_frame(asha, "mm.found", wait_s=0.6)


async def test_the_shadow_pool_only_plays_itself(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    asha_login = await sign_in(api, "asha@example.com")
    ravi_login = await sign_in(api, "ravi@example.com")
    async with sessions() as db:
        await apply_moderation(
            db,
            redis,
            uuid.UUID(asha_login["user"]["id"]),
            "shadow_pool",
            reason="cheating",
            now=utc_now(),
        )
    asha = await connect_bot(rt.url, api, asha_login, name="asha")
    ravi = await connect_bot(rt.url, api, ravi_login, name="ravi")

    await search(asha)
    await search(ravi)

    await no_frame(asha, "mm.found", wait_s=0.6)
    assert await redis.hget(await ticket_key(redis, asha.user_id), "shadow") == "1"


async def test_a_ban_closes_the_socket_and_forfeits_the_live_match(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions, settings: Settings
) -> None:
    asha, ravi, mid = await pair(rt, api, "rated")
    await ready_both(asha, ravi, mid)
    await asha.expect("q.show")
    async with sessions() as db:
        await apply_moderation(
            db,
            redis,
            uuid.UUID(asha.user_id),
            "temp_ban",
            reason="cheating",
            until=utc_now() + timedelta(days=1),
            now=utc_now(),
        )

    closed = await asha.wait_closed()
    await deliver(sessions, redis, settings)  # the worker's withdrawal
    ended = await ravi.expect("match.end", wait_s=5)
    settled = await ravi.expect("match.settled", wait_s=10)

    assert closed == (4403, "account banned")
    assert ended["d"]["result"] == "win"
    assert ended["d"]["reason"] == "forfeit"
    assert settled["d"]["rating"]["delta"] > 0
    assert await redis.get(presence_key(uuid.UUID(asha.user_id))) is None


async def test_a_ban_cancels_the_search_and_refunds_the_entry(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions, settings: Settings
) -> None:
    login = await sign_in(api, "asha@example.com")
    await fund(sessions, login["user"]["id"])
    asha = await connect_bot(rt.url, api, login, name="asha")
    await search(asha, mode="casual")
    async with sessions() as db:
        await apply_moderation(
            db,
            redis,
            uuid.UUID(asha.user_id),
            "perm_ban",
            reason="cheating",
            now=utc_now(),
        )

    await asha.wait_closed()
    await deliver(sessions, redis, settings)

    assert await redis.get(keys.busy(asha.user_id)) is None
    assert await ledger(sessions, asha.user_id) == [(-5, "match_entry"), (5, "refund")]


# Social reads


async def test_profiles_show_ratings_form_and_head_to_head(
    api: AsyncClient,
    redis: Redis,
    sessions: LockedSessions,
    rt_settings: Settings,
    plugins: Integrations,
) -> None:
    asha_headers = await onboarded(api, "asha")
    ravi_headers = await onboarded(api, "ravi")
    asha_me = (await api.get("/v1/me", headers=asha_headers)).json()
    ravi_me = (await api.get("/v1/me", headers=ravi_headers)).json()
    asha, ravi = uuid.UUID(asha_me["id"]), uuid.UUID(ravi_me["id"])
    mid = await new_match(sessions, redis, rt_settings, (asha, ravi))
    await play_rated(redis, mid, asha, ravi)
    await settle_match(deps(redis, sessions, rt_settings, plugins), mid)

    profile = (await api.get(f"/v1/users/{ravi_me['handle']}", headers=asha_headers)).json()
    rivals = (await api.get("/v1/me/opponents", headers=ravi_headers)).json()

    assert [r["scope"] for r in profile["ratings"]] == ["overall", "physics"]
    assert profile["ratings"][0]["rating"]["provisional"] is True
    assert profile["form"] == ["loss"]
    assert profile["h2h"] == {"wins": 1, "draws": 0, "losses": 0}
    assert rivals["items"][0]["relationship"] == "none"


async def test_deleting_the_account_ends_the_search(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions, settings: Settings
) -> None:
    login = await sign_in(api, "asha@example.com")
    asha = await connect_bot(rt.url, api, login, name="asha")
    await search(asha)

    deleted = await api.post(
        "/v1/me/delete",
        json={"confirm": "DELETE", "proof": {"provider": "dev"}},
        headers=bearer(login["access_token"]),
    )
    closed = await asha.wait_closed()
    await deliver(sessions, redis, settings)

    assert deleted.status_code == 202
    assert closed[0] == 4403
    assert await redis.get(keys.busy(asha.user_id)) is None


async def test_the_hold_reaper_keeps_holds_of_live_searches(
    api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    asha, _ = await two_users(api)
    await fund(sessions, asha)
    async with sessions() as db:
        hold_id = await LedgerEscrow().hold(db, user_id=asha, amount=5, key="mm:t1")
        await db.commit()
        record = await db.get_one(CoinHold, uuid.UUID(hold_id))
        ref = HoldRef(record.id, asha, RefKind.MATCH, record.ref_id, record.created_at)
        await redis.set(keys.busy(str(asha)), "q:t1")
        await redis.hset(keys.ticket("t1"), mapping={"hold_id": hold_id})
        searching = await match_hold_live(db, redis, ref)
        await redis.delete(keys.busy(str(asha)))
        gone = await match_hold_live(db, redis, ref)

    assert record.ref_id == "mm:t1"
    assert searching is True
    assert gone is False
