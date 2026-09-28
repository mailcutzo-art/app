"""Redis key and channel names of the realtime engine (``docs/realtime-engine.md``, "Redis keys").

Every key of one match carries the ``{mid}`` hash tag, so one script can touch all of them and a
later move to Redis Cluster only needs the global keys sharded.
"""

TIMERS = "rt:timers"  # zset: match id -> when it next needs a transition (ms)
SETTLE_QUEUE = "settle:q"  # zset: match id -> when it ended (ms), until settled
QUEUES = "mm:queues"  # set of "<mode>:<subject>" queues that have had tickets


def match(mid: str) -> str:
    return f"m:{{{mid}}}"


def match_players(mid: str) -> str:
    return f"{match(mid)}:p"


def match_question(mid: str, index: int) -> str:
    return f"{match(mid)}:q:{index}"


def match_log(mid: str) -> str:
    return f"{match(mid)}:log"


def match_final(mid: str) -> str:
    return f"{match(mid)}:final"


def match_lease(mid: str) -> str:
    return f"{match(mid)}:lease"


def match_rematch(mid: str) -> str:
    return f"{match(mid)}:rematch"


def match_post(mid: str) -> str:
    """Set once the after-settlement steps (requeues, cooldown strikes) have run."""
    return f"{match(mid)}:post"


def busy(uid: str) -> str:
    """Exactly one of ``q:<ticket>``, ``m:<mid>``, ``r:<room>`` or ``t:<tid>``."""
    return f"busy:{uid}"


def connection(uid: str) -> str:
    """``<node>|<conn id>|<session id>`` of the user's live socket."""
    return f"rt:conn:{uid}"


def background(uid: str) -> str:
    """Set while the user's app is in the background."""
    return f"rt:bg:{uid}"


def ticket(ticket_id: str) -> str:
    return f"mm:t:{ticket_id}"


def queue(mode: str, subject: str) -> str:
    return f"mm:q:{mode}:{subject}"


def queue_leader(mode: str, subject: str) -> str:
    return f"mm:lead:{mode}:{subject}"


def cooldown(uid: str) -> str:
    return f"mm:cool:{uid}"


def aborts(uid: str) -> str:
    """zset of this user's recent aborts (match id -> ms), for the cooldown."""
    return f"mm:aborts:{uid}"


def join_idem(uid: str, idem: str) -> str:
    return f"mm:idem:{uid}:{idem}"


def last_selection(uid: str) -> str:
    return f"mm:last:{uid}"


def pair_games(lo: str, hi: str) -> str:
    """zset of rated matches between two players (match id -> ms), for the 24 h limit."""
    return f"mm:pair:{lo}:{hi}"


def waits(subject: str, hour: int) -> str:
    """Recent waits (s) until a match was found in this subject at this IST hour."""
    return f"mm:waits:{subject}:{hour:02d}"


def rt_ticket(ticket: str) -> str:
    return f"rt:ticket:{ticket}"


def user_events(uid: str) -> str:
    return f"ev:u:{uid}"


def user_control(uid: str) -> str:
    return f"ctl:u:{uid}"


def match_events(mid: str) -> str:
    return f"ev:m:{mid}"
