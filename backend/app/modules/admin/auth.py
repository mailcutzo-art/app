"""Who may use the admin panel, and how they sign in.

* **Sign-in** is Google's OAuth authorization-code flow (a web client of its own,
  ``APP_ADMIN_GOOGLE_CLIENT_ID``). The ID token from Google's token endpoint is verified like the
  app's (signature, audience, issuer, age, verified email) and its ``sub`` must belong to a user
  who signed in to the app before and has the ``admin`` role. ``state`` (CSRF) and ``nonce``
  (replay) are kept in the session until the callback.
* **The session** is a signed cookie (``APP_ADMIN_SESSION_SECRET``) scoped to ``/admin``,
  ``SameSite=Lax``, ``Secure`` in prod and ``HttpOnly``. It records the admin's id and token
  version, and every request re-checks the user: removing the role, a ban or anything that bumps
  ``token_version`` ends the session at once.
* **Every request** passes ``AdminGuard`` first: the optional IP allowlist
  (``APP_ADMIN_IP_ALLOWLIST``), and for anything but GET/HEAD/OPTIONS a same-origin check on
  ``Origin`` (or ``Referer``), which with the Lax cookie stops cross-site form posts.
* **Dev login** (``APP_DEV_LOGIN_ENABLED``, never in prod) signs in an admin by email.
"""

import hmac
import secrets
import time
import uuid
from collections.abc import Sequence
from datetime import datetime
from ipaddress import IPv4Network, IPv6Network, ip_address
from typing import Any
from urllib.parse import urlencode, urlsplit

import httpx
import jwt
import structlog
from sqladmin.authentication import AuthenticationBackend
from sqlalchemy import select
from starlette.datastructures import MutableHeaders
from starlette.requests import HTTPConnection, Request
from starlette.responses import PlainTextResponse, RedirectResponse, Response
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.core.errors import AppError
from app.modules.admin.context import AdminContext
from app.modules.auth.google import GoogleIdTokenVerifier, JwksCache
from app.modules.auth.models import AuthIdentity
from app.modules.system.models import AuditLog
from app.modules.users.models import Role, User, UserStatus

GOOGLE_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"  # noqa: S105 - a URL, not a secret
SESSION_COOKIE = "quiz_admin"
OAUTH_TTL_S = 600  # time allowed between leaving for Google and coming back
_SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})

log = structlog.stdlib.get_logger(__name__)


class AdminGuard:
    """Pure ASGI middleware in front of the whole panel: IP allowlist, same-origin writes and
    security headers. It also hands the ``AdminContext`` to the views."""

    def __init__(self, app: ASGIApp, *, context: AdminContext) -> None:
        self.app = app
        self.context = context

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        conn = HTTPConnection(scope)
        problem = self._problem(conn)
        if problem is not None:
            log.warning("admin.request_refused", reason=problem, path=scope["path"])
            response = PlainTextResponse("Forbidden", status_code=403)
            await response(scope, receive, self._with_headers(send))
            return
        scope.setdefault("state", {})["admin_context"] = self.context
        await self.app(scope, receive, self._with_headers(send))

    def _problem(self, conn: HTTPConnection) -> str | None:
        allowlist = self.context.settings.admin_ip_allowlist
        if allowlist and not _ip_allowed(self.context.client_ip(conn), allowlist):
            return "ip_not_allowed"
        if conn.scope["method"] not in _SAFE_METHODS and not _same_origin(conn):
            return "cross_origin_write"
        return None

    @staticmethod
    def _with_headers(send: Send) -> Send:
        async def send_with_headers(message: Message) -> None:
            if message["type"] == "http.response.start":
                headers = MutableHeaders(scope=message)
                headers["X-Frame-Options"] = "DENY"
                headers["Content-Security-Policy"] = "frame-ancestors 'none'"
                headers["Referrer-Policy"] = "same-origin"
                headers["X-Content-Type-Options"] = "nosniff"
                headers.setdefault("Cache-Control", "no-store")
            await send(message)

        return send_with_headers


