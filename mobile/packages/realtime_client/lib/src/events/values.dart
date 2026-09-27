part of '../events.dart';

// Enums. Each keeps its wire spelling, and values this client doesn't know parse to `unknown` so a
// newer server can add values within v1.

/// Match phases: `ready_wait` → `countdown` → (`q_open` → `q_reveal`) × N → `finished`, or
/// `aborted` / `voided`.
enum MatchPhase {
  readyWait('ready_wait'),
  countdown('countdown'),
  qOpen('q_open'),
  qReveal('q_reveal'),
  finished('finished'),
  aborted('aborted'),
  voided('voided'),
  unknown('?');

  const MatchPhase(this.wire);

  final String wire;

  static MatchPhase parse(String wire) => _parse(values, wire, (v) => v.wire, unknown);

  /// Whether the match is over (finished, aborted or voided).
  bool get isOver => this == finished || this == aborted || this == voided;
}

/// The server's verdict on one answer (`ans.ack.status`, `match.snapshot.mine[].status`), plus the
/// local [pending] state between tapping an option and the ack.
enum AnswerStatus {
  pending('pending'),
  accepted('accepted'),
  late('late'),
  dup('dup'),
  tooEarly('too_early'),
  invalid('invalid'),
  wrongPhase('wrong_phase'),
  unknown('?');

  const AnswerStatus(this.wire);

  final String wire;

  static AnswerStatus parse(String wire) => _parse(values, wire, (v) => v.wire, unknown);
}

/// Speed labels in `q.reveal` (section 7). Bot games have none.
enum Speed {
  fast('fast'),
  slow('slow'),
  even('even');

  const Speed(this.wire);

  final String wire;

  /// Returns `null` for `null` and for labels this client doesn't know.
  static Speed? parse(String? wire) {
    for (final speed in values) {
      if (speed.wire == wire) return speed;
    }
    return null;
  }
}

/// A player's connection as other players see it (`opp.conn.state`).
enum Presence {
  connected('connected'),
  reconnecting('reconnecting'),
  left('left'),
  unknown('?');

  const Presence(this.wire);

  final String wire;

  static Presence parse(String wire) => _parse(values, wire, (v) => v.wire, unknown);
}

/// `match.end.result`, from the receiving player's point of view.
enum MatchResult {
  win('win'),
  loss('loss'),
  draw('draw'),
  unknown('?');

  const MatchResult(this.wire);

  final String wire;

  static MatchResult parse(String wire) => _parse(values, wire, (v) => v.wire, unknown);
}

/// `match.end.reason`.
enum MatchEndReason {
  normal('normal'),
  forfeit('forfeit'),
  opponentForfeit('opponent_forfeit'),
  aborted('aborted'),
  voided('voided'),
  left('left'),
  disconnected('disconnected'),
  noShow('no_show'),
  endedByHost('ended_by_host'),
  unknown('?');

  const MatchEndReason(this.wire);

  final String wire;

  static MatchEndReason parse(String wire) => _parse(values, wire, (v) => v.wire, unknown);
}

/// `rematch.status.state`.
enum RematchState {
  offered('offered'),
  accepted('accepted'),
  declined('declined'),
  expired('expired'),
  failed('failed'),
  unknown('?');

  const RematchState(this.wire);

  final String wire;

  static RematchState parse(String wire) => _parse(values, wire, (v) => v.wire, unknown);
}

/// `invite.updated.status`.
enum InviteStatus {
  accepted('accepted'),
  declined('declined'),
  expired('expired'),
  cancelled('cancelled'),
  unknown('?');

  const InviteStatus(this.wire);

  final String wire;

  static InviteStatus parse(String wire) => _parse(values, wire, (v) => v.wire, unknown);
}

/// What an [ActiveEntry] is.
enum ActiveKind {
  queue('queue'),
  match('match'),
  room('room'),
  tournament('tournament'),
  unknown('?');

  const ActiveKind(this.wire);

  final String wire;

  static ActiveKind parse(String wire) => _parse(values, wire, (v) => v.wire, unknown);
}

T _parse<T>(List<T> values, String wire, String Function(T value) wireOf, T fallback) {
  for (final value in values) {
    if (value != fallback && wireOf(value) == wire) return value;
  }
  return fallback;
}

// Value types shared by several messages.

/// A player card (`mm.found.opponent`, `match.snapshot.players[]`, `room.state.members[]`, …).
///
/// Only the user id is required. It is read from `uid`, or from `id` as in the REST user card;
/// the name from `name` or `display_name`. The whole card stays in [raw] for the UI (handle,
/// avatar, level, …).
final class PlayerCard {
  const PlayerCard({required this.uid, this.name, this.rating, this.record, this.raw = const {}});

