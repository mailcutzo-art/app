"""Realtime process: the WebSocket gateway and the quiz engine.

Run with ``uvicorn app.main_rt:create_app --factory --timeout-graceful-shutdown 8``. On SIGTERM
uvicorn stops accepting sockets and closes the open ones with 1012 (each player gets the
restart grace); the node then hands its match leases back so another replica adopts the
matches at once, and the process exits within 10 s.
"""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.core.config import Settings, get_settings
from app.core.factory import create_base_app
from app.core.resources import Resources
from app.modules.matches import wiring as matches_wiring
from app.modules.matches.ports import Integrations, integrations
from app.modules.matches.settlement import SessionFactory
from app.modules.realtime import gateway
from app.modules.realtime.node import RtNode
from app.modules.system import router as system


def create_app(
    settings: Settings | None = None,
    *,
    sessionmaker: SessionFactory | None = None,
    plugins: Integrations | None = None,
) -> FastAPI:
    """``sessionmaker`` and ``plugins`` replace the defaults (tests)."""
    settings = settings or get_settings()
    matches_wiring.install()

    @asynccontextmanager
    async def engine(app: FastAPI, resources: Resources) -> AsyncIterator[None]:
        node = RtNode(
            settings=settings,
            redis=resources.redis,
            sessionmaker=sessionmaker or resources.sessionmaker,
            integrations=plugins or integrations,
        )
        app.state.rt_node = node
        await node.start()
        try:
            yield
        finally:
            await node.stop()

    app = create_base_app(settings, component="rt", title="Quiz realtime", services=engine)
    app.include_router(system.health_router)
    app.include_router(gateway.router, prefix="/v1")
    return app
