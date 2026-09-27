"""Application errors and the handlers that render every failure as one JSON envelope.

Every error response body is ``{"error": {"code", "message", "details", "request_id"}}``: raised
``AppError`` subclasses, request validation errors, Starlette/FastAPI ``HTTPException`` (including
routing 404/405), unreachable Postgres/Redis (503) and unexpected exceptions (500, never exposing
internals).
"""

import socket
from collections.abc import Mapping
from http import HTTPStatus
from typing import Any, ClassVar, cast

import orjson
import structlog
from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from redis.exceptions import ConnectionError as RedisConnectionError
from redis.exceptions import TimeoutError as RedisTimeoutError
from sqlalchemy.exc import InterfaceError, OperationalError
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.requests import Request
from starlette.responses import Response

from app.core.logging import current_request_id

log = structlog.stdlib.get_logger(__name__)

# Infrastructure failures that mean "try again later" rather than "bug": rendered as 503.
# asyncpg raises OS-level errors (refused, reset, DNS, timeout) without SQLAlchemy wrapping.
DEPENDENCY_ERRORS: tuple[type[Exception], ...] = (
    RedisConnectionError,
    RedisTimeoutError,
    OperationalError,
    InterfaceError,
    ConnectionError,
    TimeoutError,
    socket.gaierror,
)

INTERNAL_ERROR_MESSAGE = "Something went wrong on our side. Please try again."


class AppError(Exception):
    """Base class for errors that map to a specific HTTP status and stable error code."""

    http_status: ClassVar[int] = HTTPStatus.INTERNAL_SERVER_ERROR
    default_code: ClassVar[str] = "INTERNAL_ERROR"
    default_message: ClassVar[str] = INTERNAL_ERROR_MESSAGE

    def __init__(
        self,
        message: str | None = None,
        *,
        code: str | None = None,
        details: Mapping[str, Any] | None = None,
        headers: Mapping[str, str] | None = None,
    ) -> None:
        self.code = code or self.default_code
        self.message = message or self.default_message
        self.details: dict[str, Any] = dict(details or {})
        self.headers: dict[str, str] = dict(headers or {})
        super().__init__(self.message)


class BadRequest(AppError):
    http_status = HTTPStatus.BAD_REQUEST
    default_code = "BAD_REQUEST"
    default_message = "The request is malformed."


class Unauthorized(AppError):
    http_status = HTTPStatus.UNAUTHORIZED
    default_code = "UNAUTHORIZED"
    default_message = "Authentication is required."

    def __init__(
        self,
        message: str | None = None,
        *,
        code: str | None = None,
        details: Mapping[str, Any] | None = None,
    ) -> None:
        super().__init__(
            message, code=code, details=details, headers={"WWW-Authenticate": "Bearer"}
        )


class Forbidden(AppError):
    http_status = HTTPStatus.FORBIDDEN
    default_code = "FORBIDDEN"
    default_message = "You are not allowed to do this."


class NotFound(AppError):
    http_status = HTTPStatus.NOT_FOUND
    default_code = "NOT_FOUND"
    default_message = "The requested resource was not found."


class Conflict(AppError):
    http_status = HTTPStatus.CONFLICT
    default_code = "CONFLICT"
    default_message = "The request conflicts with the current state of the resource."


class ValidationFailed(AppError):
    http_status = HTTPStatus.UNPROCESSABLE_ENTITY
    default_code = "VALIDATION_FAILED"
    default_message = "The request is invalid."


class _RetryableError(AppError):
    """An error that tells the client when to retry, via ``Retry-After`` and ``details``."""

    def __init__(
        self,
        message: str | None = None,
        *,
        retry_after: int | None = None,
        code: str | None = None,
        details: Mapping[str, Any] | None = None,
    ) -> None:
        headers: dict[str, str] = {}
        merged = dict(details or {})
        self.retry_after = None if retry_after is None else max(1, retry_after)
        if self.retry_after is not None:
            headers["Retry-After"] = str(self.retry_after)
            merged["retry_after"] = self.retry_after
        super().__init__(message, code=code, details=merged, headers=headers)


class RateLimited(_RetryableError):
    http_status = HTTPStatus.TOO_MANY_REQUESTS
    default_code = "RATE_LIMITED"
    default_message = "Too many requests. Please slow down."

    def __init__(
        self,
        retry_after: int,
        message: str | None = None,
        *,
        code: str | None = None,
        details: Mapping[str, Any] | None = None,
    ) -> None:
        super().__init__(message, retry_after=retry_after, code=code, details=details)


