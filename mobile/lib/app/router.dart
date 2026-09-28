import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/auth/session.dart';
import '../core/config/app_config.dart';
import '../features/arena/arena_screen.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/battle/battle_screen.dart';
import '../features/battle/match/match_screen.dart';
import '../features/battle/match/review_screen.dart';
import '../features/battle/search_screen.dart';
import '../features/debug/debug_screen.dart';
import '../features/home/home_screen.dart';
import '../features/learn/learn_screen.dart';
import '../features/learn/subject_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/practice/practice_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/social/blocked_users_screen.dart';
import '../features/social/public_profile_screen.dart';
import '../features/social/social_screen.dart';
import '../features/splash/splash_screen.dart';
import '../features/system/maintenance_screen.dart';
import '../features/system/suspended_screen.dart';
import '../features/system/update_required_screen.dart';
import 'shell.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const signIn = '/sign-in';
  static const onboarding = '/onboarding';
  static const update = '/update';
  static const maintenance = '/maintenance';
  static const suspended = '/suspended';
  static const home = '/home';
  static const learn = '/learn';
  static const battle = '/battle';
  static const arena = '/arena';
  static const social = '/social';
  static const profile = '/profile';
  static const debug = '/debug';
  static const practice = '/practice';

  static const tabs = [home, learn, battle, arena, social];

  /// A subject's chapters, inside the Learn tab: `/learn/:subject`.
  static String subject(String slug) => '$learn/$slug';

  /// A practice session, full screen above the tabs: `/practice/:sessionId`.
  static String practiceSession(String sessionId) => '$practice/$sessionId';

  /// The matchmaking screen, full screen above the tabs. The search goes on when the user leaves
  /// it; the "Searching" pill brings them back.
  static const battleSearch = '/battle/search';

  /// A live match (VS, questions, then its result), full screen above the tabs.
  static String battleMatch(String matchId) => '/battle/match/${Uri.encodeComponent(matchId)}';

  /// The answers of a finished match, on top of its result.
  static String battleReview(String matchId) => '${battleMatch(matchId)}/review';

  /// The Battle tab with a subject (and chapter) preselected, e.g. from a coach tip.
  static String battleWith({String? subject, String? chapter}) {
    final query = {'subject': ?subject, 'chapter': ?chapter};
    return Uri(path: battle, queryParameters: query.isEmpty ? null : query).toString();
  }

  /// Whether [path] is a match screen, optionally a given match's.
  static bool isBattleMatch(String path, [String? matchId]) {
    const prefix = '/battle/match/';
    if (!path.startsWith(prefix)) return false;
    if (matchId == null) return true;
    final rest = path.substring(prefix.length);
    final id = Uri.decodeComponent(rest.split('/').first);
    return id == matchId;
  }

  /// The Battle tab set up to challenge a friend: `/battle?friend=<user id>`.
  static String battleWithFriend(String userId) =>
      Uri(path: battle, queryParameters: {'friend': userId}).toString();

  /// A player's public profile, full screen above the tabs. The same path is the shared link.
  static String userProfile(String handle) => '/u/${Uri.encodeComponent(handle)}';

  /// The players the user has blocked, opened from Settings → Privacy.
  static const blockedUsers = '/blocked';

  /// Screens that only exist to get the user somewhere else. Being on one never
  /// counts as a destination to come back to.
  static const gates = {splash, signIn, onboarding, update, maintenance, suspended};
}

/// Where the router should send the user, and the destination to resume once
/// the gates are passed (a deep link or notification opened while signed out,
/// still loading, or before onboarding).
typedef RouteDecision = ({String? redirect, String? pending});

/// The whole navigation gate as one pure function, so it is unit-testable:
/// app gates (update, maintenance) first, then the session, and finally the
/// pending destination once the user is fully signed in.
RouteDecision decideRoute({
  required AppGate gate,
  required AsyncValue<Session> session,
  required String location,
  String? pending,
}) {
  final path = Uri.parse(location).path;
  final isDestination = !Routes.gates.contains(path) && path != Routes.debug;
  final remember = isDestination ? location : pending;

  switch (gate) {
    case AppGate.updateRequired:
      return (redirect: path == Routes.update ? null : Routes.update, pending: remember);
    case AppGate.maintenance:
      const allowed = {Routes.maintenance, Routes.debug};
      return (redirect: allowed.contains(path) ? null : Routes.maintenance, pending: remember);
    case AppGate.open:
      break;
  }

  final value = session.value;
  if (value == null) {
    // Still restoring, or restore failed with nothing cached: the splash
    // screen shows progress or a retry.
    return (redirect: path == Routes.splash ? null : Routes.splash, pending: remember);
  }
  switch (value) {
    case Suspended():
      // Nothing else is reachable, and nothing is worth remembering.
      const allowed = {Routes.suspended, Routes.debug};
      return (redirect: allowed.contains(path) ? null : Routes.suspended, pending: null);
    case SignedOut():
      const open = {Routes.signIn, Routes.debug};
      return (redirect: open.contains(path) ? null : Routes.signIn, pending: remember);
    case SignedIn(needsOnboarding: true):
      return (redirect: path == Routes.onboarding ? null : Routes.onboarding, pending: remember);
    case SignedIn():
      if (Routes.gates.contains(path)) return (redirect: pending ?? Routes.home, pending: null);
      return (redirect: null, pending: null);
  }
}

/// The path of the top-most screen, pushed or not, e.g. `/battle/search`.
String currentPath(GoRouter router) =>
    router.routerDelegate.currentConfiguration.isEmpty ? '' : router.state.uri.path;

/// Kept for callers that only care about the session.
String? authRedirect(AsyncValue<Session> session, String location) =>
    decideRoute(gate: AppGate.open, session: session, location: location).redirect;

