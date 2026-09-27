from app.core.schemas import ApiModel


class Health(ApiModel):
    status: str


class Readiness(ApiModel):
    status: str
    checks: dict[str, str]


class ClientConfig(ApiModel):
    """What the app needs before anything else: forced updates, maintenance and feature flags."""

    min_build: int
    maintenance: bool
    features: dict[str, bool]
