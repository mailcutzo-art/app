"""Wallet responses (docs/api-play.md, "Wallet and XP")."""

import uuid
from datetime import datetime

from app.core.schemas import ApiModel


class RefOut(ApiModel):
    kind: str
    id: str


class TransactionOut(ApiModel):
    id: uuid.UUID
    delta: int
    balance_after: int
    reason: str
    title: str
    ref: RefOut | None
    created_at: datetime


class WalletOut(ApiModel):
    balance: int
    held: int
    recent: list[TransactionOut]


class TransactionsOut(ApiModel):
    items: list[TransactionOut]
    next_cursor: str | None
