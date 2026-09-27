import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';
import 'live_controller.dart';
import 'live_match.dart';
import 'realtime_providers.dart';
import 'search_state.dart';

/// Whether the app is in the foreground. `RealtimeHost` keeps it up to date from the app
/// lifecycle.
final appForegroundProvider = NotifierProvider<AppForeground, bool>(AppForeground.new);

class AppForeground extends Notifier<bool> {
  @override
  bool build() => true;

  // A plain on/off value; a setter-like method reads best at the call site.
  // ignore: use_setters_to_change_properties
  void set(bool foreground) => state = foreground;
}

/// The live connection's controller while a user is signed in and onboarded. `RealtimeHost`
/// watches it, so it lives as long as the session.
final liveControllerProvider = Provider<LiveController?>((ref) {
  final connection = ref.watch(realtimeConnectionProvider);
  final me = ref.watch(currentUserIdProvider);
  final onboarded = ref.watch(
    sessionProvider.select(
      (session) => switch (session.value) {
        SignedIn(needsOnboarding: false) => true,
        _ => false,
      },
    ),
  );
  if (connection == null || me == null || !onboarded) return null;
  final controller = LiveController(
    ref,
    connection,
    me: me,
    hooks: ref.watch(liveEventHooksProvider),
  )..setForeground(ref.read(appForegroundProvider));
  ref
    ..listen(appForegroundProvider, (_, foreground) => controller.setForeground(foreground))
    ..onDispose(controller.dispose);
  return controller;
});

/// The matchmaking state, for the search screen and the Battle tab.
final searchProvider = NotifierProvider<SearchNotifier, SearchState>(SearchNotifier.new);

class SearchNotifier extends Notifier<SearchState> {
  @override
  SearchState build() {
    final live = ref.watch(liveControllerProvider);
    if (live == null) return const SearchState();
    final search = live.search;
    void sync() => state = search.value;
    search.addListener(sync);
    ref.onDispose(() => search.removeListener(sync));
    return search.value;
  }
}

/// One match, as its screen shows it. Opening a match this device doesn't know (after a restart,
/// from a link) asks the server for it.
final matchViewProvider = NotifierProvider.autoDispose
    .family<MatchViewNotifier, MatchView?, String>(MatchViewNotifier.new);

class MatchViewNotifier extends Notifier<MatchView?> {
  MatchViewNotifier(this.matchId);

  final String matchId;

  @override
  MatchView? build() {
    final live = ref.watch(liveControllerProvider);
    if (live == null) return null;
    final known = live.match(matchId);
    final match = known != null && !known.isDisposed ? known : live.openMatch(matchId);
    void sync() {
      if (!match.isDisposed) state = match.view;
    }

    match.addListener(sync);
    ref.onDispose(() => match.removeListener(sync));
    return match.view;
  }
}

/// The live match behind [matchViewProvider], for actions (answer, emote, forfeit, …).
LiveMatch? liveMatchOf(WidgetRef ref, String matchId) =>
    ref.read(liveControllerProvider)?.match(matchId);

/// Runs [action] on the live controller if there is one.
Future<void> withLive(WidgetRef ref, Future<void> Function(LiveController live) action) async {
  final live = ref.read(liveControllerProvider);
  if (live == null) return;
  await action(live);
}
