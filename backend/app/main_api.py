"""REST API process: ``uvicorn app.main_api:create_app --factory``."""

from fastapi import FastAPI
from starlette.middleware import Middleware
from starlette.middleware.cors import CORSMiddleware

from app.core.config import Settings, get_settings
from app.core.factory import create_base_app
from app.core.idempotency import IDEMPOTENCY_KEY_HEADER, REPLAYED_HEADER
from app.core.middleware import REQUEST_ID_HEADER
from app.modules.analytics import router as analytics
from app.modules.auth import router as auth
from app.modules.auth.google import JwksCache
from app.modules.coach import router as coach
from app.modules.content import router as content
from app.modules.economy import router as economy
from app.modules.feedback import router as feedback
from app.modules.matches import router as matches
from app.modules.matches import wiring as matches_wiring
from app.modules.moderation import router as moderation
from app.modules.notifications import router as notifications
from app.modules.notifications import wiring as notification_wiring
from app.modules.practice import router as practice
from app.modules.progression import router as progression
from app.modules.realtime import router as realtime
from app.modules.rooms import router as rooms
from app.modules.social import router as social
from app.modules.system import router as system
from app.modules.system.runtime import APP_BUILD_HEADER, ClientGates, RuntimeConfigCache
from app.modules.users import router as users


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
                    APP_BUILD_HEADER,
                ],
                expose_headers=[REQUEST_ID_HEADER, REPLAYED_HEADER, "Retry-After"],
            )
        )
    notification_wiring.install()
    matches_wiring.install()
    app = create_base_app(settings, component="api", title="Quiz API", middleware=middleware)
    app.state.google_jwks = JwksCache()
    app.state.runtime_config = RuntimeConfigCache()
    # Always reachable: the probes, /v1/config and sign-in/refresh, so an app can learn that
    # it must update or that maintenance is on.
    app.include_router(system.health_router)
    app.include_router(system.router, prefix="/v1")
    app.include_router(auth.router, prefix="/v1")
    if settings.dev_login_enabled:
        app.include_router(auth.dev_router, prefix="/v1")
    # Live games must be able to finish on an old build or during maintenance: a socket ticket
    # (the gateway decides the rest).
    app.include_router(realtime.router, prefix="/v1")
    # A game in progress can always show its result.
    app.include_router(matches.matches_router, prefix="/v1")
    # Room links (/j/<code>) open a public page: no sign-in, no gates.
    app.include_router(rooms.pages_router)
    # Everything else answers 426 UPDATE_REQUIRED to old builds and 503 during maintenance.
    for router in (
        auth.sessions_router,
        users.router,
        content.router,
        practice.router,
        progression.router,
        coach.router,
        economy.router,
        notifications.router,
        analytics.router,
        feedback.router,
        social.router,
        moderation.router,
        matches.router,
        rooms.router,
    ):
        app.include_router(router, prefix="/v1", dependencies=[ClientGates])
    if settings.admin_enabled:
        # Imported only when enabled: the panel pulls in SQLAdmin, Jinja and WTForms.
        from app.modules.admin.setup import mount_admin

        mount_admin(app, settings)
    return app
