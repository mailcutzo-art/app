"""Coins: postings, holds, payouts, the welcome bonus, the reaper and the wallet endpoints."""

import uuid
from collections.abc import Iterator
from datetime import timedelta

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import func, select, text
from sqlalchemy.exc import DBAPIError, IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import utc_now
from app.core.errors import Conflict
from app.modules.economy import jobs as economy_jobs
from app.modules.economy.jobs import HoldRef, reap_stuck_holds, register_liveness
from app.modules.economy.models import (
    CoinHold,
    CoinReason,
    HoldStatus,
    LedgerEntry,
    RefKind,
    Wallet,
)
from app.modules.economy.service import (
    InsufficientCoins,
    Ref,
    WalletView,
    capture_hold,
    credit,
    debit,
    get_wallet,
    hold,
    pop_welcome,
    release_hold,
    settle_pot,
    transfer,
)
from app.modules.notifications.models import Notification
from tests.platform_helpers import bare_user, onboarded, user_id

MATCH = Ref(RefKind.MATCH, "m-1")


async def entries(db: AsyncSession, user: uuid.UUID) -> list[tuple[int, int, str]]:
    rows = await db.execute(
        select(LedgerEntry.delta, LedgerEntry.balance_after, LedgerEntry.reason)
        .where(LedgerEntry.user_id == user)
        .order_by(LedgerEntry.created_at, LedgerEntry.id)
    )
    return [tuple(row) for row in rows]  # type: ignore[misc]


async def funded(db: AsyncSession, name: str, coins: int = 100) -> uuid.UUID:
    user = await bare_user(db, name)
    await credit(db, user, coins, reason=CoinReason.ADJUSTMENT, title="Start", key=f"seed:{user}")
    return user


async def test_credit_and_debit_post_entries_and_move_the_balance(db_session: AsyncSession) -> None:
    user = await bare_user(db_session)

    first = await credit(
        db_session,
        user,
        30,
        reason=CoinReason.LEVEL_UP,
        title="Level 2",
        key="lvl:2",
        ref=Ref(RefKind.LEVEL, "2"),
    )
    spent = await debit(db_session, user, 5, reason=CoinReason.HINT, title="Hint", key="hint:1")

    assert (first.entry.delta, first.entry.balance_after, first.replayed) == (30, 30, False)
    assert (first.entry.ref_kind, first.entry.ref_id, first.entry.bucket) == (
        "level",
        "2",
        "earned",
    )
    assert (spent.entry.delta, spent.entry.balance_after) == (-5, 25)
    assert await get_wallet(db_session, user) == economy_wallet(25, 0)


def economy_wallet(balance: int, held: int) -> WalletView:
    return WalletView(balance=balance, held=held, purchased=0)


async def test_postings_are_idempotent_even_after_the_coins_are_spent(
    db_session: AsyncSession,
) -> None:
    user = await funded(db_session, "asha", 10)
    first = await debit(db_session, user, 10, reason=CoinReason.HINT, title="Hint", key="hint:a")

    replay = await debit(db_session, user, 10, reason=CoinReason.HINT, title="Hint", key="hint:a")

    assert replay.replayed is True
    assert replay.entry.id == first.entry.id
    assert (await get_wallet(db_session, user)).balance == 0


async def test_a_debit_never_takes_the_balance_below_zero(db_session: AsyncSession) -> None:
    user = await funded(db_session, "asha", 4)

    with pytest.raises(InsufficientCoins) as caught:
        await debit(db_session, user, 5, reason=CoinReason.MATCH_ENTRY, title="Entry", key="e:1")

    assert caught.value.code == "INSUFFICIENT_COINS"
    assert caught.value.http_status == 409
    assert caught.value.details == {"needed": 5, "balance": 4}
    assert await entries(db_session, user) == [(4, 4, "adjustment")]
    # The database refuses a negative balance too.
    with pytest.raises(IntegrityError, match="ck_wallets_balance"):
        async with db_session.begin_nested():
            await db_session.execute(text("UPDATE wallets SET balance = -1"))


