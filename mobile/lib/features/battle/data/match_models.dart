import 'package:flutter/foundation.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../../core/network/json.dart';

/// Reads a `match.settled`-shaped object with the realtime client's own parser, so REST and the
/// socket agree on every field. Returns null for anything it can't read.
Settlement? parseSettlement(Object? json) {
  if (json is! Map<String, Object?>) return null;
  try {
    final event = ServerEvent.fromEnvelope(Envelope(type: 'match.settled', data: json));
    return event is MatchSettledEvent ? event.settlement : null;
  } on FormatException catch (e) {
    debugPrint('Ignoring an unreadable settlement: $e');
    return null;
  }
}

/// A player card from REST (`{id, handle, display_name, avatar, level}`) or the socket (`uid`).
PlayerCard? parsePlayerCard(Object? json) {
  if (json is! Map) return null;
  final uid = json['uid'] ?? json['id'];
  if (uid is! String) return null;
  final avatar = json['avatar'];
  final level = json['level'];
  return PlayerCard(
    uid: uid,
    handle: json['handle'] is String ? json['handle']! as String : null,
    displayName: json['display_name'] is String ? json['display_name']! as String : null,
    avatar: avatar is Map
        ? PlayerAvatar(
            tone: avatar['tone'] is String ? avatar['tone']! as String : null,
            symbol: avatar['symbol'] is String ? avatar['symbol']! as String : null,
          )
        : null,
    level: level is num ? level.round() : null,
    isBot: json['is_bot'] == true,
    raw: {
      for (final MapEntry(:key, :value) in json.entries)
        if (key is String) key: value,
    },
  );
}

/// Where a match stands on the server (`GET /v1/matches/{id}`).
enum MatchStatus {
  live('live'),
  settling('settling'),
  settled('settled'),
  aborted('aborted'),
  voided('voided'),
  unknown('?');

  const MatchStatus(this.wire);

  final String wire;

  static MatchStatus parse(Object? value) =>
      values.where((s) => s != unknown && s.wire == value).firstOrNull ?? unknown;
}

/// A match's result as REST reports it: the history row plus status, totals and settlement.
@immutable
class MatchSummary {
  const MatchSummary({
    required this.id,
    required this.status,
    this.kind,
    this.subject,
    this.chapters = const [],
    this.result,
    this.reason,
    this.scoreMe,
    this.scoreOther,
    this.opponents = const [],
    this.ratingDelta,
    this.coinsDelta,
    this.totals = const {},
    this.settlement,
  });

  factory MatchSummary.fromJson(Object? json) {
    final r = JsonReader(json, 'match');
    final score = r['score'];
    final totals = r['totals'];
    return MatchSummary(
      id: r.string('id'),
      status: MatchStatus.parse(r['status']),
      kind: r['kind'] is String ? r['kind']! as String : null,
      subject: r['subject'] is String ? r['subject']! as String : null,
      chapters: [
        if (r['chapters'] case final List<Object?> names)
          for (final name in names)
            if (name is String) name,
      ],
      result: r['result'] is String ? r['result']! as String : null,
      reason: r['reason'] is String ? r['reason']! as String : null,
      scoreMe: score is Map && score['me'] is num ? (score['me']! as num).round() : null,
      scoreOther: score is Map && score['best_other'] is num
          ? (score['best_other']! as num).round()
          : null,
      opponents: [
        if (r['opponents'] case final List<Object?> cards)
          for (final card in cards) ?parsePlayerCard(card),
      ],
      ratingDelta: r['rating_delta'] is num ? (r['rating_delta']! as num).round() : null,
      coinsDelta: r['coins_delta'] is num ? (r['coins_delta']! as num).round() : null,
      totals: {
        if (totals is Map)
          for (final MapEntry(:key, :value) in totals.entries)
            if (key is String && value is Map && value['points'] is num)
              key: PlayerTotals(
                points: (value['points']! as num).round(),
                correct: value['correct'] is num ? (value['correct']! as num).round() : 0,
              ),
      },
      settlement: parseSettlement(r['settlement']),
    );
  }

  final String id;
  final MatchStatus status;
  final String? kind;
  final String? subject;
  final List<String> chapters;

