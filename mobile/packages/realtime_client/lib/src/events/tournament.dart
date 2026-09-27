part of '../events.dart';

/// `t.standings`: sent in reply to `sub`, then at most every 2 s (section 9).
final class TStandingsEvent extends ServerEvent {
  TStandingsEvent._(super.envelope, {required this.round, required this.rows, required this.me});

  factory TStandingsEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    final me = d.optObject('me');
    return TStandingsEvent._(
      envelope,
      round: d.integer('round'),
      rows: d.objects('rows', _readStandingRow),
      me: me == null ? null : _readStandingRow(me),
    );
  }

  final int round;
  final List<StandingRow> rows;

  /// My own row, which may be outside [rows].
  final StandingRow? me;

  /// The tournament id, from the `t:<id>` channel.
  String? get tournamentId {
    final ch = channel;
    return ch != null && ch.startsWith('t:') ? ch.substring(2) : null;
  }
}

/// `t.round {round, status, starts_at, ends_at}`.
final class TRoundEvent extends ServerEvent {
  TRoundEvent._(
    super.envelope, {
    required this.round,
    required this.status,
    required this.startsAt,
    required this.endsAt,
  });

  factory TRoundEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return TRoundEvent._(
      envelope,
      round: d.integer('round'),
      status: d.string('status'),
      startsAt: d.optInt('starts_at'),
      endsAt: d.optInt('ends_at'),
    );
  }

  final int round;

  /// `pairing`, `live` or `done`.
  final String status;
  final int? startsAt;
  final int? endsAt;
}

/// `t.check_in`: the check-in window opened. The app shows **Check in** and **Can't make it**;
/// checking in is always a deliberate tap.
final class TCheckInEvent extends ServerEvent {
  TCheckInEvent._(
    super.envelope, {
    required this.tournamentId,
    required this.title,
    required this.startsAt,
    required this.closesAt,
  });

  factory TCheckInEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return TCheckInEvent._(
      envelope,
      tournamentId: d.string('tournament_id'),
      title: d.optString('title'),
      startsAt: d.optTimestamp('starts_at'),
      closesAt: d.optTimestamp('closes_at'),
    );
  }

  final String tournamentId;
  final String? title;

  /// Server ms when the tournament starts.
  final int? startsAt;

  /// Server ms when check-in closes.
  final int? closesAt;
}

/// `t.at_risk`: 30 minutes before the start, too few players have registered ("3 more players
/// needed. Invite friends").
final class TAtRiskEvent extends ServerEvent {
  TAtRiskEvent._(
    super.envelope, {
    required this.tournamentId,
    required this.players,
    required this.needed,
  });

  factory TAtRiskEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return TAtRiskEvent._(
      envelope,
      tournamentId: d.string('tournament_id'),
      players: d.optInt('players'),
      needed: d.optInt('needed'),
    );
  }

  final String tournamentId;

  /// Players registered so far.
  final int? players;

  /// How many more are needed.
  final int? needed;
}

/// `t.checked_in`: the player is checked in.
final class TCheckedInEvent extends ServerEvent {
  TCheckedInEvent._(super.envelope, this.tournamentId);

  factory TCheckedInEvent.fromEnvelope(Envelope envelope) =>
      TCheckedInEvent._(envelope, _payload(envelope).string('tournament_id'));

  final String tournamentId;
}

/// `t.bye`: no game this round; the bye is worth [points].
final class TByeEvent extends ServerEvent {
  TByeEvent._(
    super.envelope, {
    required this.tournamentId,
    required this.round,
    required this.points,
  });

  factory TByeEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return TByeEvent._(
      envelope,
      tournamentId: d.string('tournament_id'),
      round: d.integer('round'),
      points: d.optNum('points') ?? 1,
    );
  }

  final String tournamentId;
  final int round;
  final num points;
}

/// `t.finished`: the final result ("You finished #3 of 64").
final class TFinishedEvent extends ServerEvent {
  TFinishedEvent._(
    super.envelope, {
    required this.tournamentId,
    required this.rank,
    required this.players,
    required this.points,
    required this.prize,
    required this.xp,
  });

  factory TFinishedEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return TFinishedEvent._(
      envelope,
      tournamentId: d.string('tournament_id'),
      rank: d.integer('rank'),
      players: d.optInt('players'),
      points: d.optNum('points'),
      prize: d.optInt('prize') ?? 0,
      xp: d.optInt('xp') ?? 0,
    );
  }

  final String tournamentId;
  final int rank;

  /// How many played.
  final int? players;
  final num? points;

  /// Coins won.
  final int prize;
  final int xp;
}

/// `t.cancelled`: the tournament was called off; fees are refunded.
final class TCancelledEvent extends ServerEvent {
  TCancelledEvent._(
    super.envelope, {
    required this.tournamentId,
    required this.reason,
    required this.refunded,
  });

  factory TCancelledEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return TCancelledEvent._(
      envelope,
      tournamentId: d.string('tournament_id'),
      reason: d.optString('reason'),
      refunded: d.optInt('refunded') ?? 0,
    );
  }

  final String tournamentId;

  /// `not_enough_players` or `admin`.
  final String? reason;
  final int refunded;
}

/// `t.pairing`: my pairing for a round, on `u`. Either a match on [matchChannel] with 90 s to send
/// `match.ready`, or a [bye] (newer servers send [TByeEvent] instead).
final class TPairingEvent extends ServerEvent {
  TPairingEvent._(
    super.envelope, {
    required this.tournamentId,
    required this.round,
    required this.bye,
    required this.matchId,
    required this.matchChannel,
    required this.opponent,
    required this.readyBy,
  });

  factory TPairingEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    final bye = d.optBool('bye') ?? false;
    final matchId = bye ? d.optString('match_id') : d.string('match_id');
    final opponent = d.optObject('opponent');
    return TPairingEvent._(
      envelope,
      tournamentId: d.optString('tournament_id'),
      round: d.optInt('round'),
      bye: bye,
      matchId: matchId,
      matchChannel: d.optString('ch') ?? (matchId == null ? null : 'm:$matchId'),
      opponent: opponent == null ? null : _readCard(opponent),
      readyBy: d.optInt('ready_by'),
    );
  }

  final String? tournamentId;
  final int? round;
  final bool bye;
  final String? matchId;
  final String? matchChannel;
  final PlayerCard? opponent;

  /// Server ms by which `match.ready` must be sent.
  final int? readyBy;
}