async def test_a_key_belongs_to_one_user(db_session: AsyncSession) -> None:
    asha, bea = await funded(db_session, "asha"), await funded(db_session, "bea")
    await credit(db_session, asha, 1, reason=CoinReason.ADJUSTMENT, title="x", key="shared")

    with pytest.raises(ValueError, match="belongs to another user"):
        await credit(db_session, bea, 1, reason=CoinReason.ADJUSTMENT, title="x", key="shared")


async def test_the_ledger_is_append_only(db_session: AsyncSession) -> None:
    user = await funded(db_session, "asha")

    for statement in (
        "UPDATE coin_ledger SET delta = 1000",
        "DELETE FROM coin_ledger",
        "TRUNCATE coin_ledger",
    ):
        with pytest.raises(DBAPIError, match="append-only"):
            async with db_session.begin_nested():
                await db_session.execute(text(statement))
    assert await entries(db_session, user) == [(100, 100, "adjustment")]


async def test_hold_then_capture(db_session: AsyncSession) -> None:
    user = await funded(db_session, "asha", 20)

    placed = await hold(
        db_session,
        user,
        5,
        reason=CoinReason.MATCH_ENTRY,
        title="Casual battle entry",
        key="q:1",
        ref=MATCH,
    )
    again = await hold(
        db_session,
        user,
        5,
        reason=CoinReason.MATCH_ENTRY,
        title="Casual battle entry",
        key="q:1",
        ref=MATCH,
    )

    assert again.replayed is True
    assert again.hold.id == placed.hold.id
    assert await get_wallet(db_session, user) == economy_wallet(15, 5)
    captured = await capture_hold(db_session, placed.hold.id)
    assert captured.status == HoldStatus.CAPTURED
    assert captured.settled_at is not None
    assert (await capture_hold(db_session, placed.hold.id)).status == HoldStatus.CAPTURED
    assert await get_wallet(db_session, user) == economy_wallet(15, 0)
    assert await entries(db_session, user) == [(20, 20, "adjustment"), (-5, 15, "match_entry")]
    with pytest.raises(Conflict, match="already spent") as caught:
        await release_hold(db_session, placed.hold.id)
    assert caught.value.code == "HOLD_SETTLED"


async def test_hold_then_release_refunds(db_session: AsyncSession) -> None:
    user = await funded(db_session, "asha", 5)
    placed = await hold(
        db_session,
        user,
        5,
        reason=CoinReason.TOURNAMENT_ENTRY,
        title="Tournament entry",
        key="t:1",
        ref=Ref(RefKind.TOURNAMENT, "t-1"),
    )
    with pytest.raises(InsufficientCoins):
        await hold(
            db_session, user, 1, reason=CoinReason.MATCH_ENTRY, title="x", key="q:2", ref=MATCH
        )

    released = await release_hold(db_session, placed.hold.id, title="Refund: tournament cancelled")
    await release_hold(db_session, placed.hold.id)  # idempotent

    assert released.status == HoldStatus.RELEASED
    assert await get_wallet(db_session, user) == economy_wallet(5, 0)
    refund = await db_session.scalar(
        select(LedgerEntry).where(LedgerEntry.idempotency_key == f"hold:{placed.hold.id}:release")
    )
    assert refund is not None
    assert (refund.delta, refund.reason, refund.title) == (
        5,
        "refund",
        "Refund: tournament cancelled",
    )
    assert (refund.ref_kind, refund.ref_id) == ("tournament", "t-1")
    with pytest.raises(Conflict, match="already returned"):
        await capture_hold(db_session, placed.hold.id)


