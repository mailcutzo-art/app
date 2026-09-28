import 'dart:math' as math;

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// The small pieces around the arena on the welcome screen.

/// Fades and lifts [child] in once, between [begin] and [end] of
/// [duration]; shows it at rest straight away when motion is reduced.
class FadeUp extends StatelessWidget {
  const FadeUp({
    super.key,
    required this.child,
    this.begin = 0,
    this.end = 1,
    this.duration = const Duration(milliseconds: 700),
  });

  final Widget child;
  final double begin;
  final double end;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.of(context, duration),
      curve: Interval(begin, end, curve: AppMotion.standard),
      builder: (_, t, child) => t == 1
          ? child!
          : Opacity(
              opacity: t,
              child: Transform.translate(offset: Offset(0, 10 * (1 - t)), child: child),
            ),
      child: child,
    );
  }
}

/// The app mark and name.
class WelcomeBrand extends StatelessWidget {
  const WelcomeBrand({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: colors.accent, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: HugeIcon(AppIcons.rocket, size: 20, color: colors.onAccent),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Semantics(header: true, child: Text('Quiz Arena', style: context.text.titleLarge)),
        ),
      ],
    );
  }
}

/// "Learn. Battle. Level Up." and the one-line pitch under it.
class WelcomeHeadline extends StatelessWidget {
  const WelcomeHeadline({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    return Column(
      children: [
        Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'Learn. Battle. '),
              // A no-break space keeps "Level Up." on one line.
              TextSpan(
                text: 'Level\u00A0Up.',
                style: TextStyle(color: colors.accent),
              ),
            ],
          ),
          textAlign: TextAlign.center,
          style: text.headlineMedium.copyWith(fontSize: 24, height: 30 / 24),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Master NEET & JEE one challenge at a time.',
          textAlign: TextAlign.center,
          style: text.bodyMedium,
        ),
      ],
    );
  }
}

/// A compact pill naming one way to play, with a toned glyph.
class FeatureChip extends StatelessWidget {
  const FeatureChip({super.key, required this.icon, required this.label, required this.tone});

  final HugeIconData icon;
  final String label;
  final PastelTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pastel = colors.pastel(tone);
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.fromLTRB(5, 4, 10, 4),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppRadii.pillAll,
        border: Border.all(color: colors.outline),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: 0.35),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(color: pastel.container, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: HugeIcon(icon, size: 13, color: pastel.onContainer),
          ),
          const SizedBox(width: 6),
          Flexible(child: Text(label, style: context.text.labelMedium.copyWith(fontSize: 12))),
        ],
      ),
    );
  }
}

/// 1v1, Tournaments and Practice as a row of chips (wrapping when the text
/// is large).
class FeatureChips extends StatelessWidget {
  const FeatureChips({super.key});

  @override
  Widget build(BuildContext context) {
    return const Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        FeatureChip(icon: AppIcons.battle, label: '1v1', tone: PastelTone.sky),
        FeatureChip(icon: AppIcons.arena, label: 'Tournaments', tone: PastelTone.lemon),
        FeatureChip(icon: AppIcons.learn, label: 'Practice', tone: PastelTone.mint),
      ],
    );
  }
}

/// Why the player is back here (e.g. the session ended), wrapped rather than
/// cut off on narrow phones.
class SessionNotice extends StatelessWidget {
  const SessionNotice({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final lemon = context.colors.lemon;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(color: lemon.container, borderRadius: AppRadii.pillAll),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HugeIcon(AppIcons.info, size: 16, color: lemon.onContainer),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              message,
              style: context.text.labelMedium.copyWith(color: lemon.onContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// The arena's slot. The artwork wants [aspectRatio] of its width in height
/// (at most [maxWidth] wide, and allowed to spread [bleed] into the side
/// gutters, since its edges are soft), but shrinks down to [minHeight] on
/// short screens before anything else has to give.
///
/// When there's room to spare, the slot takes [spareShare] of it above the
/// artwork, leaving the rest to its parent (above the sign-in button on the
/// welcome screen). It reports [minHeight] as its intrinsic height, so an
/// [IntrinsicHeight] column only scrolls when even the smallest arena
/// doesn't fit.
class HeroSlot extends SingleChildRenderObjectWidget {
  const HeroSlot({
    super.key,
    required this.minHeight,
    required this.aspectRatio,
    required this.maxWidth,
    this.bleed = 0,
    this.spareShare = 0,
    super.child,
  });

  final double minHeight;
  final double aspectRatio;
  final double maxWidth;
  final double bleed;
  final double spareShare;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderHeroSlot(
    minHeight: minHeight,
    aspectRatio: aspectRatio,
    maxWidth: maxWidth,
    bleed: bleed,
    spareShare: spareShare,
  );

  @override
  void updateRenderObject(BuildContext context, RenderHeroSlot renderObject) {
    renderObject
      ..minHeight = minHeight
      ..aspectRatio = aspectRatio
      ..maxWidth = maxWidth
      ..bleed = bleed
      ..spareShare = spareShare;
  }
}

/// Render object of [HeroSlot].
class RenderHeroSlot extends RenderShiftedBox {
  RenderHeroSlot({
    required this._minHeight,
    required this._aspectRatio,
    required this._maxWidth,
    required this._bleed,
    required this._spareShare,
  }) : super(null);

  double _minHeight;
  set minHeight(double value) => _set(_minHeight, value, (v) => _minHeight = v);

  double _aspectRatio;
  set aspectRatio(double value) => _set(_aspectRatio, value, (v) => _aspectRatio = v);

  double _maxWidth;
  set maxWidth(double value) => _set(_maxWidth, value, (v) => _maxWidth = v);

  double _bleed;
  set bleed(double value) => _set(_bleed, value, (v) => _bleed = v);

  double _spareShare;
  set spareShare(double value) => _set(_spareShare, value, (v) => _spareShare = v);

  void _set(double old, double value, void Function(double) assign) {
    if (old == value) return;
    assign(value);
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicHeight(double width) => _minHeight;

  @override
  double computeMaxIntrinsicHeight(double width) => _minHeight;

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  /// The artwork's box and how far down the slot it sits.
  (Size slot, Size art, double top) _layout(BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final artWidth = width + 2 * _bleed;
    final wanted = math.max(math.min(artWidth, _maxWidth) * _aspectRatio, _minHeight);
    final artHeight = constraints.constrainHeight(wanted);
    final spare = constraints.hasBoundedHeight ? constraints.maxHeight - artHeight : 0.0;
    final top = math.max(0.0, spare) * _spareShare;
    final slot = constraints.constrain(Size(width, artHeight + top));
    return (slot, Size(artWidth, artHeight), top);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => _layout(constraints).$1;

  @override
  void performLayout() {
    final (slot, art, top) = _layout(constraints);
    size = slot;
    final child = this.child;
    if (child == null) return;
    child.layout(BoxConstraints.tight(art));
    (child.parentData! as BoxParentData).offset = Offset(-_bleed, top);
  }
}
