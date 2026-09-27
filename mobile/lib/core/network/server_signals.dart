import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// App-wide conditions the server can announce on any response: this build is
/// too old (426), or the service is in maintenance (503 `MAINTENANCE`).
@immutable
class ServerSignals {
  const ServerSignals({this.updateRequired = false, this.maintenance = false});

  final bool updateRequired;
  final bool maintenance;

  @override
  bool operator ==(Object other) =>
      other is ServerSignals &&
      other.updateRequired == updateRequired &&
      other.maintenance == maintenance;

  @override
  int get hashCode => Object.hash(updateRequired, maintenance);
}

class ServerSignalsController extends Notifier<ServerSignals> {
  @override
  ServerSignals build() => const ServerSignals();

  void updateRequired() =>
      state = ServerSignals(updateRequired: true, maintenance: state.maintenance);

  void maintenance() =>
      state = ServerSignals(updateRequired: state.updateRequired, maintenance: true);

  /// Called when a fresh config says maintenance is over.
  void maintenanceOver() {
    if (state.maintenance) state = ServerSignals(updateRequired: state.updateRequired);
  }
}

final serverSignalsProvider = NotifierProvider<ServerSignalsController, ServerSignals>(
  ServerSignalsController.new,
);
