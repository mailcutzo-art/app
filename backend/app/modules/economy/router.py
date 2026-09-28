"""The player's wallet: balance, coins in holds and the coins history."""

import uuid
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Query
from sqlalchemy import select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import SessionDep
from app.core.pagination import decode_cursor, encode_cursor
from app.core.schemas import ApiModel, Lax
from app.core.security import CurrentAuth
from app.modules.economy.models import LedgerEntry
from app.modules.economy.schemas import RefOut, TransactionOut, TransactionsOut, WalletOut
from app.modules.economy.service import get_wallet

router = APIRouter(tags=["economy"])

RECENT = 5
CursorQuery = Annotated[str | None, Query(max_length=512)]
LimitQuery = Annotated[int, Query(ge=1, le=100)]


class LedgerCursor(ApiModel):
    at: Lax[datetime]
    id: Lax[uuid.UUID]


@router.get("/me/wallet")
async def read_wallet(auth: CurrentAuth, db: SessionDep) -> WalletOut:
    """Spendable balance, coins held for entries in progress, and the last 5 transactions."""
    wallet = await get_wallet(db, auth.user_id)
    page = await transactions(db, auth.user_id, cursor=None, limit=RECENT)
    return WalletOut(balance=wallet.balance, held=wallet.held, recent=page.items)


@router.get("/me/wallet/transactions")
async def list_transactions(
    auth: CurrentAuth, db: SessionDep, cursor: CursorQuery = None, limit: LimitQuery = 30
) -> TransactionsOut:
    """The coins history, newest first: every credit and debit with its reason and source."""
    return await transactions(db, auth.user_id, cursor=cursor, limit=limit)


async def transactions(
    db: AsyncSession, user_id: uuid.UUID, *, cursor: str | None, limit: int
) -> TransactionsOut:
    statement = (
        select(LedgerEntry)
        .where(LedgerEntry.user_id == user_id)
        .order_by(LedgerEntry.created_at.desc(), LedgerEntry.id.desc())
        .limit(limit + 1)
    )
    if cursor is not None:
        position = decode_cursor(cursor, LedgerCursor)
        statement = statement.where(
            tuple_(LedgerEntry.created_at, LedgerEntry.id) < tuple_(position.at, position.id)
        )
    rows = (await db.scalars(statement)).all()
    page = rows[:limit]
    next_cursor = None
    if len(rows) > limit:
        next_cursor = encode_cursor(LedgerCursor(at=page[-1].created_at, id=page[-1].id))
    return TransactionsOut(
        items=[transaction_out(entry) for entry in page], next_cursor=next_cursor
    )


def transaction_out(entry: LedgerEntry) -> TransactionOut:
    ref = None
    if entry.ref_kind is not None and entry.ref_id is not None:
        ref = RefOut(kind=entry.ref_kind, id=entry.ref_id)
    return TransactionOut(
        id=entry.id,
        delta=entry.delta,
        balance_after=entry.balance_after,
        reason=entry.reason,
        title=entry.title,
        ref=ref,
        created_at=entry.created_at,
    )
