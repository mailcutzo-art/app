import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/features/social/data/social_models.dart';

Map<String, Object?> card(String id, {String? handle, int? level = 7}) => {
  'id': id,
  'handle': handle ?? id,
  'display_name': 'Name $id',
  'avatar': {'tone': 'sky', 'symbol': 'atom'},
  'level': level,
};

void main() {
  test('a user card reads the shared shape, with a fallback avatar', () {
    final user = UserCard.fromJson(card('u1', handle: 'rahul_07'));
    expect(user.handle, 'rahul_07');
    expect(user.at, '@rahul_07');
    expect(user.avatar, const Avatar(tone: 'sky', symbol: 'atom'));
    expect(user.level, 7);

    final odd = UserCard.fromJson({...card('u2'), 'avatar': 'nope', 'level': null});
    expect(odd.avatar, Avatar.fallback);
    expect(odd.level, isNull);
    expect(() => UserCard.fromJson(const {'id': 'x'}), throwsFormatException);
  });

  test('friends read flat cards or nested under user, and unknown presence is offline', () {
    final flat = Friend.fromJson({...card('u1'), 'presence': 'in_battle'});
    final nested = Friend.fromJson({'user': card('u2'), 'presence': 'in_tournament'});
    final unknown = Friend.fromJson({...card('u3'), 'presence': 'dancing'});
    expect(flat.presence, FriendPresence.inBattle);
    expect(nested.user.id, 'u2');
    expect(nested.presence, FriendPresence.inTournament);
    expect(unknown.presence, FriendPresence.offline);
    expect(FriendPresence.inBattle.isBusy, isTrue);
  });

  test('a page reads items and the cursor, skipping items it can\'t read', () {
    final page = CursorPage.fromJson({
      'items': [
        card('u1'),
        const {'id': 'broken'},
        card('u2'),
      ],
      'next_cursor': 'c2',
    }, UserCard.fromItem);
    expect(page.items.map((u) => u.id), ['u1', 'u2']);
    expect(page.nextCursor, 'c2');
    expect(CursorPage.fromJson([card('u3')], UserCard.fromItem).items.single.id, 'u3');
    expect(() => CursorPage.fromJson('x', UserCard.fromItem), throwsFormatException);
  });

  test('friend requests read both directions and find a player', () {
    final requests = FriendRequests.fromJson({
      'incoming': [
        {'id': 'r1', 'user': card('u1'), 'created_at': '2026-09-27T10:00:00Z'},
      ],
      'outgoing': [
        {'id': 'r2', 'to': card('u2')},
      ],
    });
    expect(requests.incomingFrom('u1')?.id, 'r1');
    expect(requests.incoming.single.createdAt, DateTime.utc(2026, 9, 27, 10));
    expect(requests.outgoingTo('u2')?.id, 'r2');
    expect(requests.outgoingTo('u1'), isNull);
    expect(FriendRequests.fromJson(const <String, Object?>{}).isEmpty, isTrue);
  });

  test('a sent request notices when it became a friendship', () {
    expect(SentRequest.fromJson(const {'id': 'r1'}).requestId, 'r1');
    expect(SentRequest.fromJson(const {'id': 'r1'}).becameFriends, isFalse);
    expect(SentRequest.fromJson(const {'id': 'r1', 'status': 'accepted'}).becameFriends, isTrue);
    expect(SentRequest.fromJson(null).requestId, isNull);
  });

  test('head-to-head records say who leads', () {
    const lead = HeadToHead(wins: 3, losses: 1);
    expect(lead.summary, 'You lead 3–1');
    expect(lead.short, '3W · 1L · 0D');
    expect(const HeadToHead(wins: 1, losses: 2).summary, 'They lead 2–1');
    expect(const HeadToHead(wins: 2, losses: 2, draws: 1).summary, 'Level at 2–2');
    expect(const HeadToHead().summary, 'No games yet');
    expect(HeadToHead.tryParse({'wins': 3, 'losses': 1, 'draws': 0}), lead);
    expect(HeadToHead.tryParse(null), isNull);
  });

  test('opponents and search results carry the relationship', () {
    final opponent = Opponent.fromJson({
      'user': card('u1'),
      'h2h': const {'wins': 2, 'losses': 0, 'draws': 1},
      'relationship': 'requested',
      'last_played_at': '2026-09-26T08:00:00Z',
    });
    expect(opponent.h2h.played, 3);
    expect(opponent.relationship, Relationship.requested);
    expect(opponent.lastPlayedAt, isNotNull);
    final result = SearchResult.fromJson({...card('u2'), 'relationship': 'friend'});
    expect(result.relationship, Relationship.friend);
    expect(Relationship.parse('weird'), Relationship.none);
  });

  group('activity', () {
    test('uses the server\'s sentence when there is one', () {
      final item = ActivityItem.fromJson({
        'id': 'a1',
        'user': card('u1'),
        'kind': 'podium',
        'title': 'finished #2 in Physics Sunday Cup',
        'created_at': '2026-09-27T10:00:00Z',
      });
      expect(item.kind, ActivityKind.podium);
      expect(item.text, 'finished #2 in Physics Sunday Cup');
    });

    test('otherwise writes one from the kind and its data', () {
      ActivityItem item(String kind, Map<String, Object?> data) => ActivityItem.fromJson({
        'id': 'a',
        'user': card('u1'),
        'kind': kind,
        'data': data,
        'created_at': '2026-09-27T10:00:00Z',
      });
      expect(item('level_up', {'level': 8}).text, 'reached level 8');
      expect(item('streak', {'days': 12}).text, 'is on a 12-day streak');
      expect(
        item('podium', {'position': 3, 'name': 'Sunday Cup'}).text,
        'finished #3 in Sunday Cup',
      );
      expect(item('achievement', {'name': 'Sharp Shooter'}).text, 'earned “Sharp Shooter”');
      expect(item('mystery', {}).kind, ActivityKind.other);
    });
  });

  group('public profile', () {
    test('reads ratings, form, head-to-head and what the user can do', () {
      final profile = PublicProfile.fromJson({
        ...card('u1', handle: 'rahul_07'),
        'ratings': const [
          {
            'scope': 'neet:physics',
            'rating': {'display': '1523?', 'value': 1523, 'provisional': true},
            'position': 42,
          },
        ],
        'form': const [
          'W',
          'loss',
          {'result': 'draw'},
          'nonsense',
        ],
        'h2h': const {'wins': 3, 'losses': 1, 'draws': 0},
        'relationship': 'friend',
        'can_challenge': true,
      });
      expect(profile.user.handle, 'rahul_07');
      expect(profile.ratings!.single.label, 'Physics');
      expect(profile.ratings!.single.rating.display, '1523?');
      expect(profile.ratings!.single.position, 42);
      expect(profile.form, [FormResult.win, FormResult.loss, FormResult.draw]);
      expect(profile.h2h!.wins, 3);
      expect(profile.relationship, Relationship.friend);
      expect(profile.canChallenge, isTrue);
      expect(profile.isLimited, isFalse);
    });

    test('a minor\'s profile for a non-friend has only the card', () {
      final profile = PublicProfile.fromJson({...card('u1'), 'relationship': 'none'});
      expect(profile.isLimited, isTrue);
      expect(profile.ratings, isNull);
      expect(profile.form, isNull);
      expect(profile.h2h, isNull);
      expect(profile.canChallenge, isFalse);
    });
  });
}
