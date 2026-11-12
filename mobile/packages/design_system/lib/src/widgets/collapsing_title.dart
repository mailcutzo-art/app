import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../theme/app_theme.dart';
import '../tokens/app_dimens.dart';
import 'app_icon_button.dart';

/// What a pinned header paints behind itself: the page's own background, exactly, so the header
/// never looks like a separate band; content just slips under it. A page with a fixed background
/// (a gradient wash) provides a slice of it here; without one the header paints the scaffold
/// colour.
class PageBackdrop extends InheritedWidget {
  const PageBackdrop({super.key, required this.backdrop, required super.child});

  final Widget backdrop;

  static Widget of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PageBackdrop>()?.backdrop ??
      ColoredBox(color: Theme.of(context).scaffoldBackgroundColor);

  @override
  bool updateShouldNotify(PageBackdrop old) => old.backdrop != backdrop;
}

/// A page title that collapses as the page scrolls, for the top of a [CustomScrollView].
///
/// At rest it reads like [LargeTitle]: a big title, an optional description under it and an
/// optional [trailing] badge on the right. Scrolling shrinks the title to a compact size, fades
/// the description out and scales the badge down, so the header ends as one slim row that stays
/// pinned while the content scrolls under it (on the page's own background, [PageBackdrop]).
/// Scrolling back up opens it again.
///
/// Pushed screens pass [onBack] (or are simply poppable) and get the back button and [actions]
/// in a row on top, as with [AppTopBar]; collapsed, the title moves up beside the back button.
///
/// With reduced motion the header still follows the finger (it is tied to the scroll position,
/// not animated on its own).
class SliverCollapsingTitle extends StatelessWidget {
  const SliverCollapsingTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleMaxLines = 2,
    this.trailing,
    this.onBack,
    this.showBack,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final int subtitleMaxLines;

  /// A badge beside the big title (an avatar, a subject icon), at most 56 high.
  final Widget? trailing;

  /// What the back button does; it defaults to popping the route.
  final VoidCallback? onBack;

  /// Whether there is a back button: by default when [onBack] is given or the route can pop.
  final bool? showBack;

  /// Round buttons on the right of the top row (pushed screens).
  final List<Widget> actions;

  /// The top row of a pushed screen, as tall as [AppTopBar].
  static const double barHeight = 76;

  /// The collapsed height of a tab page's title row.
  static const double compactHeight = 60;

  /// The most a [trailing] badge takes.
  static const double trailingSize = 56;

  @override
  Widget build(BuildContext context) {
    final back = showBack ?? (onBack != null || (Navigator.maybeOf(context)?.canPop() ?? false));
    final text = context.text;
    final scaler = MediaQuery.textScalerOf(context);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final hasBar = back || actions.isNotEmpty;
        final reserve = trailing == null ? 0.0 : trailingSize + AppSpacing.md;
        final textWidth = math.max(0.0, width - 2 * AppSpacing.gutter - reserve);
        final titleHeight = _measure(title, text.headlineLarge, textWidth, 2, scaler);
        final subtitle = this.subtitle;
        final subtitleHeight = subtitle == null || subtitle.isEmpty
            ? 0.0
            : AppSpacing.xs +
                  _measure(subtitle, text.bodyMedium, textWidth, subtitleMaxLines, scaler);
        final block = math.max(titleHeight + subtitleHeight, trailing == null ? 0 : trailingSize);
        final top = hasBar ? barHeight : AppSpacing.lg;
        final minExtent = hasBar
            ? barHeight
            : math.max(compactHeight, scaler.scale(text.titleLarge.fontSize!) * 1.3 + 2 * 17);
        final maxExtent = math.max(minExtent, top + block + AppSpacing.md);
        return SliverPersistentHeader(
          pinned: true,
          delegate: _CollapsingDelegate(
            title: title,
            subtitle: subtitle,
            subtitleMaxLines: subtitleMaxLines,
            trailing: trailing,
            back: back,
            onBack: onBack,
            actions: actions,
            backdrop: PageBackdrop.of(context),
            hasBar: hasBar,
            top: top,
            titleHeight: titleHeight,
            minHeight: minExtent,
            maxHeight: maxExtent,
          ),
        );
      },
    );
  }

  static double _measure(String text, TextStyle style, double width, int lines, TextScaler s) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: s,
      maxLines: lines,
      ellipsis: '…',
    )..layout(maxWidth: width);
    final height = painter.height;
    painter.dispose();
    return height;
  }
}

class _CollapsingDelegate extends SliverPersistentHeaderDelegate {
  _CollapsingDelegate({
    required this.title,
    required this.subtitle,
    required this.subtitleMaxLines,
    required this.trailing,
    required this.back,
    required this.onBack,
    required this.actions,
    required this.backdrop,
    required this.hasBar,
    required this.top,
    required this.titleHeight,
    required this.minHeight,
    required this.maxHeight,
  });

  final String title;
  final String? subtitle;
  final int subtitleMaxLines;
  final Widget? trailing;
  final bool back;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final Widget backdrop;
  final bool hasBar;
  final double top;
  final double titleHeight;
  final double minHeight;
  final double maxHeight;

