"""Request context middleware: request ids, the access log and the last-resort 500 response."""

import logging
import re
import time
from collections.abc import Collection
from http import HTTPStatus

import structlog
from starlette.datastructures import MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.core.errors import internal_error_response
from app.core.ids import new_id

REQUEST_ID_HEADER = "X-Request-ID"
# Accept caller-supplied ids only if they are short and cannot inject anything into log lines.
_REQUEST_ID_PATTERN = re.compile(r"[A-Za-z0-9._-]{8,128}")
_REQUEST_ID_HEADER_KEY = REQUEST_ID_HEADER.lower().encode("latin-1")

log = structlog.stdlib.get_logger(__name__)
access_log = structlog.stdlib.get_logger("app.access")


class RequestContextMiddleware:
    """Pure ASGI middleware; install it outermost so it sees every response.

    * Uses the incoming ``X-Request-ID`` when it is safe, otherwise generates one; echoes it on
      the response and binds it to the logging context.
    * Writes one access-log line per request: method, path (never the query string), status and
      duration. Successful probes of ``quiet_paths`` are not logged.
    * Logs unhandled exceptions and answers them with the standard 500 envelope, so no stack
      trace ever reaches the client.
    """

    def __init__(
        self, app: ASGIApp, *, quiet_paths: Collection[str] = ("/healthz", "/readyz")
    ) -> None:
        self.app = app
        self.quiet_paths = frozenset(quiet_paths)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        request_id = _incoming_request_id(scope) or new_id().hex
        status_code = 500
        response_started = False
        started_at = time.perf_counter()

        async def send_with_request_id(message: Message) -> None:
            nonlocal status_code, response_started
            if message["type"] == "http.response.start":
                response_started = True
                status_code = message["status"]
                MutableHeaders(scope=message)[REQUEST_ID_HEADER] = request_id
            await send(message)

        with structlog.contextvars.bound_contextvars(request_id=request_id):
            try:
                await self.app(scope, receive, send_with_request_id)
            except Exception:
                log.exception("http.unhandled_error")
                if response_started:
                    raise
                response = internal_error_response(request_id)
                await response(scope, receive, send_with_request_id)
            finally:
                self._log_access(scope, status_code, started_at)

    def _log_access(self, scope: Scope, status_code: int, started_at: float) -> None:
        path: str = scope["path"]
        if path in self.quiet_paths and status_code < HTTPStatus.BAD_REQUEST:
            return
        access_log.log(
            logging.ERROR if status_code >= HTTPStatus.INTERNAL_SERVER_ERROR else logging.INFO,
            "http.request",
            method=scope["method"],
            path=path,
            status=status_code,
            duration_ms=round((time.perf_counter() - started_at) * 1000, 2),
        )


def _incoming_request_id(scope: Scope) -> str | None:
    for name, value in scope["headers"]:
        if name == _REQUEST_ID_HEADER_KEY:
            candidate: str = value.decode("latin-1")
            return candidate if _REQUEST_ID_PATTERN.fullmatch(candidate) else None
    return None
