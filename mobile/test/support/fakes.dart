import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/auth/user.dart';
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
}

/// Onboarding API stand-in: every well-formed handle is available.
class FakeOnboardingRepository extends OnboardingRepository {
  FakeOnboardingRepository() : super(ApiClient(Dio()));

  @override
  Future<HandleStatus> checkHandle(String handle) async =>
      handlePattern.hasMatch(handle) ? HandleStatus.available : HandleStatus.invalid;
}

List<Override> testOverrides({required Session session}) => [
  appEnvProvider.overrideWithValue(testEnv),
  sessionProvider.overrideWith(() => FakeSessionController(session)),
  onboardingRepositoryProvider.overrideWithValue(FakeOnboardingRepository()),
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
