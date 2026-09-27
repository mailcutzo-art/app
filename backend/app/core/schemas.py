"""Base class for API request and response bodies, and field errors written for people."""

from typing import Annotated, TypeVar

from pydantic import BaseModel, ConfigDict, Strict
from pydantic_core import PydanticCustomError

T = TypeVar("T")

# FastAPI validates JSON bodies in pydantic's Python mode, where strict mode would reject the
# string forms of UUIDs, datetimes and enums. Mark such fields ``Lax[...]`` to accept them.
Lax = Annotated[T, Strict(False)]

# Error type whose message is shown to users as is (see ``field_error``).
FIELD_ERROR_TYPE = "invalid_field"


class ApiModel(BaseModel):
    """Strict (no "1" -> 1 or 1 -> True coercion) and closed (unknown fields are rejected)."""

    model_config = ConfigDict(strict=True, extra="forbid")


def field_error(message: str) -> PydanticCustomError:
    """Raise from a validator to report ``message`` to the user under the field's name."""
    return PydanticCustomError(FIELD_ERROR_TYPE, message)
