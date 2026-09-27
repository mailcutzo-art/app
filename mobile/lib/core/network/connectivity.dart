import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the device has a network connection. This is the radio status,
/// not proof the server is reachable: use it to show the offline banner and
/// to retry sooner when the connection comes back, never to skip a request.
final connectivityProvider = StreamProvider<bool>(
  (ref) async* {
    final connectivity = Connectivity();
    yield _online(await connectivity.checkConnectivity());
    yield* connectivity.onConnectivityChanged.map(_online);
  },
  // A platform failure here won't fix itself; treat the status as unknown.
  retry: (_, _) => null,
);

bool _online(List<ConnectivityResult> results) =>
    results.any((result) => result != ConnectivityResult.none);

/// True unless the device is known to be offline (unknown counts as online).
final isOnlineProvider = Provider<bool>((ref) => ref.watch(connectivityProvider).value ?? true);
