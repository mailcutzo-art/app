"""Reading the boards: the hub, a board's pages, and positions used elsewhere.

Rows are ``{"position", "user": card, "value", "value_display", "change_1d"}``. ``change_1d``
compares with the board's ``:snap`` copy taken at the start of the IST day: positive when the
player moved up, ``None`` when they weren't on it then. A minor seen by someone who isn't their
friend shows only name, avatar and level (no handle).

Friends boards are read from the stored weekly XP and overall rating boards with ``ZMSCORE``
over the viewer and their friends. The Hall of Fame comes from a provider the tournaments module
registers (``register_hall_of_fame``); until then it is empty and its cards are hidden.
"""

import uuid
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFound
from app.core.pagination import decode_cursor, encode_cursor
from app.core.schemas import ApiModel
from app.modules.leaderboards import boards, keys
from app.modules.leaderboards.boards import Catalog, primary_view
from app.modules.leaderboards.events import board_title
from app.modules.leaderboards.keys import ALL, AROUND, PAGE, TOP, Board, Family
from app.modules.leaderboards.schemas import (
    BoardCardOut,
    BoardPageOut,
    HubOut,
    NotRankedOut,
    RowOut,
    StandingOut,
)
from app.modules.ratings.models import OVERALL, Rating
from app.modules.social.cards import UserCard, cards_for
from app.modules.social.privacy import is_minor_user
from app.modules.social.relations import friend_ids
from app.modules.users.models import User

Scored = list[tuple[str, float]]


@dataclass(frozen=True, slots=True)
class HallEntry:
    user_id: uuid.UUID
    value: int  # e.g. the tournament's points
    value_display: str  # "Physics Sunday Cup"


# (db, subject slug, how many) -> the latest winners, newest first
HallOfFame = Callable[[AsyncSession, str, int], Awaitable[Sequence[HallEntry]]]
HALL_SIZE = 10


async def _no_winners(_db: AsyncSession, _subject: str, _limit: int) -> Sequence[HallEntry]:
    return []


_hall_of_fame: HallOfFame = _no_winners


def register_hall_of_fame(provider: HallOfFame) -> None:
    """Supply the last tournament winners per subject (``hall_of_fame:{subject}``)."""
    global _hall_of_fame
    _hall_of_fame = provider


class BoardNotFound(NotFound):
    default_code = "BOARD_NOT_FOUND"
    default_message = "That leaderboard doesn't exist."


class PageCursor(ApiModel):
    offset: int


def _view(goal: str | None) -> str:
    return goal if goal in keys.VIEWS else ALL


# --- Rows ---------------------------------------------------------------------------------------


async def _cards(
    db: AsyncSession, viewer_id: uuid.UUID, user_ids: Sequence[uuid.UUID], *, now: datetime
) -> dict[uuid.UUID, UserCard]:
    if not user_ids:
        return {}
    users = list(await db.scalars(select(User).where(User.id.in_(list(set(user_ids))))))
    found = await cards_for(db, users)
    minors = [user for user in users if user.id != viewer_id and is_minor_user(user, now)]
    if minors:
        friends = await friend_ids(db, viewer_id)
        for user in minors:
            if user.id not in friends:
                found[user.id] = found[user.id].model_copy(update={"handle": None})
    return found


def _display(board: Board, value: int) -> str:
    return str(value)


async def _rows(
    db: AsyncSession,
    viewer_id: uuid.UUID,
    board: Board,
    scored: Scored,
    *,
    first_position: int,
    changes: Mapping[str, int | None],
    now: datetime,
) -> list[RowOut]:
    ids = [uuid.UUID(member) for member, _ in scored]
    cards = await _cards(db, viewer_id, ids, now=now)
    rows = []
    for offset, (member, score) in enumerate(scored):
        card = cards.get(uuid.UUID(member))
        if card is None:
            continue  # erased since it was written; the nightly rebuild drops it
        value = keys.decode(score)
        rows.append(
            RowOut(
                position=first_position + offset,
                user=card,
                value=value,
                value_display=_display(board, value),
                change_1d=changes.get(member),
            )
        )
    return rows


