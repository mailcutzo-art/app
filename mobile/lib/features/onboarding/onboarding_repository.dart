import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/user.dart';
import '../../core/network/api_client.dart';
import '../../core/network/app_failure.dart';

enum HandleStatus { available, taken, invalid, reserved }

/// Same rule the server enforces.
final handlePattern = RegExp(r'^[a-z0-9_]{3,20}$');

class OnboardingRepository {
  OnboardingRepository(this._api);

  final ApiClient _api;

  Future<HandleStatus> checkHandle(String handle) async {
    if (!handlePattern.hasMatch(handle)) return HandleStatus.invalid;
    final data = await _api.get('/v1/handles/check', query: {'handle': handle});
    return switch (data) {
      {'available': true} => HandleStatus.available,
      {'reason': 'reserved'} => HandleStatus.reserved,
      {'reason': 'invalid'} => HandleStatus.invalid,
      {'available': false} => HandleStatus.taken,
      _ => throw const UnexpectedFailure(),
    };
  }

  Future<Me> complete({
    required String displayName,
    required String handle,
    required Avatar avatar,
    required Goal goal,
    required int birthYear,
  }) async {
    final data = await _api.post(
      '/v1/me/onboarding',
      body: {
        'display_name': displayName,
        'handle': handle,
        'avatar': avatar.toJson(),
        'goal': goal.name,
        'birth_year': birthYear,
      },
    );
    return Me.fromJson(data);
  }
}

final onboardingRepositoryProvider = Provider<OnboardingRepository>(
  (ref) => OnboardingRepository(ref.watch(apiClientProvider)),
);
