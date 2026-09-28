"""The Arena REST API: cards and filters, registration errors, withdrawal, check-in, detail,
standings, the busy check, Home's next tournament and the Hall of Fame."""

import uuid
from datetime import timedelta
from typing import Any

from httpx import AsyncClient
from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.clock import utc_now
from app.modules.economy.models import CoinReason
from app.modules.economy.service import debit
from app.modules.matches.busy import check_busy
from app.modules.tournaments import service
from app.modules.tournaments.models import (
    Tournament,
    TournamentEntry,
    TournamentPrize,
    TournamentStatus,
)
from app.modules.users.models import User
from tests.helpers import FakeClock, make_settings
from tests.learn_helpers import player, signin
from tests.platform_helpers import user_id
from tests.tournament_helpers import funded_user, make_tournament

S = TournamentStatus


def idem() -> dict[str, str]:
    return {"Idempotency-Key": uuid.uuid4().hex}


async def open_tournament(
    session_factory: async_sessionmaker[AsyncSession], clock: FakeClock, **kwargs: Any
) -> Tournament:
    async with session_factory() as db:
        t = await make_tournament(db, now=clock.now, reg_opens_in=timedelta(minutes=-60), **kwargs)
        t.status = S.REG_OPEN.value
        await db.commit()
    return t


async def test_register_withdraw_and_the_card(
    client: AsyncClient, session_factory: async_sessionmaker[AsyncSession], clock: FakeClock
) -> None:
    headers = await player(client, "asha")
    t = await open_tournament(session_factory, clock, fee=25, pool=2500, min_players=8)

    listed = await client.get("/v1/tournaments?status=open", headers=headers)
    assert listed.status_code == 200
    card = next(c for c in listed.json()["items"] if c["id"] == str(t.id))
    assert card["me"] is None
    assert card["players"] == 0
    assert card["subject"] == "physics"
    assert (await client.get("/v1/tournaments?status=upcoming", headers=headers)).json()[
        "items"
    ] == []

    first = await client.post(f"/v1/tournaments/{t.id}/register", headers={**headers, **idem()})
    assert first.status_code == 200, first.text
    body = first.json()
    assert body["me"] == {"registered": True, "checked_in": False, "withdrawn": False}
    assert body["players"] == 1
    assert body["effective_pool"] == 2500 // 32
    wallet = (await client.get("/v1/me/wallet", headers=headers)).json()
    assert wallet["held"] == 25

    detail = (await client.get(f"/v1/tournaments/{t.id}", headers=headers)).json()
    assert detail["rules"]["questions"] == 10
    assert detail["current_round"] is None
    assert detail["prizes"][0]["from"] == 1
    assert detail["me"]["next_pairing"] is None
    assert len(detail["schedule"]) == detail["rounds"]

    mine = (await client.get("/v1/me/tournaments", headers=headers)).json()
    assert [item["id"] for item in mine["items"]] == [str(t.id)]

    left = await client.delete(f"/v1/tournaments/{t.id}/register", headers=headers)
    assert left.status_code == 200
    assert left.json()["refunded"] == 25
    assert left.json()["tournament"]["players"] == 0
    again = await client.delete(f"/v1/tournaments/{t.id}/register", headers=headers)
    assert again.status_code == 409
    assert again.json()["error"]["code"] == "NOT_REGISTERED"


async def test_registration_errors(
    client: AsyncClient, session_factory: async_sessionmaker[AsyncSession], clock: FakeClock
) -> None:
    headers = await player(client, "ravi")
    jee = await player(client, "jai", goal="jee")
    me = await user_id(client, headers)

    async def register(t: Tournament, who: dict[str, str] = headers) -> dict[str, Any]:
        response = await client.post(f"/v1/tournaments/{t.id}/register", headers={**who, **idem()})
        return {**response.json(), "http": response.status_code}

    closed = await open_tournament(session_factory, clock)
    async with session_factory() as db:
        await db.execute(
            update(Tournament).where(Tournament.id == closed.id).values(status=S.LOCKED.value)
        )
        await db.commit()
    assert (await register(closed))["error"]["code"] == "REGISTRATION_CLOSED"

    exam = await register(await open_tournament(session_factory, clock), jee)
    assert exam["http"] == 403
    assert exam["error"]["details"]["reason"] == "exam"

    full = await open_tournament(session_factory, clock, capacity=4, title="Tiny")
    async with session_factory() as db:
        for i in range(4):
            await service.register(
                db, make_settings(), full.id, await funded_user(db, f"f{i}"), now=clock.now
            )
        await db.commit()
    assert (await register(full))["error"]["code"] == "TOURNAMENT_FULL"

    rich = await open_tournament(session_factory, clock, fee=50, starts_in=timedelta(days=2))
    async with session_factory() as db:
        balance = (await client.get("/v1/me/wallet", headers=headers)).json()["balance"]
        await debit(
            db, me, balance - 10, reason=CoinReason.ADJUSTMENT, title="Spent", key=f"spend:{me}"
        )
        await db.commit()
    poor = await register(rich)
    assert poor["http"] == 409
    assert poor["error"]["code"] == "INSUFFICIENT_COINS"

    free_a = await open_tournament(session_factory, clock, fee=0, title="Free A")
    free_b = await open_tournament(
        session_factory, clock, fee=0, title="Free B", starts_in=timedelta(hours=3, minutes=20)
    )
    assert (await register(free_a))["http"] == 200
    clash = await register(free_b)
    assert clash["error"]["code"] == "SCHEDULE_CONFLICT"
    assert clash["error"]["details"]["id"] == str(free_a.id)

    # Three no-shows within 30 days block paid registration for a week.
    async with session_factory() as db:
        for days in (20, 10, 2):
            past = await make_tournament(
                db,
                now=clock.now - timedelta(days=days, hours=4),
                fee=0,
                title=f"Past {days}",
            )
            past.status = S.FINISHED.value
            db.add(TournamentEntry(tournament_id=past.id, user_id=me, no_show=True, withdrawn=True))
        await db.commit()
    paid = await open_tournament(
        session_factory, clock, fee=10, title="Paid", starts_in=timedelta(days=3)
    )
    blocked = await register(paid)
    assert blocked["http"] == 403
    assert blocked["error"]["details"]["reason"] == "no_shows"


