import '../../../core/network/app_failure.dart';
import '../../../core/network/paging.dart';
import 'inbox_models.dart';
import 'inbox_repository.dart';

/// Calls of [FakeInboxRepository] that tests can make fail.
enum FakeInboxOp { list, unreadCount, markRead }

/// In-memory inbox for tests and the debug "Demo data" mode. Pages by position, newest first,
/// and keeps the unread count in step with reads, as the server does.
class FakeInboxRepository implements InboxRepository {
  FakeInboxRepository({
    List<InboxItem> items = const [],
    this.pageSize = 20,
    this.latency = Duration.zero,
  }) : _items = [...items];

  /// A few items of each group, the newest unread.
  factory FakeInboxRepository.seeded({Duration latency = Duration.zero, DateTime? now}) =>
      FakeInboxRepository(items: sampleInbox(now ?? DateTime.now()), latency: latency);

  final List<InboxItem> _items;
  final int pageSize;

  /// Delay before every response, to see loading states.
  Duration latency;

  /// Calls that fail until removed from the map.
  final Map<FakeInboxOp, AppFailure> failures = {};

  /// Cursors asked for by `notifications`, in order (null for the first page).
  final List<String?> listCalls = [];

  /// Ids passed to `markRead`, per call.
  final List<List<String>> readCalls = [];

  int markAllCalls = 0;
  int unreadCalls = 0;

  List<InboxItem> get items => List.unmodifiable(_items);

  /// A new item arriving, newest first (what the server does before a `notify`).
  void add(InboxItem item) => _items.insert(0, item);

  @override
  Future<CursorPage<InboxItem>> notifications({String? cursor}) async {
    listCalls.add(cursor);
    await _wait(FakeInboxOp.list);
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + pageSize).clamp(0, _items.length);
    return CursorPage(
      List.unmodifiable(_items.sublist(start, end)),
      nextCursor: end < _items.length ? '$end' : null,
    );
  }

  @override
  Future<int> unreadCount() async {
    unreadCalls++;
    await _wait(FakeInboxOp.unreadCount);
    return _items.where((item) => !item.read).length;
  }

  @override
  Future<void> markRead(List<String> ids) async {
    readCalls.add(ids);
    await _wait(FakeInboxOp.markRead);
    for (var i = 0; i < _items.length; i++) {
      if (ids.contains(_items[i].id)) _items[i] = _items[i].copyWith(read: true);
    }
  }

  @override
  Future<void> markAllRead() async {
    markAllCalls++;
    await _wait(FakeInboxOp.markRead);
    for (var i = 0; i < _items.length; i++) {
      _items[i] = _items[i].copyWith(read: true);
    }
  }

  Future<void> _wait(FakeInboxOp op) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failures[op] case final failure?) throw failure;
  }
}

/// Sample inbox items relative to [now].
List<InboxItem> sampleInbox(DateTime now) => [
  InboxItem(
    id: 'n-invite',
    kind: 'invite',
    title: 'Riya challenged you to a Physics duel',
    body: 'Tap to open the Battle tab.',
    action: const AppAction(route: '/battle', params: {'subject': 'physics'}),
    createdAt: now.subtract(const Duration(minutes: 4)),
  ),
  InboxItem(
    id: 'n-refund',
    kind: 'refund',
    title: 'Refund: match cancelled',
    body: '5 coins are back in your wallet.',
    action: const AppAction(route: '/wallet'),
    createdAt: now.subtract(const Duration(hours: 2)),
  ),
  InboxItem(
    id: 'n-level',
    kind: 'level_up',
    title: 'You reached level 5',
    body: 'Keep playing to unlock more.',
    action: const AppAction(route: '/profile'),
    createdAt: now.subtract(const Duration(days: 1, hours: 1)),
    read: true,
  ),
  InboxItem(
    id: 'n-mission',
    kind: 'mission_done',
    title: 'Daily missions done: +100 XP',
    action: const AppAction(route: '/home'),
    createdAt: now.subtract(const Duration(days: 3)),
    read: true,
  ),
];
