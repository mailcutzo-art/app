import 'package:flutter/foundation.dart';

import '../../../core/auth/user.dart';
import '../data/battle_models.dart';
import '../data/fake_battle_repository.dart';

/// A player the demo server plays with.
@immutable
class DemoPlayer {
  const DemoPlayer({
    required this.uid,
    required this.name,
    this.handle,
    this.tone = 'lime',
    this.symbol = 'rocket',
    this.level = 4,
    this.isBot = false,
    this.rating = '—',
  });

  /// The human opponent of every demo battle.
  static const riya = DemoPlayer(
    uid: 'demo-riya',
    name: 'Riya',
    handle: 'riya_s',
    tone: 'rose',
    symbol: 'dna',
    level: 6,
    rating: '1548',
  );

  /// The Practice Bot.
  static const bot = DemoPlayer(
    uid: 'demo-bot',
    name: 'Practice Bot',
    handle: 'practice_bot',
    tone: 'lavender',
    symbol: 'robot',
    level: 1,
    isBot: true,
  );

  /// The signed-in user, as the demo server shows them to themself.
  factory DemoPlayer.fromMe(Me? me) => DemoPlayer(
    uid: me?.id ?? 'me',
    name: me?.displayName.split(' ').first ?? 'You',
    handle: me?.handle,
    tone: me?.avatar.tone ?? 'lime',
    symbol: me?.avatar.symbol ?? 'rocket',
  );

  final String uid;
  final String name;
  final String? handle;
  final String tone;
  final String symbol;
  final int level;
  final bool isBot;
  final String rating;

  /// The socket's player card.
  Map<String, Object?> card() => {
    'uid': uid,
    'handle': handle,
    'display_name': name,
    'avatar': {'tone': tone, 'symbol': symbol},
    'level': level,
    'is_bot': isBot,
  };
}

/// One subject rating in the demo.
class DemoRating {
  DemoRating({this.value, this.provisional = true, this.position, this.gamesToRank = 7});

  int? value;
  bool provisional;

  /// Place on the subject's rating board, once ranked.
  int? position;
  int gamesToRank;

  String get display => value == null ? '—' : (provisional ? '$value?' : '$value');

  RatingInfo get info => RatingInfo(display: display, value: value, provisional: provisional);
}

/// The demo's economy and progress: coins, ratings, XP and missions. It changes as games settle,
/// so the Battle tab shows the new rating after a win.
class DemoWorld {
  int coins = 245;

  /// The first search ever offers the Practice Bot at 20 s.
  bool firstSearch = true;
  int level = 4;
  int intoLevel = 120;
  int forNext = 250;
  int streakDays = 4;
  bool playedToday = false;
  int gamesToday = 0;
  int wins = 0;
  BattleSelection? last;

  final Map<String, DemoRating> ratings = {
    'physics': DemoRating(value: 1502, position: 47, gamesToRank: 0),
  };

  DemoRating rating(String subject) => ratings.putIfAbsent(subject, DemoRating.new);

  /// `GET /v1/battle/setup` for the demo.
  BattleSetup setup(Goal goal) => sampleBattleSetup(
    goal,
    physicsRating: rating('physics').info,
    coins: coins,
    firstSearch: firstSearch,
    last: last,
  );

  /// Adds XP and says whether it took the player to a new level.
  bool addXp(int delta) {
    intoLevel += delta;
    var levelUp = false;
    while (intoLevel >= forNext) {
      intoLevel -= forNext;
      level++;
      forNext += 50;
      levelUp = true;
    }
    return levelUp;
  }
}
