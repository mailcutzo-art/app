"""The event names that may be recorded (docs/user-flows.md §15).

The app may send only ``CLIENT_EVENTS`` (screen-level things the server can't see); everything
else is recorded by the server with ``track`` when the action happens.
"""

CLIENT_EVENTS: frozenset[str] = frozenset(
    {
        "app_first_open",  # {referrer}: sent with the first batch after sign-in
        "onboarding_step",  # {step}
        "sign_in_failed",  # {code}
        "deep_link_opened",  # {kind, signed_in}
        "leaderboard_viewed",  # {board}
        "review_opened",  # {kind}
        "notification_opened",  # {kind, source: inbox | push}
        "t_viewed",
        "tip_shown",  # {rule}
        "share_link_tapped",  # {kind}
        "mm_timeout_choice",  # {choice}
        "error_shown",  # {code, screen}
        "reconnect",  # {gap_ms, resumed}
        "force_update_shown",
        "maintenance_shown",
    }
)

SERVER_EVENTS: frozenset[str] = frozenset(
    {
        # Activation
        "sign_in",
        "onboarding_done",
        "first_battle",
        "first_practice",
        # Battle
        "mm_join",
        "mm_widened",
        "mm_found",
        "mm_cancelled",
        "mm_requeued",
        "match_ready_timeout",
        "match_started",
        "match_finished",
        "rematch_offered",
        "rematch_accepted",
        "play_again",
        "settle_lag_ms",
        # Friend and group
        "room_created",
        "invite_sent",
        "invite_accepted",
        "room_started",
        "room_finished",
        "room_closed",
        "code_join",
        # Tournament
        "t_registered",
        "t_checked_in",
        "t_round_played",
        "t_finished",
        "t_withdrawn",
        "t_check_in_missed",
        "t_cancelled",
        "t_no_show",
        # Practice and tips
        "practice_started",
        "practice_finished",
        "tip_acted",
        "tip_dismissed",
        # Retention and economy
        "daily_active",
        "mission_completed",
        "streak_extended",
        "streak_lost",
        "streak_freeze_used",
        "level_up",
        "cap_reached",
        "coins_insufficient",
    }
)
