import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../icons/huge_icon.dart';
import '../icons/icon_motion.dart';
import '../theme/app_theme.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_motion.dart';
import 'avatar.dart';
import 'chips.dart';
import 'numbers.dart';
import 'pressable.dart';
import 'quiz_text.dart';

/// Question stem card: "QUESTION 3 / 7", an optional chapter tag, the rich
/// question text, then an optional [figure] (see [QuestionFigure]).
///
/// Stems may span several lines (statement, assertion–reason and match
/// questions), so the card grows with its text; put it in a scroll view.
class QuestionCard extends StatelessWidget {
  const QuestionCard({
    super.key,
    required this.number,
    required this.total,
    required this.text,
    this.tag,
    this.tone = PastelTone.sky,
    this.figure,
  });

  final int number;
  final int total;
  final String text;
  final String? tag;
  final PastelTone tone;

  /// Drawn below the stem, e.g. a [QuestionFigure].
  final Widget? figure;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.xxl),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.xxl)),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OverlineBadge(label: 'Question $number / $total', solid: true),
              if (tag != null) ...[
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: OverlineBadge(label: tag!, tone: tone),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          QuizText(
            text,
            style: context.text.titleLarge.copyWith(
              fontSize: 18,
              height: 25 / 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (figure != null) ...[const SizedBox(height: AppSpacing.lg), figure!],
        ],
      ),
    );
  }
}

/// The figure a question refers to. Shows [image] when there is one; until
/// artwork exists it shows the question's diagram [description] as a labelled
/// panel so the question stays answerable.
class QuestionFigure extends StatelessWidget {
  const QuestionFigure({super.key, required this.description, this.image})
    : assert(description != '' || image != null);

  /// What the figure shows, in quiz markup.
  final String description;

  /// The drawn figure, e.g. an `SvgPicture` or `Image`.
  final Widget? image;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    if (image != null) {
      return Semantics(
        image: true,
        label: description,
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(AppRadii.md)),
          child: image,
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.md)),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const OverlineBadge(label: 'Figure'),
          const SizedBox(height: AppSpacing.sm),
          QuizText(description, style: text.bodyMedium.copyWith(color: colors.inkMuted)),
        ],
      ),
    );
  }
}

/// The worked explanation shown after answering, with the formula used (if
/// any) set apart underneath.
class ExplanationCard extends StatelessWidget {
  const ExplanationCard({super.key, required this.text, this.formula, this.correct});

  /// Explanation in quiz markup.
  final String text;

  /// Formula in quiz markup, e.g. `v^2 = u^2 + 2as`.
  final String? formula;

  /// Whether the player got it right; tints the header. Null for a neutral card.
  final bool? correct;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.text;
    final tone = switch (correct) {
      true => PastelTone.mint,
      false => PastelTone.rose,
      null => PastelTone.neutral,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppRadii.card,
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OverlineBadge(label: 'Explanation', tone: tone),
          const SizedBox(height: AppSpacing.md),
          QuizText(text, style: type.bodyLarge),
          if (formula != null && formula!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: const BorderRadius.all(Radius.circular(AppRadii.xs)),
              ),
              child: QuizText(
                formula!,
                style: type.bodyMedium.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum AnswerOptionState { idle, selected, correct, wrong, dimmed }

/// A large tappable answer. Reveals correct/wrong with color, an animated
/// icon, and a short shake for wrong answers.
class AnswerOption extends StatefulWidget {
  const AnswerOption({
    super.key,
    required this.index,
    required this.text,
    this.state = AnswerOptionState.idle,
    this.onTap,
    this.opponent,
  });

  /// 0-based; shown as A, B, C, D.
  final int index;
  final String text;
  final AnswerOptionState state;
  final VoidCallback? onTap;

  /// Shown when the opponent picked this option (after the reveal).
  final AvatarData? opponent;

  @override
  State<AnswerOption> createState() => _AnswerOptionState();
}

class _AnswerOptionState extends State<AnswerOption> with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void didUpdateWidget(covariant AnswerOption oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state == AnswerOptionState.wrong &&
        oldWidget.state != AnswerOptionState.wrong &&
        !AppMotion.reduced(context)) {
      _shake.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final letter = String.fromCharCode(65 + widget.index);
    final duration = AppMotion.of(context, AppMotion.medium);

    final (bg, border, borderWidth) = switch (widget.state) {
      AnswerOptionState.idle => (colors.surface, colors.outline, 1.5),
      AnswerOptionState.selected => (colors.accentSoft, colors.ink, 2.0),
      AnswerOptionState.correct => (colors.mint.container, colors.mint.onContainer, 2.0),
      AnswerOptionState.wrong => (colors.rose.container, colors.rose.onContainer, 2.0),
      AnswerOptionState.dimmed => (colors.surface, colors.outline, 1.5),
    };

    final Widget marker = switch (widget.state) {
      AnswerOptionState.correct => _MarkerCircle(
        color: colors.success,
        child: const AnimatedHugeIcon(
          AppIcons.check,
          motion: IconMotions.check,
          autoplay: true,
          size: 20,
          color: Color(0xFFFFFFFF),
          strokeWidth: 2.2,
        ),
      ),
      AnswerOptionState.wrong => _MarkerCircle(
        color: colors.error,
        child: const HugeIcon(AppIcons.close, size: 20, color: Color(0xFFFFFFFF), strokeWidth: 2.2),
      ),
      AnswerOptionState.selected => _MarkerCircle(
        color: colors.inverse,
        child: Text(letter, style: text.labelLarge.copyWith(color: colors.onInverse)),
      ),
      _ => _MarkerCircle(
        color: colors.surfaceMuted,
        child: Text(letter, style: text.labelLarge),
      ),
    };

    final content = AnimatedContainer(
      duration: duration,
      curve: AppMotion.standard,
      constraints: const BoxConstraints(minHeight: AppSizes.answerOptionMin),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: border, width: borderWidth),
      ),
      child: Row(
        children: [
          AnimatedSwitcher(
            duration: duration,
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: CurvedAnimation(parent: animation, curve: AppMotion.bouncy),
              child: child,
            ),
            child: KeyedSubtree(key: ValueKey(widget.state), child: marker),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: QuizText(
              widget.text,
              style: text.bodyLarge.copyWith(fontWeight: FontWeight.w600, height: 1.35),
            ),
          ),
          if (widget.opponent != null) ...[
            const SizedBox(width: AppSpacing.sm),
            AppAvatar(data: widget.opponent!, size: 28, semanticLabel: 'Opponent picked this'),
          ],
        ],
      ),
    );

