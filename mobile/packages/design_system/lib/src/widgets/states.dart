import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../icons/huge_icon.dart';
import '../icons/icon_shapes.dart';
import '../theme/app_theme.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_motion.dart';
import 'app_button.dart';

/// Friendly empty state with an optional call to action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.tone = PastelTone.sky,
  });

  final HugeIconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final PastelTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pair = colors.pastel(tone);
    final text = context.text;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl, vertical: AppSpacing.xxxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: HugeIcon(icon, size: 32, color: pair.onContainer),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(title, style: text.titleLarge, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(message!, style: text.bodyMedium, textAlign: TextAlign.center),
          ],
          if (actionLabel != null) ...[
            const SizedBox(height: AppSpacing.xl),
            AppButton(
              label: actionLabel!,
              onPressed: onAction,
              size: AppButtonSize.medium,
              expand: false,
            ),
          ],
        ],
      ),
    );
  }
}

/// Inline error for a section or screen. Always offers a retry; never shows
/// raw exception text.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.onRetry,
    this.title = 'Couldn\'t load this',
    this.message = 'Check your connection and try again.',
    this.retrying = false,
    this.compact = false,
  });

  final VoidCallback? onRetry;
  final String title;
  final String message;
  final bool retrying;

  /// Card-sized variant for a single section of a screen.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    if (compact) {
      return Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: AppRadii.card,
          border: Border.all(color: colors.outline),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: colors.rose.container, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: HugeIcon(AppIcons.alert, size: 22, color: colors.rose.onContainer),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.titleMedium),
                  Text(message, style: text.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            AppButton(
              label: 'Retry',
              onPressed: onRetry,
              loading: retrying,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.small,
              expand: false,
            ),
          ],
        ),
      );
    }
    return EmptyState(
      icon: AppIcons.alert,
      title: title,
      message: message,
      tone: PastelTone.rose,
      actionLabel: retrying ? null : 'Try again',
      onAction: onRetry,
    );
  }
}

/// Slim banner shown while offline; content below keeps showing cached data.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.visible, this.message});

  final bool visible;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.medium),
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: CurvedAnimation(parent: animation, curve: AppMotion.emphasized),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: !visible
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.sm,
                AppSpacing.gutter,
                0,
              ),
              child: Semantics(
                liveRegion: true,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(color: colors.inverse, borderRadius: AppRadii.pillAll),
                  child: Row(
                    children: [
                      HugeIcon(AppIcons.offline, size: 18, color: colors.onInverse),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          message ?? 'You\'re offline — showing saved data',
                          style: context.text.labelMedium.copyWith(color: colors.onInverse),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

/// Paints a moving highlight over its [child] placeholders. One animation
/// drives every skeleton box inside it.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});

  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final base = colors.surfaceSunken;
    final highlight = colors.isDark ? colors.outlineStrong : colors.surface;
    return Semantics(
      label: 'Loading',
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _controller,
          child: widget.child,
          builder: (context, child) {
            final t = _controller.value;
            return ShaderMask(
              blendMode: BlendMode.srcATop,
              shaderCallback: (bounds) => LinearGradient(
                begin: Alignment(-1.6 + 3.2 * t, -0.3),
                end: Alignment(-0.6 + 3.2 * t, 0.3),
                colors: [base, highlight, base],
                stops: const [0.1, 0.5, 0.9],
              ).createShader(bounds),
              child: child,
            );
          },
        ),
      ),
    );
  }
}

/// Placeholder block for skeleton layouts; wrap groups in a [Shimmer].
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.radius = AppRadii.md,
    this.circle = false,
  });

  final double? width;
  final double height;
  final double radius;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: circle ? height : width,
      height: height,
      decoration: BoxDecoration(
        color: context.colors.surfaceSunken,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(radius),
      ),
    );
  }
}
