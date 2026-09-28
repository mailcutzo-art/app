"""Shared fixtures: a real Postgres and Redis, isolated per test.

Start them with ``scripts/dev_services.sh start``. Defaults target the ``quiz_test`` database and
Redis DB 15; ``APP_DATABASE_URL`` / ``APP_REDIS_URL`` override them (CI), but the database name
must end in ``_test`` because every test runs migrations against it and flushes Redis.

Isolation: each test runs inside one outer transaction that is rolled back afterwards. App
sessions join it with ``join_transaction_mode="create_savepoint"``, so code that calls
``commit()`` works normally but only releases a SAVEPOINT. The Redis test database is flushed
before every test that uses the ``redis`` or ``client`` fixture.
"""

from collections.abc import AsyncIterator

import httpx
import pytest
from alembic import command
from fastapi import FastAPI
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import (
    AsyncConnection,
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.core.clock import get_clock, utc_now
from app.core.config import Settings
from app.core.db import get_sessionmaker
from app.main_api import create_app
from app.modules.auth.google import GoogleIdTokenVerifier, JwksCache, get_google_verifier
from app.modules.content.loader import load_content
from app.modules.content.seed import seed_content
from app.modules.matches.ports import Integrations, NoopEscrow, default_integrations
from tests.helpers import (
    CONTENT_DIR,
    FakeClock,
    alembic_config,
    google_certs_transport,
    make_settings,
    serve,
)
from tests.rt_helpers import LockedSessions, RtServer, fast_settings, run_rt


@pytest.fixture(scope="session")
def settings() -> Settings:
    settings = make_settings()
    database = make_url(settings.database_url.get_secret_value()).database or ""
    if not database.endswith("_test"):
        pytest.exit(
            f"Refusing to run tests against database {database!r}: its name must end in '_test'.",
            returncode=2,
        )
    return settings


@pytest.fixture(scope="session")
async def engine(settings: Settings) -> AsyncIterator[AsyncEngine]:
    """Migrated, and loaded with the repository's question bank (committed; the seed is
    idempotent, so reruns change nothing)."""
    engine = create_async_engine(settings.database_url.get_secret_value())
    async with engine.begin() as connection:
        await connection.run_sync(lambda sync: command.upgrade(alembic_config(sync), "head"))
    async with async_sessionmaker(engine)() as db:
        await seed_content(db, load_content(CONTENT_DIR), now=utc_now())
        await db.commit()
    yield engine
    await engine.dispose()


@pytest.fixture
async def db_connection(engine: AsyncEngine) -> AsyncIterator[AsyncConnection]:
    """A connection inside a transaction that is rolled back when the test ends."""
    async with engine.connect() as connection:
        transaction = await connection.begin()
        try:
            yield connection
        finally:
            await transaction.rollback()


@pytest.fixture
def session_factory(db_connection: AsyncConnection) -> async_sessionmaker[AsyncSession]:
    """Sessions bound to the test transaction; their ``commit()`` releases a SAVEPOINT."""
    return async_sessionmaker(
        bind=db_connection, expire_on_commit=False, join_transaction_mode="create_savepoint"
    )


@pytest.fixture
async def db_session(
    session_factory: async_sessionmaker[AsyncSession],
) -> AsyncIterator[AsyncSession]:
    async with session_factory() as session:
        yield session


@pytest.fixture
async def redis(settings: Settings) -> AsyncIterator[Redis]:
    """A client on the (flushed) test Redis database."""
    client = Redis.from_url(settings.redis_url.get_secret_value(), decode_responses=True)
    await client.flushdb()
    yield client
    await client.aclose()


@pytest.fixture
def clock() -> FakeClock:
    """The app's clock: real time until a test advances it."""
    return FakeClock()


@pytest.fixture
async def google_http() -> AsyncIterator[httpx.AsyncClient]:
    """An HTTP client on which Google's certs URL serves the local test keys."""
    async with httpx.AsyncClient(transport=google_certs_transport()) as client:
        yield client


@pytest.fixture
def app(settings: Settings, clock: FakeClock, google_http: httpx.AsyncClient) -> FastAPI:
    """The REST app with a controllable clock and Google keys served locally.

    Tests may add routes or overrides before using ``client``.
    """
    app = create_app(settings)
    jwks = JwksCache()
    app.dependency_overrides[get_clock] = lambda: clock
    app.dependency_overrides[get_google_verifier] = lambda: GoogleIdTokenVerifier(
        client_ids=settings.google_client_ids, jwks=jwks, http=google_http
    )
    return app


@pytest.fixture
async def client(
    app: FastAPI, session_factory: async_sessionmaker[AsyncSession], redis: Redis
) -> AsyncIterator[AsyncClient]:
    """A client for ``app`` whose DB sessions join the test transaction (Redis is flushed)."""
    app.dependency_overrides[get_sessionmaker] = lambda: session_factory
    async with serve(app) as http_client:
        yield http_client


# Realtime: an rt server in-process, and a REST client whose sessions share its lock.


@pytest.fixture
def sessions(session_factory: async_sessionmaker[AsyncSession]) -> LockedSessions:
    return LockedSessions(session_factory)


@pytest.fixture
async def api(app: FastAPI, sessions: LockedSessions, redis: Redis) -> AsyncIterator[AsyncClient]:
    """Like ``client``, for tests that also run an rt server (Redis is flushed)."""
    app.dependency_overrides[get_sessionmaker] = lambda: sessions
    async with serve(app) as http_client:
        yield http_client


@pytest.fixture
def rt_settings() -> Settings:
    return fast_settings()


@pytest.fixture
def plugins() -> Integrations:
    """Fresh integrations per test: in-memory escrow, match XP."""
    integrations = default_integrations()
    integrations.escrow = NoopEscrow()
    return integrations


@pytest.fixture
async def rt(
    rt_settings: Settings, sessions: LockedSessions, plugins: Integrations, api: AsyncClient
) -> AsyncIterator[RtServer]:
    async with run_rt(rt_settings, sessions, plugins) as server:
        yield server
