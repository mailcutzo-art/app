"""The admin's edit forms (plain WTForms, so every field is explicit and validated)."""

import json
from typing import Any

from wtforms import (
    DateTimeLocalField,
    Form,
    IntegerField,
    SelectField,
    SelectMultipleField,
    StringField,
    TextAreaField,
    ValidationError,
)
from wtforms.validators import DataRequired, InputRequired, Length, NumberRange, Optional

from app.modules.content.models import BattlePool, Category, ContentStatus
from app.modules.content.rules import MAX_EXPLANATION, MAX_OPTION, MAX_STEM
from app.modules.users.models import BanReason, Role, UserStatus

ANSWER_LETTERS = ("A", "B", "C", "D")
# Statuses an admin may set; pending_deletion and deleted belong to the account deletion flow.
ADMIN_USER_STATUSES = (UserStatus.ACTIVE, UserStatus.RESTRICTED, UserStatus.BANNED)


def _choices(values: Any) -> list[tuple[str, str]]:
    return [(str(value), str(value).replace("_", " ").capitalize()) for value in values]


class UserForm(Form):
    status = SelectField("Status", choices=_choices(ADMIN_USER_STATUSES))
    roles = SelectMultipleField(
        "Roles",
        choices=_choices(Role),
        description="Every account keeps the user role.",
    )
    ban_reason = SelectField(
        "Ban reason", choices=[("", "—"), *_choices(BanReason)], validators=[Optional()]
    )
    banned_until = DateTimeLocalField(
        "Banned until (UTC; empty for a permanent ban)",
        format=["%Y-%m-%dT%H:%M", "%Y-%m-%dT%H:%M:%S"],
        validators=[Optional()],
    )


class QuestionForm(Form):
    topic_id = IntegerField(
        "Topic id",
        validators=[Optional()],
        description="The topic (module); the chapter follows from it. Passage questions have none.",
    )
    category = SelectField("Category", choices=_choices(Category))
    difficulty = IntegerField("Difficulty (1–5)", validators=[InputRequired(), NumberRange(1, 5)])
    exams = SelectMultipleField(
        "Exams",
        choices=[("neet", "NEET"), ("jee", "JEE")],
        description="None selected: every exam that includes the subject.",
    )
    battle_pool = SelectField("Battle pool", choices=_choices(BattlePool))
    status = SelectField("Status", choices=_choices(ContentStatus))
    stem = TextAreaField("Stem", validators=[DataRequired(), Length(max=MAX_STEM)])
    option_a = StringField("Option A", validators=[DataRequired(), Length(max=MAX_OPTION)])
    option_b = StringField("Option B", validators=[DataRequired(), Length(max=MAX_OPTION)])
    option_c = StringField("Option C", validators=[DataRequired(), Length(max=MAX_OPTION)])
    option_d = StringField("Option D", validators=[DataRequired(), Length(max=MAX_OPTION)])
    answer = SelectField(
        "Correct option",
        choices=[(letter, letter) for letter in ANSWER_LETTERS],
        description="Exactly one option is correct.",
    )
    explanation = TextAreaField(
        "Explanation", validators=[DataRequired(), Length(max=MAX_EXPLANATION)]
    )
    tags = StringField("Tags", description="Separated by commas.", validators=[Optional()])


class PassageForm(Form):
    title = StringField("Title", validators=[DataRequired(), Length(max=120)])
    body = TextAreaField("Body", validators=[DataRequired(), Length(min=300, max=2400)])
    difficulty = IntegerField("Difficulty (1–5)", validators=[InputRequired(), NumberRange(1, 5)])
    status = SelectField("Status", choices=_choices(ContentStatus))


class WordPuzzleForm(Form):
    external_id = StringField(
        "Id", validators=[DataRequired(), Length(max=64)], description="Unique, e.g. che-word-101"
    )
    subject_id = IntegerField("Subject id", validators=[InputRequired()])
    word = StringField("Word (3–12 letters A–Z)", validators=[DataRequired(), Length(3, 12)])
    clue = StringField("Clue", validators=[DataRequired(), Length(10, 200)])
    difficulty = IntegerField("Difficulty (1–5)", validators=[InputRequired(), NumberRange(1, 5)])
    status = SelectField("Status", choices=_choices(ContentStatus))

    def validate_word(self, field: StringField) -> None:
        value = (field.data or "").strip().upper()
        if not value.isascii() or not value.isalpha():
            raise ValidationError("Use the letters A–Z only.")
        field.data = value


class AppConfigForm(Form):
    key = StringField("Key", validators=[DataRequired(), Length(max=64)])
    value = TextAreaField(
        "Value (JSON)",
        validators=[DataRequired()],
        description='For example true, 42, "text" or null.',
    )

    def validate_value(self, field: TextAreaField) -> None:
        try:
            json.loads(field.data or "")
        except json.JSONDecodeError as exc:
            raise ValidationError(f"Not valid JSON: {exc.msg}.") from exc