  final String uid;
  final String? name;

  /// The player's rating, when the card carries one (`mm.found.opponent.rating`).
  final PlayerRating? rating;

  /// My head-to-head record against this player (`mm.found.opponent.record`).
  final HeadToHead? record;

  /// Every field of the card as sent.
  final Map<String, Object?> raw;

  @override
  String toString() => 'PlayerCard($uid)';
}

PlayerCard _readCard(JsonObject json) {
  final uid = json.optString('uid') ?? json.optString('id');
  if (uid == null) throw FormatException('${json.context}: missing required field "uid"');
  final rating = json.optObject('rating');
  final record = json.optObject('record');
  return PlayerCard(
    uid: uid,
    name: json.optString('name') ?? json.optString('display_name'),
    rating: rating == null
        ? null
        : PlayerRating(
            display: _displayString(rating, 'display'),
            value: rating.optInt('value'),
            provisional: rating.optBool('provisional') ?? false,
          ),
    record: record == null
        ? null
        : HeadToHead(
            wins: record.integer('wins'),
            losses: record.integer('losses'),
            draws: record.optInt('draws') ?? 0,
          ),
    raw: json.map,
  );
}

/// A rating as the app shows it: `—` before any rated game, `1523?` while provisional.
final class PlayerRating {
  const PlayerRating({required this.display, this.value, this.provisional = false});

  final String display;
  final int? value;
  final bool provisional;
}

/// A head-to-head record.
final class HeadToHead {
  const HeadToHead({required this.wins, required this.losses, this.draws = 0});

  final int wins;
  final int losses;
  final int draws;
}

/// One answer option. [id] is a fresh random id per match, so it reveals nothing.
final class AnswerOption {
  const AnswerOption({required this.id, required this.text});

  final String id;
  final String text;
}

AnswerOption _readOption(JsonObject json) =>
    AnswerOption(id: json.string('id'), text: json.string('text'));

/// A question as sent by `q.show` (and embedded in `match.snapshot`).
final class ShownQuestion {
  const ShownQuestion({
    required this.q,
    required this.total,
    required this.stem,
    required this.options,
    required this.shownAt,
    required this.deadlineAt,
    required this.limitMs,
    this.chapter,
  });

  /// 1-based question number.
  final int q;
  final int total;
  final String stem;
  final List<AnswerOption> options;

  /// Server ms when the question goes live. `q.show` arrives about 400 ms earlier.
  final int shownAt;

  /// Server ms when answering closes.
  final int deadlineAt;
  final int limitMs;
  final String? chapter;

  /// Whether the question may be shown yet: the synced server clock has reached [shownAt].
  ///
  /// Pass `ServerClock.nowServerMs()`. Until this is true the UI keeps the question hidden.
  bool revealedAt(int serverNowMs) => serverNowMs >= shownAt;

  /// Milliseconds until [deadlineAt] at [serverNowMs], never negative. Drives the countdown ring.
  int remainingMs(int serverNowMs) => math.max(0, deadlineAt - serverNowMs);

  /// Milliseconds since [shownAt] at [serverNowMs], never negative. A fallback for `el_ms`.
  int elapsedMs(int serverNowMs) => math.max(0, serverNowMs - shownAt);

  @override
  String toString() => 'ShownQuestion(q$q/$total)';
}

ShownQuestion _readShownQuestion(JsonObject json) {
  final shownAt = json.integer('shown_at');
  final deadlineAt = json.integer('deadline_at');
  return ShownQuestion(
    q: json.integer('q'),
    total: json.integer('total'),
    stem: json.string('stem'),
    options: json.objects('options', _readOption),
    shownAt: shownAt,
    deadlineAt: deadlineAt,
    limitMs: json.optInt('limit_ms') ?? deadlineAt - shownAt,
    chapter: json.optString('chapter'),
  );
}

/// One player's line in `q.reveal.players`.
final class PlayerReveal {
  const PlayerReveal({
    required this.opt,
    required this.correct,
    required this.pts,
    this.timeMs,
    this.speed,
  });

  /// The option the player picked, or `null` if they didn't answer.
  final String? opt;
  final bool correct;
  final int pts;

  /// The player's effective answer time.
  final int? timeMs;

  /// `null` in bot games, or when the label is unknown.
  final Speed? speed;
}

PlayerReveal _readPlayerReveal(JsonObject json) => PlayerReveal(
  opt: json.optString('opt'),
  correct: json.boolean('correct'),
  pts: json.integer('pts'),
  timeMs: json.optInt('time_ms'),
  speed: Speed.parse(json.optString('speed')),
);

