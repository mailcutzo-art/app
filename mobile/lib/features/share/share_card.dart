import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'share_models.dart';

/// The share image's size in logical pixels; captured at [ShareCard.pixelRatio] it is
/// 1080 × 1350, the 4:5 portrait that social apps show uncropped.
const shareCardSize = Size(360, 450);

/// A battle result or progress card, drawn with the design system.
///
/// [ShareCard] is the full card that becomes the shared image (and the preview in the share
/// sheet); [ShareCard.compact] is the small version the friends' feed shows. Neither shows
/// anything personal beyond the display name and handle.
class ShareCard extends StatelessWidget {
  const ShareCard({super.key, required this.data}) : compact = false;

  const ShareCard.compact({super.key, required this.data}) : compact = true;

  /// Captures at 3× the logical size: 1080 × 1350.
  static const pixelRatio = 3.0;

  final ShareCardData data;
  final bool compact;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: data.semanticLabel,
    excludeSemantics: true,
    child: switch ((data, compact)) {
      (final MatchShareData match, false) => _FullCard(
        tone: _outcomeTone(match.outcome),
        overline: 'Battle result',
        player: match.player,
        child: _MatchBody(data: match),
      ),
      (final ProgressShareData progress, false) => _FullCard(
        tone: PastelTone.lavender,
        overline: 'My progress',
        player: progress.player,
        child: _ProgressBody(data: progress),
      ),
      (final MatchShareData match, true) => _CompactMatch(data: match),
      (final ProgressShareData progress, true) => _CompactProgress(data: progress),
    },
  );
}

PastelTone _outcomeTone(ShareOutcome outcome) => switch (outcome) {
  ShareOutcome.win => PastelTone.mint,
  ShareOutcome.draw => PastelTone.lemon,
  ShareOutcome.loss => PastelTone.sky,
};

HugeIconData _outcomeIcon(ShareOutcome outcome) => switch (outcome) {
  ShareOutcome.win => AppIcons.crown,
  ShareOutcome.draw => AppIcons.thumbsUp,
  ShareOutcome.loss => AppIcons.target,
};

List<ResultDot> _dots(List<ShareAnswer> answers) => [
  for (final answer in answers)
    ResultDot(
      outcome: switch (answer) {
        ShareAnswer.correct => DotOutcome.right,
        ShareAnswer.wrong => DotOutcome.wrong,
        ShareAnswer.skipped => DotOutcome.missed,
      },
    ),
];

// ---------------------------------------------------------------- full size

class _FullCard extends StatelessWidget {
  const _FullCard({
    required this.tone,
    required this.overline,
    required this.player,
    required this.child,
  });

  final PastelTone tone;
  final String overline;
  final SharePlayer player;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final pair = colors.pastel(tone);
    return SizedBox.fromSize(
      size: shareCardSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [pair.container, colors.paper],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const _BrandMark(),
                  const Spacer(),
                  OverlineBadge(label: overline, tone: tone, solid: true),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Expanded(child: child),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  AppAvatar(data: player.avatar.toData(), size: 36),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          player.displayName,
                          style: text.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (player.at case final at?) Text(at, style: text.caption, maxLines: 1),
                      ],
                    ),
                  ),
                  Text(
                    'Live quiz battles\nfor NEET & JEE',
                    textAlign: TextAlign.end,
                    style: text.caption.copyWith(color: colors.inkMuted, height: 1.25),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The app's mark and name.
class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.accent,
            borderRadius: BorderRadius.circular(AppRadii.xs),
          ),
          child: HugeIcon(AppIcons.arena, size: 18, color: colors.onAccent),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(appName, style: context.text.titleMedium.copyWith(fontWeight: FontWeight.w800)),
      ],
    );
  }
}

class _MatchBody extends StatelessWidget {
  const _MatchBody({required this.data});

