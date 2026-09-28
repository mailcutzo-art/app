import 'dart:math' as math;

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'arena_painters.dart';

/// The welcome screen's "Quiz Battle Arena": a floating two-tier arena with a
/// trophy shield on it and a few study objects hovering around, in three
/// depth layers (backdrop, floating objects, arena and emblem).
///
/// Motion is deliberately small. On first show the arena settles in
/// (0.96 → 1) and the objects arrive one after another; then only four things
/// move: a cloud drifts, the book floats, the shield breathes and one sparkle
/// twinkles now and then. The idle motion plays for [idleCycles] rounds of
/// [idlePeriod] and comes to rest in its starting pose, so a player who leaves
/// the phone on this screen doesn't pay for animation frames forever.
///
/// Everything runs off two controllers owned here, ticking only while
/// [TickerMode] is on (the route is visible) and skipped entirely when the OS
/// asks for reduced motion. Each object is its own [RepaintBoundary]: its
/// picture is recorded once and the animations only move composited layers.
class ArenaHero extends StatefulWidget {
  const ArenaHero({super.key});

  /// Height over width of the artwork.
  static const aspectRatio = 0.84;

  static const entranceDuration = Duration(milliseconds: 1100);
  static const idlePeriod = Duration(seconds: 6);
  static const idleCycles = 4;

  @override
  State<ArenaHero> createState() => _ArenaHeroState();
}

class _ArenaHeroState extends State<ArenaHero> with TickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: ArenaHero.entranceDuration,
  )..addStatusListener(_entranceStatus);

  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: ArenaHero.idlePeriod * ArenaHero.idleCycles,
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      // Straight to the resting composition, no ticking at all.
      _entrance.value = 1;
      _idle
        ..stop()
        ..value = 0;
    } else if (!_started) {
      _entrance.forward();
    }
    _started = true;
  }

  void _entranceStatus(AnimationStatus status) {
    if (status.isCompleted && mounted && !AppMotion.reduced(context)) _idle.forward(from: 0);
  }

  @override
  void dispose() {
    _entrance.dispose();
    _idle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = math.min(
            constraints.maxWidth,
            constraints.maxHeight / ArenaHero.aspectRatio,
          );
          return Center(
            child: SizedBox(
              width: width,
              height: width * ArenaHero.aspectRatio,
              child: _Stage(width: width, colors: colors, entrance: _entrance, idle: _idle),
            ),
          );
        },
      ),
    );
  }
}

/// Lays the layers out on a [width]-wide stage. Built once per size; the
/// animations below only touch their own transitions.
class _Stage extends StatelessWidget {
  const _Stage({
    required this.width,
    required this.colors,
    required this.entrance,
    required this.idle,
  });

  final double width;
  final AppColors colors;
  final Animation<double> entrance;
  final Animation<double> idle;

  /// A rect on the stage, in fractions of its width on both axes.
  Rect _at(double left, double top, double w, double h) =>
      Rect.fromLTWH(left * width, top * width, w * width, h * width);