  @override
  double get minExtent => minHeight;

  @override
  double get maxExtent => maxHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final text = context.text;
    final range = maxHeight - minHeight;
    final t = range <= 0 ? 1.0 : (shrinkOffset / range).clamp(0.0, 1.0);
    final eased = Curves.easeOut.transform(t);
    final width = MediaQuery.sizeOf(context).width;

    // Where the title sits: below the top row (or at the top of a tab page) when open; in the
    // row, beside the back button, when collapsed.
    final collapsedStyle = hasBar ? text.titleMedium : text.titleLarge;
    final style = TextStyle.lerp(text.headlineLarge, collapsedStyle, eased)!;
    const leftOpen = AppSpacing.gutter;
    final leftShut = back ? AppSpacing.gutter + AppSizes.iconButton + AppSpacing.md : leftOpen;
    final shutLine = (collapsedStyle.height ?? 1.2) * collapsedStyle.fontSize!;
    final scaledLine = MediaQuery.textScalerOf(context).scale(shutLine);
    final topShut = (minHeight - scaledLine) / 2;
    final titleTop = ui.lerpDouble(top, topShut, eased)!;
    // Sideways first, then up: the title clears the back button before it rises into its row.
    final sideways = Curves.easeOut.transform((t / 0.22).clamp(0.0, 1.0));
    final titleLeft = ui.lerpDouble(leftOpen, leftShut, sideways)!;
    final actionsWidth = actions.isEmpty
        ? 0.0
        : actions.length * AppSizes.iconButton + actions.length * AppSpacing.sm;
    final trailingShut = trailing != null && actions.isEmpty;
    final rightOpen =
        AppSpacing.gutter +
        (trailing == null ? 0 : SliverCollapsingTitle.trailingSize + AppSpacing.md);
    final rightShut =
        AppSpacing.gutter +
        actionsWidth +
        (trailingShut ? SliverCollapsingTitle.trailingSize * 0.72 + AppSpacing.sm : 0);
    final titleRight = ui.lerpDouble(rightOpen, rightShut, eased)!;

    // The description goes first, in the first half of the collapse.
    final subtitleOpacity = (1 - t * 2).clamp(0.0, 1.0);

    final subtitle = this.subtitle;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The page's own background, so content scrolling up disappears under the header.
          Positioned.fill(child: IgnorePointer(child: backdrop)),
          if (hasBar)
            Positioned(
              left: AppSpacing.gutter,
              right: AppSpacing.gutter,
              top: 0,
              height: SliverCollapsingTitle.barHeight,
              child: Row(
                children: [
                  if (back)
                    AppIconButton(
                      icon: AppIcons.back,
                      semanticLabel: 'Back',
                      onPressed: onBack ?? () => Navigator.maybePop(context),
                    ),
                  const Spacer(),
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.sm),
                    actions[i],
                  ],
                ],
              ),
            ),
          Positioned(
            left: titleLeft,
            top: titleTop,
            width: math.max(0, width - titleLeft - titleRight),
            child: Semantics(
              header: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: style,
                    maxLines: t < 0.5 ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null && subtitle.isNotEmpty && subtitleOpacity > 0)
                    Opacity(
                      opacity: subtitleOpacity,
                      child: Transform.translate(
                        offset: Offset(0, -8 * t),
                        child: Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xs),
                          child: Text(
                            subtitle,
                            style: text.bodyMedium,
                            maxLines: subtitleMaxLines,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (trailing case final badge?)
            Positioned(
              right: AppSpacing.gutter + (trailingShut ? 0 : actionsWidth * eased),
              // Open: level with the bottom of the title block. Shut: centred in the row.
              top: ui.lerpDouble(
                top + _openBlockBottom() - SliverCollapsingTitle.trailingSize,
                (minHeight - SliverCollapsingTitle.trailingSize) / 2,
                eased,
              ),
              width: SliverCollapsingTitle.trailingSize,
              height: SliverCollapsingTitle.trailingSize,
              child: Opacity(
                // Beside a pushed screen's buttons there's no room: it fades instead.
                opacity: trailingShut ? 1 : (1 - t * 1.5).clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: ui.lerpDouble(1, 0.72, eased),
                  alignment: Alignment.centerRight,
                  child: Align(alignment: Alignment.centerRight, child: badge),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The bottom of the open title block, below [top].
  double _openBlockBottom() =>
      math.max(maxHeight - top - AppSpacing.md, SliverCollapsingTitle.trailingSize);

  @override
  bool shouldRebuild(covariant _CollapsingDelegate old) =>
      old.title != title ||
      old.subtitle != subtitle ||
      old.subtitleMaxLines != subtitleMaxLines ||
      old.trailing != trailing ||
      old.back != back ||
      old.onBack != onBack ||
      old.actions != actions ||
      old.backdrop != backdrop ||
      old.hasBar != hasBar ||
      old.top != top ||
      old.titleHeight != titleHeight ||
      old.minHeight != minHeight ||
      old.maxHeight != maxHeight;
}
