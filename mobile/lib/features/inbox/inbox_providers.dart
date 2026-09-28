import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import '../../core/network/paging.dart';
import '../../core/realtime/live_controller.dart';
import '../../core/realtime/live_providers.dart';
import 'data/inbox_models.dart';
import 'data/inbox_repository.dart';

/// The inbox list while its screen is open.
final inboxProvider = AsyncNotifierProvider.autoDispose<InboxNotifier, Paged<InboxItem>>(
  InboxNotifier.new,
  retry: (_, _) => null,
);

class InboxNotifier extends PagedNotifier<InboxItem> {
  @override
  Future<Paged<InboxItem>> build() {
    // Someone else signing in on this phone gets their own inbox.
    ref.watch(currentUserIdProvider);
    return super.build();
  }

  @override
  Future<CursorPage<InboxItem>> fetch(String? cursor) =>
      ref.read(inboxRepositoryProvider).notifications(cursor: cursor);

  /// Marks [item] read on screen at once and on the server in the background. A failed write is
  /// harmless: the item shows unread again on the next load.
  Future<void> markRead(InboxItem item) async {
    if (item.read) return;
    updateItems((items) => [for (final i in items) i.id == item.id ? i.copyWith(read: true) : i]);
    ref.read(unreadCountProvider.notifier).markedRead(1);
    try {
      await ref.read(inboxRepositoryProvider).markRead([item.id]);
    } on AppFailure {
      // The server still counts it; the next poll puts the badge right.
    }
  }

  /// "Mark all read". Rolls back and rethrows when the server refuses, so the screen can say so.
  Future<void> markAllRead() async {
    final before = state.value?.items;
    updateItems((items) => [for (final i in items) i.copyWith(read: true)]);
    final unread = ref.read(unreadCountProvider.notifier)..markedAllRead();
    try {
      await ref.read(inboxRepositoryProvider).markAllRead();
    } on AppFailure {
      if (before != null) updateItems((_) => before);
      unawaited(unread.refresh());
      rethrow;
    }
  }

  /// A `notify` that arrived while the list is open goes on top.
  void addLive(InboxItem item) =>
      updateItems((items) => [item, ...items.where((i) => i.id != item.id)]);
}

/// The unread count behind the bell. While a user is signed in and the app is in the
/// foreground, it asks the server on start, on every resume and every [pollEvery]; `notify`
/// events on the realtime connection update it at once (see [InboxLiveHook]).
final unreadCountProvider = NotifierProvider<UnreadCount, int>(UnreadCount.new);

class UnreadCount extends Notifier<int> {
  static const pollEvery = Duration(seconds: 20);

  String? _user;

  @override
  int build() {
    final user = ref.watch(currentUserIdProvider);
    final onboarded = ref.watch(
      sessionProvider.select(
        (session) => switch (session.value) {
          SignedIn(needsOnboarding: false) => true,
          _ => false,
        },
      ),
    );
    // The same user keeps their count across rebuilds; anyone else starts from zero.
    final known = user == _user ? (stateOrNull ?? 0) : 0;
    _user = user;
    if (user == null || !onboarded) return 0;
    // Watching the foreground flag rebuilds on every resume, which asks again.
    if (!ref.watch(appForegroundProvider)) return known;
    final timer = Timer.periodic(pollEvery, (_) => unawaited(refresh()));
    ref.onDispose(timer.cancel);
    scheduleMicrotask(() => unawaited(refresh()));
    return known;
  }

  /// Asks the server. Failures keep the last count; the next poll tries again.
  Future<void> refresh() async {
    if (_user == null || !ref.mounted) return;
    try {
      final count = await ref.read(inboxRepositoryProvider).unreadCount();
      if (ref.mounted) state = count;
    } on AppFailure {
      // Offline or server trouble: keep what the badge shows.
    }
  }

  /// A live `notify`: the server's count when it sent one, otherwise one more.
  void onNotify(int? unread) => state = unread ?? state + 1;

  void markedRead(int count) => state = math.max(0, state - count);

  void markedAllRead() => state = 0;
}

/// Sends live `notify` events to the badge (and to the list when it's open), and re-asks for
/// the count after every (re)connect, since events may have been missed while away.
class InboxLiveHook implements LiveEventHook {
  InboxLiveHook(this._ref, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Ref _ref;
  final DateTime Function() _now;

  @override
  void onEvent(ServerEvent event) {
    if (event is! NotifyEvent) return;
    _ref.read(unreadCountProvider.notifier).onNotify(event.unread);
    if (_ref.exists(inboxProvider)) {
      _ref.read(inboxProvider.notifier).addLive(InboxItem.fromNotify(event, receivedAt: _now()));
    }
  }

  @override
  void onWelcome(WelcomeEvent welcome) =>
      unawaited(_ref.read(unreadCountProvider.notifier).refresh());
}
