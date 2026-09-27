import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../icons/huge_icon.dart';
import '../theme/app_theme.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_dimens.dart';
import 'app_button.dart';
import 'avatar.dart';
import 'chips.dart';
import 'numbers.dart';
import 'pressable.dart';
import 'progress.dart';

/// Tournament summary card with a soft pastel gradient per subject.
class TournamentCard extends StatelessWidget {
  const TournamentCard({
    super.key,
    required this.title,
    required this.rounds,
    required this.prizePool,
    required this.joined,
    required this.capacity,
    required this.ctaLabel,
    this.description,
    this.entryFee,
    this.tone = PastelTone.lemon,
    this.statusLabel,
    this.live = false,
    this.subjectLabel,
    this.scheduleLabel,
    this.onCta,
    this.onTap,
    this.primaryCta = true,
  });

  final String title;
  final String? description;
  final int rounds;

  /// Null means free entry.
  final int? entryFee;
  final int prizePool;
  final int joined;
  final int capacity;
  final String ctaLabel;
  final PastelTone tone;
  final String? statusLabel;
  final bool live;
  final String? subjectLabel;
  final String? scheduleLabel;
  final VoidCallback? onCta;
  final VoidCallback? onTap;
  final bool primaryCta;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final pair = colors.pastel(tone);
    final fill = capacity == 0 ? 0.0 : joined / capacity;

    final card = Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        borderRadius: AppRadii.tile,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [pair.container, Color.lerp(pair.container, colors.surface, 0.55)!],
        ),
        border: Border.all(color: pair.onContainer.withValues(alpha: 0.10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              if (live) const LiveBadge(),
              if (statusLabel != null)
                OverlineBadge(label: statusLabel!, icon: AppIcons.clock, solid: true),
              if (subjectLabel != null) OverlineBadge(label: subjectLabel!, tone: tone),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(title, style: text.titleLarge),
          if (description != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              description!,
              style: text.bodySmall.copyWith(color: colors.inkMuted),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              InfoChip(icon: AppIcons.checklist, label: '$rounds rounds'),
              InfoChip(
                icon: AppIcons.coins,
                iconColor: colors.coin,
                label: entryFee == null ? 'Free entry' : '${formatCount(entryFee!)} entry',
              ),
              InfoChip(icon: AppIcons.award, label: formatCount(prizePool)),
              if (scheduleLabel != null) InfoChip(icon: AppIcons.calendar, label: scheduleLabel!),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: '$joined', style: text.numericMedium),
                          TextSpan(text: ' / $capacity players', style: text.caption),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    AppProgressBar(
                      value: fill,
                      height: 6,
                      color: colors.ink,
                      trackColor: colors.ink.withValues(alpha: 0.10),
                      semanticLabel: 'Players joined',
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              AppButton(
                label: ctaLabel,
                onPressed: onCta,
                variant: primaryCta ? AppButtonVariant.ink : AppButtonVariant.secondary,
                size: AppButtonSize.medium,
                expand: false,
              ),
            ],
          ),
        ],
      ),
    );
    if (onTap == null) return card;
    return Pressable(onPressed: onTap, pressedScale: 0.98, semanticLabel: title, child: card);
  }
}

/// A leaderboard entry. The current user's row is highlighted.
class LeaderboardRow extends StatelessWidget {
  const LeaderboardRow({
    super.key,
    required this.rank,
    required this.name,
    required this.score,
    required this.avatar,
    this.subtitle,
    this.highlight = false,
    this.onTap,
  });

  final int rank;
  final String name;
  final String score;
  final AvatarData avatar;
  final String? subtitle;
  final bool highlight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final medal = switch (rank) {
      1 => colors.lemon,
      2 => colors.sky,
      3 => colors.peach,
      _ => null,
    };
    final row = Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
      decoration: BoxDecoration(
        color: highlight ? colors.accentSoft : colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: highlight ? colors.accent : colors.outline),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: medal == null
                ? FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      formatCount(rank),
                      maxLines: 1,
                      style: text.numericMedium.copyWith(color: colors.inkMuted, fontSize: 14),
                    ),
                  )
                : Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: medal.container, shape: BoxShape.circle),
                    child: Text(
                      '$rank',
                      style: text.numericMedium.copyWith(color: medal.onContainer, fontSize: 14),
                    ),
                  ),
          ),
          const SizedBox(width: AppSpacing.sm),
          AppAvatar(data: avatar, size: 40),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  highlight ? '$name (you)' : name,
                  style: text.titleMedium.copyWith(fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) Text(subtitle!, style: text.caption),
              ],
            ),
          ),
          Text(score, style: text.numericMedium),
        ],
      ),
    );
    if (onTap == null) return row;
    return Pressable(onPressed: onTap, pressedScale: 0.98, child: row);
  }
}

@immutable
class PodiumEntry {
  const PodiumEntry({required this.name, required this.score, required this.avatar});

  final String name;
  final String score;
  final AvatarData avatar;
}

/// Top-three podium (order: 2nd, 1st, 3rd).
class Podium extends StatelessWidget {
  const Podium({super.key, required this.entries});

  /// Ranked 1st, 2nd, 3rd (extra entries are ignored).
  final List<PodiumEntry> entries;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    Widget column(int place, double height, PastelPair pair) {
      if (place > entries.length) return const Expanded(child: SizedBox());
      final e = entries[place - 1];
      return Expanded(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (place == 1) HugeIcon(AppIcons.crown, size: 26, color: colors.coin),
            const SizedBox(height: 4),
            AppAvatar(data: e.avatar, size: place == 1 ? 60 : 50, ring: place == 1),
            const SizedBox(height: 6),
            Text(e.name, style: text.labelMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(e.score, style: text.caption),
            const SizedBox(height: 8),
            Container(
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.topCenter,
              padding: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                color: pair.container,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadii.lg)),
              ),
              child: Text('$place', style: text.numericLarge.copyWith(color: pair.onContainer)),
            ),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        column(2, 84, colors.sky),
        column(1, 112, colors.lemon),
        column(3, 64, colors.peach),
      ],
    );
  }
}
