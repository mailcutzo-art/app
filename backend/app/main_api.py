"""REST API process: ``uvicorn app.main_api:create_app --factory``."""

from fastapi import FastAPI
from starlette.middleware import Middleware
from starlette.middleware.cors import CORSMiddleware

from app.core.config import Settings, get_settings
from app.core.factory import create_base_app
from app.core.idempotency import IDEMPOTENCY_KEY_HEADER, REPLAYED_HEADER
from app.core.middleware import REQUEST_ID_HEADER
from app.modules.system import router as system


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    middleware = []
    if settings.cors_origins:
        middleware.append(
            Middleware(
                CORSMiddleware,
                allow_origins=settings.cors_origins,
                allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
                allow_headers=[
                    "Authorization",
                    "Content-Type",
                    IDEMPOTENCY_KEY_HEADER,
                    REQUEST_ID_HEADER,
                ],
                expose_headers=[REQUEST_ID_HEADER, REPLAYED_HEADER, "Retry-After"],
            )
        )
    app = create_base_app(settings, component="api", title="Quiz API", middleware=middleware)
    app.include_router(system.health_router)
    app.include_router(system.router, prefix="/v1")
    return app
