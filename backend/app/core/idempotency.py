"""Idempotent POSTs: an ``Idempotency-Key`` header makes client retries safe.

Usage::

    @router.post("/v1/things", status_code=201, response_model=ThingOut)
    async def create_thing(body: ThingIn, idem: IdempotencyDep, session: SessionDep) -> Response:
        thing = await things.create(session, body)
        return await idem.complete(ThingOut.model_validate(thing), status_code=201)

The first request with a key claims it with a 60 s in-progress marker. ``complete`` commits the
DB session, stores the status and JSON body for 24 h and returns the response. Records are keyed
by (user, method + path, key) and remember a hash of the request, so:

* a retry with the same key and request gets the stored response plus ``Idempotent-Replayed:
  true``, without running the endpoint again;
* a retry while the first attempt is still running gets 409 ``IDEMPOTENCY_IN_PROGRESS``;
* the same key with a different request gets 422 ``IDEMPOTENCY_KEY_REUSED``.

If the endpoint fails, the claim is released so the client can retry with the same key. Redis
only caches responses: anything that moves coins must also carry a unique key in Postgres.
"""

import hashlib
import re
import secrets
from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Annotated, Any

import orjson
import structlog
from fastapi import Depends
from fastapi.encoders import jsonable_encoder
from redis.asyncio import Redis
from redis.exceptions import RedisError
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.requests import Request
from starlette.responses import Response

from app.core.db import SessionDep
from app.core.errors import BadRequest, Conflict, EarlyResponse, ValidationFailed
from app.core.redis import LuaScript, RedisDep
from app.core.security import CurrentUserId

IDEMPOTENCY_KEY_HEADER = "Idempotency-Key"
REPLAYED_HEADER = "Idempotent-Replayed"
IN_PROGRESS_TTL_MS = 60_000
RESULT_TTL_MS = 24 * 60 * 60 * 1000

_KEY_PATTERN = re.compile(r"[A-Za-z0-9_-]{1,64}")

log = structlog.stdlib.get_logger(__name__)

# KEYS[1] record; ARGV: owner token, request fingerprint, in-progress TTL (ms).
# Claims the key atomically (like SET NX PX) or reports what is already stored.
_CLAIM = LuaScript(
    """
local record = redis.call('HMGET', KEYS[1], 'state', 'fingerprint', 'status', 'body')
if not record[1] then
  redis.call('HSET', KEYS[1], 'state', 'in_progress', 'owner', ARGV[1], 'fingerprint', ARGV[2])
  redis.call('PEXPIRE', KEYS[1], ARGV[3])
  return {'claimed'}
end
if record[2] ~= ARGV[2] then
  return {'mismatch'}
end
if record[1] == 'in_progress' then
  return {'in_progress'}
end
return {'done', record[3], record[4]}
"""
)

# KEYS[1] record; ARGV: owner token, status, body, result TTL (ms). Only the claim owner may
# store a result (a claim that expired may have been taken over by a later attempt).
_STORE = LuaScript(
    """
if redis.call('HGET', KEYS[1], 'owner') ~= ARGV[1] then
  return 0
end
redis.call('HSET', KEYS[1], 'state', 'done', 'status', ARGV[2], 'body', ARGV[3])
redis.call('PEXPIRE', KEYS[1], ARGV[4])
return 1
"""
)

# KEYS[1] record; ARGV: owner token. Drops an unfinished claim so the client may retry.
_RELEASE = LuaScript(
    """
if redis.call('HGET', KEYS[1], 'owner') == ARGV[1]
    and redis.call('HGET', KEYS[1], 'state') == 'in_progress' then
  return redis.call('DEL', KEYS[1])
end
return 0
"""
)


@dataclass(slots=True)
class Idempotency:
    """Handle given to an endpoint that claimed an idempotency key."""

    redis: Redis
    session: AsyncSession
    record_key: str
    owner: str
    completed: bool = False

    async def complete(self, body: Any, *, status_code: int = 200) -> Response:
        """Commit the session, store the response for replays and return it.

        The commit happens first so a stored response always describes committed data.
        """
        await self.session.commit()
        self.completed = True
        content = orjson.dumps(jsonable_encoder(body))
        try:
            stored = await _STORE(
                self.redis,
                keys=[self.record_key],
                args=[self.owner, status_code, content, RESULT_TTL_MS],
            )
        except RedisError:
            # The data is committed; answer normally. A retry within the in-progress TTL gets
            # 409, a later one runs again, which is why ledgers keep their own unique keys.
            log.warning("idempotency.store_failed", exc_info=True)
        else:
            if not stored:
                log.warning("idempotency.claim_lost")
        return Response(content, status_code=status_code, media_type="application/json")

    async def release(self) -> None:
        try:
            await _RELEASE(self.redis, keys=[self.record_key], args=[self.owner])
        except RedisError:
            log.warning("idempotency.release_failed", exc_info=True)


async def _fingerprint(request: Request) -> str:
    """Hash of what the record key does not already pin down: query string and body."""
    digest = hashlib.sha256(request.url.query.encode())
    digest.update(b"\0")
    digest.update(await request.body())
    return digest.hexdigest()


async def _claim_idempotency_key(
    request: Request, user_id: CurrentUserId, redis: RedisDep, session: SessionDep
) -> AsyncIterator[Idempotency]:
    key = request.headers.get(IDEMPOTENCY_KEY_HEADER)
    if key is None:
        raise BadRequest(
            f"The {IDEMPOTENCY_KEY_HEADER} header is required.", code="IDEMPOTENCY_KEY_MISSING"
        )
    if not _KEY_PATTERN.fullmatch(key):
        raise BadRequest(
            f"The {IDEMPOTENCY_KEY_HEADER} header must be 1-64 characters from A-Z a-z 0-9 _ -.",
            code="IDEMPOTENCY_KEY_INVALID",
        )
    record_key = f"idem:{user_id}:{request.method}:{request.url.path}:{key}"
    owner = secrets.token_hex(16)
    state, *stored = await _CLAIM(
        redis, keys=[record_key], args=[owner, await _fingerprint(request), IN_PROGRESS_TTL_MS]
    )
    if state == "mismatch":
        raise ValidationFailed(
            "This Idempotency-Key was already used for a different request.",
            code="IDEMPOTENCY_KEY_REUSED",
        )
    if state == "in_progress":
        raise Conflict(
            "A request with this Idempotency-Key is still being processed.",
            code="IDEMPOTENCY_IN_PROGRESS",
        )
    if state == "done":
        status_code, content = stored
        raise EarlyResponse(
            Response(
                content,
                status_code=int(status_code),
                media_type="application/json",
                headers={REPLAYED_HEADER: "true"},
            )
        )

    handle = Idempotency(redis=redis, session=session, record_key=record_key, owner=owner)
    try:
        yield handle
    except BaseException:
        if not handle.completed:
            await handle.release()
        raise
    if not handle.completed:
        log.warning("idempotency.not_completed", path=request.url.path)
        await handle.release()


IdempotencyDep = Annotated[Idempotency, Depends(_claim_idempotency_key, scope="function")]
