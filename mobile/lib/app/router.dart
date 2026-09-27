import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/session.dart';
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
import 'shell.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const signIn = '/sign-in';
  static const onboarding = '/onboarding';
  static const home = '/home';
  static const learn = '/learn';
  static const battle = '/battle';
  static const arena = '/arena';
  static const social = '/social';
  static const profile = '/profile';
  static const debug = '/debug';

  static const tabs = [home, learn, battle, arena, social];
}

/// Where the auth state requires the user to be, or null to stay put.
/// Pure, so the whole gate is unit-testable.
String? authRedirect(AsyncValue<Session> session, String location) {
  final value = session.value;
  if (value == null) {
    // Still restoring, or restore failed with nothing cached: the splash
    // screen shows progress or a retry.
    return location == Routes.splash ? null : Routes.splash;
  }
  switch (value) {
    case SignedOut():
      const open = {Routes.signIn, Routes.debug};
      return open.contains(location) ? null : Routes.signIn;
    case SignedIn(needsOnboarding: true):
      return location == Routes.onboarding ? null : Routes.onboarding;
    case SignedIn():
      const gates = {Routes.splash, Routes.signIn, Routes.onboarding};
      return gates.contains(location) ? Routes.home : null;
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final session = ValueNotifier<AsyncValue<Session>>(ref.read(sessionProvider));
  ref
    ..listen(sessionProvider, (_, next) => session.value = next)
    ..onDispose(session.dispose);

  return GoRouter(
    initialLocation: Routes.home,
    refreshListenable: session,
    redirect: (context, state) => authRedirect(session.value, state.matchedLocation),
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(path: Routes.signIn, builder: (_, _) => const SignInScreen()),
      GoRoute(path: Routes.onboarding, builder: (_, _) => const OnboardingScreen()),
      GoRoute(path: Routes.profile, builder: (_, _) => const ProfileScreen()),
      GoRoute(path: Routes.debug, builder: (_, _) => const DebugScreen()),
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
});
