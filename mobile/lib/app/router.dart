import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/session.dart';
import '../core/config/app_config.dart';
import '../features/arena/arena_screen.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/battle/battle_screen.dart';
import '../features/debug/debug_screen.dart';
import '../features/home/home_screen.dart';
import '../features/learn/learn_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/social/social_screen.dart';
import '../features/splash/splash_screen.dart';
import '../features/system/maintenance_screen.dart';
import '../features/system/update_required_screen.dart';
import 'shell.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const signIn = '/sign-in';
  static const onboarding = '/onboarding';
  static const update = '/update';
  static const maintenance = '/maintenance';
  static const home = '/home';
  static const learn = '/learn';
  static const battle = '/battle';
  static const arena = '/arena';
  static const social = '/social';
  static const profile = '/profile';
  static const debug = '/debug';

  static const tabs = [home, learn, battle, arena, social];

  /// Screens that only exist to get the user somewhere else. Being on one never
  /// counts as a destination to come back to.
  static const gates = {splash, signIn, onboarding, update, maintenance};
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

/// Kept for callers that only care about the session.
String? authRedirect(AsyncValue<Session> session, String location) =>
    decideRoute(gate: AppGate.open, session: session, location: location).redirect;

/// The destination to open once sign-in and onboarding are done. A plain
/// holder rather than reactive state: only the router's redirect reads and
/// writes it.
class PendingDestination {
  String? location;
}

final pendingDestinationProvider = Provider<PendingDestination>((ref) => PendingDestination());

/// Links shared outside the app. Each maps onto the tab that handles it; the
/// tab reads the query parameter when its feature is available.
abstract final class DeepLinks {
  /// `/j/K7M2QX`: join a friend or group room by code.
  static String? join(GoRouterState state) =>
      '${Routes.battle}?join=${Uri.encodeQueryComponent(state.pathParameters['code'] ?? '')}';

  /// `/t/<id>`: a tournament.
  static String? tournament(GoRouterState state) =>
      '${Routes.arena}?t=${Uri.encodeQueryComponent(state.pathParameters['id'] ?? '')}';

  /// `/u/<handle>`: a player's profile.
  static String? user(GoRouterState state) =>
      '${Routes.social}?u=${Uri.encodeQueryComponent(state.pathParameters['handle'] ?? '')}';
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
      GoRoute(path: Routes.profile, builder: (_, _) => const ProfileScreen()),
      GoRoute(path: Routes.debug, builder: (_, _) => const DebugScreen()),
      GoRoute(path: '/j/:code', redirect: (_, state) => DeepLinks.join(state)),
      GoRoute(path: '/t/:id', redirect: (_, state) => DeepLinks.tournament(state)),
      GoRoute(path: '/u/:handle', redirect: (_, state) => DeepLinks.user(state)),
      StatefulShellRoute(
        builder: (context, state, shell) => AppShell(shell: shell),
        navigatorContainerBuilder: (context, shell, children) =>
            FadeIndexedStack(index: shell.currentIndex, children: children),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.learn, builder: (_, _) => const LearnScreen())],
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
