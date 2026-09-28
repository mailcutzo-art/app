import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/network/app_failure.dart';
import '../../core/utils/ids.dart';
import '../practice/data/practice_models.dart';
import '../practice/start_practice.dart';
import 'bookmark_states.dart';
import 'data/learn_models.dart';
import 'data/learn_repository.dart';
import 'data/question_models.dart';
import 'learn_providers.dart';
import 'widgets/learn_widgets.dart';
import 'widgets/question_widgets.dart';

/// The bookmarks loaded so far, and how loading the next page is going.
@immutable
class BookmarksState {
  const BookmarksState({
    required this.items,
    this.nextCursor,
    this.loadingMore = false,
    this.moreError,
  });

  /// Newest first.
  final List<Bookmark> items;

  /// Null once every page is loaded.
  final String? nextCursor;
  final bool loadingMore;
  final AppFailure? moreError;

  bool get hasMore => nextCursor != null;
}

/// `GET /v1/me/bookmarks`, one subject filter (null: all) at a time, a page
/// (the server's default of 20) at a time.
final bookmarksListProvider = AsyncNotifierProvider.autoDispose
    .family<BookmarksList, BookmarksState, String?>(
      BookmarksList.new,
      // The screen offers a retry.
      retry: (_, _) => null,
    );

class BookmarksList extends AsyncNotifier<BookmarksState> {
  BookmarksList(this.subject);

  final String? subject;

  @override
  Future<BookmarksState> build() async {
    final page = await ref.watch(learnRepositoryProvider).listBookmarks(subject: subject);
    return BookmarksState(items: page.items, nextCursor: page.nextCursor);
  }

  /// Loads the next page, once at a time; a failure is kept for the footer.
  Future<void> loadMore() async {
    final s = state.value;
    if (s == null || !s.hasMore || s.loadingMore) return;
    state = AsyncData(BookmarksState(items: s.items, nextCursor: s.nextCursor, loadingMore: true));
    try {
      final page = await ref
          .read(learnRepositoryProvider)
          .listBookmarks(subject: subject, cursor: s.nextCursor);
      if (!ref.mounted) return;
      final known = {for (final item in s.items) item.ref};
      state = AsyncData(
        BookmarksState(
          items: [
            ...s.items,
            for (final item in page.items)
              if (!known.contains(item.ref)) item,
          ],
          nextCursor: page.nextCursor,
        ),
      );
    } on AppFailure catch (failure) {
      if (!ref.mounted) return;
      state = AsyncData(
        BookmarksState(items: s.items, nextCursor: s.nextCursor, moreError: failure),
      );
    }
  }
}

/// Saved questions (`/learn/bookmarks`): filter by subject, open one, remove
/// one, or practise them as a set.
class BookmarksScreen extends ConsumerStatefulWidget {
  const BookmarksScreen({super.key});

