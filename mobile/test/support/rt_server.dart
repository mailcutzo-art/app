import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/battle/data/battle_repository.dart';
import 'package:quiz_app/features/battle/data/match_models.dart';
import 'package:quiz_app/features/battle/match/screen_guard.dart';
import 'package:realtime_client/realtime_client.dart';

/// The connection's clock on `package:clock` time, so it follows a widget test's fake time.
final class ClockRealtimeClock implements RealtimeClock {
  @override
  int get monotonicMs => clock.now().millisecondsSinceEpoch;

  @override
  DateTime now() => clock.now();

  @override
  Timer timer(Duration duration, void Function() callback) => Timer(duration, callback);

  @override
  Timer periodic(Duration period, void Function(Timer timer) callback) =>
      Timer.periodic(period, callback);
}

/// Server time now, on the test's fake clock.
int serverNow() => clock.now().millisecondsSinceEpoch;

/// A server frame `{v, t, ch, seq, ts, d}`.
Map<String, Object?> frame(
  String type, [
  Map<String, Object?> data = const {},
  String? ch,
  int? seq,
]) => {'v': 1, 't': type, 'ch': ?ch, 'seq': ?seq, 'ts': serverNow(), 'd': data};

/// Decodes [frame] the way the connection does.
ServerEvent decodeEvent(Map<String, Object?> frame) => ServerEvent.decode(jsonEncode(frame));

/// A decoded event on channel [ch] (default `u`).
ServerEvent event(
  String type, [
  Map<String, Object?> data = const {},
  String? ch = 'u',
  int? seq,
]) => decodeEvent(frame(type, data, ch, seq));

/// A scriptable realtime server for widget tests. By default it answers `hello` with `welcome`
/// and `clock.ping` with `clock.pong`; the test plays everything else with [push].
class TestRealtimeServer implements WebSocketConnector {
  TestRealtimeServer({this.userId = 'u1', this.autoWelcome = true, this.hbS = 30});

  final String userId;
  bool autoWelcome;
  int hbS;

  /// `welcome.active` for the next connections.
  List<Map<String, Object?>> active = [];

  /// When set, the next `hello` is answered with `LIVE_ELSEWHERE` for this match.
  String? liveElsewhere;

  /// Called with every message the app sends, after the automatic replies.
  void Function(TestSocket socket, Map<String, Object?> message)? onMessage;

  final List<TestSocket> sockets = [];

  TestSocket get socket => sockets.last;

  /// Every message the app sent on any socket, in order.
  List<Map<String, Object?>> get sent => [for (final socket in sockets) ...socket.sent];

  List<Map<String, Object?>> sentOfType(String type) => [
    for (final message in sent)
      if (message['t'] == type) message,
  ];

  @override
  Future<RealtimeSocket> connect() async {
    final socket = TestSocket(this);
    sockets.add(socket);
    return socket;
  }

  /// Sends [frame] to the app on the latest socket.
  void push(Map<String, Object?> frame) => socket.push(frame);
}

class TestSocket implements RealtimeSocket {
  TestSocket(this._server);

  final TestRealtimeServer _server;
  final _frames = StreamController<Object?>();
  final List<Map<String, Object?>> sent = [];
  bool _closed = false;
  int? _closeCode;

  bool get isClosed => _closed;

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => null;

  @override
  void send(String text) {
    if (_closed) return;
    final message = jsonDecode(text) as Map<String, Object?>;
    sent.add(message);
    final data = (message['d'] as Map?)?.cast<String, Object?>() ?? const {};
    switch (message['t']) {
      case 'hello' when _server.liveElsewhere != null && data['takeover'] != true:
        push(
          frame('error', {
            'code': 'LIVE_ELSEWHERE',
            'message': 'Your game is running on another device.',
            'details': {'match_id': _server.liveElsewhere},
          }, 'u'),
        );
        scheduleMicrotask(() => closeFromServer(4409));
      case 'hello' when _server.autoWelcome:
        if (data['takeover'] == true) _server.liveElsewhere = null;
        push(
          frame('welcome', {
            'conn_id': 'k${_server.sockets.length}',
            'user_id': _server.userId,
            'server_ms': serverNow(),
            'hb_s': _server.hbS,
            'active': _server.active,
          }, 'u'),
        );
      case 'clock.ping':
        push(frame('clock.pong', {'c0': data['c0'], 's': serverNow()}));
    }
    _server.onMessage?.call(this, message);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    unawaited(_frames.close());
  }

  void push(Map<String, Object?> frame) {
    if (!_closed) _frames.add(jsonEncode(frame));
  }

  /// Closes from the server's side with [code] (none: a dropped network).
  void closeFromServer([int? code]) {
    if (_closed) return;
    _closed = true;
    _closeCode = code;
    unawaited(_frames.close());
  }

  /// The id of the last message of [type] the app sent here.
  String lastIdOf(String type) =>
      sent.lastWhere((message) => message['t'] == type)['id']! as String;
}

/// Match results for tests: set [summaries] and [reviews].
class FakeMatchRepository implements MatchRepository {
  final Map<String, MatchSummary> summaries = {};
  final Map<String, MatchReview> reviews = {};

  /// When set, every call throws it.
  AppFailure? failure;
  final List<String> calls = [];

  @override
  Future<MatchSummary> match(String matchId) async {
    calls.add(matchId);
    if (failure case final failure?) throw failure;
    return summaries[matchId] ?? (throw const NotFoundFailure('Not found'));
  }

  @override
  Future<MatchReview> review(String matchId) async {
    if (failure case final failure?) throw failure;
    return reviews[matchId] ?? (throw const NotFoundFailure('Not found'));
  }
}

/// Records when live-game screens protect the screen.
class FakeScreenGuard implements ScreenGuard {
  int holders = 0;
  final List<String> calls = [];

  bool get protecting => holders > 0;

  @override
  Future<void> protect() async {
    holders++;
    calls.add('protect');
  }

  @override
  Future<void> release() async {
    holders--;
    calls.add('release');
  }
}
