import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/features/settings/data/settings_models.dart';
import 'package:quiz_app/features/settings/data/settings_repository.dart';

import '../../support/fakes.dart';

void main() {
  group('NotificationSettings', () {
    test('reads kinds and quiet hours, and writes the same shape back', () {
      final settings = NotificationSettings.fromJson(const {
        'kinds': {
          'invites': true,
          'tournaments': false,
          'friends': true,
          'missions': false,
          'streaks': true,
        },
        'quiet_hours': {'start': '23:15', 'end': '06:45'},
      });
      expect(settings.isOn(NotificationKind.tournaments), isFalse);
      expect(settings.isOn(NotificationKind.invites), isTrue);
      expect(settings.quietStart, const DayTime(23, 15));
      expect(settings.quietEnd, const DayTime(6, 45));
      expect(settings.toJson(), {
        'kinds': {
          'invites': true,
          'tournaments': false,
          'friends': true,
          'missions': false,
          'streaks': true,
        },
        'quiet_hours': {'start': '23:15', 'end': '06:45'},
      });
    });

    test('missing kinds are on and quiet hours default to 22:30–07:00', () {
      final settings = NotificationSettings.fromJson(const {'kinds': <String, Object?>{}});
      expect(NotificationKind.values.every(settings.isOn), isTrue);
      expect(settings.quietStart.wire, '22:30');
      expect(settings.quietEnd.wire, '07:00');
    });

    test('an impossible time is a format error', () {
      expect(() => DayTime.parse('25:00'), throwsFormatException);
      expect(() => DayTime.parse('7am'), throwsFormatException);
      expect(DayTime.parse('7:05').wire, '07:05');
    });
  });

  test('PrivacySettings reads and writes the documented values', () {
    const json = {
      'friend_requests': 'played_with',
      'challenges': 'everyone',
      'presence': 'nobody',
      'public_boards': false,
    };
    final privacy = PrivacySettings.fromJson(json);
    expect(privacy.friendRequests, FriendRequestsFrom.playedWith);
    expect(privacy.challenges, ChallengesFrom.everyone);
    expect(privacy.presence, PresenceTo.nobody);
    expect(privacy.publicBoards, isFalse);
    expect(privacy.toJson(), json);
    // Unknown values fall back to the safe side.
    final odd = PrivacySettings.fromJson(const {'friend_requests': 'aliens'});
    expect(odd.friendRequests, FriendRequestsFrom.playedWith);
    expect(odd.publicBoards, isTrue);
  });

  test('a device session reads GET /v1/me/sessions rows', () {
    final device = DeviceSession.fromJson(const {
      'id': 's1',
      'platform': 'android',
      'app_version': '1.0.0',
      'created_at': '2026-09-01T00:00:00Z',
      'last_seen_at': '2026-09-27T00:00:00Z',
      'current': true,
    });
    expect(device.platformLabel, 'Android');
    expect(device.current, isTrue);
  });

  test('sign-in proofs and profile patches have the documented shapes', () {
    expect(const SignInProof.google('tok').toJson(), {'provider': 'google', 'id_token': 'tok'});
    expect(const SignInProof.dev().toJson(), {'provider': 'dev'});
    expect(
      const ProfilePatch(
        handle: 'new_me',
        avatar: Avatar(tone: 'sky', symbol: 'atom'),
        goal: Goal.jee,
      ).toJson(),
      {
        'handle': 'new_me',
        'avatar': {'tone': 'sky', 'symbol': 'atom'},
        'goal': 'jee',
      },
    );
    expect(const ProfilePatch().isEmpty, isTrue);
  });

  group('API requests', () {
    late FakeAdapter adapter;
    late ApiClient api;

    setUp(() {
      adapter = FakeAdapter(
        (options) => switch ((options.method, options.path)) {
          ('GET', '/v1/me/sessions') => jsonBody([
            {
              'id': 's1',
              'platform': 'ios',
              'app_version': '1.0.0',
              'created_at': '2026-09-01T00:00:00Z',
              'last_seen_at': '2026-09-27T00:00:00Z',
              'current': false,
            },
          ]),
          ('GET', '/v1/me/settings/app') => jsonBody({'analytics': false}),
          ('PUT', _) => ResponseBody.fromString('', 204),
          ('PATCH', '/v1/me') => jsonBody({...fakeUser().toJson(), 'handle': 'new_me'}),
          ('POST', '/v1/me/restore') => jsonBody(fakeUser().toJson()),
          _ => ResponseBody.fromString('', 202),
        },
      );
      api = ApiClient(Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter);
    });

    test('settings and devices', () async {
      final repo = ApiSettingsRepository(api);
      expect((await repo.app()).analytics, isFalse);
      final saved = await repo.saveApp(const AppSettings());
      expect(saved.analytics, isTrue, reason: 'a 204 keeps what was sent');
      await repo.saveNotifications(const NotificationSettings());
      await repo.savePrivacy(const PrivacySettings());
      expect((await repo.sessions()).single.platformLabel, 'iPhone');
      await repo.endSession('s 1');
      await repo.endOtherSessions();

      expect(adapter.requests.map((r) => '${r.method} ${r.uri.path}'), [
        'GET /v1/me/settings/app',
        'PUT /v1/me/settings/app',
        'PUT /v1/me/settings/notifications',
        'PUT /v1/me/settings/privacy',
        'GET /v1/me/sessions',
        'DELETE /v1/me/sessions/s%201',
        'POST /v1/me/sessions/revoke-others',
      ]);
      expect(adapter.requests[1].data, {'analytics': true});
      expect(adapter.requests[2].data, const NotificationSettings().toJson());
    });

    test('the account: profile edit, feedback, delete and restore', () async {
      final repo = ApiAccountRepository(api);
      final me = await repo.updateProfile(const ProfilePatch(handle: 'new_me'));
      expect(me.handle, 'new_me');
      await repo.sendFeedback(
        kind: FeedbackKind.banAppeal,
        message: 'Please look again',
        idempotencyKey: 'k1',
        requestId: 'req-9',
      );
      await repo.deleteAccount(const SignInProof.google('tok'));
      expect((await repo.restore())!.id, 'u1');

      final [patch, feedback, delete, restore] = adapter.requests;
      expect((patch.method, patch.path), ('PATCH', '/v1/me'));
      expect(patch.data, {'handle': 'new_me'});
      expect(feedback.path, '/v1/feedback');
      expect(feedback.data, {
        'kind': 'ban_appeal',
        'message': 'Please look again',
        'request_id': 'req-9',
      });
      expect(feedback.headers['Idempotency-Key'], 'k1');
      expect(delete.path, '/v1/me/delete');
      expect(delete.data, {
        'confirm': 'DELETE',
        'proof': {'provider': 'google', 'id_token': 'tok'},
      });
      expect((restore.method, restore.path), ('POST', '/v1/me/restore'));
    });
  });
}
