import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:realtime_client/realtime_client.dart' hide AnswerOption;

import '../../../app/router.dart';
import '../../../core/auth/session.dart';
import '../../../core/network/app_failure.dart';
import '../../../core/realtime/live_providers.dart';
import '../../learn/data/learn_repository.dart';
import '../../learn/widgets/learn_widgets.dart' show failureMessage;
import '../data/battle_repository.dart';
import '../data/match_models.dart';
import 'match_widgets.dart';

/// `GET /v1/matches/{id}/review`, kept in memory while the screen is open.
final matchReviewProvider = FutureProvider.autoDispose.family<MatchReview, String>(
  (ref, matchId) => ref.watch(matchRepositoryProvider).review(matchId),
  retry: (_, _) => null,
);

/// "6.2 s".
String seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)} s';

/// Every question of a finished match: both picks, times, the correct answer, the explanation,
/// and a bookmark (`/battle/match/:id/review`).
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key, required this.matchId});

  final String matchId;

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  /// Bookmarks as the user last set them, by question ref.
  final Map<String, bool> _bookmarks = {};
  Future<void> _writes = Future.value();

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.battleMatch(widget.matchId));
    }
  }

  void _toggle(ReviewQuestion question) {
    final next = !(_bookmarks[question.ref] ?? question.bookmarked);
    setState(() => _bookmarks[question.ref] = next);
    // One write at a time, so the last tap wins.
    _writes = _writes.then((_) async {
      try {
        await ref.read(learnRepositoryProvider).setBookmark(question.ref, bookmarked: next);
      } on AppFailure catch (failure) {
        if (!mounted) return;
        setState(() => _bookmarks[question.ref] = !next);
        showAppToast(
          context,
          failure is NetworkFailure
              ? 'You\'re offline, so the bookmark wasn\'t saved.'
              : 'Couldn\'t save the bookmark. Please try again.',
          icon: AppIcons.alert,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final review = ref.watch(matchReviewProvider(widget.matchId));
    final me = ref.watch(currentUserIdProvider) ?? '';
    final match = ref.read(liveControllerProvider)?.match(widget.matchId)?.view;
    final List<Widget> children = switch (review) {
      AsyncValue(:final value?) when value.questions.isEmpty => [
        const EmptyState(
          icon: AppIcons.checklist,
          title: 'Nothing to review',
          message: 'This game ended before any questions were played.',
        ),
      ],
      AsyncValue(:final value?) => [
        for (final question in value.questions)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            child: _ReviewCard(
              question: question,
              total: value.questions.length,
              me: me,
              opponentName: match?.opponentName ?? 'Opponent',
              opponentAvatar: avatarOf(match?.opponentCard),
              bookmarked: _bookmarks[question.ref] ?? question.bookmarked,
              onBookmark: () => _toggle(question),
            ),
          ),
      ],
      AsyncValue(:final error?) => [
        ErrorState(
          title: 'Couldn\'t load the review',
          message: failureMessage(error),
          retrying: review.isLoading,
          onRetry: () => ref.invalidate(matchReviewProvider(widget.matchId)),
        ),
      ],
      _ => const [
        Shimmer(
          child: Column(
            children: [
              SkeletonBox(height: 320, radius: AppRadii.xxl),
              SizedBox(height: AppSpacing.lg),
              SkeletonBox(height: 320, radius: AppRadii.xxl),
            ],
          ),
        ),
      ],
    };
    return Scaffold(
      appBar: AppTopBar(title: 'Review answers', onBack: _back),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          AppSpacing.xxl,
        ),
        children: children,
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    required this.question,
    required this.total,
    required this.me,
    required this.opponentName,
    required this.opponentAvatar,
    required this.bookmarked,
    required this.onBookmark,
  });

  final ReviewQuestion question;
  final int total;
  final String me;
  final String opponentName;
  final AvatarData opponentAvatar;
  final bool bookmarked;
  final VoidCallback onBookmark;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final mine = question.players[me];
    final theirs = question.players.entries.where((e) => e.key != me).firstOrNull?.value;
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              OverlineBadge(label: 'Question ${question.q} / $total', solid: true),
              const SizedBox(width: AppSpacing.sm),
              if (question.topic ?? question.chapter case final tag?)
                Flexible(
                  child: OverlineBadge(label: tag, tone: PastelTone.sky),
                ),
              const Spacer(),
              AppIconButton(
                icon: AppIcons.bookmark,
                semanticLabel: bookmarked ? 'Remove bookmark' : 'Bookmark question',
                variant: bookmarked ? AppIconButtonVariant.ink : AppIconButtonVariant.surface,
                size: AppSizes.iconButtonSmall,
                motion: IconMotions.bookmark,
                onPressed: onBookmark,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          QuizText(question.stem, style: text.titleMedium.copyWith(height: 1.4)),
          const SizedBox(height: AppSpacing.lg),
          for (final (i, option) in question.options.indexed) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            AnswerOption(
              index: i,
              text: option.text,
              state: option.id == question.correct
                  ? AnswerOptionState.correct
                  : (option.id == mine?.opt ? AnswerOptionState.wrong : AnswerOptionState.dimmed),
              opponent: theirs?.opt == option.id ? opponentAvatar : null,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              InfoChip(label: _line('You', mine), background: colors.surfaceMuted),
              if (theirs != null)
                InfoChip(label: _line(opponentName, theirs), background: colors.surfaceMuted),
            ],
          ),
          if (question.explanation.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: QuizText(question.explanation, style: text.bodyMedium),
            ),
          ],
        ],
      ),
    );
  }

  /// "You · 6.2 s · +132", "Riya · no answer".
  static String _line(String who, PlayerReveal? reveal) {
    if (reveal == null || reveal.opt == null) return '$who · no answer';
    final time = reveal.timeMs == null ? null : seconds(reveal.timeMs!);
    return [who, ?time, if (reveal.correct) '+${reveal.pts}' else 'wrong'].join(' · ');
  }
}
