"""Realtime process (WebSocket gateway, later the quiz engine).

Run with ``uvicorn app.main_rt:create_app --factory``.
"""

from fastapi import FastAPI

from app.core.config import Settings, get_settings
from app.core.factory import create_base_app
from app.modules.realtime import gateway
from app.modules.system import router as system


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    app = create_base_app(settings, component="rt", title="Quiz realtime")
    app.include_router(system.health_router)
    app.include_router(gateway.router, prefix="/v1")
    return app
