"""Connecting the realtime engine and matches to the rest of the app, in one place.

``install()`` runs once at process start in the api, rt and worker processes (settlement runs
on rt nodes and, for retries, on the worker). It fills the engine's ports
(``app.modules.matches.ports.integrations``) with the real modules and registers the hooks
other modules expose:

- **Coins:** the casual entry on the ledger (``escrow.LedgerEscrow``), balances for the Battle
  tab and ``match.settled.coins``, and the hold reaper's liveness check for match holds.
- **Settlement:** XP, missions, streak and achievements before any wallet lock; then rated coin
  rewards, inbox notices and analytics (``rewards``).
- **Social:** blocks keep players apart in matchmaking; relationships for recent opponents;
  presence (online / in a battle) from the gateway; "played with" and the profile's ratings,
  form and head-to-head.
- **Moderation and accounts:** the shadow pool pairs only within itself; a ban or an account
  deletion withdraws the player from their search or live match (``withdraw``). Sockets are
  closed by the ban's and the deletion's own control messages (``users.control``).
- **Inbox:** abort strikes (the cooldown) are explained; refunds are told by the escrow.

Blocking someone has nothing else to cancel in live play yet: a block only matters for
pairing, which asks ``are_blocked`` at every tick.
- **Leaderboards:** leaders for the Battle tab, ``match.settled.rank``, board updates after
  settlement and positions on profiles (``app.modules.leaderboards.hooks``).
"""

import uuid
from collections.abc import Mapping, Sequence
from typing import Any

from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import utc_now
from app.modules.analytics.service import track
from app.modules.economy.jobs import register_liveness
from app.modules.economy.models import RefKind
from app.modules.leaderboards import hooks as leaderboards
from app.modules.matches import escrow, profiles, rewards, withdraw
from app.modules.matches.ports import Integrations, integrations
from app.modules.matches.shares import match_share_source
from app.modules.moderation.service import in_shadow_pool, register_ban_hook
from app.modules.notifications.service import notify
from app.modules.social import relations
from app.modules.social.presence import clear_presence, set_presence
from app.modules.social.privacy import register_have_played
from app.modules.social.profiles import register_profile_section
from app.modules.social.shares import register_share_source
from app.modules.users.deletion import on_account_deleted


async def are_blocked(db: AsyncSession, a: uuid.UUID, b: uuid.UUID) -> bool:
    return await relations.are_blocked(db, a, b)


async def shadow_pool(db: AsyncSession, user_id: uuid.UUID) -> bool:
    return await in_shadow_pool(db, user_id, now=utc_now())


async def relationships(
    db: AsyncSession, viewer_id: uuid.UUID, others: Sequence[uuid.UUID]
) -> Mapping[uuid.UUID, str]:
    found = await relations.relationships(db, viewer_id, others)
    return {user_id: relationship.value for user_id, relationship in found.items()}


async def presence(redis: Redis, user_id: uuid.UUID, state: str | None, ttl_s: int) -> None:
    if state is None:
        await clear_presence(redis, user_id)
    else:
        await set_presence(redis, user_id, state, ttl_s)


async def track_event(
    db: AsyncSession, name: str, user_id: uuid.UUID | None, props: Mapping[str, Any]
) -> None:
    await track(db, name, user_id, props, now=utc_now())


async def notices(
    db: AsyncSession, user_id: uuid.UUID, what: str, details: Mapping[str, Any]
) -> None:
    if what != "abort_strike":
        raise ValueError(f"unknown notice {what!r}")
    cooldown = details.get("cooldown_until") is not None
    await notify(
        db,
        user_id,
        kind="match_aborted",
        title="Match cancelled" if not cooldown else "Battles paused for 5 minutes",
        body=(
            "You didn't get ready or left before it started. Three of these in an hour pause "
            "your battles for 5 minutes."
            if not cooldown
            else "That was the third match cancelled on your side within an hour. You can "
            "search again in 5 minutes."
        ),
        icon="battle",
        action={"route": "/battle", "params": {}},
        key=f"match_aborted:{details['match_id']}",
    )


def connect(target: Integrations) -> Integrations:
    """Fill ``target``'s ports with the real modules (in place) and return it."""
    target.escrow = escrow.LedgerEscrow()
    target.wallet = escrow.wallet_balance
    target.are_blocked = are_blocked
    target.shadow_pool = shadow_pool
    target.relationships = relationships
    target.presence = presence
    target.track = track_event
    target.notices = notices
    target.progress_hooks.register("progression", rewards.progression_hook)
    target.hooks.register("rated_coins", rewards.rated_coins_hook)
    target.hooks.register("notices", rewards.notices_hook)
    target.hooks.register("analytics", rewards.analytics_hook)
    leaderboards.connect(target)
    return target


def production_integrations() -> Integrations:
    """A fresh, fully connected ``Integrations`` (tests use it next to the global one)."""
    return connect(Integrations())


def install() -> None:
    """Connect the global integrations and register the cross-module hooks (idempotent)."""
    connect(integrations)
    register_liveness(RefKind.MATCH, escrow.match_hold_live)
    register_have_played(profiles.have_played)
    register_profile_section("ratings", profiles.profile_ratings)
    register_profile_section("form", profiles.profile_form)
    register_profile_section("h2h", profiles.profile_h2h)
    register_ban_hook(withdraw.withdraw_on_ban)
    on_account_deleted(withdraw.withdraw_on_delete)
    register_share_source("match_result", match_share_source)
    leaderboards.install()