  @override
  Widget build(BuildContext context) {
    Animation<double> part(double begin, double end, [Curve curve = AppMotion.standard]) =>
        entrance.drive(CurveTween(curve: Interval(begin, end, curve: curve)));

    FloatingArenaObject object(
      Rect rect, {
      required double begin,
      IdleMotion? motion,
      double tilt = 0,
      required Widget child,
    }) => FloatingArenaObject(
      rect: rect,
      entrance: part(begin, begin + 0.4),
      idle: idle,
      motion: motion,
      tilt: tilt,
      child: child,
    );

    final arena = part(0, 0.75, Curves.easeOutBack);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Background layer.
        Positioned.fill(
          child: FadeTransition(
            opacity: part(0, 0.45),
            child: RepaintBoundary(child: CustomPaint(painter: ArenaBackdropPainter(colors))),
          ),
        ),
        object(
          _at(0.02, 0.06, 0.24, 0.09),
          begin: 0.1,
          motion: IdleMotion.drift,
          child: CustomPaint(painter: CloudPainter(colors)),
        ),
        object(
          _at(0.76, 0.6, 0.18, 0.07),
          begin: 0.15,
          child: CustomPaint(painter: CloudPainter(colors)),
        ),
        // Foreground: the arena and its emblem settle in together.
        Positioned.fill(
          child: FadeTransition(
            opacity: part(0, 0.4),
            child: ScaleTransition(
              scale: arena.drive(Tween(begin: 0.96, end: 1)),
              alignment: const Alignment(0, 0.4),
              child: Stack(
                children: [
                  Positioned.fromRect(
                    rect: _at(0.1, 0.52, 0.8, 0.3),
                    child: RepaintBoundary(
                      child: CustomPaint(painter: ArenaPlatformPainter(colors)),
                    ),
                  ),
                  FloatingArenaObject(
                    rect: _at(0.315, 0.16, 0.37, 0.46),
                    idle: idle,
                    motion: IdleMotion.breathe,
                    child: CustomPaint(painter: BattleShieldPainter(colors)),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Middle layer: the study objects around the arena.
        object(
          _at(0.04, 0.37, 0.23, 0.155),
          begin: 0.25,
          motion: IdleMotion.float,
          tilt: -0.12,
          child: CustomPaint(painter: FloatingBookPainter(colors)),
        ),
        object(
          _at(0.74, 0.09, 0.17, 0.21),
          begin: 0.32,
          tilt: 0.16,
          child: _QuestionCard(colors: colors, height: 0.21 * width),
        ),
        object(
          _at(0.19, 0.1, 0.085, 0.13),
          begin: 0.38,
          tilt: -0.18,
          child: CustomPaint(painter: LightningPainter(colors)),
        ),
        object(_at(0.79, 0.4, 0.12, 0.12), begin: 0.44, child: _AtomBadge(colors: colors)),
        object(
          _at(0.64, 0.05, 0.055, 0.055),
          begin: 0.5,
          motion: IdleMotion.twinkle,
          child: CustomPaint(painter: SparklePainter(colors.lemon.onContainer)),
        ),
        object(
          _at(0.1, 0.27, 0.035, 0.035),
          begin: 0.55,
          child: CustomPaint(painter: SparklePainter(colors.mint.onContainer)),
        ),
        object(
          _at(0.71, 0.33, 0.03, 0.03),
          begin: 0.58,
          child: CustomPaint(painter: SparklePainter(colors.sky.onContainer)),
        ),
      ],
    );
  }
}

/// The few idle motions the arena uses, as a function of the time [t] (in
/// seconds) since the idle loop began. Every motion is zero at the start and
/// end of each [ArenaHero.idlePeriod], so the loop ends where it began.
enum IdleMotion {
  /// Slow horizontal drift of ±4 px over two periods.
  drift,

  /// Vertical float of ±5 px.
  float,

  /// Breathing scale, 1.0 → 1.015 → 1.0 twice a period.
  breathe,

  /// A short scale-and-brighten pulse once a period.
  twinkle;

  static final double _period = ArenaHero.idlePeriod.inMilliseconds / 1000;

  Widget apply(double t, Widget child) {
    final phase = (t % _period) / _period;
    switch (this) {
      case drift:
        return Transform.translate(
          offset: Offset(4 * math.sin(math.pi * t / _period), 0),
          child: child,
        );
      case float:
        return Transform.translate(
          offset: Offset(0, -5 * math.sin(2 * math.pi * phase)),
          child: child,
        );
      case breathe:
        return Transform.scale(
          scale: 1 + 0.0075 * (1 - math.cos(4 * math.pi * phase)),
          alignment: Alignment.bottomCenter,
          child: child,
        );
      case twinkle:
        // Rests for most of the period, pulses between 40% and 60% of it.
        final pulse = phase < 0.4 || phase > 0.6 ? 0.0 : math.sin(math.pi * (phase - 0.4) / 0.2);
        return Opacity(
          opacity: 0.7 + 0.3 * pulse,
          child: Transform.scale(scale: 1 + 0.35 * pulse, child: child),
        );
    }
  }
}

/// One object on the stage: arrives with a fade and a small scale-up during
/// its slice of the [entrance], then optionally plays an [IdleMotion] off
/// [idle]. The artwork itself is a [RepaintBoundary] that never repaints.
class FloatingArenaObject extends StatelessWidget {
  const FloatingArenaObject({
    super.key,
    required this.rect,
    required this.idle,
    required this.child,
    this.entrance,
    this.motion,
    this.tilt = 0,
  });

  final Rect rect;
  final Animation<double>? entrance;
  final Animation<double> idle;
  final IdleMotion? motion;

  /// A fixed rotation in radians, so the objects don't all sit square.
  final double tilt;
  final Widget child;

  static final double _idleSeconds =
      (ArenaHero.idlePeriod * ArenaHero.idleCycles).inMilliseconds / 1000;

  @override
  Widget build(BuildContext context) {
    Widget object = RepaintBoundary(child: child);
    if (tilt != 0) object = Transform.rotate(angle: tilt, child: object);
    final motion = this.motion;
    if (motion != null) {
      object = AnimatedBuilder(
        animation: idle,
        builder: (_, child) => motion.apply(idle.value * _idleSeconds, child!),
        child: object,
      );
    }
    final entrance = this.entrance;
    if (entrance != null) {
      object = FadeTransition(
        opacity: entrance,
        child: ScaleTransition(scale: entrance.drive(Tween(begin: 0.85, end: 1)), child: object),
      );
    }
    return Positioned.fromRect(rect: rect, child: object);
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({required this.colors, required this.height});

  final AppColors colors;
  final double height;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: QuestionCardPainter(colors),
      child: Padding(
        padding: EdgeInsets.only(bottom: height * QuestionCardPainter.depthFactor),
        child: Center(
          child: Text(
            '?',
            // Artwork, not copy: it scales with the stage, not the text size.
            textScaler: TextScaler.noScaling,
            style: context.text.display.copyWith(
              fontSize: height * 0.58,
              height: 1,
              color: colors.paper,
            ),
          ),
        ),
      ),
    );
  }
}

class _AtomBadge extends StatelessWidget {
  const _AtomBadge({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final mint = colors.mint;
    return LayoutBuilder(
      builder: (context, box) => DecoratedBox(
        decoration: BoxDecoration(
          color: mint.container,
          shape: BoxShape.circle,
          border: Border.all(color: mint.onContainer.withValues(alpha: 0.55), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Color.lerp(mint.container, colors.shadow, 0.6)!,
              offset: Offset(0, box.maxWidth * 0.07),
            ),
          ],
        ),
        child: Center(
          child: HugeIcon(AppIcons.chemistry, size: box.maxWidth * 0.52, color: mint.onContainer),
        ),
      ),
    );
  }
}
