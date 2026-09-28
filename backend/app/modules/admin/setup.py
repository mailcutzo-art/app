"""Mounting the admin panel on the api app (``APP_ADMIN_ENABLED``)."""

from pathlib import Path

from fastapi import FastAPI
from sqladmin import Admin
from starlette.middleware import Middleware
from starlette.requests import Request
from starlette.responses import Response

from app.core.config import Settings
from app.modules.admin.auth import AdminAuth, AdminGuard
from app.modules.admin.context import AdminContext, DeferredSessionmaker
from app.modules.admin.pages import ImportQuestionsPage
from app.modules.admin.views import VIEWS

TEMPLATES_DIR = Path(__file__).parent / "templates"
BASE_URL = "/admin"


def mount_admin(app: FastAPI, settings: Settings) -> Admin:
    """Serve the panel at ``/admin``; every route needs a signed-in admin except sign-in."""
    context = AdminContext(app, settings)
    auth = AdminAuth(context)
    admin = Admin(
        app,
        session_maker=DeferredSessionmaker(context),  # type: ignore[arg-type]
        base_url=BASE_URL,
        title="Quiz Arena admin",
        templates_dir=str(TEMPLATES_DIR),
        # Outermost: the guard answers refused requests before the session is even read.
        middlewares=[Middleware(AdminGuard, context=context)],
        authentication_backend=auth,
    )
    admin.templates.env.globals["admin_auth"] = auth
    admin.templates.env.globals["dev_login_enabled"] = settings.dev_login_enabled

    async def google_start(request: Request) -> Response:
        return await auth.google_start(request)

    async def google_callback(request: Request) -> Response:
        return await auth.google_callback(request)

    admin.admin.add_route("/auth/google", google_start, methods=["GET"], name="auth_google")
    admin.admin.add_route("/auth/callback", google_callback, methods=["GET"], name="auth_callback")
    for view in VIEWS:
        admin.add_view(view)
    admin.add_view(ImportQuestionsPage)
    return admin
