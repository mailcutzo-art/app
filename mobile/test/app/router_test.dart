import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quiz_app/app/app.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/config/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

const _open = AppGate.open;
const _signedOut = AsyncData<Session>(SignedOut());

String? _redirect(AsyncValue<Session> session, String location) =>
    decideRoute(gate: _open, session: session, location: location).redirect;

void main() {
  group('session gates', () {
    test('while restoring, everything waits on the splash screen', () {
      const loading = AsyncLoading<Session>();
      expect(_redirect(loading, Routes.home), Routes.splash);
      expect(_redirect(loading, Routes.splash), isNull);
    });

    test('a failed restore with nothing cached stays on splash (retry lives there)', () {
      final failed = AsyncError<Session>(Exception('offline'), StackTrace.empty);
      expect(_redirect(failed, Routes.battle), Routes.splash);
    });

    test('signed out users can only see sign-in and debug', () {
      expect(_redirect(_signedOut, Routes.home), Routes.signIn);
      expect(_redirect(_signedOut, Routes.onboarding), Routes.signIn);
      expect(_redirect(_signedOut, Routes.signIn), isNull);
      expect(_redirect(_signedOut, Routes.debug), isNull);
    });

    test('users who have not finished onboarding are held there', () {
      final fresh = AsyncData<Session>(SignedIn(fakeUser(onboarded: false)));
      expect(_redirect(fresh, Routes.home), Routes.onboarding);
      expect(_redirect(fresh, Routes.profile), Routes.onboarding);
      expect(_redirect(fresh, Routes.onboarding), isNull);
    });

    test('onboarded users skip the gates and can go anywhere else', () {
      final ready = AsyncData<Session>(SignedIn(fakeUser()));
      expect(_redirect(ready, Routes.signIn), Routes.home);
      expect(_redirect(ready, Routes.splash), Routes.home);
      expect(_redirect(ready, Routes.onboarding), Routes.home);
      expect(_redirect(ready, Routes.update), Routes.home);
      expect(_redirect(ready, Routes.maintenance), Routes.home);
      expect(_redirect(ready, Routes.arena), isNull);
      expect(_redirect(ready, Routes.profile), isNull);
    });

    test('authRedirect still answers for the session alone', () {
      expect(authRedirect(_signedOut, Routes.home), Routes.signIn);
    });

    test('Learn subjects and practice sessions sit behind the same gates', () {
      final ready = AsyncData<Session>(SignedIn(fakeUser()));
      expect(authRedirect(ready, Routes.subject('physics')), isNull);
      expect(authRedirect(ready, Routes.practiceSession('s-1')), isNull);
      const out = AsyncData<Session>(SignedOut());
      expect(authRedirect(out, Routes.practiceSession('s-1')), Routes.signIn);
      final fresh = AsyncData<Session>(SignedIn(fakeUser(onboarded: false)));
      expect(authRedirect(fresh, Routes.subject('physics')), Routes.onboarding);
    });

    test('a refresh that keeps the previous value does not bounce to splash', () async {
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(() => FakeSessionController(SignedIn(fakeUser()))),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);

      container.invalidate(sessionProvider);
      final refreshing = container.read(sessionProvider);
      expect(refreshing.isLoading, isTrue);
      expect(_redirect(refreshing, Routes.home), isNull);
    });
  });

  group('suspended accounts', () {
    const suspended = AsyncData<Session>(Suspended(reason: 'cheating'));

    test('only the Suspended screen (and debug) is reachable', () {
      expect(_redirect(suspended, Routes.home), Routes.suspended);
      expect(_redirect(suspended, Routes.signIn), Routes.suspended);
      expect(_redirect(suspended, Routes.suspended), isNull);
      expect(_redirect(suspended, Routes.debug), isNull);
    });

    test('nothing is remembered as a destination while suspended', () {
      final decision = decideRoute(
        gate: _open,
        session: suspended,
        location: '/j/K7M2QX',
        pending: '/t/abc',
      );
      expect(decision, (redirect: Routes.suspended, pending: null));
    });
  });

  group('accounts awaiting deletion', () {
    final pending = AsyncData<Session>(
      PendingDeletion(Me.fromJson({...fakeUser().toJson(), 'status': 'pending_deletion'})),
    );

    test('only Restore (and debug) is reachable', () {
      expect(_redirect(pending, Routes.home), Routes.restore);
      expect(_redirect(pending, Routes.profile), Routes.restore);
      expect(_redirect(pending, Routes.signIn), Routes.restore);
      expect(_redirect(pending, Routes.restore), isNull);
      expect(_redirect(pending, Routes.debug), isNull);
    });

    test('a link opened meanwhile opens after the restore', () {
      final waiting = decideRoute(gate: _open, session: pending, location: '/j/K7M2QX');
      expect(waiting, (redirect: Routes.restore, pending: '/j/K7M2QX'));

      final restored = decideRoute(
        gate: _open,
        session: AsyncData<Session>(SignedIn(fakeUser())),
        location: Routes.restore,
        pending: waiting.pending,
      );
      expect(restored, (redirect: '/j/K7M2QX', pending: null));
    });

    test('once restored, the Restore screen is left for Home', () {
      final ready = AsyncData<Session>(SignedIn(fakeUser()));
      expect(_redirect(ready, Routes.restore), Routes.home);
    });
  });

  group('pending destination storage', () {
    test('survives an app restart for 30 minutes, then expires', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var now = DateTime.utc(2026, 9, 27, 18);
      PendingDestination(prefs: prefs, clock: () => now).location = '/j/K7M2QX';

      now = now.add(const Duration(minutes: 29));
      expect(PendingDestination(prefs: prefs, clock: () => now).location, '/j/K7M2QX');

      now = now.add(const Duration(minutes: 2));
      expect(PendingDestination(prefs: prefs, clock: () => now).location, isNull);
    });

    test('clearing it removes the saved copy', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      PendingDestination(prefs: prefs)
        ..location = '/t/abc'
        ..location = null;
      expect(prefs.getString(PendingDestination.key), isNull);
      expect(PendingDestination(prefs: prefs).location, isNull);
    });
  });

  group('app gates', () {
    final ready = AsyncData<Session>(SignedIn(fakeUser()));

    test('an update is required before anything else, even sign-in', () {
      for (final session in [ready, _signedOut, const AsyncLoading<Session>()]) {
        final decision = decideRoute(
          gate: AppGate.updateRequired,
          session: session,
          location: Routes.home,
        );
        expect(decision.redirect, Routes.update);
      }
      expect(
        decideRoute(gate: AppGate.updateRequired, session: ready, location: Routes.update).redirect,
        isNull,
      );
    });

    test('maintenance allows only its own screen and debug settings', () {
      RouteDecision at(String location) =>
          decideRoute(gate: AppGate.maintenance, session: ready, location: location);
      expect(at(Routes.battle).redirect, Routes.maintenance);
      expect(at(Routes.signIn).redirect, Routes.maintenance);
      expect(at(Routes.maintenance).redirect, isNull);
      expect(at(Routes.debug).redirect, isNull);
    });

    test('when maintenance ends, the user returns to where they were going', () {
      final during = decideRoute(gate: AppGate.maintenance, session: ready, location: Routes.arena);
      expect(during.pending, Routes.arena);
      final after = decideRoute(
        gate: _open,
        session: ready,
        location: Routes.maintenance,
        pending: during.pending,
      );
      expect(after.redirect, Routes.arena);
      expect(after.pending, isNull);
    });
  });

  group('pending destination', () {
    const link = '/j/K7M2QX';

    test('a link opened while signed out survives sign-in', () {
      var decision = decideRoute(gate: _open, session: _signedOut, location: link);
      expect(decision, (redirect: Routes.signIn, pending: link));

      decision = decideRoute(
        gate: _open,
        session: _signedOut,
        location: Routes.signIn,
        pending: decision.pending,
      );
      expect(decision, (redirect: null, pending: link));

      decision = decideRoute(
        gate: _open,
        session: AsyncData(SignedIn(fakeUser())),
        location: Routes.signIn,
        pending: decision.pending,
      );
      expect(decision, (redirect: link, pending: null));
    });

    test('it also survives onboarding', () {
      final fresh = AsyncData<Session>(SignedIn(fakeUser(onboarded: false)));
      var decision = decideRoute(gate: _open, session: fresh, location: link);
      expect(decision, (redirect: Routes.onboarding, pending: link));

      decision = decideRoute(
        gate: _open,
        session: AsyncData(SignedIn(fakeUser())),
        location: Routes.onboarding,
        pending: decision.pending,
      );
      expect(decision.redirect, link);
    });

    test('and the splash screen while the session is restored', () {
      var decision = decideRoute(
        gate: _open,
        session: const AsyncLoading(),
        location: '/t/abc?from=push',
      );
      expect(decision, (redirect: Routes.splash, pending: '/t/abc?from=push'));

      decision = decideRoute(
        gate: _open,
        session: AsyncData(SignedIn(fakeUser())),
        location: Routes.splash,
        pending: decision.pending,
      );
      expect(decision.redirect, '/t/abc?from=push');
    });

    test('gate screens and debug are never remembered as destinations', () {
      for (final location in [...Routes.gates, Routes.debug]) {
        final decision = decideRoute(
          gate: _open,
          session: _signedOut,
          location: location,
          pending: link,
        );
        expect(decision.pending, link, reason: location);
      }
    });

    test('without a pending destination, signed-in users land on Home', () {
      final decision = decideRoute(
        gate: _open,
        session: AsyncData(SignedIn(fakeUser())),
        location: Routes.signIn,
      );
      expect(decision, (redirect: Routes.home, pending: null));
    });
  });

  group('deep links', () {
    Future<GoRouter> pumpApp(WidgetTester tester) async {
      final prefs = await testPrefs();
      await tester.pumpWidget(
        ProviderScope(
          overrides: testOverrides(session: SignedIn(fakeUser()), prefs: prefs),
          child: const QuizApp(),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(QuizApp)));
      return container.read(routerProvider);
    }

    String location(GoRouter router) => router.routerDelegate.currentConfiguration.uri.toString();

    testWidgets('/j/<code> opens the Battle tab with the room code', (tester) async {
      final router = await pumpApp(tester);
      router.go('/j/K7M2QX');
      await tester.pumpAndSettle();
      expect(location(router), '/battle?join=K7M2QX');
    });

    testWidgets('/t/<id> opens Arena and /u/<handle> the player\'s profile', (tester) async {
      final router = await pumpApp(tester);
      router.go('/t/0192abc');
      await tester.pumpAndSettle();
      expect(location(router), '/arena?t=0192abc');
      router.go('/u/rahul_07');
      await tester.pumpAndSettle();
      expect(location(router), '/u/rahul_07');
      expect(find.text('@rahul_07'), findsWidgets);
      expect(find.text('Rahul'), findsOneWidget);
    });

    testWidgets('an unknown link falls back to Home', (tester) async {
      final router = await pumpApp(tester);
      router.go('/nope/123');
      await tester.pumpAndSettle();
      expect(location(router), Routes.home);
      expect(find.text('Hi, Aarav!'), findsOneWidget);
    });
  });

  group('gate screens', () {
    testWidgets('an outdated build shows the update screen', (tester) async {
      final prefs = await testPrefs();
      await tester.pumpWidget(
        ProviderScope(
          overrides: testOverrides(
            session: SignedIn(fakeUser()),
            prefs: prefs,
            config: const AppConfig(minBuild: 5),
            build: 4,
          ),
          child: const QuizApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Time for an update'), findsOneWidget);
      expect(find.text('Update on Play Store'), findsOneWidget);
    });

    testWidgets('maintenance shows the server message', (tester) async {
      final prefs = await testPrefs();
      await tester.pumpWidget(
        ProviderScope(
          overrides: testOverrides(
            session: SignedIn(fakeUser()),
            prefs: prefs,
            config: const AppConfig(maintenance: true, maintenanceMessage: 'Back at 6 pm IST.'),
          ),
          child: const QuizApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Quick maintenance'), findsOneWidget);
      expect(find.text('Back at 6 pm IST.'), findsOneWidget);
    });
  });

  test('route helpers build the documented paths', () {
    expect(Routes.subject('physics'), '/learn/physics');
    expect(Routes.practiceSession('s-1'), '/practice/s-1');
  });
}
