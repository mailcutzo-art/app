import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/auth/user.dart';
import 'data/learn_models.dart';
import 'data/learn_repository.dart';

/// The exam the Learn tab browses. It starts at the user's goal; switching
/// it changes what is browsed, never the profile.
final learnGoalProvider = NotifierProvider<LearnGoal, Goal>(LearnGoal.new);

class LearnGoal extends Notifier<Goal> {
  @override
  Goal build() => ref.watch(meProvider.select((me) => me.goal)) ?? Goal.neet;

  void select(Goal goal) => state = goal;
}

/// Sections show their own retry button and reload when the connection comes
/// back, so Riverpod's automatic retry is off.
Duration? _noAutoRetry(int _, Object _) => null;

final catalogProvider = FutureProvider.family<Catalog, Goal>(
  (ref, goal) => ref.watch(learnRepositoryProvider).catalog(goal),
  retry: _noAutoRetry,
);

final progressProvider = FutureProvider.family<Progress, Goal>((ref, goal) {
  // Someone else signing in on this phone must not see the last user's progress.
  ref.watch(meProvider.select((me) => me.id));
  return ref.watch(learnRepositoryProvider).progress(goal);
}, retry: _noAutoRetry);
