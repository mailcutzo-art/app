from datetime import datetime

from app.core.schemas import ApiModel


class Health(ApiModel):
    status: str


class Readiness(ApiModel):
    status: str
    checks: dict[str, str]


class ClientConfig(ApiModel):
    """What the app needs before anything else: forced updates, maintenance and feature flags.

    ``server_time`` lets the app notice a phone clock that is far off.
    """

    min_build: int
    maintenance: bool
    maintenance_message: str | None
    maintenance_until: datetime | None  # when maintenance should end
    maintenance_at: datetime | None  # when planned maintenance starts
    features: dict[str, bool]
    server_time: datetime
