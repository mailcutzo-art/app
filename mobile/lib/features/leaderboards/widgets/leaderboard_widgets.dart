import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../data/leaderboard_models.dart';

/// "Ends in 2 d 4 h", "Ends in 3 h 20 m", "Ends in 12 m", "Ending now".
String endsInLabel(DateTime endsAt, DateTime now) {
  final left = endsAt.difference(now);
  if (left.inMinutes < 1) return 'Ending now';
  final days = left.inDays;
  final hours = left.inHours % 24;
  final minutes = left.inMinutes % 60;
  if (days > 0) return 'Ends in $days d $hours h';
  if (left.inHours > 0) return 'Ends in ${left.inHours} h $minutes m';
  return 'Ends in ${left.inMinutes} m';
}

/// Whether [row] belongs to the signed-in player.
bool isMine(BoardRow row, String? myId) => myId != null && row.user.id == myId;

/// What the viewer still has to do to appear on a board.
String notRankedMessage(BoardFamily family, int games) => switch (family) {
  BoardFamily.weeklySubject =>
    games == 1 ? 'Play 1 battle to appear' : 'Play $games more battles to appear',
  _ =>
    games == 1 ? 'Play 1 more rated battle to appear' : 'Play $games more rated battles to appear',
};

/// "#42 Physics · #310 this week · Overall: 3 more rated games".
String hubHeadline(List<BoardSummary> boards) {
  final parts = <String>[];
  for (final card in boards) {
    final family = card.family;
    if (family == BoardFamily.friendsWeekly ||
        family == BoardFamily.friendsRating ||
        family == BoardFamily.hallOfFame) {
      continue;
    }
    final me = card.me;
    if (me == null) continue;
    final position = me.position;
    if (position != null) {
      parts.add(switch (card.board) {
        'weekly_xp' => '#${formatCount(position)} this week',
        'rating:overall' => '#${formatCount(position)} Overall',
        _ => '#${formatCount(position)} ${card.title}',
      });
    } else if (card.board == 'rating:overall' && me.gamesToRank != null) {
      final games = me.gamesToRank!;
      parts.add('Overall: $games more rated ${games == 1 ? 'game' : 'games'}');
    }
  }
  return parts.join(' · ');
}

/// Places moved since yesterday: "▲ 5" in green, "▼ 3" in red, "–" unchanged.
class ChangeBadge extends StatelessWidget {
  const ChangeBadge({super.key, required this.change});

  final int? change;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final value = change;
    if (value == null) return const SizedBox.shrink();
    final (label, fg, semantics) = switch (value) {
      > 0 => ('▲ $value', colors.success, 'Up $value since yesterday'),
      < 0 => ('▼ ${value.abs()}', colors.error, 'Down ${value.abs()} since yesterday'),
      _ => ('–', colors.inkSubtle, 'No change since yesterday'),
    };
    return Semantics(
      label: semantics,
      excludeSemantics: true,
      child: Text(label, style: context.text.labelMedium.copyWith(color: fg)),
    );
  }
}

/// A board row drawn with the design system's [LeaderboardRow].
class BoardRowTile extends StatelessWidget {
  const BoardRowTile({super.key, required this.row, this.mine = false, this.onTap});

  final BoardRow row;
  final bool mine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final change = row.change1d;
    return LeaderboardRow(
      rank: row.position,
      name: row.user.displayName,
      score: row.valueDisplay,
      avatar: row.user.avatar.toData(),
      highlight: mine,
      subtitle: [
        if (row.user.level != null) 'Level ${row.user.level}',
        if (change != null && change > 0) '▲ $change today',
        if (change != null && change < 0) '▼ ${change.abs()} today',
      ].join(' · ').emptyAsNull,
      onTap: onTap,
    );
  }
}

/// One hub card: the board's #1, where the viewer stands, and for weekly
/// boards the time left.
class BoardCard extends StatelessWidget {
  const BoardCard({
    super.key,
    required this.card,
    required this.now,
    required this.onTap,
    this.myId,
  });

