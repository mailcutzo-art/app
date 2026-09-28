import 'package:flutter/material.dart';

import '../icons/huge_icon.dart';
import '../icons/icon_motion.dart';
import '../icons/icon_shapes.dart';
import '../theme/app_theme.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_shadows.dart';
import 'pressable.dart';

/// White rounded card with a hairline border. Tappable when [onTap] is set.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(AppSpacing.xl),
    this.color,
    this.borderRadius = AppRadii.card,
    this.bordered = true,
    this.elevated = false,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final BorderRadius borderRadius;
  final bool bordered;
  final bool elevated;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? colors.surface,
        borderRadius: borderRadius,
        border: bordered ? Border.all(color: colors.outline) : null,
        boxShadow: elevated ? AppShadows.card(colors) : null,
      ),
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return card;
    return Pressable(
      onPressed: onTap,
      pressedScale: 0.98,
      semanticLabel: semanticLabel,
      child: card,
    );
  }
}

/// Pastel action tile with the icon in a white circle (reference 2).
class PastelTile extends StatelessWidget {
  const PastelTile({
    super.key,
    required this.tone,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.badge,
    this.height = 150,
    this.iconMotion,
  });

  final PastelTone tone;
  final HugeIconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  /// Optional widget in the top-right corner (e.g. a LIVE badge).
  final Widget? badge;
  final double height;
  final IconMotion? iconMotion;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pair = colors.pastel(tone);
    final text = context.text;
    final circle = colors.isDark ? colors.surface : const Color(0xFFFFFFFF);
    final iconWidget = iconMotion == null
        ? HugeIcon(icon, size: 24, color: pair.onContainer)
        : AnimatedHugeIcon(icon, motion: iconMotion!, autoplay: true, color: pair.onContainer);

    final tile = Container(
      height: height,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(color: pair.container, borderRadius: AppRadii.tile),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: circle, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: iconWidget,
              ),
              const Spacer(),
              ?badge,
            ],
          ),
          const Spacer(),
          Text(
            title,
            style: text.titleMedium.copyWith(color: colors.ink, fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: text.bodySmall.copyWith(color: pair.onContainer),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return tile;
    return Pressable(onPressed: onTap, pressedScale: 0.97, semanticLabel: title, child: tile);
  }
}

@immutable
class HeroStat {
  const HeroStat({required this.label, required this.value, this.icon, this.onTap});

  final String label;
  final String value;
  final HugeIconData? icon;

  /// Opens the stat's detail (e.g. the wallet behind Coins).
  final VoidCallback? onTap;
}

@immutable
class HeroAction {
  const HeroAction({required this.label, required this.icon, required this.onTap});

  final String label;
  final HugeIconData icon;
  final VoidCallback? onTap;
}

/// Big-number card (reference 1): a lemon panel with the headline value,
/// secondary stats, and an action row below.
class HeroStatCard extends StatelessWidget {
  const HeroStatCard({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.trailing,
    this.stats = const [],
    this.actions = const [],
    this.tone = PastelTone.lemon,
  });

  final String label;

  /// Already formatted; pass `—` when there is no value yet.
  final Widget value;
  final String? caption;
  final Widget? trailing;
  final List<HeroStat> stats;
  final List<HeroAction> actions;
  final PastelTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final pair = colors.pastel(tone);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.xxxl)),
        boxShadow: AppShadows.card(colors),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              decoration: BoxDecoration(
                color: pair.container,
                borderRadius: const BorderRadius.all(Radius.circular(AppRadii.xxl)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(
                        label.toUpperCase(),
                        style: text.overline.copyWith(color: pair.onContainer),
                      ),
                      const Spacer(),
                      ?trailing,
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  DefaultTextStyle.merge(
                    style: text.numericDisplay.copyWith(color: colors.ink),
                    child: value,
                  ),
                  if (caption != null) ...[
                    const SizedBox(height: 2),
                    Text(caption!, style: text.labelMedium.copyWith(color: pair.onContainer)),
                  ],
                  if (stats.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.lg),
                    Row(
                      children: [
                        for (final stat in stats)
                          Expanded(
                            child: _HeroStatView(stat: stat, color: pair.onContainer),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                child: IntrinsicHeight(
                  child: Row(
                    children: [
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0)
                          VerticalDivider(color: colors.outline, width: 1, indent: 8, endIndent: 8),
                        Expanded(child: _HeroActionView(action: actions[i])),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HeroStatView extends StatelessWidget {
  const _HeroStatView({required this.stat, required this.color});

  final HeroStat stat;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final view = Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (stat.icon != null) ...[
              HugeIcon(stat.icon!, size: 16, color: context.colors.ink),
              const SizedBox(width: 4),
            ],
            Text(stat.value, style: text.numericMedium),
          ],
        ),
        const SizedBox(height: 2),
        Text(stat.label, style: text.caption.copyWith(color: color)),
      ],
    );
    if (stat.onTap == null) return view;
    return Pressable(
      onPressed: stat.onTap,
      pressedScale: 0.94,
      semanticLabel: '${stat.label}: ${stat.value}',
      child: view,
    );
  }
}

class _HeroActionView extends StatelessWidget {
  const _HeroActionView({required this.action});

  final HeroAction action;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Pressable(
      onPressed: action.onTap,
      pressedScale: 0.94,
      semanticLabel: action.label,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HugeIcon(action.icon, size: 22, color: colors.ink),
            const SizedBox(height: 4),
            Text(action.label, style: context.text.caption.copyWith(color: colors.inkMuted)),
          ],
        ),
      ),
    );
  }
}

/// Row card with leading visual, title/subtitle and trailing content
/// (reference 1 transaction rows).
class ListRowCard extends StatelessWidget {
  const ListRowCard({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return SurfaceCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 14),
      semanticLabel: title,
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: AppSpacing.md)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: text.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: AppSpacing.md), trailing!],
        ],
      ),
    );
  }
}

/// Section title with an optional "See all" style action.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.gutter,
      AppSpacing.xxl,
      AppSpacing.gutter,
      AppSpacing.md,
    ),
  });

  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final colors = context.colors;
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleLarge),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: text.bodySmall),
                ],
              ],
            ),
          ),
          if (actionLabel != null)
            Pressable(
              onPressed: onAction,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(actionLabel!, style: text.labelMedium.copyWith(color: colors.inkMuted)),
              ),
            ),
        ],
      ),
    );
  }
}
