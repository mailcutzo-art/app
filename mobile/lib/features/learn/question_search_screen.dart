import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/shell.dart';
import '../../core/network/app_failure.dart';
import 'learn_providers.dart';
import 'question_search.dart';
import 'widgets/learn_widgets.dart';
import 'widgets/question_widgets.dart';

/// Question search (`/learn/search`): a pill search field, subject chips and
/// the matching questions; a result opens the question with its answer.
class QuestionSearchScreen extends ConsumerWidget {
  const QuestionSearchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = ref.watch(questionSearchProvider);
    final controller = ref.read(questionSearchProvider.notifier);
    final catalog = ref.watch(catalogProvider(ref.watch(learnGoalProvider))).value;
    return Scaffold(
      appBar: AppTopBar(
        title: 'Search questions',
        onBack: () => context.canPop() ? context.pop() : context.go(Routes.learn),
      ),
      body: Column(
        children: [
          Gutter(
            child: AppSearchField(
              hint: 'Search questions or chapters',
              autofocus: true,
              onChanged: controller.setQuery,
            ),
          ),
          if (catalog != null && catalog.subjects.length > 1) ...[
            const SizedBox(height: AppSpacing.sm),
            SubjectFilter(
              subjects: catalog.subjects,
              selected: search.subject,
              onChanged: controller.setSubject,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 3,
            child: search.loading && search.results != null
                ? LinearProgressIndicator(color: context.colors.ink, minHeight: 3)
                : null,
          ),
          Expanded(child: _body(context, ref, search)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, QuestionSearchState search) {
    final catalog = ref.watch(catalogProvider(ref.watch(learnGoalProvider))).value;
    Widget centered(Widget child) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.xl, AppSpacing.gutter, 128),
      child: child,
    );
    if (search.idle) {
      return centered(
        const EmptyState(
          icon: AppIcons.search,
          title: 'Find any question',
          message: 'Type at least 2 letters: a word from the question or a chapter name.',
        ),
      );
    }
    if (search.error case final error?) {
      return centered(
        ErrorState(
          title: 'Couldn\'t search',
          message: error is RateLimitedFailure
              ? 'That\'s a lot of searches. Wait a moment and try again.'
              : failureMessage(error),
          retrying: search.loading,
          onRetry: ref.read(questionSearchProvider.notifier).retry,
        ),
      );
    }
    final results = search.results;
    if (results == null) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.md, AppSpacing.gutter, 0),
        child: QuestionRowsSkeleton(),
      );
    }
    if (results.isEmpty) {
      return centered(
        EmptyState(
          icon: AppIcons.search,
          title: search.loading ? 'Searching…' : 'No questions found',
          message: search.loading ? null : 'Try another word, or check the spelling.',
        ),
      );
    }
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.md, AppSpacing.gutter, 128),
      itemCount: results.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, i) {
        final question = results[i];
        return QuestionRow(
          question: question,
          place: questionPlace(question, catalog),
          onTap: () => unawaited(context.push(Routes.question(question.ref))),
        );
      },
    );
  }
}
