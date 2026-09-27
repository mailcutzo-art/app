import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../app/env.dart';
import '../../features/battle/demo/demo_providers.dart';
import '../../features/learn/data/learn_repository.dart' show demoDataProvider;
import '../auth/session.dart';
import '../device/app_build.dart';
import '../network/api_client.dart';
import '../network/app_failure.dart';
import '../network/connectivity.dart';

/// The realtime endpoint for an API base URL: `http` becomes `ws`, `https` becomes `wss`, and
/// `/v1/ws` is appended to the path. Query and fragment are dropped.
Uri realtimeUri(String apiBaseUrl) {
  final base = Uri.parse(apiBaseUrl.trim());
  final scheme = switch (base.scheme) {
    'https' => 'wss',
    'http' => 'ws',
    final other => other,
  };
  final path = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
  return Uri(
    scheme: scheme,
    userInfo: base.userInfo.isEmpty ? null : base.userInfo,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '$path/v1/ws',
  );
}

/// The `platform` sent in `hello`: `android`, `ios`, `web`, or the desktop platform's name.
String realtimePlatform({bool isWeb = kIsWeb, TargetPlatform? platform}) {
  if (isWeb) return 'web';
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    final other => other.name,
  };
}

/// Opens sockets to the realtime server; the demo swaps in its scripted server and tests their
/// own.
final realtimeConnectorProvider = Provider<WebSocketConnector>((ref) {
  // The constant keeps the demo server out of release builds entirely.
  if (!kReleaseMode && ref.watch(demoDataProvider)) return ref.watch(demoRealtimeServerProvider);
  return WebSocketChannelConnector(realtimeUri(ref.watch(appEnvProvider).apiBaseUrl));
});

/// Gets a single-use connection ticket: `POST /v1/rt/tickets`.
final realtimeTicketsProvider = Provider<TicketFetcher>((ref) {
  if (!kReleaseMode && ref.watch(demoDataProvider)) return () async => 'demo-ticket';
  final api = ref.watch(apiClientProvider);
  return () async {
    final data = await api.post('/v1/rt/tickets');
    if (data case {'ticket': final String ticket} when ticket.isNotEmpty) return ticket;
    throw const UnexpectedFailure();
  };
});

/// Time and timers for the connection. Tests put it on fake time.
final realtimeClockProvider = Provider<RealtimeClock>((ref) => SystemRealtimeClock());

/// Timings for the connection; the defaults follow the protocol.
final realtimeConfigProvider = Provider<RealtimeConfig>((ref) => const RealtimeConfig());

/// Connection diagnostics, printed in debug builds.
final realtimeLogProvider = Provider<RealtimeLogger?>((ref) => kDebugMode ? _debugLog : null);

void _debugLog(String message, {Object? error, StackTrace? stackTrace}) =>
    debugPrint(error == null ? '[rt] $message' : '[rt] $message: $error');

/// The one realtime connection, while someone is signed in. A new user (or signing out, or a
/// suspension) disposes it. Nothing opens until a lease is taken (see `LiveController`).
final realtimeConnectionProvider = Provider<RealtimeConnection?>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  // Wait for the build number, so the connection is made once, with the right `hello.build`.
  final build = ref.watch(appBuildProvider);
  if (build.isLoading && !build.hasValue && !build.hasError) return null;

  final network = StreamController<bool>.broadcast();
  final connection = RealtimeConnection(
    fetchTicket: ref.watch(realtimeTicketsProvider),
    connector: ref.watch(realtimeConnectorProvider),
    networkAvailable: network.stream,
    build: build.value ?? 0,
    platform: realtimePlatform(),
    clock: ref.watch(realtimeClockProvider),
    config: ref.watch(realtimeConfigProvider),
    log: ref.watch(realtimeLogProvider),
  );
  ref
    ..listen(isOnlineProvider, (_, online) => network.add(online), fireImmediately: true)
    ..onDispose(() {
      unawaited(connection.dispose());
      unawaited(network.close());
    });
  return connection;
});

/// The connection's state, for screens that show "Reconnecting…".
final realtimeStateProvider = StreamProvider<ConnState>((ref) async* {
  final connection = ref.watch(realtimeConnectionProvider);
  if (connection == null) {
    yield const Idle();
    return;
  }
  yield connection.state;
  yield* connection.states;
}, retry: (_, _) => null);