    return AnimatedOpacity(
      duration: duration,
      opacity: widget.state == AnswerOptionState.dimmed ? 0.45 : 1,
      child: AnimatedBuilder(
        animation: _shake,
        builder: (context, child) {
          final t = _shake.value;
          final dx = math.sin(t * math.pi * 6) * 7 * (1 - t);
          return Transform.translate(offset: Offset(dx, 0), child: child);
        },
        child: Pressable(
          onPressed: widget.onTap,
          semanticLabel: 'Option $letter',
          pressedScale: 0.98,
          haptic: HapticKind.light,
          selected: widget.state == AnswerOptionState.selected,
          child: content,
        ),
      ),
    );
  }
}

class _MarkerCircle extends StatelessWidget {
  const _MarkerCircle({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: child,
    );
  }
}

@immutable
class VersusPlayer {
  const VersusPlayer({
    required this.name,
    required this.avatar,
    required this.score,
    this.answered = false,
  });

  final String name;
  final AvatarData avatar;
  final int score;

  /// Whether this player has answered the current question (never *what*).
  final bool answered;
}

/// Battle header: both players with live scores and question progress.
class VersusHeader extends StatelessWidget {
  const VersusHeader({
    super.key,
    required this.me,
    required this.opponent,
    required this.questionNumber,
    required this.total,
  });

  final VersusPlayer me;
  final VersusPlayer opponent;
  final int questionNumber;
  final int total;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.xxl)),
        border: Border.all(color: colors.outline),
      ),
      child: Row(
        children: [
          Expanded(child: _PlayerSide(player: me, alignEnd: false)),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Q$questionNumber', style: text.numericMedium),
              Text('of $total', style: text.caption),
            ],
          ),
          Expanded(child: _PlayerSide(player: opponent, alignEnd: true)),
        ],
      ),
    );
  }
}

class _PlayerSide extends StatelessWidget {
  const _PlayerSide({required this.player, required this.alignEnd});

  final VersusPlayer player;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final avatar = Stack(
      clipBehavior: Clip.none,
      children: [
        AppAvatar(data: player.avatar, ring: player.answered),
        if (player.answered)
          Positioned(
            bottom: -2,
            right: -2,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: colors.ink,
                shape: BoxShape.circle,
                border: Border.all(color: colors.surface, width: 2),
              ),
              alignment: Alignment.center,
              child: HugeIcon(AppIcons.check, size: 10, color: colors.onInverse, strokeWidth: 2.4),
            ),
          ),
      ],
    );
    final info = Column(
      crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(player.name, style: text.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
        NumberTicker(value: player.score, style: text.numericLarge.copyWith(fontSize: 22)),
      ],
    );
    return Row(
      mainAxisAlignment: alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: alignEnd
          ? [Flexible(child: info), const SizedBox(width: AppSpacing.sm), avatar]
          : [avatar, const SizedBox(width: AppSpacing.sm), Flexible(child: info)],
    );
  }
}

/// Matchmaking radar: rings pulse out from the player's avatar.
class SearchingPulse extends StatefulWidget {
  const SearchingPulse({super.key, required this.child, this.size = 240, this.color});

  final Widget child;
  final double size;
  final Color? color;

  @override
  State<SearchingPulse> createState() => _SearchingPulseState();
}

class _SearchingPulseState extends State<SearchingPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _controller
        ..stop()
        ..value = 0.5;
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
    final color = widget.color ?? context.colors.accent;
    return SizedBox.square(
      dimension: widget.size,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _PulsePainter(animation: _controller, color: color),
          child: Center(child: widget.child),
        ),
      ),
    );
  }
}

class _PulsePainter extends CustomPainter {
  _PulsePainter({required this.animation, required this.color}) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;
    final minRadius = maxRadius * 0.3;
    for (var i = 0; i < 3; i++) {
      final t = (animation.value + i / 3) % 1;
      final radius = minRadius + (maxRadius - minRadius) * Curves.easeOut.transform(t);
      final paint = Paint()..color = color.withValues(alpha: 0.55 * (1 - t));
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PulsePainter old) => old.color != color;
}