async def test_settle_pot_pays_the_winner_splits_a_draw_and_refunds_an_abort(
    db_session: AsyncSession,
) -> None:
    asha, bea = await funded(db_session, "asha", 5), await funded(db_session, "bea", 5)

    async def entry_holds(match: str) -> list[uuid.UUID]:
        ref = Ref(RefKind.MATCH, match)
        placed = [
            await hold(
                db_session,
                user,
                5,
                reason=CoinReason.MATCH_ENTRY,
                title="Casual battle entry",
                key=f"m:{match}:{user}:entry",
                ref=ref,
            )
            for user in (asha, bea)
        ]
        return [item.hold.id for item in placed]

    won = await settle_pot(
        db_session,
        await entry_holds("m1"),
        [asha],
        title="Casual battle won",
        key="m:m1:pot",
        ref=MATCH,
    )
    assert (won.pot, won.payouts, won.refunded) == (10, {asha: 10}, False)
    assert (await get_wallet(db_session, asha)).balance == 10
    assert (await get_wallet(db_session, bea)).balance == 0
    # Settling again changes nothing.
    holds_m1 = list(await db_session.scalars(select(CoinHold.id).where(CoinHold.ref_id == "m1")))
    await settle_pot(
        db_session, holds_m1, [asha], title="Casual battle won", key="m:m1:pot", ref=MATCH
    )
    assert (await get_wallet(db_session, asha)).balance == 10

    await credit(db_session, bea, 5, reason=CoinReason.ADJUSTMENT, title="x", key="top-up")
    draw = await settle_pot(
        db_session,
        await entry_holds("m2"),
        [asha, bea],
        title="Casual battle draw",
        key="m:m2:pot",
        ref=MATCH,
    )
    assert draw.payouts == {asha: 5, bea: 5}

    aborted = await settle_pot(
        db_session, await entry_holds("m3"), [], title="-", key="m:m3:pot", ref=MATCH
    )
    assert aborted.refunded is True
    assert await get_wallet(db_session, asha) == economy_wallet(10, 0)
    assert await get_wallet(db_session, bea) == economy_wallet(5, 0)


async def test_transfer_moves_coins_between_players(db_session: AsyncSession) -> None:
    asha, bea = await funded(db_session, "asha", 10), await bare_user(db_session, "bea")

    out, into = await transfer(
        db_session,
        asha,
        bea,
        7,
        reason=CoinReason.TRANSFER,
        title_from="Sent",
        title_to="Received",
        key="gift:1",
    )

    assert (out.entry.delta, into.entry.delta) == (-7, 7)
    assert (await get_wallet(db_session, asha)).balance == 3
    assert (await get_wallet(db_session, bea)).balance == 7
    with pytest.raises(InsufficientCoins):
        await transfer(
            db_session,
            asha,
            bea,
            4,
            reason=CoinReason.TRANSFER,
            title_from="Sent",
            title_to="Received",
            key="gift:2",
        )


