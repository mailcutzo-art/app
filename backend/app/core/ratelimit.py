"""Token-bucket rate limiting in Redis.

A bucket holds up to ``capacity`` tokens and refills continuously at ``refill_per_sec``; each
request spends ``cost`` tokens. The whole check runs in one Lua script that reads the clock with
Redis ``TIME``, so it is atomic and every api/rt replica sees the same clock.

Usage::

    @router.post("/v1/auth/nonce", dependencies=[Depends(rate_limit("auth.nonce", capacity=10,
                                                                      refill_per_sec=10 / 60))])
"""

import math
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Annotated, Literal

from fastapi import Depends
from redis.asyncio import Redis
from starlette.requests import Request

from app.core.config import SettingsDep
from app.core.errors import RateLimited
from app.core.redis import LuaScript, RedisDep
from app.core.security import CurrentUserId, client_ip

# KEYS[1] bucket; ARGV: capacity, refill per second, cost.
# Returns {allowed (0/1), whole tokens left, milliseconds until the request could succeed}.
_TOKEN_BUCKET = LuaScript(
    """
local capacity = tonumber(ARGV[1])
local rate = tonumber(ARGV[2])
local cost = tonumber(ARGV[3])
local time = redis.call('TIME')
local now_ms = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)

local state = redis.call('HMGET', KEYS[1], 'tokens', 'ts')
local tokens = tonumber(state[1])
local ts = tonumber(state[2])
if tokens == nil or ts == nil then
  tokens = capacity
  ts = now_ms
end
tokens = math.min(capacity, tokens + math.max(0, now_ms - ts) * rate / 1000)

if tokens < cost then
  return {0, math.floor(tokens), math.ceil((cost - tokens) * 1000 / rate)}
end
tokens = tokens - cost
redis.call('HSET', KEYS[1], 'tokens', tokens, 'ts', now_ms)
-- An idle bucket refills completely within this time, and a full bucket equals a missing one.
redis.call('PEXPIRE', KEYS[1], math.ceil(capacity * 1000 / rate) + 1000)
return {1, math.floor(tokens), 0}
"""
)


@dataclass(frozen=True, slots=True)
class RateLimitDecision:
    allowed: bool
    remaining: int
    retry_after_ms: int


async def consume(
    redis: Redis, key: str, *, capacity: int, refill_per_sec: float, cost: int = 1
) -> RateLimitDecision:
    """Spend ``cost`` tokens from the bucket at ``key`` if it holds enough."""
    _check_bucket(capacity, refill_per_sec, cost)
    allowed, remaining, retry_after_ms = await _TOKEN_BUCKET(
        redis, keys=[key], args=[capacity, refill_per_sec, cost]
    )
    return RateLimitDecision(bool(allowed), int(remaining), int(retry_after_ms))


def _check_bucket(capacity: int, refill_per_sec: float, cost: int) -> None:
    if capacity < 1 or refill_per_sec <= 0 or not 1 <= cost <= capacity:
        raise ValueError("need capacity >= 1, refill_per_sec > 0 and 1 <= cost <= capacity")


async def _client_identity(request: Request, settings: SettingsDep) -> str:
    return f"ip:{client_ip(request, settings.trusted_proxies)}"


async def _user_identity(user_id: CurrentUserId) -> str:
    return f"user:{user_id}"


_IDENTITIES: dict[str, Callable[..., Awaitable[str]]] = {
    "ip": _client_identity,
    "user": _user_identity,
}


def rate_limit(
    name: str,
    *,
    capacity: int,
    refill_per_sec: float,
    scope: Literal["ip", "user"] = "ip",
    cost: int = 1,
) -> Callable[..., Awaitable[None]]:
    """Build a FastAPI dependency that rejects requests over the limit with 429 + Retry-After.

    ``scope="ip"`` keys the bucket by client IP (see ``client_ip`` for proxy handling);
    ``scope="user"`` by the authenticated user, and requires authentication.
    """
    _check_bucket(capacity, refill_per_sec, cost)
    identify = _IDENTITIES[scope]

    async def enforce_rate_limit(
        identity: Annotated[str, Depends(identify)], redis: RedisDep
    ) -> None:
        decision = await consume(
            redis,
            f"rl:{name}:{identity}",
            capacity=capacity,
            refill_per_sec=refill_per_sec,
            cost=cost,
        )
        if not decision.allowed:
            raise RateLimited(retry_after=math.ceil(decision.retry_after_ms / 1000))

    return enforce_rate_limit