/// Running totals for one player.
final class PlayerTotals {
  const PlayerTotals({required this.points, required this.correct});

  static const zero = PlayerTotals(points: 0, correct: 0);

  final int points;
  final int correct;

  @override
  bool operator ==(Object other) =>
      other is PlayerTotals && other.points == points && other.correct == correct;

  @override
  int get hashCode => Object.hash(points, correct);

  @override
  String toString() => 'PlayerTotals($points pts, $correct correct)';
}

PlayerTotals _readTotals(JsonObject json) =>
    PlayerTotals(points: json.integer('points'), correct: json.optInt('correct') ?? 0);

/// The result of one question (`q.reveal`, and `match.snapshot.reveal`).
final class RevealResult {
  const RevealResult({
    required this.q,
    required this.correctOption,
    required this.players,
    required this.totals,
    this.standings = const [],
    this.ref,
  });

  final int q;

  /// The id of the correct option.
  final String correctOption;
  final Map<String, PlayerReveal> players;
  final Map<String, PlayerTotals> totals;

  /// The between-questions leaderboard of a group battle; empty otherwise.
  final List<GroupStanding> standings;

  /// Identifies the question in this match, for the review screen.
  final String? ref;
}

RevealResult _readReveal(JsonObject json) => RevealResult(
  q: json.integer('q'),
  correctOption: json.string('correct'),
  players: json.objectMap('players', _readPlayerReveal),
  totals: json.optObjectMap('totals', _readTotals) ?? const {},
  standings: json.optObjects('standings', _readStanding) ?? const [],
  ref: json.optString('ref'),
);

/// One row of a group battle's between-questions leaderboard (`q.reveal.standings`).
final class GroupStanding {
  const GroupStanding({
    required this.uid,
    required this.points,
    required this.place,
    this.change = 0,
  });

  final String uid;
  final int points;

  /// 1 for the leader.
  final int place;

  /// Places gained since the previous question (negative when dropping).
  final int change;

  @override
  String toString() => 'GroupStanding(#$place $uid, $points pts)';
}

GroupStanding _readStanding(JsonObject json) => GroupStanding(
  uid: json.string('uid'),
  points: json.integer('points'),
  place: json.integer('place'),
  change: json.optInt('change') ?? 0,
);

/// One entry of `match.snapshot.players`: a card plus live state.
final class SnapshotPlayer {
  const SnapshotPlayer({
    required this.card,
    required this.presence,
    required this.score,
    required this.answered,
    this.correct,
    this.graceUntil,
  });

  final PlayerCard card;
  final Presence presence;

  /// Points so far.
  final int score;

  /// Whether the player has answered the current question.
  final bool answered;

  /// Correct answers so far, if the server sends it.
  final int? correct;
  final int? graceUntil;

  String get uid => card.uid;
}

SnapshotPlayer _readSnapshotPlayer(JsonObject json) => SnapshotPlayer(
  card: _readCard(json),
  presence: _readPresence(json, 'connected'),
  score: json.integer('score'),
  answered: json.optBool('answered') ?? false,
  correct: json.optInt('correct'),
  graceUntil: json.optInt('grace_until'),
);

/// Accepts `connected: true/false` or a [Presence] string.
Presence _readPresence(JsonObject json, String key) {
  final value = json.map[key];
  return switch (value) {
    true => Presence.connected,
    false => Presence.reconnecting,
    final String state => Presence.parse(state),
    _ => throw FormatException('${json.context}: "$key" must be a boolean or a state string'),
  };
}

/// One of my answers in `match.snapshot.mine`.
final class MineEntry {
  const MineEntry({required this.q, required this.opt, required this.status});

  final int q;
  final String? opt;
  final AnswerStatus status;
}

MineEntry _readMine(JsonObject json) => MineEntry(
  q: json.integer('q'),
  opt: json.optString('opt'),
  status: AnswerStatus.parse(json.string('status')),
);

/// Where the questions of a match come from (`mm.found.sources`).
final class SourceChapter {
  const SourceChapter({required this.chapter, required this.count, this.name});

  /// The chapter slug, for example `kinematics`.
  final String chapter;
  final int count;

  /// The chapter's display name, for example `Motion in a Straight Line`.
  final String? name;
}

SourceChapter _readSource(JsonObject json) => SourceChapter(
  chapter: json.string('chapter'),
  count: json.integer('count'),
  name: json.optString('name'),
);

