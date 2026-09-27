"""Common FastAPI setup shared by the ``api`` and ``rt`` processes."""

from collections.abc import AsyncIterator, Sequence
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI
from starlette.middleware import Middleware

from app import __version__
from app.core.config import Settings
from app.core.errors import register_exception_handlers
from app.core.logging import configure_logging
from app.core.middleware import RequestContextMiddleware
from app.core.resources import open_resources

log = structlog.stdlib.get_logger(__name__)


def create_base_app(
    settings: Settings,
    *,
    component: str,
    title: str,
    middleware: Sequence[Middleware] = (),
) -> FastAPI:
    """An app with logging, the error envelope, request context and DB/Redis lifecycle.

    ``middleware`` is installed inside the request-context middleware, which stays outermost so
    every response carries a request id and gets an access-log line.
    """
    configure_logging(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        async with open_resources(settings, component=component) as resources:
            app.state.resources = resources
            log.info("app.started", component=component, env=settings.env.value)
            yield
        log.info("app.stopped", component=component)

    docs_enabled = not settings.is_prod
    app = FastAPI(
        title=title,
        version=__version__,
        lifespan=lifespan,
        docs_url="/docs" if docs_enabled else None,
        redoc_url=None,
        openapi_url="/openapi.json" if docs_enabled else None,
        middleware=[Middleware(RequestContextMiddleware), *middleware],
    )
    app.state.settings = settings
    register_exception_handlers(app)
    return app
