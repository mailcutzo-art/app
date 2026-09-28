import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'json.dart';

/// One page of a cursor-paged list: `{"items": [...], "next_cursor": "…" | null}`.
@immutable
class CursorPage<T> {
  const CursorPage(this.items, {this.nextCursor});

  /// Reads a page with [item]. A row the app can't read is skipped (and logged) rather than
  /// failing the whole page, so one odd entry never blanks a history screen.
  factory CursorPage.fromJson(Object? json, T Function(Object? json) item, {required String what}) {
    final r = JsonReader(json, what);
    final items = <T>[];
    for (final raw in r.list('items', (value) => value)) {
      try {
        items.add(item(raw));
      } on FormatException catch (e) {
        debugPrint('Skipping an unreadable $what row: $e');
      }
    }
    return CursorPage(List.unmodifiable(items), nextCursor: r.optString('next_cursor'));
  }

  final List<T> items;

  /// Null on the last page.
  final String? nextCursor;
}

/// A cursor-paged list as a screen shows it: the rows so far, and how the next page is going.
@immutable
class Paged<T> {
  const Paged({this.items = const [], this.nextCursor, this.loadingMore = false, this.moreError});

  final List<T> items;
  final String? nextCursor;
  final bool loadingMore;

  /// Why the last "load more" failed; the list shows a retry row.
  final Object? moreError;

  bool get hasMore => nextCursor != null;

  Paged<T> copyWith({
    List<T>? items,
    String? Function()? nextCursor,
    bool? loadingMore,
    Object? Function()? moreError,
  }) => Paged(
    items: items ?? this.items,
    nextCursor: nextCursor == null ? this.nextCursor : nextCursor(),
    loadingMore: loadingMore ?? this.loadingMore,
    moreError: moreError == null ? this.moreError : moreError(),
  );
}

/// Loads the first page on build, then more on request. Subclasses say how to [fetch] a page.
/// The first page's failure is the provider's error; a later page's failure stays on the list
/// ([Paged.moreError]) so the rows already shown stay.
abstract class PagedNotifier<T> extends AsyncNotifier<Paged<T>> {
  /// `GET …?cursor=` for [cursor], or the first page when null.
  Future<CursorPage<T>> fetch(String? cursor);

  @override
  Future<Paged<T>> build() async {
    final page = await fetch(null);
    return Paged(items: page.items, nextCursor: page.nextCursor);
  }

  /// Appends the next page. Does nothing while a page is loading or on the last page.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    state = AsyncData(current.copyWith(loadingMore: true, moreError: () => null));
    try {
      final page = await fetch(current.nextCursor);
      if (!ref.mounted) return;
      final latest = state.value ?? current;
      state = AsyncData(
        latest.copyWith(
          items: [...latest.items, ...page.items],
          nextCursor: () => page.nextCursor,
          loadingMore: false,
        ),
      );
    } on Object catch (error) {
      if (!ref.mounted) return;
      final latest = state.value ?? current;
      state = AsyncData(latest.copyWith(loadingMore: false, moreError: () => error));
    }
  }

  /// [loadMore] on scrolling near the end. After a failure it waits for the retry button, so
  /// scrolling doesn't hammer a failing server.
  Future<void> autoLoadMore() async {
    if (state.value?.moreError != null) return;
    await loadMore();
  }

  /// Reloads from the first page. On failure the rows already shown stay and the error is
  /// rethrown, for pull-to-refresh to report.
  Future<void> refresh() async {
    final page = await fetch(null);
    if (!ref.mounted) return;
    state = AsyncData(Paged(items: page.items, nextCursor: page.nextCursor));
  }

  /// Replaces the rows (e.g. marking inbox items read) without a request.
  @protected
  void updateItems(List<T> Function(List<T> items) change) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(items: List.unmodifiable(change(current.items))));
  }
}

/// Settles [future] without throwing: each section shows its own error.
Future<void> settle(Future<Object?> future) async {
  try {
    await future;
  } on Object {
    // Shown by the section that owns it.
  }
}
