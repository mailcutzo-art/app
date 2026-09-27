"""Content, practice sessions, answer records, per-user progress and XP; ban details.

Revision ID: 0003
Revises: 0002
Create Date: 2026-09-27 16:30:00+00:00

``question_attempts`` is partitioned by month on ``answered_at``. A DEFAULT partition catches
anything outside the created months, and ``ensure_attempt_partitions(months_ahead)`` creates the
current month and the next ``months_ahead`` (the worker calls it daily).
"""

from collections.abc import Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

STATUSES = "status IN ('draft', 'review', 'published', 'retired')"
SOURCES = "source IN ('content', 'import')"
CATEGORIES = "category IN ('concept', 'numerical', 'factual', 'application')"
OUTCOMES = "IN ('correct', 'wrong', 'skipped', 'timeout')"
DIFFICULTY = "difficulty BETWEEN 1 AND 5"

ENSURE_ATTEMPT_PARTITIONS = """
CREATE FUNCTION ensure_attempt_partitions(months_ahead integer) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    first_month timestamp := date_trunc('month', now() AT TIME ZONE 'UTC');
    month_start timestamp;
    lower_bound timestamptz;
    upper_bound timestamptz;
    partition_name text;
    created integer := 0;
BEGIN
    IF months_ahead IS NULL OR months_ahead < 0 THEN
        RAISE EXCEPTION 'months_ahead must be 0 or more, got %', months_ahead;
    END IF;
    -- One creator at a time (worker replicas, migrations).
    PERFORM pg_advisory_xact_lock(hashtext('ensure_attempt_partitions'));
    FOR i IN 0..months_ahead LOOP
        month_start := first_month + make_interval(months => i);
        partition_name := 'question_attempts_' || to_char(month_start, 'YYYY_MM');
        CONTINUE WHEN to_regclass(partition_name) IS NOT NULL;
        lower_bound := month_start AT TIME ZONE 'UTC';
        upper_bound := (month_start + interval '1 month') AT TIME ZONE 'UTC';
        -- Rows of that month already in the default partition move into the new one first;
        -- attaching would fail otherwise.
        EXECUTE format(
            'CREATE TABLE %I (LIKE question_attempts INCLUDING DEFAULTS INCLUDING CONSTRAINTS)',
            partition_name);
        EXECUTE format(
            'WITH moved AS (DELETE FROM question_attempts_default'
            ' WHERE answered_at >= %L AND answered_at < %L RETURNING *)'
            ' INSERT INTO %I SELECT * FROM moved',
            lower_bound, upper_bound, partition_name);
        EXECUTE format(
            'ALTER TABLE question_attempts ATTACH PARTITION %I FOR VALUES FROM (%L) TO (%L)',
            partition_name, lower_bound, upper_bound);
        created := created + 1;
    END LOOP;
    RETURN created;
END
$$
"""


def _timestamp(name: str) -> sa.Column[Any]:
    return sa.Column(
        name, sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False
    )


def _counter(name: str, type_: sa.types.TypeEngine[Any] | None = None) -> sa.Column[Any]:
    return sa.Column(name, type_ or sa.Integer(), server_default=sa.text("0"), nullable=False)


def _user_fk(table: str) -> sa.ForeignKeyConstraint:
    return sa.ForeignKeyConstraint(
        ["user_id"], ["users.id"], name=op.f(f"fk_{table}_user_id_users"), ondelete="CASCADE"
    )


def _totals() -> list[sa.Column[Any]]:
    """Running-total columns shared by the topic, chapter and category stats."""
    return [
        _counter("attempts"),
        _counter("correct"),
        _counter("time_ms", sa.BigInteger()),
        _counter("correct_time_ms", sa.BigInteger()),
        sa.Column("last_at", sa.DateTime(timezone=True), nullable=False),
        _counter("fast"),
        _counter("slow"),
        _counter("even"),
        _counter("typical_compared"),
        sa.Column(
            "typical_log_ratio_sum", sa.Double(), server_default=sa.text("0"), nullable=False
        ),
        _counter("fast_wrong"),
        _counter("easy_attempts"),
        _counter("easy_correct"),
    ]


