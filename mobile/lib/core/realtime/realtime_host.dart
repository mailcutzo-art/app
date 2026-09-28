import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/live/live_hub.dart';
import '../../app/router.dart';
import '../auth/session.dart';
import 'live_controller.dart';
import 'live_providers.dart';

/// Keeps the always-on realtime connection going while someone is signed in, and tells it when
/// the app goes to the background and comes back. Sits above every screen (installed through
/// `MaterialApp.router.builder`).
class RealtimeHost extends ConsumerStatefulWidget {
  const RealtimeHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<RealtimeHost> createState() => _RealtimeHostState();
}

class _RealtimeHostState extends ConsumerState<RealtimeHost> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    final initial = SchedulerBinding.instance.lifecycleState;
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onLifecycle(initial);
      });
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// The notification shade or the app switcher (`inactive`) still counts as the foreground: a
  /// quick look shouldn't stop a search.
  void _onLifecycle(AppLifecycleState state) {
    final foreground = switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => false,
    };
    ref.read(appForegroundProvider.notifier).set(foreground);
  }

  /// A different user (or nobody) now: the old live pill and alerts go.
  void _clearLiveLayer() {
    if (!mounted) return;
    final hub = ref.read(liveHubProvider.notifier);
    final state = ref.read(liveHubProvider);
    for (final alert in state.alerts) {
      if (alert.id.startsWith(LiveAlertIds.prefix)) hub.dismiss(alert.id);
    }
    final route = state.status?.route;
    // The "Searching" and "Tournament live" pills.
    if (route == Routes.battleSearch || (route?.startsWith('${Routes.arena}/') ?? false)) {
      hub.setStatus(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref
      ..watch(liveControllerProvider)
      ..listen(currentUserIdProvider, (previous, next) {
        if (previous != next) scheduleMicrotask(_clearLiveLayer);
      });
    return widget.child;
  }
}
