"""Every ORM model, imported so ``Base.metadata`` is complete (Alembic autogenerate uses it)."""

from app.core.db import Base
from app.modules.system.models import AppConfig, AuditLog

__all__ = ["AppConfig", "AuditLog", "Base"]
