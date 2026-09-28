import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Calls [onPoll] every [interval] while its [child] is on screen: the tab
/// is selected (tickers enabled), no full-screen page covers it, and the app
/// is in the foreground. Coming back after a longer break polls right away.
class PresencePoller extends StatefulWidget {
  const PresencePoller({
    super.key,
    required this.interval,
    required this.onPoll,
    required this.child,
  });

  final Duration interval;
  final Future<void> Function() onPoll;
  final Widget child;

  @override
  State<PresencePoller> createState() => _PresencePollerState();
}

class _PresencePollerState extends State<PresencePoller> with WidgetsBindingObserver {
  ValueListenable<TickerModeData>? _tickerMode;
  Timer? _timer;
  bool _foreground = true;
  final _sinceLastPoll = clock.stopwatch()..start();

  bool get _visible => (_tickerMode?.value.enabled ?? true) && _foreground;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = TickerMode.getValuesNotifier(context);
    if (!identical(notifier, _tickerMode)) {
      _tickerMode?.removeListener(_update);
      _tickerMode = notifier..addListener(_update);
      _update();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _update();
  }

  void _update() {
    if (!_visible) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_timer != null) return;
    if (_sinceLastPoll.elapsed >= widget.interval) unawaited(_poll());
    _timer = Timer.periodic(widget.interval, (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    _sinceLastPoll.reset();
    await widget.onPoll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tickerMode?.removeListener(_update);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
