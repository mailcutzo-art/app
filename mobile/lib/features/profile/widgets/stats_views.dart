import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../../../core/utils/time_text.dart';
import '../../learn/widgets/learn_widgets.dart' show TwoColumnGrid;
import '../data/profile_models.dart';

/// "Level 4" with the XP bar to the next level.
class LevelBar extends StatelessWidget {
  const LevelBar({super.key, required this.level});

  final LevelInfo level;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OverlineBadge(
                label: 'Level ${level.level}',
                tone: PastelTone.lime,
                icon: AppIcons.star,
              ),
              const Spacer(),
              if (level.forNext > 0)
                Text(
                  '${formatCount(level.intoLevel)} / ${formatCount(level.forNext)} XP',
                  style: text.labelMedium,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          AppProgressBar(
            value: level.progress,
            semanticLabel: 'Progress to level ${level.level + 1}',
          ),
        ],
      ),
    );
  }
}

/// Ratings per board with position, then W/D/L, accuracy, questions answered and streaks.
class StatsCard extends StatelessWidget {
  const StatsCard({super.key, required this.stats});

  final PlayerStats stats;

  static const _modeNames = {
    'rated': 'Rated',
    'casual': 'Casual',
    'bot': 'Practice Bot',
    'friend': 'Friends',
    'group': 'Group',
    'tournament': 'Tournaments',
  };

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final colors = context.colors;
    final total = stats.total;
    final accuracy = stats.accuracy;
    final modes = [
      for (final MapEntry(key: mode, value: record) in stats.records.entries)
        if (record.played > 0) '${_modeNames[mode] ?? scopeLabel(mode)} ${record.compact}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SurfaceCard(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
          child: stats.ratings.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: Text('Play rated battles to earn a rating.', style: text.bodyMedium),
                )
              : Column(
                  children: [
                    for (final (i, rating) in stats.ratings.indexed) ...[
                      if (i > 0) Divider(height: 1, color: colors.outline),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                        child: Row(
                          children: [
                            Expanded(child: Text(rating.label, style: text.titleMedium)),
                            Text(rating.rating.display, style: text.numericMedium),
                            const SizedBox(width: AppSpacing.md),
                            SizedBox(
                              width: 76,
                              child: Text(
                                rating.position == null
                                    ? 'Unranked'
                                    : '#${formatCount(rating.position!)}',
                                style: text.labelMedium.copyWith(color: colors.inkMuted),
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.md),
        TwoColumnGrid(
          children: [
            _StatTile(
              label: 'Won · drawn · lost',
              value: '${total.wins} · ${total.draws} · ${total.losses}',
              icon: AppIcons.battle,
              tone: PastelTone.sky,
            ),
            _StatTile(
              label: 'Accuracy',
              value: accuracy == null ? '—' : '${(accuracy * 100).round()}%',
              icon: AppIcons.target,
              tone: PastelTone.mint,
            ),
            _StatTile(
              label: 'Questions answered',
              value: formatCount(stats.questionsAnswered),
              icon: AppIcons.quiz,
              tone: PastelTone.lavender,
            ),
            _StatTile(
              label: 'Streak · best ${stats.bestStreak}',
              value: stats.currentStreak == 1 ? '1 day' : '${stats.currentStreak} days',
              icon: AppIcons.fire,
              tone: PastelTone.peach,
            ),
          ],
        ),
        if (modes.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(modes.join('  ·  '), style: text.caption),
        ],
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.tone,
  });

  final String label;
  final String value;
  final HugeIconData icon;
  final PastelTone tone;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final pair = context.colors.pastel(tone);
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(color: pair.container, borderRadius: AppRadii.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HugeIcon(icon, size: 20, color: pair.onContainer),
            const SizedBox(height: AppSpacing.sm),
            Text(value, style: text.numericMedium),
            Text(label, style: text.caption.copyWith(color: pair.onContainer)),
          ],
        ),
      ),
    );
  }
}

/// The overall rating over the picked range as a dot-matrix chart; tapping a column shows its
/// value and date.
class RatingChartCard extends StatelessWidget {
  const RatingChartCard({super.key, required this.history});

  final List<RatingPoint> history;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const SurfaceCard(
        child: EmptyState(
          icon: AppIcons.chart,
          tone: PastelTone.lemon,
          title: 'No rating history yet',
          message: 'Play rated battles to see your rating move.',
        ),
      );
    }
    final text = context.text;
    final first = history.first.value;
    final last = history.last.value;
    final change = last - first;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(formatCount(last), style: text.numericLarge),
              const SizedBox(width: AppSpacing.sm),
              if (history.length > 1) RatingDelta(delta: change),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          DotMatrixChart(
            values: [for (final point in history) point.value.toDouble()],
            tooltipBuilder: (i, value) => '${value.round()} · ${shortDate(history[i].at)}',
            semanticLabel: 'Rating chart',
          ),
        ],
      ),
    );
  }
}
