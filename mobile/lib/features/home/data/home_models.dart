import 'package:flutter/foundation.dart';

import '../../../core/network/json.dart';
import '../../leaderboards/data/leaderboard_models.dart';
import '../../learn/data/learn_models.dart';
import '../../missions/data/missions_models.dart';

/// One Home section: its data, or why the server couldn't build it. Each
/// section fails on its own, so one error never blanks the screen.
sealed class HomeSection<T> {
  const HomeSection();

  /// Reads `{status, data}` / `{status: "error", error: {code, message}}`.
  /// A section the app can't read counts as failed rather than failing Home.
  factory HomeSection.fromJson(Object? json, String name, T Function(Object? data) parse) {
    try {
      final r = JsonReader(json, 'home $name');
      if (r.optString('status') == 'ok') return SectionOk(parse(r['data']));
      final error = r['error'];
      final e = error is Map<String, Object?> ? JsonReader(error, 'home $name error') : null;
      return SectionFailed(
        code: e?.optString('code') ?? 'UNKNOWN',
        message: e?.optString('message'),
      );
    } on FormatException catch (e) {
      debugPrint('Unreadable Home section $name: $e');
      return const SectionFailed(code: 'UNREADABLE');
    }
  }

  T? get data => switch (this) {
    SectionOk(:final value) => value,
    SectionFailed() => null,
  };
}

final class SectionOk<T> extends HomeSection<T> {
  const SectionOk(this.value);

  final T value;
}

final class SectionFailed<T> extends HomeSection<T> {
  const SectionFailed({required this.code, this.message});

  final String code;
  final String? message;
}

/// The rating as shown, e.g. `1523?` while provisional.
@immutable
class HomeRating {
  const HomeRating({required this.display, this.value, this.provisional = false});

  factory HomeRating.fromJson(Object? json) {
    final r = JsonReader(json, 'rating');
    return HomeRating(
      display: r.string('display'),
      value: r.optInt('value'),
      provisional: r.flag('provisional'),
    );
  }

  final String display;
  final int? value;
  final bool provisional;
}

/// The player's place on the overall rating board, or games left to be ranked.
@immutable
class HomeRank {
  const HomeRank({required this.board, this.position, this.gamesToRank});

  factory HomeRank.fromJson(Object? json) {
    final r = JsonReader(json, 'rank');
    return HomeRank(
      board: r.optString('board') ?? 'rating:overall',
      position: r.optInt('position'),
      gamesToRank: r.optInt('games_to_rank'),
    );
  }

  final String board;
  final int? position;
  final int? gamesToRank;
}

@immutable
class HomeLevel {
  const HomeLevel({required this.level, this.intoLevel = 0, this.forNext = 0});

  factory HomeLevel.fromJson(Object? json) {
    final r = JsonReader(json, 'level');
    return HomeLevel(
      level: r.integer('level'),
      intoLevel: r.optInt('into_level') ?? 0,
      forNext: r.optInt('for_next') ?? 0,
    );
  }

  final int level;
  final int intoLevel;
  final int forNext;
}

/// Home's headline card.
@immutable
class HomeHero {
  const HomeHero({required this.rating, required this.rank, required this.coins, this.level});

  factory HomeHero.fromJson(Object? json) {
    final r = JsonReader(json, 'hero');
    return HomeHero(
      rating: r.object('rating', HomeRating.fromJson),
      rank: r.optObject('rank', HomeRank.fromJson) ?? const HomeRank(board: 'rating:overall'),
      coins: r.integer('coins'),
      level: r.optObject('level', HomeLevel.fromJson),
    );
  }

  final HomeRating rating;
  final HomeRank rank;
  final int coins;
  final HomeLevel? level;
}

/// Something that needs the player now: a search, a match, a room, or a
/// tournament checking in or running.
@immutable
class HomeLive {
  const HomeLive({
    required this.kind,
    required this.id,
    this.title,
    this.state,
    this.until,
    this.action,
  });