async def _changes(
    redis: Redis, key: str, members: Sequence[str], positions: Mapping[str, int]
) -> dict[str, int | None]:
    """Places gained since the day's snapshot, per member."""
    if not members:
        return {}
    pipe = redis.pipeline(transaction=False)
    for member in members:
        pipe.zrevrank(keys.snap_key(key), member)
    before = await pipe.execute()
    return {
        member: (None if then is None else int(then) + 1 - positions[member])
        for member, then in zip(members, before, strict=True)
    }


# --- Board sources ------------------------------------------------------------------------------


@dataclass(slots=True)
class _Source:
    """A board's members in order, stored (a ZSET) or computed (friends)."""

    board: Board
    key: str | None
    friends: Scored | None = None  # the whole friends board, best first
    friends_before: dict[str, int] | None = None

    async def count(self, redis: Redis) -> int:
        if self.friends is not None:
            return len(self.friends)
        return int(await redis.zcard(self.key)) if self.key else 0

    async def slice(self, redis: Redis, start: int, stop: int) -> Scored:
        """Members at 0-based ``start``..``stop`` (inclusive)."""
        if stop < start:
            return []
        if self.friends is not None:
            return self.friends[start : stop + 1]
        if self.key is None:
            return []
        found: list[Any] = await redis.zrevrange(self.key, start, stop, withscores=True)
        return [(str(member), float(score)) for member, score in found]

    async def rank(self, redis: Redis, member: str) -> tuple[int, float] | None:
        """0-based rank and score of ``member``."""
        if self.friends is not None:
            for index, (other, score) in enumerate(self.friends):
                if other == member:
                    return index, score
            return None
        if self.key is None:
            return None
        pipe = redis.pipeline(transaction=False)
        pipe.zrevrank(self.key, member)
        pipe.zscore(self.key, member)
        rank, score = await pipe.execute()
        return None if rank is None or score is None else (int(rank), float(score))

    async def changes(self, redis: Redis, scored: Scored, first: int) -> dict[str, int | None]:
        positions = {member: first + index for index, (member, _) in enumerate(scored)}
        if self.friends_before is not None:
            before = self.friends_before
            return {
                member: (before[member] - positions[member] if member in before else None)
                for member in positions
            }
        if self.key is None:
            return {}
        return await _changes(redis, self.key, list(positions), positions)


async def _friends_board(
    db: AsyncSession, redis: Redis, viewer_id: uuid.UUID, key: str
) -> tuple[Scored, dict[str, int]]:
    members = sorted(str(uid) for uid in {*await friend_ids(db, viewer_id), viewer_id})
    pipe = redis.pipeline(transaction=False)
    pipe.zmscore(key, members)
    pipe.zmscore(keys.snap_key(key), members)
    now_scores, then_scores = await pipe.execute()

    def ranked(scores: Sequence[float | None]) -> Scored:
        present = [(m, float(s)) for m, s in zip(members, scores, strict=True) if s is not None]
        return sorted(present, key=lambda item: (-item[1], item[0]))

    before = {member: index + 1 for index, (member, _) in enumerate(ranked(then_scores))}
    return ranked(now_scores), before


async def _source(
    db: AsyncSession, redis: Redis, viewer_id: uuid.UUID, board: Board, view: str, now: datetime
) -> _Source:
    key = keys.board_key(board, view, now)
    if key is not None and board.family in {Family.FRIENDS_WEEKLY, Family.FRIENDS_RATING}:
        scored, before = await _friends_board(db, redis, viewer_id, key)
        return _Source(board, key, friends=scored, friends_before=before)
    return _Source(board, key)


def _check(board: Board | None, catalog: Catalog, view: str) -> Board:
    if board is None:
        raise BoardNotFound()
    subject = board.subject_slug
    if subject is not None and (subject not in catalog.names or not catalog.allowed(subject, view)):
        raise BoardNotFound()
    return board


async def _rating_row(db: AsyncSession, user_id: uuid.UUID, scope: str) -> Rating | None:
    return await db.get(Rating, (user_id, scope))


async def _not_ranked(
    db: AsyncSession, viewer_id: uuid.UUID, board: Board, now: datetime
) -> NotRankedOut | None:
    if board.last or board.family == Family.HALL_OF_FAME:
        return None
    if board.rated:
        scope = board.subject if board.family == Family.RATING and board.subject else OVERALL
        row = await _rating_row(db, viewer_id, scope)
        return NotRankedOut(games_to_rank=boards.games_to_rank(row, now))
    return NotRankedOut(games_to_rank=1)


