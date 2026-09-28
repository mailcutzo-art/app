import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import 'data/missions_models.dart';
import 'data/missions_repository.dart';

/// Screens show their own retry button, so Riverpod's automatic retry is off.
Duration? _noAutoRetry(int _, Object _) => null;

/// Today's missions (`GET /v1/me/missions`), with the free swap.
final missionsProvider = AsyncNotifierProvider.autoDispose<MissionsController, MissionsDay>(
  MissionsController.new,
  retry: _noAutoRetry,
);

class MissionsController extends AsyncNotifier<MissionsDay> {
  @override
  Future<MissionsDay> build() {
    // Someone else signing in on this phone must not see the last user's missions.
    ref.watch(currentUserIdProvider);
    return ref.watch(missionsRepositoryProvider).missions();
  }

  /// Swaps [missionId] for a different mission. Throws the [AppFailure] for
  /// the screen to show; the day on screen stays as it was.
  Future<void> swap(String missionId) async {
    final day = await ref.read(missionsRepositoryProvider).swap(missionId);
    if (ref.mounted) state = AsyncData(day);
  }
}

/// The streak calendar (`GET /v1/me/streak?days=30`).
final streakProvider = FutureProvider.autoDispose<StreakCalendar>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(missionsRepositoryProvider).streak();
}, retry: _noAutoRetry);

/// Earned achievements and progress on the rest (`GET /v1/me/achievements`).
final achievementsProvider = FutureProvider.autoDispose<Achievements>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(missionsRepositoryProvider).achievements();
}, retry: _noAutoRetry);