def _ip_allowed(ip: str, allowlist: Sequence[IPv4Network | IPv6Network]) -> bool:
    try:
        address = ip_address(ip)
    except ValueError:
        return False
    return any(address in network for network in allowlist)


def _same_origin(conn: HTTPConnection) -> bool:
    """The request comes from a page of this host (``Origin``, else ``Referer``)."""
    fetch_site = conn.headers.get("sec-fetch-site")
    if fetch_site is not None and fetch_site not in ("same-origin", "none"):
        return False
    source = conn.headers.get("origin") or conn.headers.get("referer")
    host = conn.headers.get("host")
    if not source or source == "null" or not host:
        return False
    return urlsplit(source).netloc.lower() == host.lower()


class AdminAuth(AuthenticationBackend):
    def __init__(self, context: AdminContext) -> None:
        settings = context.settings
        secret = settings.admin_session_secret
        if secret is None:
            raise RuntimeError("the admin session secret is resolved during validation")
        super().__init__(
            secret_key=secret.get_secret_value(),
            session_cookie=SESSION_COOKIE,
            max_age=settings.admin_session_max_age_s,
            path="/admin",
            same_site="lax",
            https_only=settings.is_prod,
        )
        self.context = context
        self.jwks = JwksCache()

    @property
    def google_enabled(self) -> bool:
        settings = self.context.settings
        return bool(settings.admin_google_client_id and settings.admin_google_client_secret)

    async def authenticate(self, request: Request) -> bool:
        """Whether the session belongs to a current admin (checked against the database)."""
        raw_id, version = request.session.get("admin_id"), request.session.get("ver")
        if not isinstance(raw_id, str) or not isinstance(version, int):
            return False
        try:
            user_id = uuid.UUID(raw_id)
        except ValueError:
            return False
        async with self.context.sessionmaker() as db:
            user = await db.get(User, user_id)
        if (
            user is None
            or not _may_administer(user, self.context.now())
            or (user.token_version != version)
        ):
            request.session.clear()
            return False
        request.state.admin_id = user.id
        request.state.admin_user = user
        return True

    async def get_user_id(self, request: Request) -> Any:
        return getattr(request.state, "admin_id", None)

    async def login(self, request: Request) -> Response | bool:
        """The login form's POST: the dev-login shortcut (Google sign-in has its own routes)."""
        if not self.context.settings.dev_login_enabled:
            return False
        form = await request.form()
        email = str(form.get("email") or "").strip()
        if not email:
            return False
        async with self.context.sessionmaker() as db:
            users = list(await db.scalars(select(User).where(User.email == email).limit(2)))
            user = users[0] if len(users) == 1 else None
            if user is None or not _may_administer(user, self.context.now()):
                return False
            await self._start_session(db, request, user, method="dev")
        return True

    async def logout(self, request: Request) -> Response | bool:
        request.session.clear()
        return RedirectResponse(request.url_for("admin:login"), status_code=302)

    async def _start_session(self, db: Any, request: Request, user: User, *, method: str) -> None:
        request.session.clear()
        request.session.update(
            {"admin_id": str(user.id), "ver": user.token_version, "at": int(time.time())}
        )
        db.add(
            AuditLog(
                actor_id=user.id,
                action="admin.signed_in",
                entity_type="user",
                entity_id=str(user.id),
                before=None,
                after={"method": method},
                ip=self.context.client_ip(request),
            )
        )
        await db.commit()
        log.info("admin.signed_in", user_id=str(user.id), method=method)

    # Google OAuth -------------------------------------------------------------------------

    def redirect_uri(self, request: Request) -> str:
        configured = self.context.settings.admin_oauth_redirect_url
        return configured or str(request.url_for("admin:auth_callback"))

    async def google_start(self, request: Request) -> Response:
        """Send the browser to Google's consent screen."""
        if not self.google_enabled:
            return _login_error(request, "Google sign-in isn't set up on this server.")
        state, nonce = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
        request.session["oauth"] = {"state": state, "nonce": nonce, "at": int(time.time())}
        query = urlencode(
            {
                "client_id": self.context.settings.admin_google_client_id,
                "redirect_uri": self.redirect_uri(request),
                "response_type": "code",
                "scope": "openid email profile",
                "state": state,
                "nonce": nonce,
                "prompt": "select_account",
            }
        )
        return RedirectResponse(f"{GOOGLE_AUTHORIZE_URL}?{query}", status_code=302)

    async def google_callback(self, request: Request) -> Response:
        """Google sends the browser back here with a one-time code."""
        pending = request.session.pop("oauth", None)
        params = request.query_params
        if not isinstance(pending, dict) or not self.google_enabled:
            return _login_error(request, "That sign-in expired. Please try again.")
        if params.get("error"):
            return _login_error(request, "Google sign-in was cancelled.")
        state, code = params.get("state", ""), params.get("code", "")
        fresh = int(time.time()) - int(pending.get("at", 0)) <= OAUTH_TTL_S
        if not (fresh and code and hmac.compare_digest(str(pending.get("state")), state)):
            return _login_error(request, "That sign-in expired. Please try again.")
        try:
            subject = await self._google_subject(request, code, str(pending.get("nonce")))
        except (AppError, httpx.HTTPError, ValueError, KeyError, jwt.InvalidTokenError) as exc:
            log.warning("admin.google_sign_in_failed", error_type=type(exc).__name__)
            return _login_error(request, "Google sign-in failed. Please try again.")
        async with self.context.sessionmaker() as db:
            user = await db.scalar(
                select(User)
                .join(AuthIdentity, AuthIdentity.user_id == User.id)
                .where(AuthIdentity.provider == "google", AuthIdentity.subject == subject)
            )
            if user is None or not _may_administer(user, self.context.now()):
                log.warning("admin.not_an_admin", user_id=str(user.id) if user else None)
                return _login_error(request, "This Google account isn't an admin of this server.")
            await self._start_session(db, request, user, method="google")
        return RedirectResponse(request.url_for("admin:index"), status_code=302)

    async def _google_subject(self, request: Request, code: str, nonce: str) -> str:
        settings = self.context.settings
        secret = settings.admin_google_client_secret
        client_id = settings.admin_google_client_id or ""
        response = await self.context.http.post(
            GOOGLE_TOKEN_URL,
            data={
                "code": code,
                "client_id": client_id,
                "client_secret": secret.get_secret_value() if secret else "",
                "redirect_uri": self.redirect_uri(request),
                "grant_type": "authorization_code",
            },
            headers={"Accept": "application/json"},
        )
        response.raise_for_status()
        id_token = response.json()["id_token"]
        if not isinstance(id_token, str):
            raise ValueError("no ID token in Google's answer")
        verifier = GoogleIdTokenVerifier(
            client_ids=[client_id], jwks=self.jwks, http=self.context.http
        )
        identity = await verifier.verify(id_token, now=self.context.now())
        # Already verified above; this only reads the nonce claim back.
        claims = jwt.decode(id_token, options={"verify_signature": False})
        if not hmac.compare_digest(str(claims.get("nonce", "")), nonce):
            raise ValueError("nonce mismatch")
        return identity.subject


def _may_administer(user: User, now: datetime) -> bool:
    """Admins with an active account (a restricted, banned or deleted one can't administer)."""
    return (
        Role.ADMIN in user.roles and user.status == UserStatus.ACTIVE and not user.ban_in_force(now)
    )


def _login_error(request: Request, message: str) -> Response:
    url = request.url_for("admin:login").include_query_params(error=message)
    return RedirectResponse(url, status_code=302)
