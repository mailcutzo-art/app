"""Base class for API request and response bodies."""

from typing import Annotated, TypeVar

from pydantic import BaseModel, ConfigDict, Strict

T = TypeVar("T")

# FastAPI validates JSON bodies in pydantic's Python mode, where strict mode would reject the
# string forms of UUIDs, datetimes and enums. Mark such fields ``Lax[...]`` to accept them.
Lax = Annotated[T, Strict(False)]


class ApiModel(BaseModel):
    """Strict (no "1" -> 1 or 1 -> True coercion) and closed (unknown fields are rejected)."""

    model_config = ConfigDict(strict=True, extra="forbid")
