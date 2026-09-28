import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/user.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_failure.dart';
import '../../battle/data/battle_repository.dart' show parseResponse;
import '../../leaderboards/data/leaderboard_models.dart';
import '../../learn/data/learn_models.dart';
import '../../learn/data/learn_repository.dart' show demoDataProvider;
import '../../missions/data/fake_missions_repository.dart';
import 'home_models.dart';

/// The Home REST contract (`docs/api-play.md`, "Home").
abstract interface class HomeRepository {
  /// `GET /v1/home`: every section, each with its own status.
  Future<HomeFeed> home();
}

class ApiHomeRepository implements HomeRepository {
  ApiHomeRepository(this._api);

  final ApiClient _api;

  @override
  Future<HomeFeed> home() async {
    final data = await _api.get('/v1/home');
    return parseResponse(() => HomeFeed.fromJson(data));
  }
}

/// Home sections that [FakeHomeRepository] can report as failed.
enum FakeHomeSection { hero, live, continuePractice, tip, missions, leaders, tournament }

/// In-memory Home for tests and the debug "Demo data" mode.
class FakeHomeRepository implements HomeRepository {
  FakeHomeRepository({required this.feed, this.latency = Duration.zero});

  /// A provisional rating, some coins, a session to continue, a tip, the
  /// seeded missions, the weekly top 3 and a tournament on Sunday.
  factory FakeHomeRepository.seeded({
    Duration latency = Duration.zero,
    int? welcomeCoins,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    const players = [
      PlayerCard(
        id: 'p1',
        handle: 'meera_k',
        displayName: 'Meera',
        avatar: Avatar(tone: 'sky', symbol: 'atom'),
        level: 18,
      ),
      PlayerCard(
        id: 'p2',
        handle: 'kabir_22',
        displayName: 'Kabir',
        avatar: Avatar(tone: 'peach', symbol: 'flask'),
        level: 15,
      ),
      PlayerCard(
        id: 'p3',
        handle: 'isha_n',
        displayName: 'Isha',
        avatar: Avatar(tone: 'lavender', symbol: 'dna'),
        level: 12,
      ),
    ];
    return FakeHomeRepository(
      latency: latency,
      feed: HomeFeed(
        hero: const SectionOk(
          HomeHero(
            rating: HomeRating(display: '1523?', value: 1523, provisional: true),
            rank: HomeRank(board: 'rating:overall', gamesToRank: 7),
            coins: 245,
            level: HomeLevel(level: 4, intoLevel: 120, forNext: 250),
          ),
        ),
        continuePractice: const SectionOk(
          ContinuePractice(
            sessionId: 'demo-session',
            title: 'Physics · Motion in a Straight Line',
            answered: 12,
            count: 20,
          ),
        ),
        tip: const SectionOk(
          Tip(
            key: 'demo-tip',
            message: 'Projectile motion trips you up. Try 10 questions on it.',
            action: TipAction.practice,
            params: {'subject': 'physics', 'topic': 'projectile-motion', 'count': '10'},
          ),
        ),
        missions: SectionOk(FakeMissionsRepository.seeded(today: now).day),
        leaders: SectionOk(
          HomeLeaders(
            board: 'weekly_xp',
            top: [
              for (final (i, player) in players.indexed)
                BoardRow(
                  position: i + 1,
                  user: player,
                  value: 2200 - i * 240,
                  valueDisplay: '${2200 - i * 240} XP',
                ),
            ],
            me: const BoardRow(
              position: 58,
              user: PlayerCard(id: 'me', displayName: 'You', level: 4),
              value: 140,
              valueDisplay: '140 XP',
              change1d: 25,
            ),
          ),
        ),
        tournament: SectionOk(
          HomeTournament(
            id: 'demo-t2',
            title: 'Physics Sunday Cup',
            subject: 'physics',
            startsAt: at.add(const Duration(days: 2, hours: 3)),
            entryFee: 20,
            prizePool: 500,
            players: 38,
            capacity: 64,
          ),
        ),
        welcomeCoins: welcomeCoins,
      ),
    );
  }

  HomeFeed feed;

  /// Delay before every response, to see loading states.
  Duration latency;

  /// Set to make the whole request fail.
  AppFailure? failure;

  /// Sections reported as failed until removed.
  final Set<FakeHomeSection> failedSections = {};

  /// How many times Home was fetched.
  int calls = 0;

  @override
  Future<HomeFeed> home() async {
    calls++;
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failure case final failure?) throw failure;
    final served = _withFailures(feed);
    // The welcome bonus shows once.
    feed = _copy(feed, welcomeCoins: null);
    return served;
  }

  HomeFeed _withFailures(HomeFeed f) {
    HomeSection<T> or<T>(FakeHomeSection section, HomeSection<T> value) =>
        failedSections.contains(section)
        ? const SectionFailed(code: 'INTERNAL', message: 'Something went wrong.')
        : value;
    return HomeFeed(
      hero: or(FakeHomeSection.hero, f.hero),
      live: or(FakeHomeSection.live, f.live),
      continuePractice: or(FakeHomeSection.continuePractice, f.continuePractice),
      tip: or(FakeHomeSection.tip, f.tip),
      missions: or(FakeHomeSection.missions, f.missions),
      leaders: or(FakeHomeSection.leaders, f.leaders),
      tournament: or(FakeHomeSection.tournament, f.tournament),
      welcomeCoins: f.welcomeCoins,
      maintenanceBanner: f.maintenanceBanner,
    );
  }

  static HomeFeed _copy(HomeFeed f, {required int? welcomeCoins}) => HomeFeed(
    hero: f.hero,
    live: f.live,
    continuePractice: f.continuePractice,
    tip: f.tip,
    missions: f.missions,
    leaders: f.leaders,
    tournament: f.tournament,
    welcomeCoins: welcomeCoins,
    maintenanceBanner: f.maintenanceBanner,
  );
}

/// Home in the debug "Demo data" mode.
final demoHomeRepositoryProvider = Provider<FakeHomeRepository>(
  (ref) => FakeHomeRepository.seeded(latency: const Duration(milliseconds: 300)),
);

final homeRepositoryProvider = Provider<HomeRepository>((ref) {
  // The constant keeps the demo out of release builds entirely.
  if (!kReleaseMode && ref.watch(demoDataProvider)) return ref.watch(demoHomeRepositoryProvider);
  return ApiHomeRepository(ref.watch(apiClientProvider));
});
