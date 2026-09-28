import '../../../core/network/app_failure.dart';
import 'missions_models.dart';
import 'missions_repository.dart';

/// Calls of [FakeMissionsRepository] that tests can make fail.
enum FakeMissionsOp { missions, swap, buyFreeze, streak, achievements }

/// In-memory stand-in for the missions, streak and achievements API. Used by
/// tests and by the debug "Demo data" switch.
///
/// It follows the contract where the app can notice: one free swap a day,
/// done missions can't be swapped, a freeze costs coins and at most two are
/// held, and a repeated idempotency key buys only once.
class FakeMissionsRepository implements MissionsRepository {
  FakeMissionsRepository({
    required this.day,
    required this.calendar,
    required this.achievementList,
    this.coins = 245,
    this.bestStreak = 12,
    this.latency = Duration.zero,
    List<Mission>? swapPool,
  }) : swapPool = swapPool ?? [..._swapPool];

  /// A day with one mission done, a 4-day streak with one freeze used, and a
  /// few achievements earned.
  factory FakeMissionsRepository.seeded({Duration latency = Duration.zero, DateTime? today}) {
    final now = today ?? DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    final todayDay = DateTime.utc(now.year, now.month, now.day);
    String iso(DateTime d) => d.toIso8601String().substring(0, 10);
    return FakeMissionsRepository(
      latency: latency,
      day: MissionsDay(
        day: iso(todayDay),
        items: const [
          Mission(
            id: 'm-practice',
            title: 'Answer 20 practice questions',
            progress: 12,
            target: 20,
            xp: 20,
            action: AppAction(route: '/learn'),
          ),
          Mission(
            id: 'm-rated',
            title: 'Play 1 rated battle or tournament game',
            progress: 1,
            target: 1,
            xp: 25,
            done: true,
            action: AppAction(route: '/battle'),
          ),
          Mission(
            id: 'm-review',
            title: 'Review 5 weak questions',
            progress: 0,
            target: 5,
            xp: 30,
            action: AppAction(route: '/learn', params: {'review': '1'}),
          ),
        ],
        streak: const StreakSummary(days: 4, freezes: 1),
      ),
      calendar: [
        for (var i = 29; i >= 0; i--)
          StreakDay(
            day: todayDay.subtract(Duration(days: i)),
            state: switch (i) {
              0 => StreakDayState.missed, // Today isn't done yet.
              2 => StreakDayState.frozen,
              1 || 3 || 4 => StreakDayState.active,
              _ when i % 3 == 0 => StreakDayState.missed,
              _ => StreakDayState.active,
            },
          ),
      ],
      achievementList: [
        Achievement(
          id: 'first-battle',
          title: 'First battle',
          description: 'Finish your first battle against a person.',
          icon: 'battle',
          progress: 1,
          target: 1,
          coins: 10,
          earnedAt: todayDay.subtract(const Duration(days: 9)),
        ),
        Achievement(
          id: 'streak-7',
          title: 'On fire',
          description: 'Keep a 7-day streak.',
          icon: 'fire',
          progress: 7,
          target: 7,
          coins: 30,
          earnedAt: todayDay.subtract(const Duration(days: 3)),
        ),
        const Achievement(
          id: 'questions-500',
          title: 'Question machine',
          description: 'Answer 500 practice questions.',
          icon: 'quiz',
          progress: 312,
          target: 500,
          coins: 50,
        ),
        const Achievement(
          id: 'wins-10',
          title: 'Ten wins',
          description: 'Win 10 rated battles.',
          icon: 'medal',
          progress: 3,
          target: 10,
          coins: 50,
        ),
        const Achievement(
          id: 'streak-30',
          title: 'Unstoppable',
          description: 'Keep a 30-day streak.',
          icon: 'crown',
          progress: 4,
          target: 30,
          coins: 100,
        ),
        const Achievement(
          id: 'tournament',
          title: 'Arena debut',
          description: 'Play every round of a tournament.',
          icon: 'arena',
          progress: 0,
          target: 1,
          coins: 20,
        ),
      ],
    );
  }