  @override
  ConsumerState<BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends ConsumerState<BookmarksScreen> {
  String? _subject;
  bool _starting = false;

  Future<void> _practise() async {
    setState(() => _starting = true);
    try {
      final session = await ref
          .read(practiceStarterProvider)
          .start(
            SessionSettings(mode: PracticeMode.bookmarks, subject: _subject, count: 20),
            idempotencyKey: randomHexId(),
          );
      if (mounted) unawaited(context.push(Routes.practiceSession(session.sessionId)));
    } on AppFailure catch (failure) {
      if (!mounted) return;
      showAppToast(
        context,
        practiceStartError(failure, noQuestions: 'These bookmarks can\'t be practised right now.'),
        icon: AppIcons.info,
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _remove(Bookmark bookmark) async {
    final failure = await ref
        .read(bookmarkStatesProvider.notifier)
        .set(bookmark.ref, bookmarked: false);
    if (!mounted) return;
    showAppToast(
      context,
      failure == null ? 'Removed from bookmarks' : bookmarkFailureMessage(failure),
      icon: failure == null ? AppIcons.bookmark : AppIcons.alert,
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = bookmarksListProvider(_subject);
    final async = ref.watch(provider);
    final catalog = ref.watch(catalogProvider(ref.watch(learnGoalProvider))).value;
    final states = ref.watch(bookmarkStatesProvider);
    final visible = [
      for (final item in async.value?.items ?? const <Bookmark>[])
        if (states[item.ref] ?? true) item,
    ];
    final subjectLabel = _subject == null ? null : subjectName(catalog, _subject!);

    final Widget body = switch (async) {
      AsyncValue(value: final s?) when visible.isEmpty && !s.hasMore => _Centered(
        child: EmptyState(
          icon: AppIcons.bookmark,
          title: subjectLabel == null ? 'No bookmarks yet' : 'No $subjectLabel bookmarks',
          message: 'Tap the bookmark on any question to save it here.',
        ),
      ),
      AsyncValue(value: final s?) => _List(
        state: s,
        visible: visible,
        catalog: catalog,
        starting: _starting,
        onPractise: _practise,
        onRemove: _remove,
        onLoadMore: () => ref.read(provider.notifier).loadMore(),
      ),
      AsyncValue(:final error?) => _Centered(
        child: ErrorState(
          title: 'Couldn\'t load your bookmarks',
          message: failureMessage(error),
          retrying: async.isLoading,
          onRetry: () => ref.invalidate(provider),
        ),
      ),
      _ => const Padding(
        padding: EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.md, AppSpacing.gutter, 0),
        child: QuestionRowsSkeleton(),
      ),
    };

    return Scaffold(
      appBar: AppTopBar(
        title: 'Bookmarks',
        onBack: () => context.canPop() ? context.pop() : context.go(Routes.learn),
      ),
      body: RefreshIndicator(
        color: context.colors.ink,
        backgroundColor: context.colors.surface,
        onRefresh: () async {
          ref.invalidate(provider);
          try {
            await ref.read(provider.future);
          } on Object {
            // The screen shows the error.
          }
        },
        child: Column(
          children: [
            if (catalog != null && catalog.subjects.length > 1)
              SubjectFilter(
                subjects: catalog.subjects,
                selected: _subject,
                onChanged: (subject) => setState(() => _subject = subject),
              ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xl, AppSpacing.gutter, 128),
    children: [child],
  );
}

class _List extends StatelessWidget {
  const _List({
    required this.state,
    required this.visible,
    required this.catalog,
    required this.starting,
    required this.onPractise,
    required this.onRemove,
    required this.onLoadMore,
  });

  final BookmarksState state;
  final List<Bookmark> visible;
  final Catalog? catalog;
  final bool starting;
  final VoidCallback onPractise;
  final ValueChanged<Bookmark> onRemove;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    // The practise button, the rows, then a footer while more pages exist.
    final count = 1 + visible.length + (state.hasMore ? 1 : 0);
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.sm, AppSpacing.gutter, 128),
      itemCount: count,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            child: AppButton(
              label: 'Practise these',
              leadingIcon: AppIcons.quiz,
              loading: starting,
              onPressed: visible.isEmpty ? null : onPractise,
            ),
          );
        }
        final index = i - 1;
        if (index == visible.length) return _Footer(state: state, onLoadMore: onLoadMore);
        final bookmark = visible[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: QuestionRow(
            question: bookmark.question,
            place: questionPlace(bookmark.question, catalog),
            onTap: () => unawaited(context.push(Routes.question(bookmark.ref))),
            trailing: AppIconButton(
              icon: AppIcons.bookmark,
              semanticLabel: 'Remove bookmark',
              variant: AppIconButtonVariant.ink,
              size: AppSizes.iconButtonSmall,
              onPressed: () => onRemove(bookmark),
            ),
          ),
        );
      },
    );
  }
}

/// The last row while more pages exist: it asks for the next page as soon
/// as it is built (scrolled into view), and offers a retry if that failed.
class _Footer extends StatefulWidget {
  const _Footer({required this.state, required this.onLoadMore});

  final BookmarksState state;
  final VoidCallback onLoadMore;

  @override
  State<_Footer> createState() => _FooterState();
}

class _FooterState extends State<_Footer> {
  @override
  void initState() {
    super.initState();
    _request();
  }

  @override
  void didUpdateWidget(_Footer old) {
    super.didUpdateWidget(old);
    if (old.state.nextCursor != widget.state.nextCursor) _request();
  }

  void _request() {
    final s = widget.state;
    if (s.loadingMore || s.moreError != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onLoadMore();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.state.moreError case final error?) {
      return ErrorState(
        compact: true,
        title: 'Couldn\'t load more',
        message: failureMessage(error),
        onRetry: widget.onLoadMore,
      );
    }
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: context.colors.ink),
        ),
      ),
    );
  }
}
