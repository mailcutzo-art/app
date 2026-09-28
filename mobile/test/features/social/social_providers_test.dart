import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/core/storage/prefs.dart';
import 'package:quiz_app/features/learn/data/learn_repository.dart' show DemoDataSetting;
import 'package:quiz_app/features/social/data/fake_social_repository.dart';
import 'package:quiz_app/features/social/data/social_models.dart';
import 'package:quiz_app/features/social/data/social_repository.dart';
import 'package:quiz_app/features/social/social_providers.dart';

import '../../support/fakes.dart';

void main() {
  late FakeSocialRepository repo;
  late ProviderContainer container;

  setUp(() async {
    repo = FakeSocialRepository.seeded();
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => FakeSessionController(SignedIn(fakeUser()))),
        socialRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
  });

  SocialActions actions() => container.read(socialActionsProvider);
  Relationship? override(String id) => container.read(relationshipOverridesProvider)[id];
  UserCard user(String id) => repo.player(id).card;

  // Keeps the lists alive between reads, as the Social tab does.
  Future<void> loadLists() async {
    container
      ..listen(friendsProvider, (_, _) {})
      ..listen(friendRequestsProvider, (_, _) {})
      ..listen(blockedUsersProvider, (_, _) {});
    await container.read(friendsProvider.future);
    await container.read(friendRequestsProvider.future);
    await container.read(blockedUsersProvider.future);
  }

  List<String> friendIds() => [
    for (final f in container.read(friendsProvider).value!.friends) f.user.id,
  ];

  test('friends sort online first, then busy, then offline', () async {
    await loadLists();
    final sorted = container.read(friendsProvider).value!.sorted;
    expect(sorted.map((f) => f.presence), [
      FriendPresence.online,
      FriendPresence.inTournament,
      FriendPresence.inBattle,
      FriendPresence.offline,
    ]);
    expect(sorted.map((f) => f.user.displayName).take(3), ['Rahul', 'Ishaan', 'Meera']);
    expect(container.read(friendsProvider).value!.onlineCount, 3);
  });

  test('a poll refreshes presence and keeps the list when it fails', () async {
    await loadLists();
    repo.setPresence('u-kabir', FriendPresence.online);
    await container.read(friendsProvider.notifier).poll();
    final kabir = container
        .read(friendsProvider)
        .value!
        .friends
        .firstWhere((f) => f.user.id == 'u-kabir');
    expect(kabir.presence, FriendPresence.online);

    repo.failures[FakeSocialOp.friends] = const NetworkFailure();
    await container.read(friendsProvider.notifier).poll();
    expect(container.read(friendsProvider).hasError, isFalse);
    expect(friendIds(), hasLength(4));
  });

  test('more friends load page by page', () async {
    final paged = FakeSocialRepository(
      players: [for (final id in repo.friendIds) repo.player(id)],
      friends: repo.friendIds,
      pageSize: 3,
    );
    container.updateOverrides([
      sessionProvider.overrideWith(() => FakeSessionController(SignedIn(fakeUser()))),
      socialRepositoryProvider.overrideWithValue(paged),
    ]);
    container.listen(friendsProvider, (_, _) {});
    final first = await container.read(friendsProvider.future);
    expect(first.friends, hasLength(3));
    expect(first.hasMore, isTrue);
    await container.read(friendsProvider.notifier).loadMore();
    final all = container.read(friendsProvider).value!;
    expect(all.friends, hasLength(4));
    expect(all.hasMore, isFalse);
  });

  group('add friend', () {
    test('shows as requested right away and lands in outgoing requests', () async {
      await loadLists();
      final pending = actions().addFriend(user('u-arjun'));
      expect(override('u-arjun'), Relationship.requested);
      final sent = await pending;
      expect(sent.becameFriends, isFalse);
      expect(container.read(friendRequestsProvider).value!.outgoingTo('u-arjun'), isNotNull);
    });

    test('rolls back when the server says no', () async {
      await loadLists();
      final pending = actions().addFriend(user('u-riya'));
      expect(override('u-riya'), Relationship.requested);
      await expectLater(pending, throwsA(isA<ForbiddenFailure>()));
      expect(override('u-riya'), isNull);
      expect(container.read(friendRequestsProvider).value!.outgoingTo('u-riya'), isNull);
    });

    test('two requests that meet make friends at once', () async {
      await loadLists();
      final sent = await actions().addFriend(user('u-zoya'));
      expect(sent.becameFriends, isTrue);
      expect(override('u-zoya'), Relationship.friend);
      expect(friendIds(), contains('u-zoya'));
      expect(container.read(friendRequestsProvider).value!.incomingFrom('u-zoya'), isNull);
    });
  });

  test('cancelling a request finds it and removes it', () async {
    await loadLists();
    await actions().cancelRequest(user('u-ananya'));
    expect(override('u-ananya'), Relationship.none);
    expect(container.read(friendRequestsProvider).value!.outgoing, isEmpty);
    expect(repo.outgoingRequests, isEmpty);
  });

  test('cancelling works before the requests list has loaded', () async {
    await actions().cancelRequest(user('u-ananya'));
    expect(repo.outgoingRequests, isEmpty);
  });

  group('accept and decline', () {
    test('accepting adds the friend; a failure puts the request back', () async {
      await loadLists();
      final zoya = container.read(friendRequestsProvider).value!.incomingFrom('u-zoya')!;
      repo.failures[FakeSocialOp.accept] = const ServerFailure();
      final failing = actions().accept(zoya);
      expect(friendIds(), contains('u-zoya'), reason: 'optimistic');
      await expectLater(failing, throwsA(isA<ServerFailure>()));
      expect(friendIds(), isNot(contains('u-zoya')));
      expect(container.read(friendRequestsProvider).value!.incomingFrom('u-zoya'), isNotNull);
      expect(override('u-zoya'), isNull);

      repo.failures.clear();
      await actions().accept(zoya);
      expect(friendIds(), contains('u-zoya'));
      expect(repo.friendIds, contains('u-zoya'));
    });

    test('declining removes the request', () async {
      await loadLists();
      final dev = container.read(friendRequestsProvider).value!.incomingFrom('u-dev')!;
      await actions().decline(dev);
      expect(container.read(friendRequestsProvider).value!.incomingFrom('u-dev'), isNull);
      expect(repo.incomingRequests.values, isNot(contains('u-dev')));
    });
  });

  test('removing a friend rolls back on failure', () async {
    await loadLists();
    repo.failures[FakeSocialOp.removeFriend] = const NetworkFailure();
    final failing = actions().removeFriend(user('u-meera'));
    expect(friendIds(), isNot(contains('u-meera')));
    await expectLater(failing, throwsA(isA<NetworkFailure>()));
    expect(friendIds(), contains('u-meera'));

    repo.failures.clear();
    await actions().removeFriend(user('u-meera'));
    expect(friendIds(), isNot(contains('u-meera')));
    expect(override('u-meera'), Relationship.none);
  });

  test('blocking hides the player everywhere and undoes it all on failure', () async {
    await loadLists();
    repo.failures[FakeSocialOp.block] = const ServerFailure();
    final failing = actions().block(user('u-rahul'));
    expect(friendIds(), isNot(contains('u-rahul')));
    expect(override('u-rahul'), Relationship.blocked);
    expect(container.read(blockedUsersProvider).value!.map((u) => u.id), contains('u-rahul'));
    await expectLater(failing, throwsA(isA<ServerFailure>()));
    expect(friendIds(), contains('u-rahul'));
    expect(override('u-rahul'), isNull);
    expect(container.read(blockedUsersProvider).value!.map((u) => u.id), ['u-sam']);

    repo.failures.clear();
    await actions().block(user('u-zoya'));
    expect(container.read(friendRequestsProvider).value!.incomingFrom('u-zoya'), isNull);
    expect(repo.blockedIds, contains('u-zoya'));
  });

  test('unblocking leaves the blocked list', () async {
    await loadLists();
    await actions().unblock(user('u-sam'));
    expect(container.read(blockedUsersProvider).value, isEmpty);
    expect(override('u-sam'), Relationship.none);
  });

  test('actions don\'t fetch lists that were never shown', () async {
    await actions().block(user('u-kabir'));
    expect(repo.calls[FakeSocialOp.friends], isNull);
    expect(repo.calls[FakeSocialOp.blocks], isNull);
  });

  test('a new user signing in starts with fresh lists and no overrides', () async {
    await loadLists();
    await actions().removeFriend(user('u-meera'));
    expect(override('u-meera'), Relationship.none);
    container.read(sessionProvider.notifier).state = const AsyncData(
      SignedIn(
        Me(id: 'u2', displayName: 'Riya', avatar: Avatar.fallback, onboardingCompleted: true),
      ),
    );
    await container.read(friendsProvider.future);
    expect(container.read(relationshipOverridesProvider), isEmpty);
  });

  test('the demo data switch serves Social from the sample world', () async {
    Future<SocialRepository> read({required bool demo}) async {
      final scoped = ProviderContainer(
        overrides: [
          appEnvProvider.overrideWithValue(testEnv),
          sharedPrefsProvider.overrideWithValue(await testPrefs({DemoDataSetting.prefKey: demo})),
        ],
      );
      addTearDown(scoped.dispose);
      return scoped.read(socialRepositoryProvider);
    }

    expect(await read(demo: true), isA<FakeSocialRepository>());
    expect(await read(demo: false), isA<ApiSocialRepository>());
  });
}
