"""Coach tip bodies (``docs/api-learn.md``, "Coach tips")."""

from app.core.schemas import ApiModel


class TipOut(ApiModel):
    """One tip: a short instruction with one button (``action`` and its ``params``)."""

    key: str  # rule and target, e.g. "weak_topic:physics:projectile-motion"
    message: str
    action: str
    params: dict[str, str]


class TipItemOut(TipOut):
    rule: str


class TipsOut(ApiModel):
    unlocked: bool
    # How many more answers unlock tips; null while the tip rules aren't wired in.
    answers_needed: int | None
    tips: list[TipItemOut]