class ServiceUnavailable(_RetryableError):
    http_status = HTTPStatus.SERVICE_UNAVAILABLE
    default_code = "SERVICE_UNAVAILABLE"
    default_message = "The service is temporarily unavailable. Please try again."


class EarlyResponse(Exception):
    """Raise from a dependency to answer with ``response`` without running the endpoint."""

    def __init__(self, response: Response) -> None:
        super().__init__("early response")
        self.response = response


def error_response(
    status_code: int,
    code: str,
    message: str,
    *,
    details: Mapping[str, Any] | None = None,
    headers: Mapping[str, str] | None = None,
    request_id: str | None = None,
) -> Response:
    """Build a response carrying the standard error envelope."""
    body = {
        "error": {
            "code": code,
            "message": message,
            "details": dict(details or {}),
            "request_id": request_id or current_request_id(),
        }
    }
    return Response(
        orjson.dumps(body, default=str),
        status_code=status_code,
        headers=headers,
        media_type="application/json",
    )


def internal_error_response(request_id: str | None = None) -> Response:
    return error_response(500, "INTERNAL_ERROR", INTERNAL_ERROR_MESSAGE, request_id=request_id)


def _render(error: AppError) -> Response:
    return error_response(
        error.http_status, error.code, error.message, details=error.details, headers=error.headers
    )


async def _handle_app_error(_request: Request, exc: Exception) -> Response:
    error = cast(AppError, exc)
    if error.http_status >= HTTPStatus.INTERNAL_SERVER_ERROR:
        log.warning("app_error", code=error.code, status=error.http_status)
    return _render(error)


async def _handle_validation_error(_request: Request, exc: Exception) -> Response:
    # Only location, message and type: the rejected input itself may contain secrets or PII.
    errors = [
        {"loc": list(item.get("loc", ())), "msg": item.get("msg", ""), "type": item.get("type", "")}
        for item in cast(RequestValidationError, exc).errors()
    ]
    return error_response(
        HTTPStatus.UNPROCESSABLE_ENTITY,
        ValidationFailed.default_code,
        ValidationFailed.default_message,
        details={"errors": errors},
    )


_HTTP_CODE_OVERRIDES = {
    HTTPStatus.UNPROCESSABLE_ENTITY: ValidationFailed.default_code,
    HTTPStatus.INTERNAL_SERVER_ERROR: "INTERNAL_ERROR",
}


async def _handle_http_exception(_request: Request, exc: Exception) -> Response:
    error = cast(StarletteHTTPException, exc)
    status_code = error.status_code
    if status_code in {HTTPStatus.NO_CONTENT, HTTPStatus.NOT_MODIFIED}:
        return Response(status_code=status_code, headers=error.headers)
    try:
        status = HTTPStatus(status_code)
        code, phrase = _HTTP_CODE_OVERRIDES.get(status, status.name), status.phrase
    except ValueError:
        code, phrase = "HTTP_ERROR", "Request failed."
    message = error.detail if isinstance(error.detail, str) and error.detail else phrase
    return error_response(status_code, code, message, headers=error.headers)


async def _handle_dependency_unavailable(_request: Request, exc: Exception) -> Response:
    log.error("dependency_unavailable", error_type=type(exc).__name__, exc_info=exc)
    return _render(ServiceUnavailable(retry_after=1))


async def _handle_early_response(_request: Request, exc: Exception) -> Response:
    return cast(EarlyResponse, exc).response


async def _handle_unexpected(_request: Request, _exc: Exception) -> Response:
    # Last resort for failures outside the request middleware, which logs and renders the
    # exceptions it sees itself; Starlette re-raises afterwards so the server logs this one.
    return internal_error_response()


def register_exception_handlers(app: FastAPI) -> None:
    app.add_exception_handler(AppError, _handle_app_error)
    app.add_exception_handler(EarlyResponse, _handle_early_response)
    app.add_exception_handler(RequestValidationError, _handle_validation_error)
    app.add_exception_handler(StarletteHTTPException, _handle_http_exception)
    for error_type in DEPENDENCY_ERRORS:
        app.add_exception_handler(error_type, _handle_dependency_unavailable)
    app.add_exception_handler(Exception, _handle_unexpected)
