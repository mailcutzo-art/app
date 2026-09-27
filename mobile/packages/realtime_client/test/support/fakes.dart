import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:realtime_client/realtime_client.dart';

/// An in-memory WebSocket: one [StreamController] per direction, plus close codes.
///
/// The test plays the server: [push] sends a frame to the client, [fromClient] and [sent] show
/// what the client sent, and [closeFromServer] closes with a code.
final class FakeSocket implements RealtimeSocket {
  FakeSocket(this.index);

  /// 0 for the first socket a connector opened, 1 for the next, …
  final int index;

  final _toClient = StreamController<Object?>();
  final _toServer = StreamController<Map<String, Object?>>.broadcast();

  /// Every message the client sent, decoded.
  final List<Map<String, Object?>> sent = [];

  int? _closeCode;
  String? _closeReason;
  bool _closed = false;

  /// Set when the client closed the socket.
  bool closedByClient = false;
  int? clientCloseCode;
  String? clientCloseReason;

  bool get isClosed => _closed;

  @override
  Stream<Object?> get frames => _toClient.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  @override
  void send(String text) {
    if (_closed) return;
    final message = jsonDecode(text) as Map<String, Object?>;
    sent.add(message);
    _toServer.add(message);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    closedByClient = true;
    clientCloseCode = code;
    clientCloseReason = reason;
    unawaited(_toClient.close());
    unawaited(_toServer.close());
  }

  // Server side.

  /// What the client sends, as it happens.
  Stream<Map<String, Object?>> get fromClient => _toServer.stream;

  /// Sends a JSON frame to the client.
  void push(Map<String, Object?> frame) => pushRaw(jsonEncode(frame));

  /// Sends a raw frame (for example a malformed string or a binary frame).
  void pushRaw(Object? frame) {
    if (!_closed) _toClient.add(frame);
  }

  /// Closes the socket from the server with [code] (or none, like a network drop).
  void closeFromServer([int? code, String? reason]) {
    if (_closed) return;
    _closed = true;
    _closeCode = code;
    _closeReason = reason;
    unawaited(_toClient.close());
    unawaited(_toServer.close());
  }

  /// The messages of [type] the client sent, in order.
  List<Map<String, Object?>> sentOfType(String type) => [
    for (final message in sent)
      if (message['t'] == type) message,
  ];

  /// The ids of every message the client sent, in order.
  List<String> get sentIds => [for (final message in sent) message['id']! as String];
}

/// Opens [FakeSocket]s. Tests can make attempts fail or hang.
final class FakeConnector implements WebSocketConnector {
  final List<FakeSocket> sockets = [];

  /// How many times [connect] was called.
  int attempts = 0;

  /// Errors to throw for the next attempts, in order.
  final List<Object> failures = [];

  /// When set, [connect] never completes.
  bool hang = false;

  /// When set, the next [connect] throws it synchronously instead of returning a future.
  Error? throwNow;

  /// Called with every socket before it is returned.
  void Function(FakeSocket socket)? onSocket;

  @override
  Future<RealtimeSocket> connect() {
    attempts++;
    final error = throwNow;
    if (error != null) {
      throwNow = null;
      throw error;
    }
    if (hang) return Completer<RealtimeSocket>().future;
    if (failures.isNotEmpty) return Future.error(failures.removeAt(0));
    final socket = FakeSocket(sockets.length);
    sockets.add(socket);
    onSocket?.call(socket);
    return Future.value(socket);
  }
}

/// A [RealtimeClock] on `fake_async` time.
final class FakeClock implements RealtimeClock {
  FakeClock(this.async, {this.monotonicBase = 5000000, DateTime? origin})
    : origin = origin ?? DateTime.utc(2026, 9, 27, 12);

  final FakeAsync async;
  final int monotonicBase;
  final DateTime origin;

  @override
  int get monotonicMs => monotonicBase + async.elapsed.inMilliseconds;

  @override
  DateTime now() => origin.add(async.elapsed);

  @override
  Timer timer(Duration duration, void Function() callback) => Timer(duration, callback);

  @override
  Timer periodic(Duration period, void Function(Timer timer) callback) =>
      Timer.periodic(period, callback);
}

/// Always draws the largest value, so backoff delays equal their window.
final class MaxRandom implements Random {
  @override
  int nextInt(int max) => max - 1;

  @override
  double nextDouble() => 1 - 1e-9;

  @override
  bool nextBool() => true;
}

/// Always draws 0, so every backoff delay is 0.
final class ZeroRandom implements Random {
  @override
  int nextInt(int max) => 0;

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}