async def test_check_in_window_and_busy(
    client: AsyncClient,
    session_factory: async_sessionmaker[AsyncSession],
    clock: FakeClock,
    redis: Any,
) -> None:
    headers = await player(client, "mira")
    me = await user_id(client, headers)
    t = await open_tournament(session_factory, clock, fee=0, starts_in=timedelta(minutes=40))
    response = await client.post(f"/v1/tournaments/{t.id}/register", headers={**headers, **idem()})
    assert response.status_code == 200
    early = await client.post(f"/v1/tournaments/{t.id}/check-in", headers=headers)
    assert early.status_code == 409
    assert early.json()["error"]["code"] == "CHECK_IN_CLOSED"

    # A 20-minute game can't start: it could still be running 2 minutes before the start.
    async with session_factory() as db:
        soon = await check_busy(
            db, redis, me, int((clock.now + timedelta(minutes=39)).timestamp() * 1000)
        )
        later = await check_busy(
            db, redis, me, int((clock.now + timedelta(minutes=10)).timestamp() * 1000)
        )
    assert soon is not None
    assert soon.kind == "tournament"
    assert soon.id == str(t.id)
    assert later is None

    clock.advance(minutes=30)  # T - 10 min
    headers = await signin(client, "mira")
    ok = await client.post(f"/v1/tournaments/{t.id}/check-in", headers=headers)
    assert ok.status_code == 200
    assert ok.json()["me"]["checked_in"] is True
    other = await player(client, "noor")
    stranger = await client.post(f"/v1/tournaments/{t.id}/check-in", headers=other)
    assert stranger.json()["error"]["code"] == "NOT_REGISTERED"
    clock.advance(minutes=9)  # T - 1 min
    headers = await signin(client, "mira")
    late = await client.post(f"/v1/tournaments/{t.id}/check-in", headers=headers)
    assert late.json()["error"]["code"] == "CHECK_IN_CLOSED"

    async with session_factory() as db:
        user = await db.get_one(User, me)
        home = await service.next_tournament(db, make_settings(), user, clock.now)
    assert home is not None
    assert home["id"] == str(t.id)


async def test_standings_hall_of_fame_and_account_deletion_hooks(
    client: AsyncClient, session_factory: async_sessionmaker[AsyncSession], clock: FakeClock
) -> None:
    headers = await player(client, "zoya")
    me = await user_id(client, headers)
    async with session_factory() as db:
        t = await make_tournament(db, now=clock.now - timedelta(hours=5), title="Old Cup")
        t.status = S.FINISHED.value
        t.finished_at = clock.now - timedelta(hours=1)
        for rank, user in enumerate([me, await funded_user(db, "second")], start=1):
            db.add(
                TournamentEntry(
                    tournament_id=t.id,
                    user_id=user,
                    checked_in=True,
                    points=3 - rank,
                    wins=3 - rank,
                    rank=rank,
                    final_rank=rank,
                )
            )
        db.add(TournamentPrize(tournament_id=t.id, user_id=me, place=1, amount=100))
        await db.commit()
    table = (await client.get(f"/v1/tournaments/{t.id}/standings", headers=headers)).json()
    assert [row["position"] for row in table["items"]] == [1, 2]
    assert table["me"]["points"] == 2
    assert table["items"][0]["user"]["id"] == str(me)
    games = await client.get(f"/v1/tournaments/{t.id}/me", headers=headers)
    assert games.status_code == 200
    assert games.json()["rank"] == 1
    finished = (await client.get("/v1/tournaments?status=finished", headers=headers)).json()
    assert str(t.id) in [c["id"] for c in finished["items"]]
    mine = (await client.get("/v1/me/tournaments", headers=headers)).json()["items"][0]
    assert mine["final_rank"] == 1
    assert mine["prize"] == 100
    async with session_factory() as db:
        fame = await service.hall_of_fame(db, "physics", "neet")
    assert fame[0]["tournament_id"] == str(t.id)
    assert fame[0]["winner"]["id"] == str(me)

    # Deleting the account withdraws (and refunds) an upcoming registration.
    upcoming = await open_tournament(session_factory, clock, fee=10, title="Next")
    response = await client.post(
        f"/v1/tournaments/{upcoming.id}/register", headers={**headers, **idem()}
    )
    assert response.status_code == 200
    from app.modules.tournaments.wiring import withdraw_on_delete

    async with session_factory() as db:
        await withdraw_on_delete(db, me, utc_now())
        entry = await db.get_one(TournamentEntry, (upcoming.id, me), populate_existing=True)
        assert entry.withdrawn
        assert entry.withdraw_reason == "deleted"
        assert (await db.get_one(Tournament, upcoming.id, populate_existing=True)).players == 0
