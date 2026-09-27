import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../icons/huge_icon.dart';
import '../theme/app_theme.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_motion.dart';
import '../tokens/app_shadows.dart';
import 'pressable.dart';

/// One quick reaction in an [EmoteBar]: [id] goes over the wire, [label] is shown.
@immutable
class EmoteOption {
  const EmoteOption({required this.id, required this.label});

  final String id;
  final String label;
}

/// A row of quick reactions for live games ("GG", "Nice!", …).
///
/// After a tap the whole bar rests for [cooldown] (at most one reaction every few seconds), and a
/// thin bar under it shows the time left.
class EmoteBar extends StatefulWidget {
  const EmoteBar({
    super.key,
    required this.emotes,
    required this.onSend,
    this.cooldown = const Duration(seconds: 3),
  });

  final List<EmoteOption> emotes;

  /// Called with the [EmoteOption.id] of the tapped reaction. Null disables the bar.
  final ValueChanged<String>? onSend;
  final Duration cooldown;

  @override
  State<EmoteBar> createState() => _EmoteBarState();
}

class _EmoteBarState extends State<EmoteBar> with SingleTickerProviderStateMixin {
  late final AnimationController _rest = AnimationController(
    vsync: this,
    duration: widget.cooldown,
    value: 1,
  );

  bool get _resting => _rest.value < 1;

  @override
  void didUpdateWidget(covariant EmoteBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _rest.duration = widget.cooldown;
  }

  @override
  void dispose() {
    _rest.dispose();
    super.dispose();
  }

  void _send(EmoteOption emote) {
    final onSend = widget.onSend;
    if (onSend == null || _resting) return;
    onSend(emote.id);
    _rest.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    return AnimatedBuilder(
      animation: _rest,
      builder: (context, _) {
        final enabled = widget.onSend != null && !_resting;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final (i, emote) in widget.emotes.indexed) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: AnimatedOpacity(
                      duration: AppMotion.of(context, AppMotion.fast),
                      opacity: enabled ? 1 : 0.45,
                      child: Pressable(
                        onPressed: enabled ? () => _send(emote) : null,
                        semanticLabel: 'Send ${emote.label}',
                        pressedScale: 0.92,
                        child: Container(
                          height: AppSizes.buttonSmall,
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                          alignment: Alignment.center,
                          decoration: ShapeDecoration(
                            color: colors.surface,
                            shape: StadiumBorder(side: BorderSide(color: colors.outline)),
                          ),
                          child: Text(
                            emote.label,
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            style: text.labelMedium,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            SizedBox(
              width: 64,
              height: 3,
              child: _resting
                  ? ClipRRect(
                      borderRadius: AppRadii.pillAll,
                      child: LinearProgressIndicator(
                        value: 1 - _rest.value,
                        color: colors.inkSubtle,
                        backgroundColor: Colors.transparent,
                      ),
                    )
                  : null,
            ),
          ],
        );
      },
    );
  }
}

/// A reaction popping up next to a player ("GG"). Give it a new [key] for every reaction so the
/// pop plays again, even for the same text.
class EmoteBubble extends StatelessWidget {
  const EmoteBubble({super.key, required this.label, this.pointsLeft = true});

  final String label;

  /// Which side the little tail points to.
  final bool pointsLeft;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
      decoration: BoxDecoration(
        color: colors.inverse,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(AppRadii.md),
          topRight: const Radius.circular(AppRadii.md),
          bottomLeft: Radius.circular(pointsLeft ? 4 : AppRadii.md),
          bottomRight: Radius.circular(pointsLeft ? AppRadii.md : 4),
        ),
        boxShadow: AppShadows.card(colors),
      ),
      child: Text(label, style: context.text.labelMedium.copyWith(color: colors.onInverse)),
    );
    return Semantics(
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: AppMotion.of(context, AppMotion.medium),
        curve: AppMotion.bouncy,
        builder: (context, t, child) => Transform.scale(
          scale: 0.6 + 0.4 * t,
          alignment: pointsLeft ? Alignment.bottomLeft : Alignment.bottomRight,
          child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
        ),
        child: bubble,
      ),
    );
  }
}

/// How one question of a game went, for [ResultDots].
enum DotOutcome {
  /// Answered correctly.
  right,

  /// Answered, but wrong.
  wrong,

  /// Not answered in time.
  missed,

  /// Not known on this device (for example after the app was restarted mid-game).
  unknown,
}

/// Whether the player was quicker or slower than their opponent on a question.
enum DotSpeed { fast, even, slow }

@immutable
class ResultDot {
  const ResultDot({required this.outcome, this.speed});

  final DotOutcome outcome;

  /// `null` when there is no comparison (a bot game, or no answer).
  final DotSpeed? speed;
}

/// One dot per question of a finished game: a tick or a cross, with a small bolt when the player
/// was faster and an hourglass when slower.
class ResultDots extends StatelessWidget {
  const ResultDots({super.key, required this.dots, this.size = 32});

  final List<ResultDot> dots;
  final double size;

  static String describe(int number, ResultDot dot) {
    final outcome = switch (dot.outcome) {
      DotOutcome.right => 'right',
      DotOutcome.wrong => 'wrong',
      DotOutcome.missed => 'no answer',
      DotOutcome.unknown => 'not known',
    };
    final speed = switch (dot.speed) {
      DotSpeed.fast => ', faster',
      DotSpeed.slow => ', slower',
      DotSpeed.even || null => '',
    };
    return 'Question $number: $outcome$speed';
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final (i, dot) in dots.indexed)
          Semantics(
            label: describe(i + 1, dot),
            excludeSemantics: true,
            child: _Dot(dot: dot, size: size),
          ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.dot, required this.size});

  final ResultDot dot;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (background, foreground, icon) = switch (dot.outcome) {
      DotOutcome.right => (colors.mint.container, colors.mint.onContainer, AppIcons.check),
      DotOutcome.wrong => (colors.rose.container, colors.rose.onContainer, AppIcons.close),
      DotOutcome.missed => (colors.surfaceSunken, colors.inkMuted, AppIcons.minus),
      DotOutcome.unknown => (colors.surfaceMuted, colors.inkSubtle, null),
    };
    final badge = switch (dot.speed) {
      DotSpeed.fast => (colors.accent, colors.onAccent, AppIcons.flash),
      DotSpeed.slow => (colors.surfaceSunken, colors.inkMuted, AppIcons.hourglass),
      DotSpeed.even || null => null,
    };
    final badgeSize = size * 0.5;
    return SizedBox.square(
      dimension: size + badgeSize * 0.3,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            bottom: 0,
            child: Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: background,
                shape: BoxShape.circle,
                border: dot.outcome == DotOutcome.unknown
                    ? Border.all(color: colors.outlineStrong)
                    : null,
              ),
              child: icon == null
                  ? null
                  : HugeIcon(icon, size: size * 0.5, color: foreground, strokeWidth: 2.2),
            ),
          ),
          if (badge case (final fill, final ink, final symbol))
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                width: badgeSize,
                height: badgeSize,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: fill,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.surface, width: 1.5),
                ),
                child: HugeIcon(symbol, size: badgeSize * 0.62, color: ink, strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }
}
