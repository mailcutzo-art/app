import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/rooms/data/room_models.dart';
import 'package:quiz_app/features/rooms/room_code.dart';
import 'package:quiz_app/features/rooms/room_text.dart';
import 'package:quiz_app/features/rooms/widgets/room_widgets.dart';

void main() {
  test('codes are normalized to Crockford base32', () {
    expect(RoomCode.normalize('k7m2qx'), 'K7M2QX');
    expect(RoomCode.normalize(' K7M-2QX '), 'K7M2QX');
    expect(RoomCode.normalize('ABOIL1'), 'AB0111', reason: 'O, I and L read as 0 and 1');
    expect(RoomCode.normalize('https://quizarena.app/j/K7M2QX'), 'K7M2QX');
    expect(RoomCode.normalize('K7M2Q'), isNull);
    expect(RoomCode.normalize('K7M2QU'), isNull, reason: 'U is not Crockford');
    expect(RoomCode.normalize('K7M2Q!'), isNull);
    expect(RoomCode.spaced('K7M2QX'), 'K7M 2QX');
  });

  test('previews, invites and created rooms parse', () {
    final preview = RoomPreview.fromJson(const {
      'room_id': 'R1',
      'kind': 'group',
      'host': {'id': 'u2', 'handle': 'riya_s', 'display_name': 'Riya'},
      'subject': 'Physics',
      'chapters': ['Kinematics'],
      'questions': 10,
      'seconds': 15,
      'members': 3,
      'capacity': 8,
      'joinable': false,
      'reason': 'friends_only',
    });
    expect(preview.kind, RoomKind.group);
    expect(preview.host.displayName, 'Riya');
    expect(preview.chapters, ['Kinematics']);
    expect(preview.joinable, isFalse);
    expect(preview.reason, JoinBlock.friendsOnly);
    expect(JoinBlock.parse('snowed_in'), JoinBlock.unknown);
    expect(JoinBlock.parse(null), isNull);

    final list = InviteList.fromJson(const {
      'incoming': [
        {
          'invite_id': 'I1',
          'from': {'id': 'u2', 'handle': 'riya_s', 'display_name': 'Riya'},
          'room_id': 'R1',
          'kind': 'friend',
          'subject': 'physics',
          'expires_at': '2026-09-28T10:02:00Z',
        },
      ],
      'outgoing': [
        {
          'invite_id': 'I2',
          'to': {'id': 'u3', 'handle': 'neha', 'display_name': 'Neha'},
          'room_id': 'R1',
          'kind': 'group',
        },
      ],
    });
    expect(list.incoming.single.user.id, 'u2');
    expect(list.incoming.single.expiresAt, DateTime.utc(2026, 9, 28, 10, 2));
    expect(list.outgoing.single.user.displayName, 'Neha');

    final created = CreatedRoom.fromJson(const {
      'room_id': 'R1',
      'code': 'K7M2QX',
      'link': 'https://quizarena.app/j/K7M2QX',
    });
    expect(created.link, endsWith('/j/K7M2QX'));
    expect(AcceptedInvite.fromJson(const {'room_id': 'R1', 'code': 'K7M2QX'}).code, 'K7M2QX');
  });

  test('default settings and their summary', () {
    final friend = defaultRoomSettings(RoomKind.friend, subject: 'physics');
    expect(friend.questions, 7);
    expect(friend.seconds, 15);
    expect(friend.difficulty, isNull);
    final group = defaultRoomSettings(RoomKind.group, subject: 'physics', chapter: 'kinematics');
    expect(group.questions, 10);
    expect(group.lateJoin, 'halfway');
    expect(group.leaderboard, isTrue);
    expect(group.join, 'code');
    expect(settingsLines(group, RoomKind.group), [
      'Physics',
      'Kinematics',
      '10 questions',
      '15 s each',
      'Mixed difficulty',
      'Late join until halfway',
      'Leaderboard between questions',
      'Anyone with the code',
    ]);
    expect(questionChoices(RoomKind.friend), [5, 7, 10]);
    expect(questionChoices(RoomKind.group), [5, 10, 15, 20]);
  });

  test('ordinals and closing reasons', () {
    expect([1, 2, 3, 4, 11, 12, 13, 21, 22].map(RoomText.ordinal), [
      '1st',
      '2nd',
      '3rd',
      '4th',
      '11th',
      '12th',
      '13th',
      '21st',
      '22nd',
    ]);
    expect(RoomText.closed('host_left'), 'The lobby closed because the host left');
    expect(RoomText.closed('whatever'), 'The room closed');
  });
}