def _ends_at(board: Board, now: datetime) -> datetime | None:
    if not board.weekly or board.last:
        return None
    return keys.week_end(keys.week_of(now))


def _period(board: Board, now: datetime) -> str | None:
    if not board.weekly:
        return None
    week = keys.week_of(now)
    return keys.week_label(week - timedelta(days=7) if board.last else week)


# --- Endpoints ----------------------------------------------------------------------------------


async def board_page(
    db: AsyncSession,
    redis: Redis,
    viewer_id: uuid.UUID,
    board_id: str,
    *,
    goal: str | None,
    cursor: str | None,
    limit: int,
    now: datetime,
) -> BoardPageOut:
    """One page of a board (the top 100 in all), the viewer's row and the ±10 around it."""
    view = _view(goal)
    catalog = await boards.load_catalog(db)
    board = _check(keys.parse_board(board_id), catalog, view)
    limit = max(1, min(PAGE, limit))
    offset = decode_cursor(cursor, PageCursor).offset if cursor else 0
    offset = max(0, min(offset, TOP))
    common: dict[str, Any] = {
        "board": board.id,
        "title": board_title(board, catalog.names),
        "period": _period(board, now),
        "ends_at": _ends_at(board, now),
    }
    if board.family == Family.HALL_OF_FAME:
        return await _hall_page(db, viewer_id, board, common, now=now)

    source = await _source(db, redis, viewer_id, board, view, now)
    players = await source.count(redis)
    stop = min(offset + limit, TOP, players) - 1
    scored = await source.slice(redis, offset, stop)
    items = await _rows(
        db,
        viewer_id,
        board,
        scored,
        first_position=offset + 1,
        changes=await source.changes(redis, scored, offset + 1),
        now=now,
    )
    next_offset = offset + len(scored)
    next_cursor = (
        encode_cursor(PageCursor(offset=next_offset))
        if scored and next_offset < min(TOP, players)
        else None
    )
    me = None
    around: list[RowOut] = []
    mine = await source.rank(redis, str(viewer_id))
    if mine is not None:
        rank, score = mine
        me_rows = await _rows(
            db,
            viewer_id,
            board,
            [(str(viewer_id), score)],
            first_position=rank + 1,
            changes=await source.changes(redis, [(str(viewer_id), score)], rank + 1),
            now=now,
        )
        me = me_rows[0] if me_rows else None
        start = max(0, rank - AROUND)
        near = await source.slice(redis, start, rank + AROUND)
        around = await _rows(
            db,
            viewer_id,
            board,
            near,
            first_position=start + 1,
            changes=await source.changes(redis, near, start + 1),
            now=now,
        )
    return BoardPageOut(
        **common,
        items=items,
        next_cursor=next_cursor,
        me=me,
        around_me=around,
        not_ranked=None if me is not None else await _not_ranked(db, viewer_id, board, now),
        players=players,
    )


async def _hall_page(
    db: AsyncSession, viewer_id: uuid.UUID, board: Board, common: dict[str, Any], *, now: datetime
) -> BoardPageOut:
    winners = list(await _hall_of_fame(db, board.subject or "", HALL_SIZE))
    cards = await _cards(db, viewer_id, [w.user_id for w in winners], now=now)
    items = [
        RowOut(
            position=index + 1,
            user=cards[w.user_id],
            value=w.value,
            value_display=w.value_display,
            change_1d=None,
        )
        for index, w in enumerate(winners)
        if w.user_id in cards
    ]
    me = next((row for row in items if row.user.id == viewer_id), None)
    return BoardPageOut(
        **common,
        items=items,
        next_cursor=None,
        me=me,
        around_me=[],
        not_ranked=None,
        players=len(items),
    )


