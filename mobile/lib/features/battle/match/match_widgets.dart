import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:realtime_client/realtime_client.dart' hide AnswerOption;

import '../../../core/auth/user.dart';
import '../../../core/realtime/live_providers.dart';
import '../../../core/realtime/realtime_providers.dart';

/// Server time now, from the synced clock (the device clock if there's no connection).
int serverNowOf(WidgetRef ref) =>
    ref.read(realtimeConnectionProvider)?.serverClock.nowServerMs() ??
    clock.now().millisecondsSinceEpoch;

/// A player's avatar from their card. The Practice Bot is always the robot.
AvatarData avatarOf(PlayerCard? card) {
  if (card == null) return const AvatarData(tone: PastelTone.neutral, symbol: AppIcons.user);
  if (card.isBot) return const AvatarData(tone: PastelTone.lavender, symbol: AppIcons.robot);
  final avatar = card.avatar;
  final tone = PastelTone.values.where((t) => t.name == avatar?.tone).firstOrNull;
  final symbol = Avatar.symbols[avatar?.symbol];
  if (tone == null || symbol == null) {
    return AvatarData(
      tone: tone ?? PastelTone.sky,
      initials: (card.displayName ?? card.handle ?? '?').characters.first,
    );
  }
  return AvatarData(tone: tone, symbol: symbol);
}

/// The reactions of the emote bar, in order.
const battleEmotes = [
  EmoteOption(id: 'gg', label: 'GG'),
  EmoteOption(id: 'nice', label: 'Nice!'),
  EmoteOption(id: 'wow', label: 'Wow'),
  EmoteOption(id: 'oops', label: 'Oops'),
];

String emoteLabel(String id) =>
    battleEmotes.where((e) => e.id == id).firstOrNull?.label ?? id.toUpperCase();

/// The countdown ring of an open question, driven by the synced clock. Only the ring repaints
/// on each tick: once a frame normally, once a second with reduced motion.
class QuestionRing extends ConsumerStatefulWidget {
  const QuestionRing({
    super.key,
    required this.deadlineAt,
    required this.limitMs,
    this.size = AppSizes.iconButton,
  });

  final int deadlineAt;
  final int limitMs;
  final double size;

  @override
  ConsumerState<QuestionRing> createState() => _QuestionRingState();
}

class _QuestionRingState extends ConsumerState<QuestionRing> with TickerProviderStateMixin {
  Ticker? _ticker;
  Timer? _timer;
  late int _remainingMs = _remaining();

  int _remaining() => math.max(0, widget.deadlineAt - serverNowOf(ref));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restart();
  }

  @override
  void didUpdateWidget(covariant QuestionRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deadlineAt != widget.deadlineAt) _restart();
  }

  void _restart() {
    _ticker?.dispose();
    _ticker = null;
    _timer?.cancel();
    _timer = null;
    _remainingMs = _remaining();
    if (_remainingMs <= 0) return;
    if (AppMotion.reduced(context)) {
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
    } else {
      _ticker = createTicker((_) => _tick())..start();
    }
  }

  void _tick() {
    if (!mounted) return;
    final remaining = _remaining();
    final reduced = _timer != null;
    // With reduced motion the ring moves in whole seconds.
    final changed = reduced
        ? (remaining / 1000).ceil() != (_remainingMs / 1000).ceil()
        : remaining != _remainingMs;
    if (changed) setState(() => _remainingMs = remaining);
    if (remaining <= 0) {
      _ticker?.stop();
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = (_remainingMs / 1000).ceil();
    final reduced = AppMotion.reduced(context);
    final progress = widget.limitMs <= 0
        ? 0.0
        : (reduced ? seconds * 1000 / widget.limitMs : _remainingMs / widget.limitMs);
    return RepaintBoundary(
      child: CountdownRing(progress: progress, label: '$seconds', size: widget.size),
    );
  }
}

/// The 3-2-1 before the first question, from the server's `ends_at`.
class CountdownDigits extends ConsumerStatefulWidget {
  const CountdownDigits({super.key, required this.endsAt});

  final int endsAt;

  @override
  ConsumerState<CountdownDigits> createState() => _CountdownDigitsState();
}

class _CountdownDigitsState extends ConsumerState<CountdownDigits> {
  Timer? _timer;
  late int _n = _digit();

