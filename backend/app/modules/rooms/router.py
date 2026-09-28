"""Rooms and invites over REST (``docs/api-play.md``, "Rooms and invites"), and the public
join page for room links (``/j/<code>``).

Creating a room needs an ``Idempotency-Key``; everything after it happens on the socket
(``room.join``). Code previews count wrong codes against the guess limit.
"""

import html
import uuid
from typing import Annotated
from urllib.parse import quote

from fastapi import APIRouter, Depends, Path, Response
from fastapi.responses import HTMLResponse

from app.core.clock import ClockDep
from app.core.config import SettingsDep
from app.core.db import SessionDep
from app.core.idempotency import IdempotencyDep
from app.core.ratelimit import rate_limit
from app.core.redis import RedisDep
from app.core.security import CurrentAuth
from app.modules.rooms import codes, invites, service
from app.modules.rooms.models import RoomKind
from app.modules.rooms.schemas import (
    InviteAcceptedOut,
    InviteCreatedOut,
    InviteIn,
    InvitesOut,
    RoomIn,
    RoomPreviewOut,
)

router = APIRouter(tags=["rooms"])
pages_router = APIRouter(tags=["rooms"], include_in_schema=False)

_create_limit = rate_limit("rooms.create", capacity=10, refill_per_sec=10 / 60, scope="user")
_invite_limit = rate_limit("rooms.invite", capacity=15, refill_per_sec=15 / 300, scope="user")


@router.post("/rooms", status_code=201, dependencies=[Depends(_create_limit)])
async def create_room(
    body: RoomIn,
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    settings: SettingsDep,
    clock: ClockDep,
    idem: IdempotencyDep,
) -> Response:
    """A friend duel or group lobby with you as host: ``{room_id, code, link, expires_at}``.
    ``409 BUSY`` (with ``details.active``) when you're already in a game or needed by a
    tournament before the room's game could end."""
    now = clock()
    await service.ensure_open(db, settings, now)
    created = await service.create_room(
        db, redis, settings, auth.user_id, RoomKind(body.kind), body.settings, now=now
    )
    return await idem.complete(created, status_code=201)


@router.get("/rooms/code/{code}")
async def preview_room(
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    code: Annotated[str, Path(max_length=16)],
) -> RoomPreviewOut:
    """What joining this code would mean, and whether you can (``joinable``, ``reason``).
    ``404 ROOM_NOT_FOUND`` for a code that isn't active; wrong codes are limited to 5 a minute
    and 30 an hour."""
    return await service.preview(db, redis, auth.user_id, code)


@router.post("/invites", status_code=201, dependencies=[Depends(_invite_limit)])
async def create_invite(
    body: InviteIn,
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    settings: SettingsDep,
    clock: ClockDep,
) -> InviteCreatedOut:
    """Invite a friend to your room for 2 minutes. ``409 BUSY`` when they're busy,
    ``403 NOT_ALLOWED`` for their privacy settings, a block or someone who isn't a friend."""
    return await invites.create_invite(db, redis, settings, auth.user_id, body, now=clock())


@router.get("/me/invites")
async def my_invites(auth: CurrentAuth, db: SessionDep, clock: ClockDep) -> InvitesOut:
    """Pending invites, to you and from you."""
    return await invites.list_invites(db, auth.user_id, now=clock())


@router.post("/invites/{invite_id}/accept")
async def accept_invite(
    invite_id: uuid.UUID,
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    settings: SettingsDep,
    clock: ClockDep,
) -> InviteAcceptedOut:
    """``{room_id, code}``; then ``room.join``. ``410 INVITE_EXPIRED``, ``409 BUSY``."""
    return await invites.accept_invite(db, redis, settings, auth.user_id, invite_id, now=clock())


@router.post("/invites/{invite_id}/decline", status_code=204)
async def decline_invite(
    invite_id: uuid.UUID, auth: CurrentAuth, db: SessionDep, redis: RedisDep, clock: ClockDep
) -> None:
    await invites.decline_invite(db, redis, auth.user_id, invite_id, now=clock())


@router.delete("/invites/{invite_id}", status_code=204)
async def cancel_invite(
    invite_id: uuid.UUID, auth: CurrentAuth, db: SessionDep, redis: RedisDep, clock: ClockDep
) -> None:
    await invites.cancel_invite(db, redis, auth.user_id, invite_id, now=clock())


# The room link's page: https://<domain>/j/<code>

_PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Join my Quiz Arena room</title>
<style>
  body {{ margin: 0; font-family: system-ui, sans-serif; background: #0f1222; color: #f4f5fb;
         display: flex; min-height: 100vh; align-items: center; justify-content: center; }}
  main {{ max-width: 420px; padding: 32px 20px; text-align: center; }}
  .code {{ font-size: 56px; font-weight: 800; letter-spacing: 8px; margin: 16px 0 8px;
           font-family: ui-monospace, monospace; }}
  a.button {{ display: block; margin: 12px 0; padding: 16px; border-radius: 14px;
              font-weight: 700; text-decoration: none; }}
  .open {{ background: #c6f432; color: #0f1222; }}
  .store {{ background: #262b45; color: #f4f5fb; }}
  p {{ color: #b7bbd3; }}
</style>
</head>
<body>
<main>
  <h1>You're invited to a quiz battle</h1>
  <p>Room code</p>
  <div class="code">{code}</div>
  <a class="button open" href="{app_link}">Open app</a>
  <a class="button store" href="{store_link}">Get it on Google Play</a>
  <p>New here? Install the app; the code is saved and you'll land in the room after sign-in.
  You can also type it in Battle &rarr; Join with code.</p>
</main>
</body>
</html>
"""


@pages_router.get("/j/{code}", response_class=HTMLResponse)
async def join_page(code: Annotated[str, Path(max_length=32)], settings: SettingsDep) -> Response:
    """The page a shared room link opens: the code in big type, "Open app" (the app) and
    the Play Store listing with the code in the install referrer. No sign-in, no lookup: the
    page never says whether a code is live."""
    normalized = codes.normalize(code)
    if normalized is None:
        return HTMLResponse("<!doctype html><title>Not found</title>Not found", status_code=404)
    # An Android intent link opens the installed app on this very URL (its App Link).
    link = service.room_link(settings, normalized).split("://", 1)[-1]
    app_link = f"intent://{link}#Intent;scheme=https;package={settings.android_package};end"
    referrer = quote(f"room_code={normalized}", safe="")
    store = (
        "https://play.google.com/store/apps/details"
        f"?id={quote(settings.android_package)}&referrer={referrer}"
    )
    page = _PAGE.format(
        code=html.escape(normalized), app_link=html.escape(app_link), store_link=html.escape(store)
    )
    return HTMLResponse(page, headers={"Cache-Control": "public, max-age=300"})
