import 'dart:async';
import 'dart:math';

import 'channel_tracker.dart';
import 'config.dart';
import 'conn_state.dart';
import 'envelope.dart';
import 'errors.dart';
import 'events.dart';
import 'realtime_clock.dart';
import 'server_clock.dart';
import 'socket.dart';

/// Gets a single-use connection ticket. In the app: `POST /v1/rt/tickets`.
typedef TicketFetcher = Future<String> Function();

/// Decides whether [event] is the reply to the request sent with message id [id].
typedef ReplyMatcher = bool Function(ServerEvent event, String id);

/// Receives diagnostics: state changes, dropped frames, close codes, failures.
typedef RealtimeLogger = void Function(String message, {Object? error, StackTrace? stackTrace});

/// The successful reply to [RealtimeConnection.request].
final class Ack {
  const Ack({required this.id, required this.reply});

  /// The message id the request was sent with.
  final String id;

  /// An [AckEvent], or the request's natural reply (for example [MmQueuedEvent] for `mm.join`).
  final ServerEvent reply;

  @override
  String toString() => 'Ack($id, ${reply.type})';
}

/// Keeps the socket open while at least one [RealtimeLease] is held. Get one from
/// [RealtimeConnection.acquire] and [release] it when the screen goes away.
final class RealtimeLease {
  RealtimeLease._(this._connection, this.reason, {required this.inMatch});

  final RealtimeConnection _connection;

  /// Why the lease is held, for logs (`battle-tab`, `match:<id>`, …).
  final String reason;

  /// Whether a live match needs the connection. While any such lease is held, reconnects back off
  /// at most 2 s, the heartbeat watchdog uses the in-match heartbeat, and the clock re-syncs every
  /// minute.
  final bool inMatch;

  bool _released = false;

  bool get isReleased => _released;

  /// Gives the lease back. Safe to call more than once.
  void release() {
    if (_released) return;
    _released = true;
    _connection._release(this);
  }

  @override
  String toString() => 'RealtimeLease($reason${inMatch ? ', in match' : ''})';
}

/// The realtime connection manager (docs/protocol.md).
///
/// - Opens the socket while a lease is held, and closes it [RealtimeConfig.linger] after the last
///   lease is released.
/// - Fetches a fresh ticket for every attempt, says `hello` with the resume list, and is [Open]
///   once `welcome` arrives.
/// - Answers `ping`, reconnects when the heartbeat watchdog fires, backs off with full jitter,
///   pauses while offline and follows the close-code table.
/// - Correlates [request]s with their `ack`, `error` or natural reply, and keeps answers from
///   [submitAnswer] in an outbox until the server acknowledges them.
/// - Filters [events] through a [ChannelTracker] and sends `sync` on seq gaps.
/// - Syncs [serverClock] after every `welcome`, then every [RealtimeConfig.clockResyncEvery] in a
///   match and every [RealtimeConfig.idleClockResyncEvery] otherwise.
/// - Reports the app's foreground state ([setAppForeground]) and can take over a live match from
///   another device ([connect] with `takeover`).
final class RealtimeConnection {
  RealtimeConnection({
    required this._fetchTicket,
    required this._connector,
    required Stream<bool> networkAvailable,
    required this.build,
    required this.platform,
    RealtimeClock? clock,
    Random? random,
    this.config = const RealtimeConfig(),
    RealtimeLogger? log,
  }) : _clock = clock ?? SystemRealtimeClock(),
       _random = random ?? Random(),
       _logger = log {
    _networkSubscription = networkAvailable.listen(_onNetworkChanged);
  }

  final TicketFetcher _fetchTicket;
  final WebSocketConnector _connector;
  final RealtimeClock _clock;
  final Random _random;
  final RealtimeLogger? _logger;

  /// The app's build number, sent in `hello`.
  final int build;

  /// `android`, `ios` or `web`, sent in `hello`.
  final String platform;
  final RealtimeConfig config;

  /// Server time, synced after every `welcome` and then periodically.
  late final ServerClock serverClock = ServerClock(
    monotonicMs: () => _clock.monotonicMs,
    samplesPerSync: config.clockSamples,
    maxRttMs: config.clockMaxRtt.inMilliseconds,
  );

  late final StreamSubscription<bool> _networkSubscription;
  final _stateController = StreamController<ConnState>.broadcast();
  final _eventController = StreamController<ServerEvent>.broadcast();
  final _tracker = ChannelTracker();

  ConnState _state = const Idle();
  bool _disposed = false;
  bool _networkAvailable = true;

  final List<RealtimeLease> _leases = [];
  Timer? _lingerTimer;

  /// Bumped to abandon an attempt that is still fetching a ticket or connecting.
  int _generation = 0;
  _Link? _link;
  int _attempt = 0;
  int _ticketRejections = 0;
  Timer? _retryTimer;

  /// After 4429, no attempt starts before this monotonic time, even if the network comes back.
  int? _retryNotBeforeMs;