/// Something the user is in right now: a queue ticket, a match, a room or a tournament.
///
/// `welcome.active` entries carry [channel] and [state]; the `details.active` of a `BUSY` error
/// carries [id] and [title] (see [RealtimeError.active]).
final class ActiveEntry {
  const ActiveEntry({
    required this.kind,
    this.channel,
    this.state,
    this.id,
    this.title,
    this.raw = const {},
  });

  /// Reads an entry, or returns `null` if [json] isn't a valid one.
  static ActiveEntry? tryParse(Object? json) {
    try {
      return _readActive(JsonObject.from(json, 'active'));
    } on FormatException {
      return null;
    }
  }

  final ActiveKind kind;

  /// The channel to rejoin, for example `m:<match_id>`.
  final String? channel;

  /// For a match, its phase (`q_open`, …).
  final String? state;

  /// The match, room, queue ticket or tournament id.
  final String? id;

  /// What to call it on a "Go there" button, for example the tournament's name.
  final String? title;

  /// Every field as sent (including an `action` route, if any).
  final Map<String, Object?> raw;

  @override
  String toString() => 'ActiveEntry(${kind.name}, ${channel ?? id ?? '-'})';
}

ActiveEntry _readActive(JsonObject json) => ActiveEntry(
  kind: ActiveKind.parse(json.string('kind')),
  channel: json.optString('ch'),
  state: json.optString('state'),
  id: json.optString('id'),
  title: json.optString('title'),
  raw: json.map,
);

/// `match.settled.rating`. Ratings are display strings; a trailing `?` marks a provisional one.
final class RatingChange {
  const RatingChange({
    required this.scope,
    required this.before,
    required this.after,
    required this.delta,
  });

  final String scope;
  final String before;
  final String after;
  final int delta;
}

RatingChange _readRating(JsonObject json) => RatingChange(
  scope: json.string('scope'),
  before: _displayString(json, 'before'),
  after: _displayString(json, 'after'),
  delta: json.integer('delta'),
);

/// Accepts a string or a number (a rating might be sent as `1502`).
String _displayString(JsonObject json, String key) {
  final value = json.map[key];
  return switch (value) {
    final String text => text,
    final num number => asInt(number)?.toString() ?? number.toString(),
    _ => json.string(key),
  };
}

/// `match.settled.coins`.
final class CoinsChange {
  const CoinsChange({
    required this.delta,
    required this.balance,
    this.capped = false,
    this.resetsAt,
  });

  final int delta;
  final int balance;

  /// Whether a daily earning cap limited [delta].
  final bool capped;

  /// When the cap resets (server ms).
  final int? resetsAt;
}

/// `match.settled.xp`.
final class XpChange {
  const XpChange({
    required this.delta,
    required this.level,
    required this.intoLevel,
    required this.forNext,
    this.levelUp = false,
    this.capped = false,
    this.resetsAt,
  });

  final int delta;
  final int level;
  final int intoLevel;
  final int forNext;

  /// Whether this game took the player to [level]: time for the celebration.
  final bool levelUp;

  /// Whether a daily earning cap limited [delta].
  final bool capped;

  /// When the cap resets (server ms).
  final int? resetsAt;
}

/// One entry of `match.settled.missions`.
final class MissionProgress {
  const MissionProgress({
    required this.id,
    required this.progress,
    required this.target,
    required this.done,
    this.title,
  });

  final String id;
  final int progress;
  final int target;
  final bool done;
  final String? title;
}

/// `match.settled.rank`: where the game left the player on a leaderboard.
sealed class RankUpdate {
  const RankUpdate(this.board);

  /// The leaderboard, for example `rating:physics`.
  final String board;
}

/// `{board, before, after}`: the player's position moved (or stayed).
final class RankMoved extends RankUpdate {
  const RankMoved({required String board, required this.after, this.before}) : super(board);

  /// The previous position, or `null` if the player wasn't ranked yet.
  final int? before;
  final int after;

  /// Places gained (positive when moving up, since 1 is the top).
  int get change => before == null ? 0 : before! - after;
}

/// `{board, games_to_rank}`: not ranked yet; this many more rated games are needed.
final class RankPending extends RankUpdate {
  const RankPending({required String board, required this.gamesToRank}) : super(board);

  final int gamesToRank;
}

RankUpdate _readRank(JsonObject json) {
  final board = json.string('board');
  final gamesToRank = json.optInt('games_to_rank');
  if (gamesToRank != null) return RankPending(board: board, gamesToRank: gamesToRank);
  return RankMoved(board: board, before: json.optInt('before'), after: json.integer('after'));
}

/// `match.settled.streak`.
final class StreakUpdate {
  const StreakUpdate({required this.days, required this.extended});