  MissionsDay day;
  List<StreakDay> calendar;
  List<Achievement> achievementList;
  int coins;
  int bestStreak;

  /// Missions handed out by swaps, in order.
  final List<Mission> swapPool;

  /// Delay before every response, to see loading states.
  Duration latency;

  /// Calls that fail until removed from the map.
  final Map<FakeMissionsOp, AppFailure> failures = {};

  /// Every swap call's mission id, in order.
  final List<String> swapCalls = [];

  /// Every freeze purchase's idempotency key, in order (repeats included).
  final List<String> freezeKeys = [];

  final _purchases = <String, FreezePurchase>{};

  static const freezePrice = 50;
  static const maxFreezes = 2;

  @override
  Future<MissionsDay> missions() async {
    await _wait(FakeMissionsOp.missions);
    return day;
  }

  @override
  Future<MissionsDay> swap(String missionId) async {
    swapCalls.add(missionId);
    await _wait(FakeMissionsOp.swap);
    final index = day.items.indexWhere((m) => m.id == missionId);
    if (index == -1) throw const NotFoundFailure('That mission is gone.', code: 'NOT_FOUND');
    if (day.items[index].done) {
      throw const ConflictFailure('Done missions can\'t be swapped.', code: 'MISSION_DONE');
    }
    if (day.swapsLeft <= 0 || swapPool.isEmpty) {
      throw const ConflictFailure('You\'ve used today\'s free swap.', code: 'SWAP_USED');
    }
    final items = [...day.items]..[index] = swapPool.removeAt(0);
    return day = day.copyWith(items: items, swapsLeft: day.swapsLeft - 1);
  }

  @override
  Future<FreezePurchase> buyFreeze({required String idempotencyKey}) async {
    freezeKeys.add(idempotencyKey);
    await _wait(FakeMissionsOp.buyFreeze);
    if (_purchases[idempotencyKey] case final done?) return done;
    final held = day.streak.freezes;
    if (held >= maxFreezes) {
      throw const ConflictFailure('You can hold at most 2 freezes.', code: 'LIMIT_REACHED');
    }
    if (coins < freezePrice) {
      throw const ConflictFailure('You need 50 coins for a freeze.', code: 'INSUFFICIENT_COINS');
    }
    coins -= freezePrice;
    final streak = day.streak;
    day = day.copyWith(
      streak: StreakSummary(days: streak.days, todayDone: streak.todayDone, freezes: held + 1),
    );
    return _purchases[idempotencyKey] = FreezePurchase(freezes: held + 1, coins: coins);
  }

  @override
  Future<StreakCalendar> streak({int days = 30}) async {
    await _wait(FakeMissionsOp.streak);
    final shown = calendar.length > days ? calendar.sublist(calendar.length - days) : calendar;
    return StreakCalendar(
      days: day.streak.days,
      best: bestStreak,
      freezes: day.streak.freezes,
      todayDone: day.streak.todayDone,
      calendar: List.unmodifiable(shown),
      coins: coins,
    );
  }

  @override
  Future<Achievements> achievements() async {
    await _wait(FakeMissionsOp.achievements);
    return Achievements(items: List.unmodifiable(achievementList));
  }

  Future<void> _wait(FakeMissionsOp op) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failures[op] case final failure?) throw failure;
  }

  static const _swapPool = [
    Mission(
      id: 'm-chapter',
      title: '10 questions in any chapter',
      progress: 0,
      target: 10,
      xp: 20,
      action: AppAction(route: '/learn'),
    ),
    Mission(
      id: 'm-practice-30',
      title: 'Answer 30 practice questions',
      progress: 0,
      target: 30,
      xp: 20,
      action: AppAction(route: '/learn'),
    ),
  ];
}
