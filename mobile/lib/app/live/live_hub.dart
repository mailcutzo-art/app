import 'package:design_system/design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How an alert appears: a banner at the top, or a card that takes over the
/// screen (match found, tournament round ready).
enum AlertStyle { banner, takeover }

/// Which alert wins when several are waiting: lower shows first.
abstract final class LivePriority {
  static const roundJoin = 10;
  static const matchFound = 20;
  static const rematch = 30;
  static const invite = 40;
  static const checkIn = 50;
  static const notice = 60;
}

/// A button on an alert: runs [run] (e.g. decline an invite) and/or opens
/// [route], then dismisses the alert.
@immutable
class LiveAction {
  const LiveAction(this.label, {this.route, this.run});

  final String label;
  final String? route;
  final Future<void> Function()? run;
}

/// A time-critical event shown above whatever screen is open: a match found,
/// an invite, a tournament round, or a "what happened" notice (a refund, a
/// cancelled search). Feature code builds these from realtime events.
@immutable
class LiveAlert {
  const LiveAlert({
    required this.id,
    required this.title,
    this.message,
    this.icon = AppIcons.notification,
    this.tone = PastelTone.lemon,
    this.style = AlertStyle.banner,
    this.primary,
    this.secondary,
    this.expiresAt,
    this.autoRunAfter,
    this.priority = LivePriority.notice,
  });

  /// Stable per event: showing an alert with the same id replaces it.
  final String id;
  final String title;
  final String? message;
  final HugeIconData icon;
  final PastelTone tone;
  final AlertStyle style;
  final LiveAction? primary;
  final LiveAction? secondary;

  /// Shows a countdown and dismisses the alert when it runs out (invites,
  /// "join within 90 s").
  final DateTime? expiresAt;

  /// Runs [primary] by itself after this long (a found match opens the game).
  final Duration? autoRunAfter;

  /// See [LivePriority]; ties keep arrival order.
  final int priority;
}

/// A long-running state worth a pill on every screen ("Searching · 0:32").
@immutable
class LiveStatus {
  const LiveStatus({required this.label, this.since, this.route, this.icon = AppIcons.battle});

  final String label;

  /// Counts up from here when set.
  final DateTime? since;

  /// Tapping the pill opens this.
  final String? route;
  final HugeIconData icon;
}

@immutable
class LiveState {
  const LiveState({this.alerts = const [], this.status});

  final List<LiveAlert> alerts;
  final LiveStatus? status;

  /// The one alert on screen: the most urgent, and the oldest among equals.
  LiveAlert? get visible {
    LiveAlert? best;
    for (final alert in alerts) {
      if (best == null || alert.priority < best.priority) best = alert;
    }
    return best;
  }
}

/// The queue behind the live banner layer.
class LiveHub extends Notifier<LiveState> {
  @override
  LiveState build() => const LiveState();

  void show(LiveAlert alert) => state = LiveState(
    alerts: [
      for (final a in state.alerts)
        if (a.id != alert.id) a,
      alert,
    ],
    status: state.status,
  );

  void dismiss(String id) => state = LiveState(
    alerts: [
      for (final a in state.alerts)
        if (a.id != id) a,
    ],
    status: state.status,
  );

  // A status is replaced as a whole, so a setter-like method reads best.
  // ignore: use_setters_to_change_properties
  void setStatus(LiveStatus? status) => state = LiveState(alerts: state.alerts, status: status);
}

final liveHubProvider = NotifierProvider<LiveHub, LiveState>(LiveHub.new);

/// The time source for countdowns; tests replace it.
final liveClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
