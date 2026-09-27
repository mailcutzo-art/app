"""Structured logging: JSON lines in prod/test, a readable console in dev, secrets and PII redacted.

Both structlog loggers and stdlib loggers (uvicorn, SQLAlchemy, Alembic, ...) are rendered by the
same handler, so every line has the same shape and passes through the same redaction.
"""

import logging
import sys
from collections.abc import Mapping
from typing import Any, TextIO

import orjson
import structlog
from structlog.types import EventDict, Processor, WrappedLogger

from app.core.config import Environment, Settings

REDACTED = "[REDACTED]"

_SENSITIVE_KEYS = frozenset(
    {
        "access_token",
        "api_key",
        "authorization",
        "cookie",
        "email",
        "id_token",
        "passwd",
        "password",
        "phone",
        "private_key",
        "refresh_token",
        "secret",
        "set_cookie",
        "ticket",
        "token",
    }
)
_SENSITIVE_SUFFIXES = ("_token", "_secret", "_password", "_email", "_phone")


def _is_sensitive(key: object) -> bool:
    if not isinstance(key, str):
        return False
    normalized = key.lower().replace("-", "_")
    return normalized in _SENSITIVE_KEYS or normalized.endswith(_SENSITIVE_SUFFIXES)


def _redact(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {k: REDACTED if _is_sensitive(k) else _redact(v) for k, v in value.items()}
    if isinstance(value, list | tuple):
        return [_redact(item) for item in value]
    return value


def redact_sensitive(_logger: WrappedLogger, _method: str, event_dict: EventDict) -> EventDict:
    """structlog processor masking values whose key names suggest secrets or PII, at any depth."""
    for key, value in list(event_dict.items()):
        if _is_sensitive(key):
            event_dict[key] = REDACTED
        elif isinstance(value, Mapping | list | tuple):
            event_dict[key] = _redact(value)
    return event_dict


def current_request_id() -> str | None:
    """The request id bound to the current context by the request middleware, if any."""
    request_id = structlog.contextvars.get_contextvars().get("request_id")
    return request_id if isinstance(request_id, str) else None


def _json_dumps(event: Any, **_: Any) -> str:
    return orjson.dumps(event, default=str, option=orjson.OPT_NON_STR_KEYS).decode()


class _AppLogHandler(logging.StreamHandler[TextIO]):
    """Marker type so reconfiguring replaces only the handler installed here."""


class _DropWebSocketConnectionLines(logging.Filter):
    """Drops the lines uvicorn logs for every WebSocket connection.

    The handshake line carries the client IP and query string; open/close lines are noise with
    thousands of sockets. The gateway logs connection outcomes itself.
    """

    _NOISE = frozenset({"connection open", "connection closed"})

    def filter(self, record: logging.LogRecord) -> bool:
        message = record.msg
        return not isinstance(message, str) or not (
            message.startswith('%s - "WebSocket ') or message in self._NOISE
        )


def configure_logging(settings: Settings) -> None:
    """Configure structlog and route stdlib logging through the same renderer. Idempotent."""
    shared: list[Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
        redact_sensitive,
    ]
    structlog.configure(
        processors=[
            structlog.stdlib.filter_by_level,
            *shared,
            structlog.processors.StackInfoRenderer(),
            structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
        ],
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=True,
    )

    renderers: list[Processor]
    if settings.env is Environment.DEV:
        renderers = [structlog.dev.ConsoleRenderer(colors=sys.stdout.isatty())]
    else:
        renderers = [
            # Never include local variables: they may hold tokens or personal data.
            structlog.processors.ExceptionRenderer(
                structlog.tracebacks.ExceptionDictTransformer(show_locals=False)
            ),
            structlog.processors.JSONRenderer(serializer=_json_dumps),
        ]
    handler = _AppLogHandler(sys.stdout)
    handler.setFormatter(
        structlog.stdlib.ProcessorFormatter(
            foreign_pre_chain=shared,
            processors=[structlog.stdlib.ProcessorFormatter.remove_processors_meta, *renderers],
        )
    )

    root = logging.getLogger()
    for existing in [h for h in root.handlers if isinstance(h, _AppLogHandler)]:
        root.removeHandler(existing)
    root.addHandler(handler)
    root.setLevel(settings.log_level)

    # Uvicorn installs its own handlers. Send its error log through ours, and silence its access
    # lines: the request middleware writes them without query strings (which may carry secrets)
    # or client IPs (personal data, kept only in security events).
    for name in ("uvicorn", "uvicorn.error"):
        uvicorn_logger = logging.getLogger(name)
        uvicorn_logger.handlers.clear()
        uvicorn_logger.propagate = True
    error_logger = logging.getLogger("uvicorn.error")
    error_logger.filters = [
        *(f for f in error_logger.filters if not isinstance(f, _DropWebSocketConnectionLines)),
        _DropWebSocketConnectionLines(),
    ]
    access_logger = logging.getLogger("uvicorn.access")
    access_logger.handlers.clear()
    access_logger.propagate = False
    access_logger.disabled = True
    # httpx logs every request's full URL, query string included, at INFO.
    for name in ("httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.WARNING)