async def _card(
    db: AsyncSession,
    redis: Redis,
    viewer_id: uuid.UUID,
    board: Board,
    view: str,
    catalog: Catalog,
    now: datetime,
) -> BoardCardOut | None:
    """A hub card, or ``None`` for an empty subject board."""
    source = await _source(db, redis, viewer_id, board, view, now)
    top = await source.slice(redis, 0, 0)
    if not top and board.subject_slug is not None:
        return None
    leader_rows = await _rows(
        db,
        viewer_id,
        board,
        top,
        first_position=1,
        changes=await source.changes(redis, top, 1),
        now=now,
    )
    mine = await source.rank(redis, str(viewer_id))
    if mine is not None:
        rank, score = mine
        change = (await source.changes(redis, [(str(viewer_id), score)], rank + 1)).get(
            str(viewer_id)
        )
        me = StandingOut(position=rank + 1, value=keys.decode(score), change_1d=change)
    else:
        not_ranked = await _not_ranked(db, viewer_id, board, now)
        me = StandingOut(
            games_to_rank=not_ranked.games_to_rank if board.rated and not_ranked else None
        )
    return BoardCardOut(
        board=board.id,
        title=board_title(board, catalog.names),
        ends_at=_ends_at(board, now),
        leader=leader_rows[0] if leader_rows else None,
        me=me,
    )


async def hub(
    db: AsyncSession, redis: Redis, viewer_id: uuid.UUID, *, goal: str | None, now: datetime
) -> HubOut:
    """One card per board with its leader and the viewer's standing, and last week's top 3."""
    view = _view(goal)
    catalog = await boards.load_catalog(db)
    subjects = catalog.subjects_in(view)
    wanted = [
        Board(Family.WEEKLY_XP),
        Board(Family.RATING, OVERALL),
        *(Board(Family.WEEKLY_SUBJECT, s) for s in subjects),
        *(Board(Family.RATING, s) for s in subjects),
        Board(Family.FRIENDS_WEEKLY),
        Board(Family.FRIENDS_RATING),
    ]
    cards = []
    for board in wanted:
        card = await _card(db, redis, viewer_id, board, view, catalog, now)
        if card is not None:
            cards.append(card)
    for subject in subjects:
        winners = await _hall_of_fame(db, subject, 1)
        if winners:
            page = await _hall_page(
                db,
                viewer_id,
                Board(Family.HALL_OF_FAME, subject),
                {"board": "", "title": "", "period": None, "ends_at": None},
                now=now,
            )
            board = Board(Family.HALL_OF_FAME, subject)
            cards.append(
                BoardCardOut(
                    board=board.id,
                    title=board_title(board, catalog.names),
                    ends_at=None,
                    leader=page.items[0] if page.items else None,
                    me=StandingOut(position=page.me.position if page.me else None),
                )
            )
    last = Board(Family.WEEKLY_XP, last=True)
    last_source = await _source(db, redis, viewer_id, last, view, now)
    top3 = await last_source.slice(redis, 0, 2)
    last_week = await _rows(db, viewer_id, last, top3, first_position=1, changes={}, now=now)
    return HubOut(boards=cards, last_week=last_week)


# --- Positions for other features ---------------------------------------------------------------


async def rating_positions(
    redis: Redis, user_id: uuid.UUID, goal: str | None, scopes: Sequence[str]
) -> dict[str, int | None]:
    """The player's positions on their own exam's rating boards."""
    view = primary_view(goal)
    return {
        scope: await boards.position(redis, keys.rating_key(view, scope), user_id)
        for scope in scopes
    }


async def weekly_leaders(
    db: AsyncSession,
    redis: Redis,
    viewer_id: uuid.UUID,
    board: Board,
    *,
    goal: str | None,
    top: int,
    now: datetime,
) -> tuple[list[RowOut], RowOut | None]:
    """The top ``top`` rows of a board on the viewer's own view, and the viewer's row."""
    view = primary_view(goal)
    source = await _source(db, redis, viewer_id, board, view, now)
    scored = await source.slice(redis, 0, top - 1)
    rows = await _rows(
        db,
        viewer_id,
        board,
        scored,
        first_position=1,
        changes=await source.changes(redis, scored, 1),
        now=now,
    )
    me = None
    mine = await source.rank(redis, str(viewer_id))
    if mine is not None:
        rank, score = mine
        found = await _rows(
            db,
            viewer_id,
            board,
            [(str(viewer_id), score)],
            first_position=rank + 1,
            changes=await source.changes(redis, [(str(viewer_id), score)], rank + 1),
            now=now,
        )
        me = found[0] if found else None
    return rows, me
