import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/share/share_models.dart';
import 'package:quiz_app/features/social/data/fake_social_repository.dart';
import 'package:quiz_app/features/social/data/social_models.dart';

import '../../support/share_samples.dart';

void main() {
  late FakeSocialRepository repo;

  setUp(() => repo = FakeSocialRepository.seeded());

  test('the seeded world has friends in every presence, requests, rivals and activity', () async {
    final friends = await repo.friends();
    expect(friends.items.map((f) => f.presence).toSet(), FriendPresence.values.toSet());
    final requests = await repo.requests();
    expect(requests.incoming.map((r) => r.user.handle), ['zoya_z', 'dev_neet']);
    expect(requests.outgoing.single.user.handle, 'ananya');
    expect((await repo.rivals()).map((r) => r.user.handle), containsAll(['rahul_07', 'ananya']));
    expect((await repo.opponents()).length, greaterThanOrEqualTo(4));
    final activity = (await repo.activity()).items;
    expect(activity, hasLength(6));
    expect(activity.where((a) => a.share != null).map((a) => a.kind), [
      ActivityKind.sharedResult,
      ActivityKind.sharedProgress,
    ]);
    expect((await repo.blocks()).single.handle, 'sam_x');
  });

  test('search needs 3 characters, matches handle prefixes and hides blocked players', () async {
    await expectLater(repo.search('ra'), throwsA(isA<ValidationFailure>()));
    final r = await repo.search('RAH');
    expect(r.single.relationship, Relationship.friend);
    expect((await repo.search('ana')).single.relationship, Relationship.requested);
    expect((await repo.search('riy')).single.relationship, Relationship.none);
    expect(await repo.search('sam'), isEmpty, reason: 'blocked players are hidden');
  });

  test('a minor accepts requests only from people they have played', () async {
    await expectLater(
      repo.sendRequest('u-riya'),
      throwsA(
        isA<ForbiddenFailure>()
            .having((f) => f.code, 'code', 'NOT_ALLOWED')
            .having((f) => f.details['reason'], 'reason', 'played_with'),
      ),
    );
    final sent = await repo.sendRequest('u-arjun');
    expect(sent.requestId, isNotNull);
    expect(repo.outgoingRequests.values, contains('u-arjun'));
  });

  test('two requests that meet become a friendship', () async {
    final sent = await repo.sendRequest('u-zoya');
    expect(sent.becameFriends, isTrue);
    expect(repo.friendIds, contains('u-zoya'));
    expect((await repo.requests()).incomingFrom('u-zoya'), isNull);
  });

  test('at most 20 requests go out a day', () async {
    repo.sentToday = FakeSocialRepository.dailyLimit;
    await expectLater(
      repo.sendRequest('u-arjun'),
      throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', 'LIMIT_REACHED')),
    );
    await expectLater(
      repo.sendRequest('u-rahul'),
      throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', 'ALREADY_FRIENDS')),
    );
  });

  test('accept, decline and cancel move requests', () async {
    final requests = await repo.requests();
    await repo.acceptRequest(requests.incoming.first.id);
    await repo.declineRequest(requests.incoming.last.id);
    await repo.cancelRequest(requests.outgoing.single.id);
    expect(repo.friendIds, contains('u-zoya'));
    expect((await repo.requests()).isEmpty, isTrue);
    await expectLater(repo.acceptRequest('nope'), throwsA(isA<NotFoundFailure>()));
  });

  test('blocking ends the friendship, drops requests and hides the profile', () async {
    await repo.block('u-rahul');
    expect(repo.friendIds, isNot(contains('u-rahul')));
    expect((await repo.friends()).items.map((f) => f.user.id), isNot(contains('u-rahul')));
    await expectLater(repo.profile('rahul_07'), throwsA(isA<NotFoundFailure>()));
    expect((await repo.activity()).items.map((a) => a.user.id), isNot(contains('u-rahul')));

    await repo.block('u-zoya');
    expect(repo.incomingRequests.values, isNot(contains('u-zoya')));

    await repo.unblock('u-rahul');
    final profile = await repo.profile('rahul_07');
    expect(profile.relationship, Relationship.none);
  });

  test('a minor who isn\'t a friend shows only their card', () async {
    final minor = await repo.profile('riya_s');
    expect(minor.isLimited, isTrue);
    final friend = await repo.profile('rahul_07');
    expect(friend.isLimited, isFalse);
    expect(friend.canChallenge, isTrue);
    expect(friend.h2h, const HeadToHead(wins: 3, losses: 1));
    await expectLater(repo.profile('nobody_here'), throwsA(isA<NotFoundFailure>()));
  });

  test('friends come in pages', () async {
    final small = FakeSocialRepository.seeded();
    final paged = FakeSocialRepository(
      players: [for (final id in small.friendIds) small.player(id)],
      friends: small.friendIds,
      pageSize: 3,
    );
    final first = await paged.friends();
    expect(first.items, hasLength(3));
    final second = await paged.friends(cursor: first.nextCursor);
    expect(second.items, hasLength(1));
    expect(second.nextCursor, isNull);
  });

  test('failures are injectable per call and reports are recorded', () async {
    repo.failures[FakeSocialOp.friends] = const NetworkFailure();
    await expectLater(repo.friends(), throwsA(isA<NetworkFailure>()));
    await repo.report(userId: 'u-sam', reason: ReportReason.harassment, note: 'spam');
    expect(repo.reports.single.reason, ReportReason.harassment);
    expect(repo.calls[FakeSocialOp.friends], 1);
  });

  test('shares follow the server\'s rules and show in the user\'s own feed', () async {
    final repo = FakeSocialRepository(matchResults: {'m-1': sampleWin});

    final win = await repo.share(const MatchShareTarget('m-1'), idempotencyKey: 'a');
    expect(await repo.share(const MatchShareTarget('m-1'), idempotencyKey: 'a'), same(win));
    await expectLater(
      repo.share(const MatchShareTarget('m-1'), idempotencyKey: 'b'),
      throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', 'ALREADY_SHARED')),
    );
    await expectLater(
      repo.share(const MatchShareTarget('m-unknown'), idempotencyKey: 'c'),
      throwsA(isA<NotFoundFailure>()),
    );
    for (var i = 0; i < 3; i++) {
      await repo.share(const ProgressShareTarget(), idempotencyKey: 'p$i');
    }
    await expectLater(
      repo.share(const ProgressShareTarget(), idempotencyKey: 'p3'),
      throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', 'LIMIT_REACHED')),
    );

    final feed = (await repo.activity()).items;
    expect(feed, hasLength(4));
    expect(feed.every((item) => item.user.id == FakeSocialRepository.defaultMe.id), isTrue);
    expect((win.share! as MatchShareData).player.displayName, 'You');
    expect(repo.posted, hasLength(4));
  });
}