  int _digit() => ((widget.endsAt - serverNowOf(ref)) / 1000).ceil().clamp(0, 3);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      final n = _digit();
      if (n != _n) setState(() => _n = n);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final reduced = AppMotion.reduced(context);
    final label = _n <= 0 ? 'Go!' : '$_n';
    return Semantics(
      liveRegion: true,
      label: _n <= 0 ? 'Go' : 'Starting in $_n',
      excludeSemantics: true,
      child: AnimatedSwitcher(
        duration: AppMotion.of(context, AppMotion.medium),
        transitionBuilder: (child, animation) => reduced
            ? FadeTransition(opacity: animation, child: child)
            : ScaleTransition(
                scale: Tween<double>(
                  begin: 1.6,
                  end: 1,
                ).animate(CurvedAnimation(parent: animation, curve: AppMotion.emphasized)),
                child: FadeTransition(opacity: animation, child: child),
              ),
        child: Text(
          label,
          key: ValueKey(label),
          style: text.numericDisplay.copyWith(fontSize: 112, height: 1.1),
        ),
      ),
    );
  }
}

/// "Riya is reconnecting… 23 s", counting down to the end of their grace period.
class OpponentReconnecting extends ConsumerStatefulWidget {
  const OpponentReconnecting({super.key, required this.name, this.graceUntil});

  final String name;
  final int? graceUntil;

  @override
  ConsumerState<OpponentReconnecting> createState() => _OpponentReconnectingState();
}

class _OpponentReconnectingState extends ConsumerState<OpponentReconnecting> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final graceUntil = widget.graceUntil;
    final seconds = graceUntil == null
        ? null
        : ((graceUntil - serverNowOf(ref)) / 1000).ceil().clamp(0, 999);
    final label = seconds == null
        ? '${widget.name} is reconnecting…'
        : '${widget.name} is reconnecting… $seconds s';
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.warningContainer,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Row(
          children: [
            HugeIcon(AppIcons.offline, size: 18, color: colors.onWarningContainer),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: context.text.labelMedium.copyWith(color: colors.onWarningContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Reconnecting…" over the match while this device's connection is down. The game goes on;
/// answers wait in the outbox and are sent on reconnect. Taps pass through.
class ReconnectingOverlay extends ConsumerWidget {
  const ReconnectingOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(realtimeStateProvider).value;
    final down = state is Backoff || state is Connecting || state is Ticketing;
    final colors = context.colors;
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: AppMotion.of(context, AppMotion.medium),
        child: !down
            ? const SizedBox.shrink()
            : Align(
                key: const ValueKey('reconnecting'),
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                        vertical: AppSpacing.sm,
                      ),
                      decoration: BoxDecoration(
                        color: colors.inverse,
                        borderRadius: AppRadii.pillAll,
                        boxShadow: AppShadows.floating(colors),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.onInverse,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Text(
                            'Reconnecting… your answers are safe',
                            style: context.text.labelMedium.copyWith(color: colors.onInverse),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// Shows each reaction as a bubble by the player who sent it, for 2 s.
class EmoteLayer extends ConsumerStatefulWidget {
  const EmoteLayer({super.key, required this.matchId, required this.me, required this.child});

  final String matchId;
  final String me;
  final Widget child;

  @override
  ConsumerState<EmoteLayer> createState() => _EmoteLayerState();
}

class _EmoteLayerState extends ConsumerState<EmoteLayer> {
  EmoteState? _shown;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _show(EmoteState? emote) {
    if (emote == null || emote.serial == _shown?.serial) return;
    _hide?.cancel();
    setState(() => _shown = emote);
    _hide = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _shown = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      matchViewProvider(widget.matchId).select((v) => v?.state.lastEmote),
      (_, emote) => _show(emote),
    );
    final shown = _shown;
    final mine = shown?.uid == widget.me;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        if (shown != null)
          Positioned(
            top: -18,
            left: mine ? AppSpacing.md : null,
            right: mine ? null : AppSpacing.md,
            child: EmoteBubble(
              key: ValueKey(shown.serial),
              label: emoteLabel(shown.emote),
              pointsLeft: mine,
            ),
          ),
      ],
    );
  }
}