  final int days;

  /// Whether this game extended the streak today.
  final bool extended;
}

/// An achievement earned (`match.settled.achievements[]`).
final class Achievement {
  const Achievement({required this.id, required this.title});

  final String id;
  final String title;
}

/// The one-line coaching tip on the result screen (`match.settled.tip`).
final class Tip {
  const Tip({required this.message, this.action, this.params = const {}});

  final String message;

  /// What the tip's button does, for example `practice`.
  final String? action;
  final Map<String, Object?> params;
}

/// Everything `match.settled` reports.
final class Settlement {
  const Settlement({
    this.rating,
    this.rank,
    this.coins,
    this.xp,
    this.missions = const [],
    this.streak,
    this.achievements = const [],
    this.tip,
  });

  /// `null` for unrated games.
  final RatingChange? rating;

  /// `null` when the game doesn't touch a leaderboard.
  final RankUpdate? rank;
  final CoinsChange? coins;
  final XpChange? xp;
  final List<MissionProgress> missions;
  final StreakUpdate? streak;
  final List<Achievement> achievements;
  final Tip? tip;
}

Settlement _readSettlement(JsonObject json) {
  final rating = json.optObject('rating');
  final rank = json.optObject('rank');
  final coins = json.optObject('coins');
  final xp = json.optObject('xp');
  final streak = json.optObject('streak');
  final tip = json.optObject('tip');
  return Settlement(
    rating: rating == null ? null : _readRating(rating),
    rank: rank == null ? null : _readRank(rank),
    coins: coins == null
        ? null
        : CoinsChange(
            delta: coins.integer('delta'),
            balance: coins.integer('balance'),
            capped: coins.optBool('capped') ?? false,
            resetsAt: coins.optTimestamp('resets_at'),
          ),
    xp: xp == null
        ? null
        : XpChange(
            delta: xp.integer('delta'),
            level: xp.integer('level'),
            intoLevel: xp.integer('into_level'),
            forNext: xp.integer('for_next'),
            levelUp: xp.optBool('level_up') ?? false,
            capped: xp.optBool('capped') ?? false,
            resetsAt: xp.optTimestamp('resets_at'),
          ),
    missions:
        json.optObjects(
          'missions',
          (m) => MissionProgress(
            id: m.string('id'),
            progress: m.integer('progress'),
            target: m.integer('target'),
            done: m.boolean('done'),
            title: m.optString('title'),
          ),
        ) ??
        const [],
    streak: streak == null
        ? null
        : StreakUpdate(days: streak.integer('days'), extended: streak.optBool('extended') ?? false),
    achievements:
        json.optObjects(
          'achievements',
          (a) => Achievement(id: a.string('id'), title: a.string('title')),
        ) ??
        const [],
    tip: tip == null
        ? null
        : Tip(
            message: tip.string('message'),
            action: tip.optString('action'),
            params: tip.optObject('params')?.map ?? const {},
          ),
  );
}

/// One member of a room lobby (`room.state.members`).
final class RoomMember {
  const RoomMember({
    required this.card,
    required this.ready,
    required this.connected,
    required this.role,
  });

  final PlayerCard card;
  final bool ready;
  final bool connected;

  /// `host` or `member`, as sent.
  final String role;

  String get uid => card.uid;
}

RoomMember _readMember(JsonObject json) => RoomMember(
  card: _readCard(json),
  ready: json.optBool('ready') ?? false,
  connected: json.optBool('connected') ?? true,
  role: json.optString('role') ?? 'member',
);

/// A rematch on offer in a room lobby (`room.state.rematch`).
final class RoomRematch {
  const RoomRematch({required this.offeredBy, this.until});

  /// The uid of the member who offered it.
  final String offeredBy;

  /// When the offer lapses (server ms).
  final int? until;
}

/// Where tapping an inbox item goes (`notify.action`).
final class NotifyAction {
  const NotifyAction({required this.route, this.params = const {}});

  /// An app route, for example `/arena/<id>`.
  final String route;
  final Map<String, Object?> params;
}

/// One row of `t.standings`. Tie-break columns (`bh_c1`, …) stay in [raw].
final class StandingRow {
  const StandingRow({this.rank, this.uid, this.name, this.points, this.raw = const {}});

  final int? rank;
  final String? uid;
  final String? name;
  final num? points;
  final Map<String, Object?> raw;
}

StandingRow _readStandingRow(JsonObject json) => StandingRow(
  rank: json.optInt('rank'),
  uid: json.optString('uid'),
  name: json.optString('name'),
  points: json.optNum('points'),
  raw: json.map,
);