/// The destination to open once sign-in and onboarding are done. A plain
/// holder rather than reactive state: only the router's redirect reads and
/// writes it. It is saved for 30 minutes, so an invite link survives the app
/// being closed during sign-in or onboarding.
class PendingDestination {
  PendingDestination({this._prefs, this._clock = DateTime.now}) {
    _location = _load();
  }

  static const key = 'router.pending';
  static const ttl = Duration(minutes: 30);

  final SharedPreferences? _prefs;
  final DateTime Function() _clock;
  String? _location;

  String? get location => _location;

  set location(String? value) {
    if (value == _location) return;
    _location = value;
    final prefs = _prefs;
    if (prefs == null) return;
    if (value == null) {
      unawaited(prefs.remove(key));
    } else {
      unawaited(
        prefs.setString(
          key,
          jsonEncode({'location': value, 'at': _clock().toUtc().toIso8601String()}),
        ),
      );
    }
  }

  String? _load() {
    try {
      final raw = _prefs?.getString(key);
      if (raw == null) return null;
      final saved = jsonDecode(raw);
      if (saved case {'location': final String location, 'at': final String at}) {
        final savedAt = DateTime.tryParse(at);
        if (savedAt != null && _clock().difference(savedAt) < ttl) return location;
      }
    } on FormatException {
      // Ignore an unreadable entry.
    }
    return null;
  }
}

final pendingDestinationProvider = Provider<PendingDestination>((ref) {
  SharedPreferences? prefs;
  try {
    prefs = ref.read(sharedPrefsProvider);
  } on Object {
    prefs = null; // Not provided (tests): keep it in memory only.
  }
  return PendingDestination(prefs: prefs);
});

/// Links shared outside the app. Each maps onto the tab that handles it; the
/// tab reads the query parameter when its feature is available. (`/u/<handle>`,
/// a player's profile, is a screen of its own.)
abstract final class DeepLinks {
  /// `/j/K7M2QX`: join a friend or group room by code.
  static String? join(GoRouterState state) =>
      '${Routes.battle}?join=${Uri.encodeQueryComponent(state.pathParameters['code'] ?? '')}';

  /// `/t/<id>`: a tournament.
  static String? tournament(GoRouterState state) =>
      '${Routes.arena}?t=${Uri.encodeQueryComponent(state.pathParameters['id'] ?? '')}';
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  void bump() => refresh.value++;
  ref
    ..listen(sessionProvider, (_, _) => bump())
    ..listen(appGateProvider, (_, _) => bump())
    ..onDispose(refresh.dispose);

  final router = GoRouter(
    initialLocation: Routes.home,
    refreshListenable: refresh,
    redirect: (context, state) {
      final pending = ref.read(pendingDestinationProvider);
      final decision = decideRoute(
        gate: ref.read(appGateProvider),
        session: ref.read(sessionProvider),
        location: state.uri.toString(),
        pending: pending.location,
      );
      pending.location = decision.pending;
      return decision.redirect;
    },
    // Unknown or stale links land on Home instead of an error page.
    onException: (context, state, router) => router.go(Routes.home),
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(path: Routes.signIn, builder: (_, _) => const SignInScreen()),
      GoRoute(path: Routes.onboarding, builder: (_, _) => const OnboardingScreen()),
      GoRoute(path: Routes.update, builder: (_, _) => const UpdateRequiredScreen()),
      GoRoute(path: Routes.maintenance, builder: (_, _) => const MaintenanceScreen()),
      GoRoute(path: Routes.suspended, builder: (_, _) => const SuspendedScreen()),
      GoRoute(path: Routes.profile, builder: (_, _) => const ProfileScreen()),
      GoRoute(path: Routes.debug, builder: (_, _) => const DebugScreen()),
      GoRoute(
        path: '${Routes.practice}/:sessionId',
        builder: (_, state) => PracticeScreen(sessionId: state.pathParameters['sessionId']!),
      ),
      // Battles run full screen above the tabs; the search keeps going when its screen closes.
      GoRoute(path: Routes.battleSearch, builder: (_, _) => const SearchScreen()),
      GoRoute(
        path: '/battle/match/:matchId',
        builder: (_, state) => MatchScreen(matchId: state.pathParameters['matchId']!),
        routes: [
          GoRoute(
            path: 'review',
            builder: (_, state) => ReviewScreen(matchId: state.pathParameters['matchId']!),
          ),
        ],
      ),
      GoRoute(path: '/j/:code', redirect: (_, state) => DeepLinks.join(state)),
      GoRoute(path: '/t/:id', redirect: (_, state) => DeepLinks.tournament(state)),
      // A player's profile; `/u/<handle>` is also the link shared outside the app.
      GoRoute(
        path: '/u/:handle',
        builder: (_, state) => PublicProfileScreen(handle: state.pathParameters['handle']!),
      ),
      GoRoute(path: Routes.blockedUsers, builder: (_, _) => const BlockedUsersScreen()),
      StatefulShellRoute(
        builder: (context, state, shell) => AppShell(shell: shell),
        navigatorContainerBuilder: (context, shell, children) =>
            FadeIndexedStack(index: shell.currentIndex, children: children),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.learn,
                builder: (_, _) => const LearnScreen(),
                routes: [
                  // Pushed on the Learn tab's own navigator, so the nav bar stays.
                  GoRoute(
                    path: ':subject',
                    builder: (_, state) => SubjectScreen(slug: state.pathParameters['subject']!),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.battle, builder: (_, _) => const BattleScreen())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.arena, builder: (_, _) => const ArenaScreen())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.social, builder: (_, _) => const SocialScreen())],
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