  /// Whether the next `hello` asks to take over a live match from another device.
  bool _takeover = false;

  /// The app state last set with [setAppForeground], sent after every `welcome`.
  bool? _foreground;

  WelcomeEvent? _welcome;
  Timer? _helloTimer;
  Timer? _watchdog;
  int _lastFrameMs = 0;
  Timer? _clockResyncTimer;
  Timer? _clockPingTimer;
  int? _clockPingC0;
  int? _lastClockSyncMs;

  final List<_Request> _queued = [];
  final Map<String, _Request> _inflight = {};
  final List<_Answer> _outbox = [];
  final Map<String, List<ServerEvent>> _gapBuffers = {};
  final Map<String, Timer> _gapTimers = {};
  final Map<String, String> _syncRefs = {};
  int _protocolErrors = 0;

  // ---------------------------------------------------------------------------------------------
  // Public API

  /// The current state.
  ConnState get state => _state;

  /// State changes, as they happen.
  Stream<ConnState> get states => _stateController.stream;

  /// Server events in order, after duplicate and gap filtering. Connection plumbing (`welcome`,
  /// `ping`, `clock.pong`) is not included. [UnknownEvent]s are, and consumers ignore them.
  Stream<ServerEvent> get events => _eventController.stream;

  /// The last `welcome`. Its `active` list says which games to jump back into.
  WelcomeEvent? get welcome => _welcome;

  /// Whether a lease with `inMatch` is held.
  bool get inMatch => _leases.any((lease) => lease.inMatch);

  /// The leases currently held.
  List<RealtimeLease> get leases => List.unmodifiable(_leases);

  /// What the next `hello` would resume.
  List<ResumeEntry> get resumeList => _tracker.resumeList();

  /// The last applied seq on [channel], if it is tracked.
  int? lastSeq(String channel) => _tracker.lastSeq(channel);

  /// Frames dropped because they could not be decoded.
  int get protocolErrors => _protocolErrors;

  /// Answers still waiting for their `ans.ack`.
  int get pendingAnswers => _outbox.length;

  /// How long the watchdog waits for a frame before it reconnects: `2 × hb + 2 s`, where hb is
  /// `welcome.hb_s`, or the in-match heartbeat while an `inMatch` lease is held.
  Duration get heartbeatTimeout {
    var heartbeatMs = max(1, _welcome?.hbS ?? 10) * 1000;
    if (inMatch) heartbeatMs = min(heartbeatMs, config.matchHeartbeat.inMilliseconds);
    return Duration(milliseconds: 2 * heartbeatMs + 2000);
  }

  /// Asks for the connection. It opens (if it isn't already) and stays open until every lease is
  /// released, plus [RealtimeConfig.linger].
  RealtimeLease acquire(String reason, {bool inMatch = false}) {
    final lease = RealtimeLease._(this, reason, inMatch: inMatch);
    if (_disposed) {
      lease._released = true;
      return lease;
    }
    _leases.add(lease);
    _lingerTimer?.cancel();
    _lingerTimer = null;
    _log('Acquired $lease');
    _onLeasesChanged();
    if (_state is Idle) _connectNow();
    return lease;
  }

  /// Sends a request and completes with its reply.
  ///
  /// The reply is the `ack` whose `ref` is the request's id, or the first event [isReply] accepts
  /// (a natural reply). Some types get a matching [isReply] by default: `mm.join` (`mm.queued`, or
  /// `mm.found` for a bot game), `ans.submit` (`ans.ack`), `sub` (`t.standings`) and
  /// `match.rematch` (`rematch.status`). The future fails with a [RealtimeError]: the server's
  /// `error` for this id, or [RealtimeErrorCode.timeout] after [timeout], or
  /// [RealtimeErrorCode.disconnected] if the socket drops after sending. While the connection is
  /// still opening, the request waits (within [timeout]) and is sent right after `welcome`.
  Future<Ack> request(
    String type,
    Map<String, Object?> data, {
    Duration? timeout,
    ReplyMatcher? isReply,
  }) {
    final refusal = _refusal();
    if (refusal != null) return Future.error(refusal);
    final request = _Request(type, data, isReply ?? _defaultReplyMatcher(type, data));
    request.timer = _clock.timer(
      timeout ?? config.requestTimeout,
      () => _onRequestTimeout(request),
    );
    if (_isOpen) {
      _sendRequest(request);
    } else {
      _queued.add(request);
    }
    return request.future;
  }

