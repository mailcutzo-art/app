import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/core/auth/auth_repository.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';

import '../support/fakes.dart';

class _MockRepo extends Mock implements AuthRepository {}

void main() {
  late _MockRepo repo;

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        appEnvProvider.overrideWithValue(testEnv),
        authRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    repo = _MockRepo();
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('no stored session → signed out', () async {
    when(() => repo.hasStoredSession()).thenAnswer((_) async => false);
    expect(await container().read(sessionProvider.future), isA<SignedOut>());
  });

  test('stored session restores the user', () async {
    when(() => repo.hasStoredSession()).thenAnswer((_) async => true);
    when(() => repo.fetchMe()).thenAnswer((_) async => fakeUser());
    final session = await container().read(sessionProvider.future);
    expect(session, isA<SignedIn>().having((s) => s.user.handle, 'handle', 'aarav'));
  });

  test('a revoked session signs out', () async {
    when(() => repo.hasStoredSession()).thenAnswer((_) async => true);
    when(() => repo.fetchMe()).thenThrow(const UnauthorizedFailure());
    expect(await container().read(sessionProvider.future), isA<SignedOut>());
  });

  test('offline start uses the cached profile', () async {
    FlutterSecureStorage.setMockInitialValues({
      'auth.user_snapshot': jsonEncode(fakeUser().toJson()),
    });
    when(() => repo.hasStoredSession()).thenAnswer((_) async => true);
    when(() => repo.fetchMe()).thenThrow(const NetworkFailure());
    final session = await container().read(sessionProvider.future);
    expect(session, isA<SignedIn>().having((s) => s.offline, 'offline', isTrue));
  });

  test('offline start without a cache surfaces the error (splash offers retry)', () async {
    when(() => repo.hasStoredSession()).thenAnswer((_) async => true);
    when(() => repo.fetchMe()).thenThrow(const NetworkFailure());
    await expectLater(container().read(sessionProvider.future), throwsA(isA<NetworkFailure>()));
  });

  test('the refresh token being rejected mid-session signs out with a message', () async {
    when(() => repo.hasStoredSession()).thenAnswer((_) async => true);
    when(() => repo.fetchMe()).thenAnswer((_) async => fakeUser());
    final c = container();
    await c.read(sessionProvider.future);

    c.read(sessionExpiredProvider.notifier).fire();
    final session = c.read(sessionProvider).value;
    expect(session, isA<SignedOut>().having((s) => s.message, 'message', isNotNull));
  });

  test('sign out clears the session', () async {
    when(() => repo.hasStoredSession()).thenAnswer((_) async => true);
    when(() => repo.fetchMe()).thenAnswer((_) async => fakeUser());
    when(() => repo.signOut()).thenAnswer((_) async {});
    final c = container();
    await c.read(sessionProvider.future);

    await c.read(sessionProvider.notifier).signOut();
    expect(c.read(sessionProvider).value, isA<SignedOut>());
    verify(() => repo.signOut()).called(1);
  });

  test('a suspended account on restore opens the Suspended state', () async {
    when(() => repo.hasStoredSession()).thenAnswer((_) async => true);
    when(() => repo.fetchMe()).thenThrow(
      const ForbiddenFailure(
        'This account has been suspended.',
        code: 'ACCOUNT_BANNED',
        details: {'reason': 'cheating', 'until': '2026-10-04T00:00:00Z', 'appeal': 'a@b.in'},
      ),
    );
    final session = await container().read(sessionProvider.future);
    expect(
      session,
      isA<Suspended>()
          .having((s) => s.reason, 'reason', 'cheating')
          .having((s) => s.until, 'until', DateTime.utc(2026, 10, 4))
          .having((s) => s.appeal, 'appeal', 'a@b.in'),
    );
  });

  test('a revoke reason becomes a message the user understands', () async {
    when(() => repo.hasStoredSession()).thenAnswer((_) async => true);
    when(() => repo.fetchMe()).thenAnswer((_) async => fakeUser());
    final c = container();
    await c.read(sessionProvider.future);

    c.read(sessionExpiredProvider.notifier).fire(const SessionEnd(reason: 'signed_out'));
    expect(
      c.read(sessionProvider).value,
      isA<SignedOut>().having(
        (s) => s.message,
        'message',
        'You were signed out from another device.',
      ),
    );
  });

  test('a ban mid-session switches to Suspended, and leaving it signs out locally', () async {
    when(() => repo.hasStoredSession()).thenAnswer((_) async => true);
    when(() => repo.fetchMe()).thenAnswer((_) async => fakeUser());
    final c = container();
    await c.read(sessionProvider.future);

    c.read(sessionExpiredProvider.notifier).fire(const SessionEnd(ban: {'reason': 'abuse'}));
    expect(c.read(sessionProvider).value, isA<Suspended>());

    await c.read(sessionProvider.notifier).leaveSuspended();
    expect(c.read(sessionProvider).value, isA<SignedOut>());
    verifyNever(() => repo.signOut());
  });

  test('signing in to a suspended account opens the Suspended state', () async {
    when(() => repo.hasStoredSession()).thenAnswer((_) async => false);
    when(
      () => repo.devLogin(
        email: any(named: 'email'),
        displayName: any(named: 'displayName'),
      ),
    ).thenThrow(
      const ForbiddenFailure(
        'This account has been suspended.',
        code: 'ACCOUNT_BANNED',
        details: {'reason': 'cheating', 'until': '2026-10-04T00:00:00Z'},
      ),
    );
    final c = container();
    await c.read(sessionProvider.future);

    await c.read(sessionProvider.notifier).devLogin('a@b.c');
    expect(
      c.read(sessionProvider).value,
      isA<Suspended>()
          .having((s) => s.reason, 'reason', 'cheating')
          .having((s) => s.until, 'until', DateTime.utc(2026, 10, 4)),
    );
  });

  test('the current user outlives sign-out for screens still animating away', () async {
    when(() => repo.hasStoredSession()).thenAnswer((_) async => true);
    when(() => repo.fetchMe()).thenAnswer((_) async => fakeUser());
    when(() => repo.signOut()).thenAnswer((_) async {});
    final c = container();
    await c.read(sessionProvider.future);
    final subscription = c.listen(meProvider, (_, _) {});
    addTearDown(subscription.close);
    expect(c.read(meProvider).handle, 'aarav');

    await c.read(sessionProvider.notifier).signOut();
    expect(c.read(sessionProvider).value, isA<SignedOut>());
    expect(c.read(meProvider).handle, 'aarav');
  });

  group('an account awaiting deletion', () {
    Me pending() => Me.fromJson({
      ...fakeUser().toJson(),
      'status': 'pending_deletion',
      'restore_until': '2026-10-05T10:00:00Z',
    });

    test('/v1/me with status pending_deletion restores a restricted session', () async {
      when(() => repo.hasStoredSession()).thenAnswer((_) async => true);
      when(() => repo.fetchMe()).thenAnswer((_) async => pending());
      final session = await container().read(sessionProvider.future);
      expect(
        session,
        isA<PendingDeletion>().having(
          (s) => s.restoreUntil,
          'restoreUntil',
          DateTime.utc(2026, 10, 5, 10),
        ),
      );
    });

    test('signing in during the 7 days opens it too, and a restore signs in fully', () async {
      when(() => repo.hasStoredSession()).thenAnswer((_) async => false);
      when(
        () => repo.devLogin(
          email: any(named: 'email'),
          displayName: any(named: 'displayName'),
        ),
      ).thenAnswer((_) async => pending());
      final c = container();
      await c.read(sessionProvider.future);

      await c.read(sessionProvider.notifier).devLogin('a@b.c');
      expect(c.read(sessionProvider).value, isA<PendingDeletion>());
      expect(c.read(currentUserIdProvider), isNull, reason: 'nothing runs for a restricted user');

      when(() => repo.fetchMe()).thenAnswer((_) async => fakeUser());
      await c.read(sessionProvider.notifier).refreshUser();
      expect(c.read(sessionProvider).value, isA<SignedIn>());
    });

    test('the status survives the offline snapshot', () {
      final restored = Me.fromJson(pending().toJson());
      expect(restored.isPendingDeletion, isTrue);
      expect(restored.restoreUntil, DateTime.utc(2026, 10, 5, 10));
      expect(Me.fromJson(fakeUser().toJson()).status, AccountStatus.active);
    });
  });

  test('ending the session locally (after a delete) skips the server and says why', () async {
    when(() => repo.hasStoredSession()).thenAnswer((_) async => true);
    when(() => repo.fetchMe()).thenAnswer((_) async => fakeUser());
    final c = container();
    await c.read(sessionProvider.future);

    await c.read(sessionProvider.notifier).endLocally(message: 'Deleted.');
    expect(
      c.read(sessionProvider).value,
      isA<SignedOut>().having((s) => s.message, 'message', 'Deleted.'),
    );
    verifyNever(() => repo.signOut());
  });
}
