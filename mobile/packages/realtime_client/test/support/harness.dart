import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

import 'fakes.dart';
import 'frames.dart';

/// A [RealtimeConnection] wired to fakes, plus a small scriptable server.
///
/// By default the server answers `hello` with `welcome` and `clock.ping` with an instant
/// `clock.pong`. Everything runs on `fake_async` time; [flush] delivers pending frames.
final class Harness {
  Harness(
    this.async, {
    this.hbS = 10,
    this.autoWelcome = true,
    this.autoClockPong = true,
    this.active = const [],
    Random? random,
    RealtimeConfig config = const RealtimeConfig(),
  }) {
    clock = FakeClock(async);
    connector.onSocket = _serve;
    connection = RealtimeConnection(
      fetchTicket: _fetchTicket,
      connector: connector,
      networkAvailable: network.stream,
      build: 57,
      platform: 'android',
      clock: clock,
      random: random ?? Random(42),
      config: config,
      log: (message, {error, stackTrace}) => logs.add(error == null ? message : '$message: $error'),
    );
    _subscriptions
      ..add(connection.states.listen(states.add))
      ..add(connection.events.listen(events.add));
  }

  /// Server time at fake time zero.
  static const serverEpochMs = 1790000000000;

  final FakeAsync async;
  late final FakeClock clock;
  final connector = FakeConnector();
  final network = StreamController<bool>.broadcast();
  late final RealtimeConnection connection;

  /// Every state the connection went through, in order.
  final List<ConnState> states = [];

  /// Every event the connection delivered, in order.
  final List<ServerEvent> events = [];
  final List<String> logs = [];

  /// Every ticket handed out, in order.
  final List<String> tickets = [];

  /// Errors the next ticket requests throw.
  final List<Error> ticketFailures = [];

  /// When set, ticket requests never complete.
  bool hangTickets = false;

  /// `welcome.hb_s`; `null` leaves it out.
  int? hbS;
  bool autoWelcome;
  bool autoClockPong;
  List<Map<String, Object?>> active;

  /// Called with every message a client sends, after the automatic replies.
  void Function(FakeSocket socket, Map<String, Object?> message)? onMessage;

  final List<StreamSubscription<Object?>> _subscriptions = [];

  int get serverNowMs => serverEpochMs + async.elapsed.inMilliseconds;

  /// The latest socket.
  FakeSocket get socket => connector.sockets.last;

  ConnState get state => connection.state;

  Future<String> _fetchTicket() async {
    if (hangTickets) return Completer<String>().future;
    if (ticketFailures.isNotEmpty) throw ticketFailures.removeAt(0);
    final ticket = 't${tickets.length + 1}';
    tickets.add(ticket);
    return ticket;
  }

  void _serve(FakeSocket socket) {
    _subscriptions.add(
      socket.fromClient.listen((message) {
        switch (message['t']) {
          case 'hello' when autoWelcome:
            socket.push(
              frame(
                'welcome',
                welcomeData(serverMs: serverNowMs, hbS: hbS, active: active),
                'u',
                null,
                serverNowMs,
              ),
            );
          case 'clock.ping' when autoClockPong:
            final data = message['d']! as Map<String, Object?>;
            socket.push(frame('clock.pong', {'c0': data['c0'], 's': serverNowMs}));
        }
        onMessage?.call(socket, message);
      }),
    );
  }

  /// Acquires a lease and runs until the connection is open.
  RealtimeLease open({String reason = 'test', bool inMatch = false}) {
    final lease = connection.acquire(reason, inMatch: inMatch);
    flush();
    expect(connection.state, isA<Open>(), reason: 'the connection should be open');
    return lease;
  }

  /// Runs pending microtasks: delivers frames, completes futures.
  void flush() => async.flushMicrotasks();

  void elapse(Duration duration) => async.elapse(duration);

  void elapseMs(int milliseconds) => async.elapse(Duration(milliseconds: milliseconds));

  /// Sends [frame] from the server on the latest socket and delivers it.
  void push(Map<String, Object?> frame) {
    socket.push(frame);
    flush();
  }

  /// The id of the last message of [type] sent on the latest socket.
  String lastIdOf(String type) => socket.sentOfType(type).last['id']! as String;

  /// Time until the pending retry of a [Backoff] state.
  Duration get retryIn {
    final state = connection.state;
    if (state is! Backoff || state.retryAt == null) {
      fail('expected a scheduled Backoff, got $state');
    }
    return state.retryAt!.difference(clock.now());
  }

  void dispose() {
    unawaited(_dispose());
    flush();
  }

  Future<void> _dispose() async {
    // Not awaited: broadcast cancel futures complete in the root zone, outside fake_async.
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    await connection.dispose();
    await network.close();
  }
}

/// Captures how a future ends, for inspection under `fake_async` without awaiting.
final class Outcome<T> {
  Outcome(Future<T> future) {
    unawaited(
      future.then(
        (value) {
          _value = value;
          isDone = true;
        },
        onError: (Object error) {
          this.error = error;
          isDone = true;
        },
      ),
    );
  }

  T? _value;
  Object? error;
  bool isDone = false;

  bool get isPending => !isDone;

  /// The value; fails the test if the future hasn't completed with one.
  T get value {
    if (!isDone || error != null) fail('expected a value, got ${error ?? 'nothing yet'}');
    return _value as T;
  }

  /// The error as a [RealtimeError]; fails the test otherwise.
  RealtimeError get realtimeError {
    final error = this.error;
    if (error is! RealtimeError) fail('expected a RealtimeError, got ${error ?? 'no error'}');
    return error;
  }
}
