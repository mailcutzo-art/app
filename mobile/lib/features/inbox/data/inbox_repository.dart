import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/app_failure.dart';
import '../../../core/network/paging.dart';
import '../../battle/data/battle_repository.dart' show parseResponse;
import '../../learn/data/learn_repository.dart' show demoDataProvider;
import 'fake_inbox_repository.dart';
import 'inbox_models.dart';

/// The inbox REST contract (`docs/api-play.md`, "Inbox and push").
abstract interface class InboxRepository {
  /// `GET /v1/me/notifications?cursor=`, newest first.
  Future<CursorPage<InboxItem>> notifications({String? cursor});

  /// `GET /v1/me/notifications/unread-count`.
  Future<int> unreadCount();

  /// `POST /v1/me/notifications/read` with `{"ids": [...]}`.
  Future<void> markRead(List<String> ids);

  /// `POST /v1/me/notifications/read` with `{"all": true}`.
  Future<void> markAllRead();
}

class ApiInboxRepository implements InboxRepository {
  ApiInboxRepository(this._api);

  final ApiClient _api;

  @override
  Future<CursorPage<InboxItem>> notifications({String? cursor}) async {
    final data = await _api.get('/v1/me/notifications', query: {'cursor': ?cursor});
    return parseResponse(
      () => CursorPage.fromJson(data, InboxItem.fromJson, what: 'notifications'),
    );
  }

  @override
  Future<int> unreadCount() async {
    final data = await _api.get('/v1/me/notifications/unread-count');
    if (data case {'count': final num count} when count >= 0) return count.toInt();
    debugPrint('Unexpected unread count: $data');
    throw const UnexpectedFailure();
  }

  @override
  Future<void> markRead(List<String> ids) =>
      _api.post('/v1/me/notifications/read', body: {'ids': ids});

  @override
  Future<void> markAllRead() => _api.post('/v1/me/notifications/read', body: {'all': true});
}

/// The inbox in the debug "Demo data" mode.
final demoInboxRepositoryProvider = Provider<FakeInboxRepository>(
  (ref) => FakeInboxRepository.seeded(latency: const Duration(milliseconds: 300)),
);

final inboxRepositoryProvider = Provider<InboxRepository>((ref) {
  // The constant keeps the demo out of release builds entirely.
  if (!kReleaseMode && ref.watch(demoDataProvider)) return ref.watch(demoInboxRepositoryProvider);
  return ApiInboxRepository(ref.watch(apiClientProvider));
});