  final MatchShareData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final pair = colors.pastel(_outcomeTone(data.outcome));
    final white = colors.isDark ? colors.surface : Colors.white;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: white, shape: BoxShape.circle),
              child: HugeIcon(_outcomeIcon(data.outcome), size: 26, color: pair.onContainer),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(data.outcome.title, style: text.headlineLarge),
                  Text(
                    [data.subject, ?data.chapter].join(' · '),
                    style: text.labelMedium.copyWith(color: pair.onContainer),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(color: white, borderRadius: BorderRadius.circular(AppRadii.xl)),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _Side(
                      avatar: data.player.avatar.toData(),
                      name: data.player.displayName,
                      points: data.score,
                      alignEnd: false,
                    ),
                  ),
                  Text('–', style: text.numericLarge.copyWith(color: colors.inkMuted)),
                  Expanded(
                    child: _Side(
                      avatar:
                          data.opponentAvatar ??
                          const AvatarData(tone: PastelTone.neutral, symbol: AppIcons.user),
                      name: data.opponentName,
                      points: data.opponentScore,
                      alignEnd: true,
                    ),
                  ),
                ],
              ),
              if (data.answers.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                ResultDots(dots: _dots(data.answers), size: data.answers.length > 10 ? 18 : 22),
              ],
            ],
          ),
        ),
        const Spacer(),
        _RewardChips(data: data),
      ],
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({
    required this.avatar,
    required this.name,
    required this.points,
    required this.alignEnd,
  });

  final AvatarData avatar;
  final String name;
  final int points;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final info = Flexible(
      child: Column(
        crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(name, style: text.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(formatCount(points), style: text.numericLarge),
        ],
      ),
    );
    final children = [
      AppAvatar(data: avatar, size: 34),
      const SizedBox(width: AppSpacing.sm),
      info,
    ];
    return Row(
      mainAxisAlignment: alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: alignEnd ? children.reversed.toList() : children,
    );
  }
}

class _RewardChips extends StatelessWidget {
  const _RewardChips({required this.data, this.small = false, this.showCorrect = true});

  final MatchShareData data;
  final bool small;
  final bool showCorrect;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final chips = [
      if (showCorrect && data.answers.isNotEmpty)
        (AppIcons.checkCircle, '${data.correct}/${data.answers.length} correct', colors.mint),
      if (data.ratingChange case final change?)
        (AppIcons.chart, 'Rating ${signed(change)}', colors.sky),
      if (data.coins case final coins? when coins != 0)
        (AppIcons.coins, '${signed(coins)} coins', colors.lemon),
      if (data.xp case final xp? when xp != 0) (AppIcons.star, '${signed(xp)} XP', colors.lavender),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: small ? AppSpacing.xs : AppSpacing.sm,
      runSpacing: small ? AppSpacing.xs : AppSpacing.sm,
      children: [
        for (final (icon, label, pair) in chips)
          _Pill(icon: icon, label: label, pair: pair, small: small),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, required this.pair, this.small = false});

  final HugeIconData icon;
  final String label;
  final PastelPair pair;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final style = (small ? context.text.caption : context.text.labelMedium).copyWith(
      color: pair.onContainer,
      fontWeight: FontWeight.w700,
    );
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? AppSpacing.sm : AppSpacing.md,
        vertical: small ? AppSpacing.xxs : AppSpacing.xs + 2,
      ),
      decoration: BoxDecoration(color: pair.container, borderRadius: AppRadii.pillAll),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HugeIcon(icon, size: small ? 12 : 16, color: pair.onContainer),
          SizedBox(width: small ? AppSpacing.xxs : AppSpacing.xs),
          Text(label, style: style),
        ],
      ),
    );
  }
}

class _ProgressBody extends StatelessWidget {
  const _ProgressBody({required this.data});