def upgrade() -> None:
    _extend_users()
    _create_content()
    _create_practice()
    _create_attempts()
    _create_user_progress()


def _extend_users() -> None:
    """Ban details, so a suspended player can be told why and until when."""
    op.add_column("users", sa.Column("ban_reason", sa.Text(), nullable=True))
    op.add_column("users", sa.Column("banned_until", sa.DateTime(timezone=True), nullable=True))
    op.create_check_constraint(
        op.f("ck_users_ban_reason"),
        "users",
        "ban_reason IN ('cheating', 'abuse', 'offensive_name', 'other')",
    )


def _create_content() -> None:
    op.create_table(
        "goals",
        sa.Column("id", sa.SmallInteger(), sa.Identity(always=False), nullable=False),
        sa.Column("slug", sa.Text(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_goals")),
        sa.UniqueConstraint("slug", name=op.f("uq_goals_slug")),
    )
    op.create_table(
        "subjects",
        sa.Column("id", sa.SmallInteger(), sa.Identity(always=False), nullable=False),
        sa.Column("slug", sa.Text(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("tone", sa.Text(), nullable=False),
        sa.Column("icon", sa.Text(), nullable=False),
        sa.Column("sort", sa.SmallInteger(), nullable=False),
        sa.CheckConstraint(
            "tone IN ('sky', 'mint', 'lemon', 'lavender', 'peach', 'rose', 'lime')",
            name=op.f("ck_subjects_tone"),
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_subjects")),
        sa.UniqueConstraint("slug", name=op.f("uq_subjects_slug")),
    )
    op.create_table(
        "goal_subjects",
        sa.Column("goal_id", sa.SmallInteger(), nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=False),
        sa.ForeignKeyConstraint(
            ["goal_id"],
            ["goals.id"],
            name=op.f("fk_goal_subjects_goal_id_goals"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["subject_id"],
            ["subjects.id"],
            name=op.f("fk_goal_subjects_subject_id_subjects"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("goal_id", "subject_id", name=op.f("pk_goal_subjects")),
    )
    op.create_table(
        "chapters",
        sa.Column("id", sa.Integer(), sa.Identity(always=False), nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=False),
        sa.Column("slug", sa.Text(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("sort", sa.SmallInteger(), nullable=False),
        sa.Column("is_active", sa.Boolean(), server_default=sa.text("true"), nullable=False),
        sa.ForeignKeyConstraint(
            ["subject_id"], ["subjects.id"], name=op.f("fk_chapters_subject_id_subjects")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_chapters")),
        sa.UniqueConstraint("subject_id", "slug", name=op.f("uq_chapters_subject_id_slug")),
    )
    op.create_table(
        "topics",
        sa.Column("id", sa.Integer(), sa.Identity(always=False), nullable=False),
        sa.Column("chapter_id", sa.Integer(), nullable=False),
        sa.Column("slug", sa.Text(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("sort", sa.SmallInteger(), nullable=False),
        sa.Column("is_active", sa.Boolean(), server_default=sa.text("true"), nullable=False),
        sa.ForeignKeyConstraint(
            ["chapter_id"], ["chapters.id"], name=op.f("fk_topics_chapter_id_chapters")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_topics")),
        sa.UniqueConstraint("chapter_id", "slug", name=op.f("uq_topics_chapter_id_slug")),
    )
    op.create_table(
        "passages",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("external_id", sa.Text(), nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=False),
        sa.Column("chapter_id", sa.Integer(), nullable=True),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("body", sa.Text(), nullable=False),
        sa.Column("difficulty", sa.SmallInteger(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        _timestamp("created_at"),
        _timestamp("updated_at"),
        sa.CheckConstraint(DIFFICULTY, name=op.f("ck_passages_difficulty")),
        sa.CheckConstraint(STATUSES, name=op.f("ck_passages_status")),
        sa.CheckConstraint(SOURCES, name=op.f("ck_passages_source")),
        sa.ForeignKeyConstraint(
            ["chapter_id"], ["chapters.id"], name=op.f("fk_passages_chapter_id_chapters")
        ),
        sa.ForeignKeyConstraint(
            ["subject_id"], ["subjects.id"], name=op.f("fk_passages_subject_id_subjects")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_passages")),
        sa.UniqueConstraint("external_id", name=op.f("uq_passages_external_id")),
    )
    op.create_table(
        "questions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("external_id", sa.Text(), nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=False),
        sa.Column("chapter_id", sa.Integer(), nullable=True),
        sa.Column("topic_id", sa.Integer(), nullable=True),
        sa.Column("passage_id", sa.Uuid(), nullable=True),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("category", sa.Text(), nullable=False),
        sa.Column("exams", postgresql.ARRAY(sa.Text()), nullable=True),
        sa.Column("difficulty", sa.SmallInteger(), nullable=False),
        sa.Column("battle_pool", sa.Text(), server_default="none", nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("stem", sa.Text(), nullable=False),
        sa.Column("options", postgresql.ARRAY(sa.Text()), nullable=False),
        sa.Column("answer", sa.SmallInteger(), nullable=False),
        sa.Column("explanation", sa.Text(), nullable=False),
        sa.Column(
            "tags", postgresql.ARRAY(sa.Text()), server_default=sa.text("'{}'"), nullable=False
        ),
        sa.Column("search_text", sa.Text(), nullable=False),
        sa.Column("content_hash", sa.Text(), nullable=False),
        sa.Column("supersedes_id", sa.Uuid(), nullable=True),
        sa.Column("seq", sa.Integer(), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        _timestamp("created_at"),
        _timestamp("updated_at"),
        sa.CheckConstraint("kind IN ('mcq_single', 'passage_mcq')", name=op.f("ck_questions_kind")),
        sa.CheckConstraint(CATEGORIES, name=op.f("ck_questions_category")),
        sa.CheckConstraint(
            "battle_pool IN ('none', 'shared', 'reserved')", name=op.f("ck_questions_battle_pool")
        ),
        sa.CheckConstraint(STATUSES, name=op.f("ck_questions_status")),
        sa.CheckConstraint(SOURCES, name=op.f("ck_questions_source")),
        sa.CheckConstraint(DIFFICULTY, name=op.f("ck_questions_difficulty")),
        sa.CheckConstraint("cardinality(options) = 4", name=op.f("ck_questions_options")),
        sa.CheckConstraint("answer BETWEEN 0 AND 3", name=op.f("ck_questions_answer")),
        sa.CheckConstraint(
            "exams IS NULL OR (cardinality(exams) > 0 AND exams <@ ARRAY['neet', 'jee']::text[])",
            name=op.f("ck_questions_exams"),
        ),
        sa.CheckConstraint(
            "(kind = 'passage_mcq') = (passage_id IS NOT NULL)", name=op.f("ck_questions_passage")
        ),
        sa.CheckConstraint(
            "kind = 'passage_mcq' OR (chapter_id IS NOT NULL AND topic_id IS NOT NULL)",
            name=op.f("ck_questions_placement"),
        ),
        sa.ForeignKeyConstraint(
            ["subject_id"], ["subjects.id"], name=op.f("fk_questions_subject_id_subjects")
        ),
        sa.ForeignKeyConstraint(
            ["chapter_id"], ["chapters.id"], name=op.f("fk_questions_chapter_id_chapters")
        ),
        sa.ForeignKeyConstraint(
            ["topic_id"], ["topics.id"], name=op.f("fk_questions_topic_id_topics")
        ),
        sa.ForeignKeyConstraint(
            ["passage_id"], ["passages.id"], name=op.f("fk_questions_passage_id_passages")
        ),
        sa.ForeignKeyConstraint(
            ["supersedes_id"], ["questions.id"], name=op.f("fk_questions_supersedes_id_questions")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_questions")),
        sa.UniqueConstraint("subject_id", "seq", name=op.f("uq_questions_subject_id_seq")),
    )
    published = sa.text("status = 'published'")
    op.create_index(
        "uq_questions_external_id_live",
        "questions",
        ["external_id"],
        unique=True,
        postgresql_where=sa.text("status <> 'retired'"),
    )
    op.create_index(
        "ix_questions_chapter_difficulty_published",
        "questions",
        ["chapter_id", "difficulty"],
        postgresql_where=published,
    )
    op.create_index(
        "ix_questions_topic_published", "questions", ["topic_id"], postgresql_where=published
    )
    op.create_index(
        "ix_questions_battle_published",
        "questions",
        ["chapter_id"],
        postgresql_where=sa.text("status = 'published' AND battle_pool <> 'none'"),
    )
    op.create_index(
        "ix_questions_passage_id",
        "questions",
        ["passage_id"],
        postgresql_where=sa.text("passage_id IS NOT NULL"),
    )
    op.create_index(
        "ix_questions_search_trgm",
        "questions",
        ["search_text"],
        postgresql_using="gin",
        postgresql_ops={"search_text": "gin_trgm_ops"},
    )
    op.create_index(
        "ix_questions_search_fts",
        "questions",
        [sa.text("to_tsvector('simple'::regconfig, search_text)")],
        postgresql_using="gin",
    )
    op.create_table(
        "question_stats",
        sa.Column("question_id", sa.Uuid(), nullable=False),
        _counter("attempts"),
        _counter("correct"),
        sa.Column("typical_ms", sa.Integer(), nullable=True),
        _counter("timed_correct"),
        sa.Column("p_correct", sa.Double(), nullable=True),
        _timestamp("updated_at"),
        sa.ForeignKeyConstraint(
            ["question_id"],
            ["questions.id"],
            name=op.f("fk_question_stats_question_id_questions"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("question_id", name=op.f("pk_question_stats")),
    )
    op.create_table(
        "question_reports",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("question_id", sa.Uuid(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("status", sa.Text(), server_default="open", nullable=False),
        _timestamp("created_at"),
        sa.CheckConstraint(
            "reason IN ('wrong_answer', 'typo', 'unclear', 'other')",
            name=op.f("ck_question_reports_reason"),
        ),
        sa.CheckConstraint(
            "status IN ('open', 'resolved', 'dismissed')", name=op.f("ck_question_reports_status")
        ),
        _user_fk("question_reports"),
        sa.ForeignKeyConstraint(
            ["question_id"],
            ["questions.id"],
            name=op.f("fk_question_reports_question_id_questions"),
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_question_reports")),
    )
    op.create_index(
        "uq_question_reports_open",
        "question_reports",
        ["user_id", "question_id"],
        unique=True,
        postgresql_where=sa.text("status = 'open'"),
    )
    op.create_index("ix_question_reports_question_id", "question_reports", ["question_id"])
    op.create_index(
        "ix_question_reports_user_created", "question_reports", ["user_id", "created_at"]
    )
    op.create_table(
        "word_puzzles",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("external_id", sa.Text(), nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=False),
        sa.Column("word", sa.Text(), nullable=False),
        sa.Column("clue", sa.Text(), nullable=False),
        sa.Column("difficulty", sa.SmallInteger(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        _timestamp("created_at"),
        _timestamp("updated_at"),
        sa.CheckConstraint("word ~ '^[A-Z]{3,12}$'", name=op.f("ck_word_puzzles_word")),
        sa.CheckConstraint(DIFFICULTY, name=op.f("ck_word_puzzles_difficulty")),
        sa.CheckConstraint(STATUSES, name=op.f("ck_word_puzzles_status")),
        sa.CheckConstraint(SOURCES, name=op.f("ck_word_puzzles_source")),
        sa.ForeignKeyConstraint(
            ["subject_id"], ["subjects.id"], name=op.f("fk_word_puzzles_subject_id_subjects")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_word_puzzles")),
        sa.UniqueConstraint("external_id", name=op.f("uq_word_puzzles_external_id")),
    )


def _create_practice() -> None:
    op.create_table(
        "practice_sessions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("mode", sa.Text(), nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=True),
        sa.Column("passage_id", sa.Uuid(), nullable=True),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("settings", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("question_ids", postgresql.ARRAY(sa.Uuid()), nullable=False),
        sa.Column(
            "option_orders", postgresql.ARRAY(sa.SmallInteger(), dimensions=2), nullable=False
        ),
        _timestamp("created_at"),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "mode IN ('chapter', 'topic', 'category', 'review', 'bookmarks', 'challenge',"
            " 'passage')",
            name=op.f("ck_practice_sessions_mode"),
        ),
        sa.CheckConstraint(
            "cardinality(question_ids) BETWEEN 1 AND 50"
            " AND array_length(option_orders, 1) = cardinality(question_ids)",
            name=op.f("ck_practice_sessions_questions"),
        ),
        _user_fk("practice_sessions"),
        sa.ForeignKeyConstraint(
            ["subject_id"], ["subjects.id"], name=op.f("fk_practice_sessions_subject_id_subjects")
        ),
        sa.ForeignKeyConstraint(
            ["passage_id"], ["passages.id"], name=op.f("fk_practice_sessions_passage_id_passages")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_practice_sessions")),
    )
    unfinished = sa.text("finished_at IS NULL")
    op.create_index(
        "ix_practice_sessions_open",
        "practice_sessions",
        ["user_id", sa.text("created_at DESC")],
        postgresql_where=unfinished,
    )
    op.create_index(
        "ix_practice_sessions_expiring",
        "practice_sessions",
        ["expires_at"],
        postgresql_where=unfinished,
    )
    op.create_table(
        "practice_answers",
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("position", sa.SmallInteger(), nullable=False),
        sa.Column("question_id", sa.Uuid(), nullable=False),
        sa.Column("client_answer_id", sa.Text(), nullable=False),
        sa.Column("selected_option", sa.SmallInteger(), nullable=True),
        sa.Column("outcome", sa.Text(), nullable=False),
        sa.Column("time_ms", sa.Integer(), nullable=False),
        _counter("answer_changes", sa.SmallInteger()),
        sa.Column("answered_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(f"outcome {OUTCOMES}", name=op.f("ck_practice_answers_outcome")),
        sa.CheckConstraint(
            "selected_option BETWEEN 0 AND 3", name=op.f("ck_practice_answers_selected_option")
        ),
        sa.CheckConstraint("time_ms >= 0", name=op.f("ck_practice_answers_time_ms")),
        sa.ForeignKeyConstraint(
            ["session_id"],
            ["practice_sessions.id"],
            name=op.f("fk_practice_answers_session_id_practice_sessions"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["question_id"],
            ["questions.id"],
            name=op.f("fk_practice_answers_question_id_questions"),
        ),
        sa.PrimaryKeyConstraint("session_id", "position", name=op.f("pk_practice_answers")),
    )
    op.create_table(
        "attempt_keys",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("client_answer_id", sa.Text(), nullable=False),
        _timestamp("created_at"),
        _user_fk("attempt_keys"),
        sa.PrimaryKeyConstraint("user_id", "client_answer_id", name=op.f("pk_attempt_keys")),
    )
    op.create_index("ix_attempt_keys_created_at", "attempt_keys", ["created_at"])


def _create_attempts() -> None:
    op.create_table(
        "question_attempts",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("answered_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("question_id", sa.Uuid(), nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=False),
        sa.Column("chapter_id", sa.Integer(), nullable=True),
        sa.Column("topic_id", sa.Integer(), nullable=True),
        sa.Column("category", sa.Text(), nullable=False),
        sa.Column("difficulty", sa.SmallInteger(), nullable=False),
        sa.Column("mode", sa.Text(), nullable=False),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("position", sa.SmallInteger(), nullable=False),
        sa.Column("selected_option", sa.SmallInteger(), nullable=True),
        sa.Column("outcome", sa.Text(), nullable=False),
        sa.Column("time_ms", sa.Integer(), nullable=False),
        sa.Column("time_limit_ms", sa.Integer(), nullable=True),
        sa.Column("speed", sa.Text(), nullable=True),
        sa.Column("speed_basis", sa.Text(), nullable=True),
        sa.Column("peer_time_ms", sa.Integer(), nullable=True),
        _counter("answer_changes", sa.SmallInteger()),
        sa.Column("first_try", sa.Boolean(), nullable=False),
        sa.Column("points", sa.SmallInteger(), nullable=True),
        sa.Column("ist_day", sa.Date(), nullable=False),
        sa.CheckConstraint(
            "mode IN ('chapter', 'topic', 'category', 'challenge', 'review', 'bookmarks',"
            " 'fun_learn', 'quick_rated', 'quick_casual', 'bot', 'friend', 'group',"
            " 'tournament')",
            name=op.f("ck_question_attempts_mode"),
        ),
        sa.CheckConstraint(f"outcome {OUTCOMES}", name=op.f("ck_question_attempts_outcome")),
        sa.CheckConstraint(
            "speed IN ('fast', 'slow', 'even')", name=op.f("ck_question_attempts_speed")
        ),
        sa.CheckConstraint(
            "speed_basis IN ('opponents', 'typical')", name=op.f("ck_question_attempts_speed_basis")
        ),
        sa.CheckConstraint(CATEGORIES, name=op.f("ck_question_attempts_category")),
        sa.CheckConstraint(DIFFICULTY, name=op.f("ck_question_attempts_difficulty")),
        sa.CheckConstraint(
            "selected_option BETWEEN 0 AND 3", name=op.f("ck_question_attempts_selected_option")
        ),
        sa.CheckConstraint("time_ms >= 0", name=op.f("ck_question_attempts_time_ms")),
        _user_fk("question_attempts"),
        sa.ForeignKeyConstraint(
            ["question_id"],
            ["questions.id"],
            name=op.f("fk_question_attempts_question_id_questions"),
        ),
        sa.PrimaryKeyConstraint("id", "answered_at", name=op.f("pk_question_attempts")),
        postgresql_partition_by="RANGE (answered_at)",
    )
    op.create_index(
        "ix_question_attempts_user_answered",
        "question_attempts",
        ["user_id", sa.text("answered_at DESC")],
    )
    op.create_index(
        "ix_question_attempts_question_answered",
        "question_attempts",
        ["question_id", "answered_at"],
    )
    op.execute("CREATE TABLE question_attempts_default PARTITION OF question_attempts DEFAULT")
    op.execute(ENSURE_ATTEMPT_PARTITIONS)
    op.execute("SELECT ensure_attempt_partitions(3)")


def _create_user_progress() -> None:
    op.create_table(
        "user_questions",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("question_id", sa.Uuid(), nullable=False),
        sa.Column("first_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_at", sa.DateTime(timezone=True), nullable=True),
        _counter("attempts"),
        _counter("correct"),
        sa.Column("last_outcome", sa.Text(), nullable=True),
        sa.Column("review_box", sa.SmallInteger(), nullable=True),
        sa.Column("review_due_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("bookmarked_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(f"last_outcome {OUTCOMES}", name=op.f("ck_user_questions_last_outcome")),
        sa.CheckConstraint("review_box BETWEEN 1 AND 5", name=op.f("ck_user_questions_review_box")),
        sa.CheckConstraint(
            "(review_box IS NULL) = (review_due_at IS NULL)", name=op.f("ck_user_questions_review")
        ),
        _user_fk("user_questions"),
        sa.ForeignKeyConstraint(
            ["question_id"],
            ["questions.id"],
            name=op.f("fk_user_questions_question_id_questions"),
        ),
        sa.PrimaryKeyConstraint("user_id", "question_id", name=op.f("pk_user_questions")),
    )
    op.create_index(
        "ix_user_questions_review_due",
        "user_questions",
        ["user_id", "review_due_at"],
        postgresql_where=sa.text("review_box IS NOT NULL"),
    )
    op.create_index(
        "ix_user_questions_bookmarks",
        "user_questions",
        ["user_id", sa.text("bookmarked_at DESC")],
        postgresql_where=sa.text("bookmarked_at IS NOT NULL"),
    )
    op.create_table(
        "user_topic_stats",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("topic_id", sa.Integer(), nullable=False),
        *_totals(),
        _user_fk("user_topic_stats"),
        sa.ForeignKeyConstraint(
            ["topic_id"], ["topics.id"], name=op.f("fk_user_topic_stats_topic_id_topics")
        ),
        sa.PrimaryKeyConstraint("user_id", "topic_id", name=op.f("pk_user_topic_stats")),
    )
    op.create_table(
        "user_chapter_stats",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("chapter_id", sa.Integer(), nullable=False),
        _counter("seen"),
        *_totals(),
        _user_fk("user_chapter_stats"),
        sa.ForeignKeyConstraint(
            ["chapter_id"], ["chapters.id"], name=op.f("fk_user_chapter_stats_chapter_id_chapters")
        ),
        sa.PrimaryKeyConstraint("user_id", "chapter_id", name=op.f("pk_user_chapter_stats")),
    )
    op.create_table(
        "user_category_stats",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=False),
        sa.Column("category", sa.Text(), nullable=False),
        *_totals(),
        sa.CheckConstraint(CATEGORIES, name=op.f("ck_user_category_stats_category")),
        _user_fk("user_category_stats"),
        sa.ForeignKeyConstraint(
            ["subject_id"], ["subjects.id"], name=op.f("fk_user_category_stats_subject_id_subjects")
        ),
        sa.PrimaryKeyConstraint(
            "user_id", "subject_id", "category", name=op.f("pk_user_category_stats")
        ),
    )
    op.create_table(
        "user_daily_stats",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("day", sa.Date(), nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=False),
        _counter("attempts"),
        _counter("correct"),
        _counter("time_ms", sa.BigInteger()),
        sa.Column("last_at", sa.DateTime(timezone=True), nullable=False),
        _user_fk("user_daily_stats"),
        sa.ForeignKeyConstraint(
            ["subject_id"], ["subjects.id"], name=op.f("fk_user_daily_stats_subject_id_subjects")
        ),
        sa.PrimaryKeyConstraint("user_id", "day", "subject_id", name=op.f("pk_user_daily_stats")),
    )
    op.create_table(
        "user_tips",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("tip_key", sa.Text(), nullable=False),
        sa.Column("hidden_until", sa.DateTime(timezone=True), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        _timestamp("updated_at"),
        sa.CheckConstraint("reason IN ('acted', 'dismissed')", name=op.f("ck_user_tips_reason")),
        _user_fk("user_tips"),
        sa.PrimaryKeyConstraint("user_id", "tip_key", name=op.f("pk_user_tips")),
    )
    op.create_table(
        "user_progress",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        _counter("xp", sa.BigInteger()),
        sa.Column("practice_xp_day", sa.Date(), nullable=True),
        _counter("practice_xp_today"),
        _timestamp("updated_at"),
        sa.CheckConstraint("xp >= 0", name=op.f("ck_user_progress_xp")),
        sa.CheckConstraint(
            "practice_xp_today >= 0", name=op.f("ck_user_progress_practice_xp_today")
        ),
        _user_fk("user_progress"),
        sa.PrimaryKeyConstraint("user_id", name=op.f("pk_user_progress")),
    )
    op.create_table(
        "xp_events",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("source_key", sa.Text(), nullable=False),
        sa.Column("amount", sa.Integer(), nullable=False),
        sa.Column("ref_id", sa.Uuid(), nullable=True),
        sa.Column("ist_day", sa.Date(), nullable=False),
        _timestamp("created_at"),
        sa.CheckConstraint(
            "source IN ('practice', 'match', 'mission', 'achievement', 'adjustment')",
            name=op.f("ck_xp_events_source"),
        ),
        _user_fk("xp_events"),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_xp_events")),
        sa.UniqueConstraint("user_id", "source_key", name=op.f("uq_xp_events_user_id_source_key")),
    )


def downgrade() -> None:
    for table in (
        "xp_events",
        "user_progress",
        "user_tips",
        "user_daily_stats",
        "user_category_stats",
        "user_chapter_stats",
        "user_topic_stats",
        "user_questions",
    ):
        op.drop_table(table)
    op.execute("DROP FUNCTION ensure_attempt_partitions(integer)")
    op.drop_table("question_attempts")  # drops its partitions too
    for table in (
        "attempt_keys",
        "practice_answers",
        "practice_sessions",
        "word_puzzles",
        "question_reports",
        "question_stats",
        "questions",
        "passages",
        "topics",
        "chapters",
        "goal_subjects",
        "subjects",
        "goals",
    ):
        op.drop_table(table)
    op.drop_constraint(op.f("ck_users_ban_reason"), "users", type_="check")
    op.drop_column("users", "banned_until")
    op.drop_column("users", "ban_reason")
