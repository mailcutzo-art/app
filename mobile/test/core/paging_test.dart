import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/core/network/json.dart';
import 'package:quiz_app/core/network/paging.dart';

String _name(Object? json) => JsonReader(json, 'row').string('name');

/// Pages of three rows out of [total]; [failAt] makes that cursor fail once.
class _Numbers extends PagedNotifier<int> {
  static int total = 7;
  static String? failAt;
  static final List<String?> calls = [];

  @override
  Future<CursorPage<int>> fetch(String? cursor) async {
    calls.add(cursor);
    if (cursor != null && cursor == failAt) {
      failAt = null;
      throw const NetworkFailure();
    }
    final start = int.parse(cursor ?? '0');
    final end = (start + 3).clamp(0, total);
    return CursorPage([
      for (var i = start; i < end; i++) i,
    ], nextCursor: end < total ? '$end' : null);
  }
}

final _numbers = AsyncNotifierProvider<_Numbers, Paged<int>>(_Numbers.new, retry: (_, _) => null);

void main() {
  group('CursorPage.fromJson', () {
    test('reads items and the next cursor', () {
      final page = CursorPage.fromJson(
        const {
          'items': [
            {'name': 'a'},
            {'name': 'b'},
          ],
          'next_cursor': 'c2',
        },
        _name,
        what: 'rows',
      );
      expect(page.items, ['a', 'b']);
      expect(page.nextCursor, 'c2');
    });

    test('the last page has no cursor', () {
      final page = CursorPage.fromJson(const {'items': <Object?>[]}, _name, what: 'rows');
      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
    });

    test('an unreadable row is skipped, not the whole page', () {
      final page = CursorPage.fromJson(
        const {
          'items': [
            {'name': 'a'},
            {'name': 3},
            'junk',
            {'name': 'd'},
          ],
        },
        _name,
        what: 'rows',
      );
      expect(page.items, ['a', 'd']);
    });

    test('a payload without items is a format error', () {
      expect(
        () => CursorPage.fromJson(const {'rows': <Object?>[]}, _name, what: 'rows'),
        throwsFormatException,
      );
    });
  });

  group('PagedNotifier', () {
    late ProviderContainer container;

    setUp(() {
      _Numbers.total = 7;
      _Numbers.failAt = null;
      _Numbers.calls.clear();
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test('loads the first page, then appends pages until the last', () async {
      final first = await container.read(_numbers.future);
      expect(first.items, [0, 1, 2]);
      expect(first.hasMore, isTrue);

      final notifier = container.read(_numbers.notifier);
      await notifier.loadMore();
      await notifier.loadMore();
      final all = container.read(_numbers).value!;
      expect(all.items, [0, 1, 2, 3, 4, 5, 6]);
      expect(all.hasMore, isFalse);

      await notifier.loadMore();
      expect(_Numbers.calls, [null, '3', '6'], reason: 'nothing asked past the last page');
    });

    test('a failed next page keeps the rows; retry continues from the same cursor', () async {
      await container.read(_numbers.future);
      _Numbers.failAt = '3';
      final notifier = container.read(_numbers.notifier);

      await notifier.loadMore();
      var state = container.read(_numbers).value!;
      expect(state.items, [0, 1, 2]);
      expect(state.moreError, isA<NetworkFailure>());

      await notifier.autoLoadMore();
      expect(_Numbers.calls, [null, '3'], reason: 'scrolling waits for the retry button');

      await notifier.loadMore();
      state = container.read(_numbers).value!;
      expect(state.items, [0, 1, 2, 3, 4, 5]);
      expect(state.moreError, isNull);
    });

    test('refresh starts again from the first page', () async {
      await container.read(_numbers.future);
      final notifier = container.read(_numbers.notifier);
      await notifier.loadMore();
      _Numbers.total = 2;

      await notifier.refresh();
      expect(container.read(_numbers).value!.items, [0, 1]);
    });
  });
}