  /// `win`, `loss`, `draw`, `aborted` or `voided`.
  final String? result;
  final String? reason;
  final int? scoreMe;
  final int? scoreOther;
  final List<PlayerCard> opponents;
  final int? ratingDelta;
  final int? coinsDelta;
  final Map<String, PlayerTotals> totals;

  /// Null while the server is still settling.
  final Settlement? settlement;

  bool get isOver => status != MatchStatus.live;

  /// The result in the socket's terms, for the result screen.
  MatchOutcome? outcome({required String me}) {
    final result = this.result;
    if (result == null || status == MatchStatus.live) return null;
    final opponent = opponents.firstOrNull?.uid;
    final (MatchResult matchResult, MatchEndReason defaultReason) = switch (result) {
      'win' => (MatchResult.win, MatchEndReason.normal),
      'loss' => (MatchResult.loss, MatchEndReason.normal),
      'draw' => (MatchResult.draw, MatchEndReason.normal),
      'aborted' => (MatchResult.draw, MatchEndReason.aborted),
      'voided' => (MatchResult.draw, MatchEndReason.voided),
      _ => (MatchResult.unknown, MatchEndReason.normal),
    };
    final parsedReason = reason == null ? null : MatchEndReason.parse(reason!);
    return MatchOutcome(
      result: matchResult,
      reason: parsedReason == null || parsedReason == MatchEndReason.unknown
          ? defaultReason
          : parsedReason,
      totals: totals.isNotEmpty
          ? totals
          : {
              if (scoreMe != null) me: PlayerTotals(points: scoreMe!, correct: 0),
              if (opponent != null && scoreOther != null)
                opponent: PlayerTotals(points: scoreOther!, correct: 0),
            },
    );
  }
}

/// One option of a reviewed question.
@immutable
class ReviewOption {
  const ReviewOption({required this.id, required this.text});

  final String id;
  final String text;
}

/// One question of `GET /v1/matches/{id}/review`.
@immutable
class ReviewQuestion {
  const ReviewQuestion({
    required this.q,
    required this.ref,
    required this.stem,
    required this.options,
    required this.correct,
    this.explanation = '',
    this.chapter,
    this.topic,
    this.players = const {},
    this.bookmarked = false,
  });

  factory ReviewQuestion.fromJson(Object? json) {
    final r = JsonReader(json, 'review question');
    final players = r['players'];
    return ReviewQuestion(
      q: r.integer('q'),
      ref: r.string('ref'),
      stem: r.string('stem'),
      options: r.list('options', (o) {
        final option = JsonReader(o, 'review option');
        return ReviewOption(id: option.string('id'), text: option.string('text'));
      }),
      correct: r.string('correct'),
      explanation: r['explanation'] is String ? r['explanation']! as String : '',
      chapter: r['chapter'] is String ? r['chapter']! as String : null,
      topic: r['topic'] is String ? r['topic']! as String : null,
      players: {
        if (players is Map)
          for (final MapEntry(:key, :value) in players.entries)
            if (key is String && value is Map)
              key: PlayerReveal(
                opt: value['opt'] is String ? value['opt']! as String : null,
                correct: value['correct'] == true,
                pts: value['pts'] is num ? (value['pts']! as num).round() : 0,
                timeMs: value['time_ms'] is num ? (value['time_ms']! as num).round() : null,
                speed: Speed.parse(value['speed'] is String ? value['speed']! as String : null),
              ),
      },
      bookmarked: r['bookmarked'] == true,
    );
  }

  final int q;

  /// Identifies the question for bookmarks.
  final String ref;
  final String stem;
  final List<ReviewOption> options;

  /// The id of the correct option.
  final String correct;
  final String explanation;
  final String? chapter;
  final String? topic;
  final Map<String, PlayerReveal> players;
  final bool bookmarked;
}

/// `GET /v1/matches/{id}/review`. Only ever held in memory.
@immutable
class MatchReview {
  const MatchReview({required this.questions});

  factory MatchReview.fromJson(Object? json) {
    final r = JsonReader(json, 'match review');
    return MatchReview(
      questions: [...r.list('questions', ReviewQuestion.fromJson)]..sort((a, b) => a.q - b.q),
    );
  }

  final List<ReviewQuestion> questions;
}
