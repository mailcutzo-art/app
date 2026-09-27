import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../router.dart';
import 'live_hub.dart';

/// Sits above every screen (installed through `MaterialApp.router.builder`):
/// the status pill ("Searching · 0:32") and one live alert at a time, either a
/// banner or a full-screen takeover. Nothing time-critical can be missed
/// because the user happens to be on another tab.
class LiveLayer extends ConsumerStatefulWidget {
  const LiveLayer({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LiveLayer> createState() => _LiveLayerState();
}

class _LiveLayerState extends ConsumerState<LiveLayer> {
  Timer? _ticker;
  Timer? _autoRun;
  String? _autoRunFor;
  bool _busy = false;

  @override
  void dispose() {
    _ticker?.cancel();
    _autoRun?.cancel();
    super.dispose();
  }

  /// Ticks once a second while anything on screen counts.
  void _syncTicker(LiveState state) {
    final counting = state.status?.since != null || state.visible?.expiresAt != null;
    if (counting && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    } else if (!counting) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _onTick() {
    final alert = ref.read(liveHubProvider).visible;
    final expiresAt = alert?.expiresAt;
    if (alert != null && expiresAt != null && !ref.read(liveClockProvider)().isBefore(expiresAt)) {
      ref.read(liveHubProvider.notifier).dismiss(alert.id);
    }
    if (mounted) setState(() {});
  }

  void _syncAutoRun(LiveAlert? alert) {
    if (alert?.id == _autoRunFor) return;
    _autoRun?.cancel();
    _autoRunFor = alert?.id;
    final delay = alert?.autoRunAfter;
    final action = alert?.primary;
    if (alert != null && delay != null && action != null) {
      _autoRun = Timer(delay, () => _run(alert, action));
    }
  }

  Future<void> _run(LiveAlert alert, LiveAction action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action.run?.call();
      final route = action.route;
      if (route != null) ref.read(routerProvider).go(route);
      ref.read(liveHubProvider.notifier).dismiss(alert.id);
    } on Object catch (error) {
      if (mounted) {
        showAppToast(context, 'That didn\'t work. Please try again.', icon: AppIcons.alert);
      }
      debugPrint('Live action failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(liveHubProvider);
    final alert = state.visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncTicker(state);
      _syncAutoRun(alert);
    });
    final now = ref.read(liveClockProvider)();
    final reduced = AppMotion.reduced(context);
    final duration = AppMotion.of(context, AppMotion.medium);

    return Stack(
      children: [
        widget.child,
        if (state.status case final status?)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Align(
                alignment: Alignment.topCenter,
                child: _StatusPill(
                  status: status,
                  now: now,
                  onTap: status.route == null
                      ? null
                      : () => ref.read(routerProvider).go(status.route!),
                ),
              ),
            ),
          ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: AnimatedSwitcher(
              duration: duration,
              transitionBuilder: (child, animation) => reduced
                  ? FadeTransition(opacity: animation, child: child)
                  : SlideTransition(
                      position: Tween(
                        begin: const Offset(0, -1),
                        end: Offset.zero,
                      ).animate(CurvedAnimation(parent: animation, curve: AppMotion.emphasized)),
                      child: child,
                    ),
              child: alert != null && alert.style == AlertStyle.banner
                  ? _Banner(
                      key: ValueKey(alert.id),
                      alert: alert,
                      now: now,
                      busy: _busy,
                      onAction: (action) => _run(alert, action),
                      onClose: () => ref.read(liveHubProvider.notifier).dismiss(alert.id),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
        if (alert != null && alert.style == AlertStyle.takeover)
          Positioned.fill(
            child: _Takeover(
              key: ValueKey(alert.id),
              alert: alert,
              now: now,
              busy: _busy,
              onAction: (action) => _run(alert, action),
            ),
          ),
      ],
    );
  }
}

String _mmss(Duration d) {
  final seconds = d.inSeconds.clamp(0, 99 * 60 + 59);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status, required this.now, this.onTap});

  final LiveStatus status;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final since = status.since;
    final label = since == null
        ? status.label
        : '${status.label} · ${_mmss(now.difference(since))}';
    // Not a live region: it ticks every second and would flood screen readers.
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Pressable(
        onPressed: onTap,
        semanticLabel: label,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: colors.inverse,
            borderRadius: AppRadii.pillAll,
            boxShadow: AppShadows.floating(colors),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              HugeIcon(status.icon, size: 16, color: colors.accent),
              const SizedBox(width: AppSpacing.sm),
              Text(
                label,
                style: context.text.labelMedium.copyWith(
                  color: colors.onInverse,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.alert,
    required this.now,
    required this.busy,
    required this.onAction,
    required this.onClose,
  });

  final LiveAlert alert;
  final DateTime now;
  final bool busy;
  final ValueChanged<LiveAction> onAction;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pair = colors.pastel(alert.tone);
    final expiresAt = alert.expiresAt;
    final message = [
      ?alert.message,
      if (expiresAt != null) 'Expires in ${_mmss(expiresAt.difference(now))}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.sm, AppSpacing.gutter, 0),
      child: Semantics(
        liveRegion: true,
        container: true,
        child: Material(
          color: Colors.transparent,
          child: SurfaceCard(
            elevated: true,
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: HugeIcon(alert.icon, size: 20, color: pair.onContainer),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(alert.title, style: context.text.titleMedium),
                          if (message.isNotEmpty) Text(message, style: context.text.bodySmall),
                        ],
                      ),
                    ),
                    AppIconButton(
                      icon: AppIcons.close,
                      size: AppSizes.iconButtonSmall,
                      semanticLabel: 'Dismiss',
                      onPressed: onClose,
                    ),
                  ],
                ),
                if (alert.primary != null || alert.secondary != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: [
                      if (alert.secondary case final secondary?) ...[
                        Expanded(
                          child: AppButton(
                            label: secondary.label,
                            size: AppButtonSize.small,
                            variant: AppButtonVariant.secondary,
                            onPressed: busy ? null : () => onAction(secondary),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                      ],
                      if (alert.primary case final primary?)
                        Expanded(
                          child: AppButton(
                            label: primary.label,
                            size: AppButtonSize.small,
                            loading: busy,
                            onPressed: () => onAction(primary),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Takeover extends StatelessWidget {
  const _Takeover({
    super.key,
    required this.alert,
    required this.now,
    required this.busy,
    required this.onAction,
  });

  final LiveAlert alert;
  final DateTime now;
  final bool busy;
  final ValueChanged<LiveAction> onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pair = colors.pastel(alert.tone);
    final expiresAt = alert.expiresAt;
    return Material(
      color: colors.inverse.withValues(alpha: 0.72),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            child: Semantics(
              liveRegion: true,
              container: true,
              child: SurfaceCard(
                elevated: true,
                padding: const EdgeInsets.all(AppSpacing.xxl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: HugeIcon(alert.icon, size: 34, color: pair.onContainer),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      alert.title,
                      style: context.text.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (alert.message case final message?) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(message, style: context.text.bodyLarge, textAlign: TextAlign.center),
                    ],
                    if (expiresAt != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(_mmss(expiresAt.difference(now)), style: context.text.numericLarge),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    if (alert.primary case final primary?)
                      AppButton(
                        label: primary.label,
                        loading: busy,
                        onPressed: () => onAction(primary),
                      ),
                    if (alert.secondary case final secondary?) ...[
                      const SizedBox(height: AppSpacing.sm),
                      AppButton(
                        label: secondary.label,
                        variant: AppButtonVariant.ghost,
                        onPressed: busy ? null : () => onAction(secondary),
                      ),
                    ],
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