  /// Submits an answer that is never lost.
  ///
  /// The `ans.submit` frame stays in an outbox until an `ans.ack` with its `ref` arrives. It is
  /// resent with the same id after [RealtimeConfig.answerResendAfter] without an ack, and after
  /// every reconnect. Any `ans.ack` status counts, including `dup`. A second call for the same
  /// match and question returns the first call's future.
  ///
  /// The future fails only if the server rejects the answer with a non-retryable `error`, the
  /// match's channel is forgotten, or the connection becomes terminal or is disposed. Nothing
  /// fails if nobody listens to it.
  Future<AnsAckEvent> submitAnswer(String matchId, int q, String opt, int elMs) {
    if (_disposed || _state is Terminal) return _answerFuture(Future.error(_closedError()));
    for (final answer in _outbox) {
      if (answer.matchId == matchId && answer.q == q) return answer.future;
    }
    final answer = _Answer(matchId: matchId, q: q, opt: opt, elMs: elMs);
    _outbox.add(answer);
    if (_isOpen) _sendAnswer(answer);
    return answer.future;
  }

  /// Starts tracking [channel] (from seq 0) so it is resumed after a reconnect. Channels named by
  /// `mm.found`, `room.started` and `t.pairing` are tracked automatically.
  void trackChannel(String channel) => _tracker.track(channel);

  /// Asks the server to replay [channel] from the last applied seq (or send a snapshot), for
  /// example for an `active` entry after a cold start.
  void syncChannel(String channel) {
    if (!ChannelTracker.isResumable(channel)) {
      throw ArgumentError.value(channel, 'channel', 'is not resumable');
    }
    _tracker.track(channel);
    _sendSync(channel);
  }

  /// Stops tracking [channel] (once a match is settled, or a room is left) and drops unacked
  /// answers for that match.
  void forgetChannel(String channel) {
    _tracker.forget(channel);
    _clearGap(channel);
    if (!channel.startsWith('m:')) return;
    final matchId = channel.substring(2);
    for (final answer in _outbox.where((answer) => answer.matchId == matchId).toList()) {
      _removeAnswer(answer);
      answer.fail(
        RealtimeError(code: RealtimeErrorCode.cancelled, message: 'Match $matchId was forgotten'),
      );
    }
  }

