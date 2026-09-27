import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/config/app_config.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/features/onboarding/onboarding_repository.dart';

const testEnv = AppEnv(flavor: Flavor.dev, apiBaseUrl: 'http://api.test', googleServerClientId: '');

Me fakeUser({bool onboarded = true}) => Me(
  id: 'u1',
  displayName: 'Aarav Sharma',
  handle: onboarded ? 'aarav' : null,
  avatar: const Avatar(tone: 'lime', symbol: 'rocket'),
  goal: onboarded ? Goal.neet : null,
  birthYear: onboarded ? 2008 : null,
  isMinor: true,
  onboardingCompleted: onboarded,
);

/// Session controller that starts in a fixed state.
class FakeSessionController extends SessionController {
  FakeSessionController(this.initial);

  final Session initial;

  @override
  Future<Session> build() async => initial;

  @override
  Future<void> signOut() async => state = const AsyncData(SignedOut());
}

/// Onboarding API stand-in: every well-formed handle is available.
class FakeOnboardingRepository extends OnboardingRepository {
  FakeOnboardingRepository() : super(ApiClient(Dio()));

  @override
  Future<HandleStatus> checkHandle(String handle) async =>
      handlePattern.hasMatch(handle) ? HandleStatus.available : HandleStatus.invalid;
}

/// Config stand-in: a fixed answer, no network.
class FakeConfigController extends ConfigController {
  FakeConfigController([this.config = const AppConfig()]);

  final AppConfig config;

  @override
  Future<AppConfig> build() async => config;

  @override
  Future<void> recheck() async {}
}

List<Override> testOverrides({
  required Session session,
  AppConfig config = const AppConfig(),
  int build = 1,
}) => [
  appEnvProvider.overrideWithValue(testEnv),
  sessionProvider.overrideWith(() => FakeSessionController(session)),
  onboardingRepositoryProvider.overrideWithValue(FakeOnboardingRepository()),
  configProvider.overrideWith(() => FakeConfigController(config)),
  appBuildProvider.overrideWith((ref) async => build),
];

/// Scripted HTTP responses for Dio, recorded for assertions.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions options) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Object? body, {int status = 200, Map<String, List<String>>? headers}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...?headers,
      },
    );
