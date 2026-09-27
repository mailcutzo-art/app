import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/core/auth/auth_repository.dart';
import 'package:quiz_app/core/auth/session.dart';
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
}