  final ProgressShareData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final white = colors.isDark ? colors.surface : Colors.white;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Level ${data.level}', style: text.display.copyWith(fontSize: 44)),
        const SizedBox(height: AppSpacing.sm),
        _Bar(value: data.levelProgress, color: colors.lavender.onContainer, height: 10),
        const SizedBox(height: AppSpacing.xs),
        Text(
          data.xpForLevel > 0
              ? '${formatCount(data.xpIntoLevel)} / ${formatCount(data.xpForLevel)} XP to level ${data.level + 1}'
              : 'Top level reached',
          style: text.caption,
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                icon: AppIcons.target,
                label: 'Accuracy',
                value: data.accuracyLabel,
                pair: colors.mint,
                background: white,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _StatTile(
                icon: AppIcons.quiz,
                label: 'Answered',
                value: formatCount(data.answered),
                pair: colors.sky,
                background: white,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                icon: AppIcons.fire,
                label: 'Streak',
                value: '${data.currentStreak} ${data.currentStreak == 1 ? 'day' : 'days'}',
                pair: colors.peach,
                background: white,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _StatTile(
                icon: AppIcons.medal,
                label: 'Best streak',
                value: '${data.bestStreak} ${data.bestStreak == 1 ? 'day' : 'days'}',
                pair: colors.lemon,
                background: white,
              ),
            ),
          ],
        ),
        const Spacer(),
        if (data.ratings.isNotEmpty)
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final rating in data.ratings.take(3))
                _Pill(
                  icon: AppIcons.chart,
                  label: '${rating.label} ${rating.rating}',
                  pair: colors.sky,
                ),
            ],
          ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.pair,
    required this.background,
  });

  final HugeIconData icon;
  final String label;
  final String value;
  final PastelPair pair;
  final Color background;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
            child: HugeIcon(icon, size: 16, color: pair.onContainer),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: text.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(value, style: text.numericMedium, maxLines: 1),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A plain progress bar (no animation, so an off-screen capture draws it at its value).
class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.color, this.height = 8});

  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: AppRadii.pillAll,
    child: SizedBox(
      height: height,
      child: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: context.colors.surfaceSunken)),
          FractionallySizedBox(
            widthFactor: value.clamp(0, 1).toDouble(),
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, borderRadius: AppRadii.pillAll),
            ),
          ),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------- compact (the feed)

class _CompactFrame extends StatelessWidget {
  const _CompactFrame({required this.tone, required this.child});

  final PastelTone tone;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: BoxDecoration(
      color: context.colors.pastel(tone).container,
      borderRadius: BorderRadius.circular(AppRadii.lg),
    ),
    child: child,
  );
}

class _CompactMatch extends StatelessWidget {
  const _CompactMatch({required this.data});

  final MatchShareData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final pair = colors.pastel(_outcomeTone(data.outcome));
    return _CompactFrame(
      tone: _outcomeTone(data.outcome),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HugeIcon(_outcomeIcon(data.outcome), size: 18, color: pair.onContainer),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  '${data.outcome.title} · ${[data.subject, ?data.chapter].join(' · ')}',
                  style: text.labelMedium.copyWith(color: pair.onContainer),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${formatCount(data.score)} – ${formatCount(data.opponentScore)} vs ${data.opponentName}',
            style: text.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (data.answers.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: ResultDots(dots: _dots(data.answers), size: 14),
            ),
          ],
          if (data.ratingChange != null || data.coins != null || data.xp != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _RewardChips(data: data, small: true, showCorrect: false),
          ],
        ],
      ),
    );
  }
}

class _CompactProgress extends StatelessWidget {
  const _CompactProgress({required this.data});

  final ProgressShareData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final pair = colors.lavender;
    return _CompactFrame(
      tone: PastelTone.lavender,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HugeIcon(AppIcons.star, size: 18, color: pair.onContainer),
              const SizedBox(width: AppSpacing.xs),
              Text('Level ${data.level}', style: text.titleMedium),
              const Spacer(),
              if (data.ratings.firstOrNull case final rating?)
                Text('${rating.label} ${rating.rating}', style: text.labelMedium),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _Bar(value: data.levelProgress, color: pair.onContainer, height: 6),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              _Pill(
                icon: AppIcons.target,
                label: '${data.accuracyLabel} accuracy',
                pair: colors.mint,
                small: true,
              ),
              _Pill(
                icon: AppIcons.quiz,
                label: '${formatCount(data.answered)} answered',
                pair: colors.sky,
                small: true,
              ),
              _Pill(
                icon: AppIcons.fire,
                label: '${data.currentStreak}-day streak',
                pair: colors.peach,
                small: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