  final BoardSummary card;
  final DateTime now;
  final VoidCallback onTap;
  final String? myId;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final leader = card.leader;
    final me = card.me;
    final endsAt = card.endsAt;
    return SurfaceCard(
      onTap: onTap,
      semanticLabel: card.title,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HugeIcon(_icon(card), size: 20, color: colors.inkMuted),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(card.title, style: text.titleMedium)),
              if (card.family.weekly && endsAt != null)
                InfoChip(icon: AppIcons.clock, label: endsInLabel(endsAt, now)),
              const SizedBox(width: AppSpacing.xs),
              HugeIcon(AppIcons.chevronRight, size: 18, color: colors.inkSubtle),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (leader == null)
            Text('No one on this board yet. Be the first!', style: text.bodySmall)
          else
            Row(
              children: [
                HugeIcon(AppIcons.crown, size: 18, color: colors.coin),
                const SizedBox(width: AppSpacing.sm),
                AppAvatar(data: leader.user.avatar.toData(), size: 32),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    isMine(leader, myId) ? 'You lead' : '${leader.user.displayName} leads',
                    style: text.labelLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(leader.valueDisplay, style: text.numericMedium.copyWith(fontSize: 15)),
              ],
            ),
          const SizedBox(height: AppSpacing.md),
          Divider(height: 1, color: colors.outline),
          const SizedBox(height: AppSpacing.md),
          _Standing(card: card, me: me),
        ],
      ),
    );
  }

  static HugeIconData _icon(BoardSummary card) => switch (card.subject) {
    'physics' => AppIcons.physics,
    'chemistry' => AppIcons.chemistry,
    'biology' => AppIcons.biology,
    'maths' => AppIcons.maths,
    _ => switch (card.family) {
      BoardFamily.friendsWeekly || BoardFamily.friendsRating => AppIcons.social,
      BoardFamily.rating => AppIcons.chart,
      BoardFamily.hallOfFame => AppIcons.award,
      _ => AppIcons.flash,
    },
  };
}

class _Standing extends StatelessWidget {
  const _Standing({required this.card, required this.me});

  final BoardSummary card;
  final BoardStanding? me;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final colors = context.colors;
    final me = this.me;
    final position = me?.position;
    if (position == null) {
      final games = me?.gamesToRank;
      return Text(
        games == null ? 'You\'re not on this board yet' : notRankedMessage(card.family, games),
        style: text.bodySmall.copyWith(color: colors.inkMuted),
      );
    }
    return Row(
      children: [
        Text('You', style: text.labelMedium.copyWith(color: colors.inkMuted)),
        const SizedBox(width: AppSpacing.sm),
        Text('#${formatCount(position)}', style: text.numericMedium.copyWith(fontSize: 15)),
        if (me?.value != null) ...[
          Text('  ·  ', style: text.caption),
          Text(formatCount(me!.value!), style: text.labelMedium),
        ],
        const Spacer(),
        ChangeBadge(change: me?.change1d),
      ],
    );
  }
}

/// Loading placeholder for the hub.
class HubSkeleton extends StatelessWidget {
  const HubSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Shimmer(
    child: Column(
      children: [
        SkeletonBox(height: 200, radius: AppRadii.xl),
        SizedBox(height: AppSpacing.md),
        SkeletonBox(height: 150, radius: AppRadii.xl),
        SizedBox(height: AppSpacing.md),
        SkeletonBox(height: 150, radius: AppRadii.xl),
      ],
    ),
  );
}

/// Loading placeholder shaped like board rows.
class BoardRowsSkeleton extends StatelessWidget {
  const BoardRowsSkeleton({super.key, this.rows = 8});

  final int rows;

  @override
  Widget build(BuildContext context) => Shimmer(
    child: Column(
      children: [
        for (var i = 0; i < rows; i++)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.sm),
            child: SkeletonBox(height: 62, radius: AppRadii.lg),
          ),
      ],
    ),
  );
}

extension on String {
  String? get emptyAsNull => isEmpty ? null : this;
}
