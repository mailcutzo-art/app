import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quiz_app/app/app.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/config/app_config.dart';

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
      await tester.pumpWidget(
        ProviderScope(
          overrides: testOverrides(session: SignedIn(fakeUser())),
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

    testWidgets('/t/<id> and /u/<handle> open Arena and Social', (tester) async {
      final router = await pumpApp(tester);
      router.go('/t/0192abc');
      await tester.pumpAndSettle();
      expect(location(router), '/arena?t=0192abc');
      router.go('/u/rahul_07');
      await tester.pumpAndSettle();
      expect(location(router), '/social?u=rahul_07');
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
      await tester.pumpWidget(
        ProviderScope(
          overrides: testOverrides(
            session: SignedIn(fakeUser()),
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
      await tester.pumpWidget(
        ProviderScope(
          overrides: testOverrides(
            session: SignedIn(fakeUser()),
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
}