async def test_onboarding_grants_the_welcome_bonus_once(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await onboarded(client, "asha")
    user = await user_id(client, headers)

    wallet = (await client.get("/v1/me/wallet", headers=headers)).json()

    assert wallet["balance"] == 100
    assert wallet["held"] == 0
    [welcome] = wallet["recent"]
    assert welcome["delta"] == 100
    assert welcome["balance_after"] == 100
    assert (welcome["reason"], welcome["title"]) == ("welcome", "Welcome bonus")
    assert welcome["ref"] == {"kind": "welcome", "id": str(user)}
    # Home shows it once.
    assert await pop_welcome(db_session, user, now=utc_now()) == 100
    assert await pop_welcome(db_session, user, now=utc_now()) is None


async def test_no_welcome_to_show_before_onboarding(db_session: AsyncSession) -> None:
    user = await funded(db_session, "asha")
    assert await pop_welcome(db_session, user, now=utc_now()) is None


async def test_wallet_history_pages_newest_first(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await onboarded(client, "asha")
    user = await user_id(client, headers)
    for n in range(6):
        await credit(
            db_session,
            user,
            n + 1,
            reason=CoinReason.MISSION_BONUS,
            title=f"Bonus {n}",
            key=f"b:{n}",
            ref=Ref(RefKind.MISSION, f"mission-{n}"),
        )
    await db_session.commit()

    wallet = (await client.get("/v1/me/wallet", headers=headers)).json()
    assert wallet["balance"] == 121
    assert [item["title"] for item in wallet["recent"]] == [f"Bonus {n}" for n in (5, 4, 3, 2, 1)]

    first = (await client.get("/v1/me/wallet/transactions?limit=4", headers=headers)).json()
    second = (
        await client.get(
            f"/v1/me/wallet/transactions?limit=4&cursor={first['next_cursor']}", headers=headers
        )
    ).json()
    titles = [item["title"] for item in first["items"] + second["items"]]
    assert titles == [
        "Bonus 5",
        "Bonus 4",
        "Bonus 3",
        "Bonus 2",
        "Bonus 1",
        "Bonus 0",
        "Welcome bonus",
    ]
    assert second["next_cursor"] is None
    assert first["items"][0]["ref"] == {"kind": "mission", "id": "mission-5"}

    # Another player sees only their own coins.
    other = await onboarded(client, "bea")
    theirs = (await client.get("/v1/me/wallet/transactions", headers=other)).json()
    assert [item["title"] for item in theirs["items"]] == ["Welcome bonus"]
    bad = await client.get("/v1/me/wallet/transactions?cursor=nope!", headers=headers)
    assert bad.status_code == 422


async def test_wallet_needs_sign_in(client: AsyncClient) -> None:
    assert (await client.get("/v1/me/wallet")).status_code == 401


@pytest.fixture
def liveness() -> Iterator[set[str]]:
    """Registers a liveness check for tournaments: refs in the returned set are live."""
    live: set[str] = set()

    async def check(_db: AsyncSession, _redis: Redis, ref: HoldRef) -> bool:
        return ref.ref_id in live

    register_liveness(RefKind.TOURNAMENT, check)
    yield live
    economy_jobs._LIVENESS.pop(RefKind.TOURNAMENT, None)


async def test_the_reaper_refunds_stuck_holds_nothing_live_uses(
    db_session: AsyncSession, redis: Redis, liveness: set[str]
) -> None:
    user = await funded(db_session, "asha", 30)
    stuck_match = await hold(
        db_session,
        user,
        5,
        reason=CoinReason.MATCH_ENTRY,
        title="Casual battle entry",
        key="q:stuck",
        ref=MATCH,
    )
    live_cup = await hold(
        db_session,
        user,
        10,
        reason=CoinReason.TOURNAMENT_ENTRY,
        title="Tournament entry",
        key="t:live",
        ref=Ref(RefKind.TOURNAMENT, "cup"),
    )
    captured = await hold(
        db_session,
        user,
        5,
        reason=CoinReason.MATCH_ENTRY,
        title="Casual battle entry",
        key="q:done",
        ref=Ref(RefKind.MATCH, "m-2"),
    )
    await capture_hold(db_session, captured.hold.id)
    await db_session.commit()
    liveness.add("cup")
    now = utc_now()

    assert await reap_stuck_holds(db_session, redis, now=now + timedelta(minutes=10)) == 0
    assert await reap_stuck_holds(db_session, redis, now=now + timedelta(minutes=31)) == 1

    await db_session.refresh(stuck_match.hold)
    await db_session.refresh(live_cup.hold)
    assert stuck_match.hold.status == HoldStatus.RELEASED
    assert live_cup.hold.status == HoldStatus.HELD
    assert await get_wallet(db_session, user) == economy_wallet(15, 10)
    [notice] = await db_session.scalars(select(Notification).where(Notification.user_id == user))
    assert (notice.kind, notice.title) == ("refund", "5 coins returned")

    liveness.clear()
    assert await reap_stuck_holds(db_session, redis, now=now + timedelta(minutes=31)) == 1
    assert await get_wallet(db_session, user) == economy_wallet(25, 0)
    count = await db_session.scalar(
        select(func.count()).select_from(Wallet).where(Wallet.user_id == user)
    )
    assert count == 1
