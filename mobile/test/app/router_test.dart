import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/session.dart';

import '../support/fakes.dart';

void main() {
  group('authRedirect', () {
    test('while restoring, everything waits on the splash screen', () {
      const loading = AsyncLoading<Session>();
      expect(authRedirect(loading, Routes.home), Routes.splash);
      expect(authRedirect(loading, Routes.splash), isNull);
    });

    test('a failed restore with nothing cached stays on splash (retry lives there)', () {
      final failed = AsyncError<Session>(Exception('offline'), StackTrace.empty);
      expect(authRedirect(failed, Routes.battle), Routes.splash);
    });

    test('signed out users can only see sign-in and debug', () {
      const out = AsyncData<Session>(SignedOut());
      expect(authRedirect(out, Routes.home), Routes.signIn);
      expect(authRedirect(out, Routes.onboarding), Routes.signIn);
      expect(authRedirect(out, Routes.signIn), isNull);
      expect(authRedirect(out, Routes.debug), isNull);
    });

    test('users who have not finished onboarding are held there', () {
      final fresh = AsyncData<Session>(SignedIn(fakeUser(onboarded: false)));
      expect(authRedirect(fresh, Routes.home), Routes.onboarding);
      expect(authRedirect(fresh, Routes.profile), Routes.onboarding);
      expect(authRedirect(fresh, Routes.onboarding), isNull);
    });

    test('onboarded users skip the gates and can go anywhere else', () {
      final ready = AsyncData<Session>(SignedIn(fakeUser()));
      expect(authRedirect(ready, Routes.signIn), Routes.home);
      expect(authRedirect(ready, Routes.splash), Routes.home);
      expect(authRedirect(ready, Routes.onboarding), Routes.home);
      expect(authRedirect(ready, Routes.arena), isNull);
      expect(authRedirect(ready, Routes.profile), isNull);
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
      expect(authRedirect(refreshing, Routes.home), isNull);
    });
  });

  test('route helpers build the documented paths', () {
    expect(Routes.subject('physics'), '/learn/physics');
    expect(Routes.practiceSession('s-1'), '/practice/s-1');
  });
}