  /// Reports whether the app is in the foreground: `client.state` is sent now if the connection is
  /// open, and again right after every `welcome`. The server stops a queued search after 10 s in
  /// the background, and uses it as an anti-cheat signal.
  void setAppForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    _sendAppState();
  }

  /// Connects now: leaves [Terminal] (after the user signed in again, chose "Play here", …) and
  /// skips any pending backoff. Nothing opens without a lease; the next [acquire] connects.
  ///
  /// With [takeover], `hello` asks to move a live match from another device to this one, the
  /// answer to [TerminalReason.liveElsewhere]. It applies until the next `welcome`.
  void connect({bool takeover = false}) {
    if (_disposed || _state is Open) return;
    if (takeover) _takeover = true;
    if (_state is Terminal) {
      _attempt = 0;
      _ticketRejections = 0;
      _retryNotBeforeMs = null;
      _setState(const Idle());
    }
    final state = _state;
    if (_wanted && (state is Idle || state is Backoff)) _connectNow();
  }

  /// Closes the socket, fails whatever is pending with [RealtimeErrorCode.closed] and closes the
  /// streams.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _cancelRetry();
    _lingerTimer?.cancel();
    _lingerTimer = null;
    final error = _closedError();
    _teardownLink(reason: 'disposed', inflightError: error);
    _failQueued(error);
    _failOutbox(error);
    for (final lease in _leases) {
      lease._released = true;
    }
    _leases.clear();
    // Cancelling takes effect at once. Its future is not awaited: for broadcast streams it is a
    // root-zone future, which would stall dispose under fake_async.
    unawaited(_networkSubscription.cancel());
    await Future.wait([_stateController.close(), _eventController.close()]);
  }

  // ---------------------------------------------------------------------------------------------
  // Leases

  bool get _wanted => _leases.isNotEmpty || _lingerTimer != null;

  bool get _isOpen => _link?.welcomed ?? false;

  void _release(RealtimeLease lease) {
    if (!_leases.remove(lease)) return;
    _log('Released $lease');
    _onLeasesChanged();
    if (_leases.isNotEmpty || _state is Idle || _state is Terminal) return;
    _lingerTimer = _clock.timer(config.linger, () {
      _lingerTimer = null;
      if (_leases.isEmpty) _stop('no lease for ${config.linger.inSeconds} s');
    });
  }

  void _onLeasesChanged() {
    if (_isOpen) {
      _armWatchdog();
      _scheduleClockResync();
    }
    _shortenBackoffForMatch();
  }

  /// A match started while a long backoff was pending: bring the retry within the match cap.
  void _shortenBackoffForMatch() {
    final state = _state;
    if (!inMatch || state is! Backoff || _retryTimer == null || _retryNotBeforeMs != null) return;
    final retryAt = state.retryAt;
    final capMs = config.matchBackoffCap.inMilliseconds;
    if (retryAt == null || retryAt.difference(_clock.now()).inMilliseconds <= capMs) return;
    _scheduleRetry(Duration(milliseconds: _random.nextInt(capMs + 1)), attempt: state.attempt);
  }

  // ---------------------------------------------------------------------------------------------
  // Connecting

  void _connectNow() {
    if (_disposed || _state is Terminal) return;
    _cancelRetry();
    final notBefore = _retryNotBeforeMs;
    if (notBefore != null) {
      final waitMs = notBefore - _clock.monotonicMs;
      if (waitMs > 0) {
        final state = _state;
        _scheduleRetry(
          Duration(milliseconds: waitMs),
          attempt: state is Backoff ? state.attempt : _attempt,
        );
        return;
      }
      _retryNotBeforeMs = null;
    }
    if (!_networkAvailable) {
      _setState(Backoff(attempt: _attempt, retryAt: null));
      return;
    }
    final generation = ++_generation;
    _setState(const Ticketing());
    unawaited(_runAttempt(generation));
  }

  Future<void> _runAttempt(int generation) async {
    final String ticket;
    try {
      ticket = await _bounded(_fetchTicket, config.ticketTimeout, 'Ticket request');
    } on Object catch (error, stackTrace) {
      if (generation != _generation) return;
      _log('Ticket request failed', error: error, stackTrace: stackTrace);
      _backoff();
      return;
    }
    if (generation != _generation) return;
    _setState(const Connecting());
    final RealtimeSocket socket;
    try {
      socket = await _bounded(
        _connector.connect,
        config.connectTimeout,
        'WebSocket connect',
        onLate: (socket) => _closeQuietly(socket, 'connect timed out'),
      );
    } on Object catch (error, stackTrace) {
      if (generation != _generation) return;
      _log('Connect failed', error: error, stackTrace: stackTrace);
      _backoff();
      return;
    }
    if (generation != _generation) {
      _closeQuietly(socket, 'abandoned');
      return;
    }
    _attach(socket, ticket);
  }

  /// Runs [start], failing with a [TimeoutException] after [timeout]. A result that arrives after
  /// the timeout goes to [onLate].
  Future<T> _bounded<T>(
    Future<T> Function() start,
    Duration timeout,
    String what, {
    void Function(T late)? onLate,
  }) {
    final completer = Completer<T>();
    final timer = _clock.timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('$what timed out', timeout));
      }
    });
    unawaited(
      Future.sync(start).then(
        (value) {
          timer.cancel();
          if (completer.isCompleted) {
            onLate?.call(value);
          } else {
            completer.complete(value);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          timer.cancel();
          if (!completer.isCompleted) completer.completeError(error, stackTrace);
        },
      ),
    );
    return completer.future;
  }

  void _attach(RealtimeSocket socket, String ticket) {
    final link = _Link(socket);
    for (final answer in _outbox) {
      final id = answer.id;
      if (id != null) link.ids.reserve(id);
    }
    _link = link;
    _lastFrameMs = _clock.monotonicMs;
    link.subscription = socket.frames.listen(
      (frame) => _onFrame(link, frame),
      onError: (Object error, StackTrace stackTrace) => _onSocketError(link, error, stackTrace),
      onDone: () => _onSocketDone(link),
    );
    _sendOn(link, 'hello', {
      'ticket': ticket,
      'proto': protocolVersion,
      'build': build,
      'platform': platform,
      'resume': [for (final entry in _tracker.resumeList()) entry.toJson()],
      if (_takeover) 'takeover': true,
    });
    _helloTimer = _clock.timer(config.helloTimeout, () {
      _helloTimer = null;
      if (!identical(link, _link) || link.welcomed) return;
      _log('No welcome within ${config.helloTimeout.inSeconds} s');
      _dropLink('welcome timeout');
    });
  }

  void _onWelcome(_Link link, WelcomeEvent welcome) {
    if (link.welcomed) {
      _log('Ignored a second welcome');
      return;
    }
    link.welcomed = true;
    _helloTimer?.cancel();
    _helloTimer = null;
    _attempt = 0;
    _ticketRejections = 0;
    _takeover = false;
    _welcome = welcome;
    serverClock.seed(welcome.serverMs);
    _setState(Open(welcome));
    _armWatchdog();
    _sendAppState();
    // Then answers: they are the most time-critical frames.
    for (final answer in List.of(_outbox)) {
      _sendAnswer(answer);
    }
    final queued = List.of(_queued);
    _queued.clear();
    queued.forEach(_sendRequest);
    _startClockSync();
  }

  // ---------------------------------------------------------------------------------------------
  // Incoming frames

  void _onFrame(_Link link, Object? frame) {
    if (!identical(link, _link)) return;
    _lastFrameMs = _clock.monotonicMs;
    if (link.welcomed) _armWatchdog();
    final ServerEvent event;
    try {
      event = ServerEvent.decode(frame);
    } on FormatException catch (error) {
      _protocolErrors++;
      _log('Dropped a bad frame: ${error.message}', error: error);
      return;
    }
    switch (event) {
      case PingEvent(:final n):
        _sendOn(link, 'pong', {'n': n});
      case ClockPongEvent():
        _onClockPong(event);
      case WelcomeEvent():
        _onWelcome(link, event);
      default:
        _correlate(event);
        _route(event);
        _followChannels(event);
    }
  }

  /// Completes requests and answers that [event] replies to.
  void _correlate(ServerEvent event) {
    switch (event) {
      case ErrorEvent(code: RealtimeErrorCode.liveElsewhere):
        // Another device is in a live match. The server closes with 4409 next.
        _log('A live match is running on another device');
        _link?.liveElsewhere = TerminalReason.liveElsewhere(event.toError().matchId);
      case AckEvent(:final ref):
        _inflight.remove(ref)?.succeed(Ack(id: ref, reply: event));
      case ErrorEvent(:final ref?):
        final request = _inflight.remove(ref);
        if (request != null) {
          request.fail(event.toError());
        } else if (!_answerRejected(ref, event) && !_syncRejected(ref, event)) {
          _log('Error ${event.code} for unknown ref $ref: ${event.message}');
        }
      case ErrorEvent():
        _log('Server error ${event.code}: ${event.message}');
      case AnsAckEvent():
        _answerAcked(event);
        _matchNaturalReply(event);
      default:
        _matchNaturalReply(event);
    }
  }

  void _matchNaturalReply(ServerEvent event) {
    for (final request in _inflight.values) {
      final isReply = request.isReply;
      if (isReply == null) continue;
      final id = request.id!;
      bool matches;
      try {
        matches = isReply(event, id);
      } on Object catch (error, stackTrace) {
        _log('The reply matcher of ${request.type} threw', error: error, stackTrace: stackTrace);
        matches = false;
      }
      if (matches) {
        _inflight.remove(id);
        request.succeed(Ack(id: id, reply: event));
        return;
      }
    }
  }

  /// Delivers [event] if its seq is next, drops duplicates, and holds events after a gap.
  void _route(ServerEvent event) {
    switch (_tracker.accept(event)) {
      case SeqDecision.apply:
        _emit(event);
        final channel = event.channel;
        if (channel != null && _gapBuffers.containsKey(channel)) _drainGap(channel);
      case SeqDecision.duplicate:
        _log('Dropped duplicate $event');
      case SeqDecision.gap:
        _holdForGap(event);
    }
  }

  void _holdForGap(ServerEvent event) {
    final channel = event.channel!;
    final buffer = _gapBuffers.putIfAbsent(channel, () => []);
    if (buffer.length < config.maxGapBuffer && buffer.every((held) => held.seq != event.seq)) {
      buffer.add(event);
    }
    if (_gapTimers.containsKey(channel)) return;
    _log('Gap on $channel after seq ${_tracker.lastSeq(channel)}: got ${event.seq}');
    _sendSync(channel);
    _gapTimers[channel] = _clock.periodic(config.syncRetryAfter, (_) => _sendSync(channel));
  }

  /// Delivers held events that are now next in line; ends the gap once nothing is held.
  void _drainGap(String channel) {
    final buffer = _gapBuffers[channel]!..sort((a, b) => a.seq!.compareTo(b.seq!));
    while (buffer.isNotEmpty) {
      final decision = _tracker.accept(buffer.first);
      if (decision == SeqDecision.gap) break;
      final event = buffer.removeAt(0);
      if (decision == SeqDecision.apply) _emit(event);
    }
    if (buffer.isEmpty) _clearGap(channel);
  }

  void _clearGap(String channel) {
    _gapBuffers.remove(channel);
    _gapTimers.remove(channel)?.cancel();
    _syncRefs.removeWhere((_, syncChannel) => syncChannel == channel);
  }

  void _sendSync(String channel) {
    final link = _link;
    if (link == null || !link.welcomed) return;
    final id = _sendOn(link, 'sync', {'ch': channel, 'last_seq': _tracker.lastSeq(channel) ?? 0});
    _syncRefs[id] = channel;
  }

  /// The server refused a `sync`: stop re-sending it. The next gap event starts over.
  bool _syncRejected(String ref, ErrorEvent error) {
    final channel = _syncRefs.remove(ref);
    if (channel == null) return false;
    _log('sync for $channel failed: ${error.code} ${error.message}');
    _gapTimers.remove(channel)?.cancel();
    return true;
  }

  /// Tracks match channels as soon as they are announced, and forgets rooms that are gone.
  void _followChannels(ServerEvent event) {
    switch (event) {
      case MmFoundEvent(:final matchChannel) || RoomStartedEvent(:final matchChannel):
        _tracker.track(matchChannel);
      case TPairingEvent(:final matchChannel?):
        _tracker.track(matchChannel);
      case RoomKickedEvent(:final roomId) || RoomClosedEvent(:final roomId):
        forgetChannel('r:$roomId');
      default:
        break;
    }
  }

  void _emit(ServerEvent event) {
    if (!_eventController.isClosed) _eventController.add(event);
  }

  // ---------------------------------------------------------------------------------------------
  // Requests and answers

  RealtimeError? _refusal() {
    if (_disposed || _state is Terminal) return _closedError();
    if (!_wanted) {
      return const RealtimeError(
        code: RealtimeErrorCode.notConnected,
        message: 'No lease is held, so there is no connection to send on',
        retryable: true,
      );
    }
    return null;
  }

  RealtimeError _closedError() {
    final state = _state;
    return RealtimeError(
      code: RealtimeErrorCode.closed,
      message: state is Terminal
          ? 'The connection ended: ${state.reason.name}'
          : 'The connection was disposed',
    );
  }

  static ReplyMatcher? _defaultReplyMatcher(String type, Map<String, Object?> data) =>
      switch (type) {
        // A bot game (`mode: bot`) starts at once, so its reply is `mm.found`.
        'mm.join' => (event, _) => event is MmQueuedEvent || event is MmFoundEvent,
        'ans.submit' => (event, id) => event is AnsAckEvent && event.ref == id,
        'sub' => (event, _) => event is TStandingsEvent && event.channel == data['ch'],
        'match.rematch' => (
          event,
          _,
        ) => event is RematchStatusEvent && event.matchId == data['match_id'],
        _ => null,
      };

  void _sendRequest(_Request request) {
    final link = _link!;
    final id = _sendOn(link, request.type, request.data);
    request.id = id;
    _inflight[id] = request;
  }

  void _onRequestTimeout(_Request request) {
    _queued.remove(request);
    final id = request.id;
    if (id != null) _inflight.remove(id);
    request.fail(
      RealtimeError(
        code: RealtimeErrorCode.timeout,
        message: 'No reply to ${request.type}',
        retryable: true,
        ref: id,
      ),
    );
  }

  void _failQueued(RealtimeError error) {
    final queued = List.of(_queued);
    _queued.clear();
    for (final request in queued) {
      request.fail(error);
    }
  }

  void _sendAnswer(_Answer answer) {
    final link = _link;
    if (link == null || !link.welcomed) return;
    final id = answer.id ??= link.ids.next();
    _sendOn(link, 'ans.submit', {
      'match_id': answer.matchId,
      'q': answer.q,
      'opt': answer.opt,
      'el_ms': answer.elMs,
    }, id: id);
    answer.resendTimer?.cancel();
    answer.resendTimer = _clock.timer(config.answerResendAfter, () {
      answer.resendTimer = null;
      if (!_outbox.contains(answer)) return;
      _log('No ans.ack for $id; resending');
      _sendAnswer(answer);
    });
  }

  void _answerAcked(AnsAckEvent ack) {
    final answer = _outbox.where((a) => a.id == ack.ref && a.q == ack.q).firstOrNull;
    if (answer == null) return;
    _removeAnswer(answer);
    answer.complete(ack);
  }

  /// An `error` for an answer. Retryable ones are resent by the timer; others end the answer.
  bool _answerRejected(String ref, ErrorEvent error) {
    final answer = _outbox.where((a) => a.id == ref).firstOrNull;
    if (answer == null) return false;
    if (error.retryable) {
      _log('ans.submit $ref failed (${error.code}); will resend');
      return true;
    }
    _removeAnswer(answer);
    answer.fail(error.toError());
    return true;
  }

  void _removeAnswer(_Answer answer) {
    _outbox.remove(answer);
    answer.resendTimer?.cancel();
    answer.resendTimer = null;
  }

  void _failOutbox(RealtimeError error) {
    for (final answer in List.of(_outbox)) {
      _removeAnswer(answer);
      answer.fail(error);
    }
  }

  static Future<AnsAckEvent> _answerFuture(Future<AnsAckEvent> future) => future..ignore();

  // ---------------------------------------------------------------------------------------------
  // Heartbeat and clock sync

  void _armWatchdog() {
    _watchdog?.cancel();
    if (!_isOpen) return;
    final remainingMs = heartbeatTimeout.inMilliseconds - (_clock.monotonicMs - _lastFrameMs);
    _watchdog = _clock.timer(Duration(milliseconds: max(0, remainingMs)), () {
      _watchdog = null;
      if (_link == null) return;
      _log('No frame for ${heartbeatTimeout.inSeconds} s; reconnecting');
      _dropLink('heartbeat timeout');
    });
  }

  void _startClockSync() {
    _clockResyncTimer?.cancel();
    _clockResyncTimer = null;
    if (serverClock.isSyncing || !_isOpen) return;
    serverClock.startSync();
    _sendClockPing();
  }

  /// Plans the next sync: [RealtimeConfig.clockResyncEvery] after the last one while a match
  /// lease is held, [RealtimeConfig.idleClockResyncEvery] otherwise. Called after each sync and
  /// whenever leases change, so entering a match with a stale clock syncs at once.
  void _scheduleClockResync() {
    _clockResyncTimer?.cancel();
    _clockResyncTimer = null;
    final lastSync = _lastClockSyncMs;
    if (!_isOpen || serverClock.isSyncing || lastSync == null) return;
    final interval = inMatch ? config.clockResyncEvery : config.idleClockResyncEvery;
    final dueInMs = lastSync + interval.inMilliseconds - _clock.monotonicMs;
    if (dueInMs <= 0) {
      _startClockSync();
    } else {
      _clockResyncTimer = _clock.timer(Duration(milliseconds: dueInMs), _startClockSync);
    }
  }

  void _sendAppState() {
    final link = _link;
    final foreground = _foreground;
    if (link == null || !link.welcomed || foreground == null) return;
    _sendOn(link, 'client.state', {'state': foreground ? 'foreground' : 'background'});
  }

  void _sendClockPing() {
    final link = _link;
    if (link == null || !link.welcomed) return;
    final c0 = _clock.monotonicMs;
    _clockPingC0 = c0;
    _sendOn(link, 'clock.ping', {'c0': c0});
    _clockPingTimer?.cancel();
    _clockPingTimer = _clock.timer(config.clockMaxRtt, () {
      _clockPingTimer = null;
      _clockPingC0 = null;
      serverClock.addLostSample();
      _continueClockSync();
    });
  }

  void _onClockPong(ClockPongEvent pong) {
    if (_clockPingC0 != pong.c0) return;
    _clockPingTimer?.cancel();
    _clockPingTimer = null;
    _clockPingC0 = null;
    serverClock.addSample(c0: pong.c0, serverMs: pong.s);
    _continueClockSync();
  }

  void _continueClockSync() {
    if (serverClock.isSyncing) {
      _sendClockPing();
      return;
    }
    _log('Clock synced: ${serverClock.sample}');
    _lastClockSyncMs = _clock.monotonicMs;
    _scheduleClockResync();
  }

  // ---------------------------------------------------------------------------------------------
  // Closing, backoff and the network

  void _onSocketError(_Link link, Object error, StackTrace stackTrace) {
    if (!identical(link, _link)) return;
    _log('Socket error', error: error, stackTrace: stackTrace);
    _dropLink('socket error');
  }

  void _onSocketDone(_Link link) {
    if (!identical(link, _link)) return;
    final code = link.socket.closeCode;
    _log('Socket closed (code: $code, reason: ${link.socket.closeReason})');
    _teardownLink();
    _afterClose(code, liveElsewhere: link.liveElsewhere);
  }

  /// Closes the socket from this side and reconnects as after a network drop.
  void _dropLink(String reason) {
    final liveElsewhere = _link?.liveElsewhere;
    _teardownLink(reason: reason);
    _afterClose(null, liveElsewhere: liveElsewhere);
  }

  void _teardownLink({String reason = 'closing', RealtimeError? inflightError}) {
    final link = _link;
    if (link == null) return;
    _link = null;
    link.close(reason);
    _helloTimer?.cancel();
    _helloTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    _clockResyncTimer?.cancel();
    _clockResyncTimer = null;
    _clockPingTimer?.cancel();
    _clockPingTimer = null;
    _clockPingC0 = null;
    serverClock.finishSync();
    for (final answer in _outbox) {
      answer.resendTimer?.cancel();
      answer.resendTimer = null;
    }
    final inflight = List.of(_inflight.values);
    _inflight.clear();
    for (final request in inflight) {
      request.fail(
        inflightError ??
            RealtimeError(
              code: RealtimeErrorCode.disconnected,
              message: 'The connection dropped before ${request.type} was answered',
              retryable: true,
              ref: request.id,
            ),
      );
    }
    for (final timer in _gapTimers.values) {
      timer.cancel();
    }
    _gapTimers.clear();
    _gapBuffers.clear();
    _syncRefs.clear();
  }

  /// Applies the close-code table (docs/protocol.md section 4). [liveElsewhere] is set when the
  /// server sent `LIVE_ELSEWHERE` on this socket; it turns the close into that terminal reason.
  void _afterClose(int? code, {TerminalReason? liveElsewhere}) {
    final terminal =
        liveElsewhere ??
        switch (code) {
          4403 => TerminalReason.revoked,
          4409 => TerminalReason.superseded,
          4426 => TerminalReason.updateRequired,
          _ => null,
        };
    if (terminal != null) {
      _terminate(terminal);
      return;
    }
    if (!_wanted) {
      _stop('closed with $code and no lease is held');
      return;
    }
    switch (code) {
      case 1012:
        // Server restarting: reconnect after 0–2 s. It doesn't count as a failed attempt.
        final jitterMs = config.restartJitter.inMilliseconds;
        _scheduleRetry(Duration(milliseconds: _random.nextInt(jitterMs + 1)), attempt: _attempt);
      case 4401 when _ticketRejections == 0:
        // Bad or expired ticket: get a new one and reconnect right away, once.
        _ticketRejections++;
        _connectNow();
      case 4401:
        _ticketRejections++;
        _backoff();
      case 4429:
        _retryNotBeforeMs = _clock.monotonicMs + config.rateLimitWait.inMilliseconds;
        _scheduleRetry(config.rateLimitWait, attempt: _attempt);
        _attempt++;
      default:
        // 1000, 1013, 4400, 4408, other codes and plain network drops.
        _backoff();
    }
  }

  /// Full jitter: a random delay from 0 to min(cap, base × 2^attempt).
  void _backoff() {
    final capMs = (inMatch ? config.matchBackoffCap : config.backoffCap).inMilliseconds;
    final windowMs = min(capMs, config.backoffBase.inMilliseconds * (1 << min(_attempt, 30)));
    final attempt = _attempt++;
    _scheduleRetry(Duration(milliseconds: _random.nextInt(windowMs + 1)), attempt: attempt);
  }

  void _scheduleRetry(Duration delay, {required int attempt}) {
    _cancelRetry();
    if (!_networkAvailable) {
      _setState(Backoff(attempt: attempt, retryAt: null));
      return;
    }
    _setState(Backoff(attempt: attempt, retryAt: _clock.now().add(delay)));
    _retryTimer = _clock.timer(delay, () {
      _retryTimer = null;
      _connectNow();
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _onNetworkChanged(bool available) {
    if (_disposed || available == _networkAvailable) return;
    _networkAvailable = available;
    _log(available ? 'Network is back' : 'Network lost');
    final state = _state;
    if (state is! Backoff) return;
    if (available) {
      _connectNow();
    } else {
      _cancelRetry();
      _setState(Backoff(attempt: state.attempt, retryAt: null));
    }
  }

  /// Closes everything and goes [Idle].
  void _stop(String reason) {
    _log('Stopping: $reason');
    _generation++;
    _cancelRetry();
    _lingerTimer?.cancel();
    _lingerTimer = null;
    _teardownLink(reason: 'no longer needed');
    _failQueued(
      const RealtimeError(
        code: RealtimeErrorCode.notConnected,
        message: 'The connection closed because no lease is held',
        retryable: true,
      ),
    );
    _attempt = 0;
    _ticketRejections = 0;
    _setState(const Idle());
  }

  void _terminate(TerminalReason reason) {
    _log('Terminal: ${reason.name}');
    _generation++;
    _cancelRetry();
    _lingerTimer?.cancel();
    _lingerTimer = null;
    _teardownLink(reason: reason.name);
    _setState(Terminal(reason));
    final error = _closedError();
    _failQueued(error);
    _failOutbox(error);
  }

  // ---------------------------------------------------------------------------------------------
  // Helpers

  String _sendOn(_Link link, String type, Map<String, Object?> data, {String? id}) {
    final messageId = id ?? link.ids.next();
    link.socket.send(encodeClientMessage(type, messageId, data));
    return messageId;
  }

  void _setState(ConnState next) {
    _state = next;
    _log('State: $next');
    if (!_stateController.isClosed) _stateController.add(next);
  }

  void _log(String message, {Object? error, StackTrace? stackTrace}) =>
      _logger?.call(message, error: error, stackTrace: stackTrace);

  static void _closeQuietly(RealtimeSocket socket, String reason) {
    unawaited(socket.close(1000, reason).catchError((Object _) {}));
  }
}

/// One socket after the handshake started.
final class _Link {
  _Link(this.socket);

  final RealtimeSocket socket;

  /// Message ids for this connection.
  final MessageIds ids = MessageIds();
  StreamSubscription<Object?>? subscription;
  bool welcomed = false;

  /// Set when the server said `LIVE_ELSEWHERE` on this socket.
  TerminalReason? liveElsewhere;

  void close(String reason) {
    unawaited(subscription?.cancel());
    subscription = null;
    RealtimeConnection._closeQuietly(socket, reason);
  }
}

final class _Request {
  _Request(this.type, this.data, this.isReply);

  final String type;
  final Map<String, Object?> data;
  final ReplyMatcher? isReply;
  final Completer<Ack> _completer = Completer<Ack>();
  String? id;
  Timer? timer;

  Future<Ack> get future => _completer.future;

  void succeed(Ack ack) {
    timer?.cancel();
    if (!_completer.isCompleted) _completer.complete(ack);
  }

  void fail(RealtimeError error) {
    timer?.cancel();
    if (!_completer.isCompleted) _completer.completeError(error);
  }
}

final class _Answer {
  _Answer({required this.matchId, required this.q, required this.opt, required this.elMs}) {
    // The ack also reaches the app through the event stream, so callers may ignore the future.
    _completer.future.ignore();
  }

  final String matchId;
  final int q;
  final String opt;
  final int elMs;
  final Completer<AnsAckEvent> _completer = Completer<AnsAckEvent>();

  /// Assigned on the first send and kept for every resend.
  String? id;
  Timer? resendTimer;

  Future<AnsAckEvent> get future => _completer.future;

  void complete(AnsAckEvent ack) {
    if (!_completer.isCompleted) _completer.complete(ack);
  }

  void fail(RealtimeError error) {
    if (!_completer.isCompleted) _completer.completeError(error);
  }
}
