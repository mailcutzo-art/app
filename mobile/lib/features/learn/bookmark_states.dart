import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import 'data/learn_repository.dart';

/// Bookmarks the user has set on the Learn screens in this run, by question
/// ref, so a question unbookmarked on its detail screen is gone from the
/// bookmarks list too without reloading it.
///
/// Writes are optimistic and go out one at a time, so the last tap wins.
final bookmarkStatesProvider = NotifierProvider<BookmarkStates, Map<String, bool>>(
  BookmarkStates.new,
);

class BookmarkStates extends Notifier<Map<String, bool>> {
  Future<void> _writes = Future.value();

  @override
  Map<String, bool> build() {
    // Another user, or demo data switched on, starts from the server again.
    ref
      ..watch(learnRepositoryProvider)
      ..watch(currentUserIdProvider);
    return const {};
  }

  /// The bookmark as last set here, else [fallback] (what the server said).
  bool isBookmarked(String questionRef, {required bool fallback}) => state[questionRef] ?? fallback;

  /// Sets the bookmark at once, then saves it. On failure it is put back
  /// (unless it has been changed again since) and the failure returned.
  Future<AppFailure?> set(String questionRef, {required bool bookmarked}) async {
    _put(questionRef, bookmarked);
    final repository = ref.read(learnRepositoryProvider);
    final write = _writes.then((_) => repository.setBookmark(questionRef, bookmarked: bookmarked));
    _writes = write.then((_) {}, onError: (Object _) {});
    try {
      await write;
      return null;
    } on AppFailure catch (failure) {
      if (ref.mounted && state[questionRef] == bookmarked) _put(questionRef, !bookmarked);
      return failure;
    }
  }

  /// Records a bookmark written elsewhere (the practice screen).
  void remember(String questionRef, {required bool bookmarked}) => _put(questionRef, bookmarked);

  void _put(String questionRef, bool bookmarked) => state = {...state, questionRef: bookmarked};
}

/// The toast for a bookmark that couldn't be saved.
String bookmarkFailureMessage(AppFailure failure) => switch (failure) {
  ConflictFailure(code: 'BOOKMARK_LIMIT') => 'You\'ve reached the bookmark limit.',
  NetworkFailure() => 'You\'re offline, so the bookmark wasn\'t saved.',
  _ => 'Couldn\'t save the bookmark. Please try again.',
};