  factory HomeLive.fromJson(Object? json) {
    final r = JsonReader(json, 'live');
    final until = r.optString('until');
    return HomeLive(
      kind: r.string('kind'),
      id: r.string('id'),
      title: r.optString('title'),
      state: r.optString('state'),
      until: until == null ? null : DateTime.tryParse(until),
      action: r.optObject('action', AppAction.fromJson),
    );
  }

  final String kind;
  final String id;
  final String? title;
  final String? state;
  final DateTime? until;
  final AppAction? action;
}

/// The weekly XP board's top 3, plus the viewer's row when they're on it.
@immutable
class HomeLeaders {
  const HomeLeaders({required this.board, required this.top, this.me});

  factory HomeLeaders.fromJson(Object? json) {
    final r = JsonReader(json, 'leaders');
    return HomeLeaders(
      board: r.optString('board') ?? 'weekly_xp',
      top: r.list('top', BoardRow.fromJson),
      me: r.optObject('me', BoardRow.fromJson),
    );
  }

  final String board;
  final List<BoardRow> top;
  final BoardRow? me;
}

/// The next tournament worth joining.
@immutable
class HomeTournament {
  const HomeTournament({
    required this.id,
    required this.title,
    this.subject,
    this.startsAt,
    this.entryFee,
    this.prizePool,
    this.players,
    this.capacity,
  });

  factory HomeTournament.fromJson(Object? json) {
    final r = JsonReader(json, 'tournament');
    final starts = r.optString('starts_at');
    return HomeTournament(
      id: r.string('id'),
      title: r.string('title'),
      subject: r.optString('subject'),
      startsAt: starts == null ? null : DateTime.tryParse(starts),
      entryFee: r.optInt('entry_fee'),
      prizePool: r.optInt('prize_pool'),
      players: r.optInt('players'),
      capacity: r.optInt('capacity'),
    );
  }

  final String id;
  final String title;
  final String? subject;
  final DateTime? startsAt;
  final int? entryFee;
  final int? prizePool;
  final int? players;
  final int? capacity;
}

/// `GET /v1/home` (`docs/api-play.md`, "Home").
@immutable
class HomeFeed {
  const HomeFeed({
    required this.hero,
    this.live = const SectionOk(null),
    this.continuePractice = const SectionOk(null),
    this.tip = const SectionOk(null),
    required this.missions,
    required this.leaders,
    this.tournament = const SectionOk(null),
    this.welcomeCoins,
    this.maintenanceBanner,
  });

  factory HomeFeed.fromJson(Object? json) {
    final r = JsonReader(json, 'home');
    HomeSection<T> section<T>(String name, T Function(Object? data) parse) =>
        HomeSection.fromJson(r[name], name, parse);
    T? orNull<T>(Object? data, T Function(Object? json) parse) => data == null ? null : parse(data);
    final welcome = r['welcome'];
    final banner = r['maintenance_banner'];
    return HomeFeed(
      hero: section('hero', HomeHero.fromJson),
      live: section('live', (d) => orNull(d, HomeLive.fromJson)),
      continuePractice: section('continue', (d) => orNull(d, ContinuePractice.fromJson)),
      tip: section('tip', (d) => orNull(d, Tip.fromJson)),
      missions: section('missions', MissionsDay.fromJson),
      leaders: section('leaders', HomeLeaders.fromJson),
      tournament: section('tournament', (d) => orNull(d, HomeTournament.fromJson)),
      welcomeCoins: welcome is Map<String, Object?>
          ? JsonReader(welcome, 'welcome').optInt('coins')
          : null,
      maintenanceBanner: switch (banner) {
        final String message when message.isNotEmpty => message,
        {'message': final String message} when message.isNotEmpty => message,
        _ => null,
      },
    );
  }

  final HomeSection<HomeHero> hero;
  final HomeSection<HomeLive?> live;
  final HomeSection<ContinuePractice?> continuePractice;
  final HomeSection<Tip?> tip;
  final HomeSection<MissionsDay> missions;
  final HomeSection<HomeLeaders> leaders;
  final HomeSection<HomeTournament?> tournament;

  /// The welcome bonus, on the first Home after onboarding only.
  final int? welcomeCoins;

  /// A notice of planned maintenance, when one is scheduled.
  final String? maintenanceBanner;
}
