import 'events.dart';

/// What to do with an incoming event, per [ChannelTracker.accept].
enum SeqDecision {
  /// Deliver it. For a tracked channel its seq is now the last applied one.
  apply,

  /// Drop it: its seq is at or below the last applied one.
  duplicate,

  /// Hold it: one or more earlier events are missing. The caller sends
  /// `sync {ch, last_seq}` and buffers or drops events until the replay or snapshot arrives.
  gap,
}

/// One `hello.resume` entry.
final class ResumeEntry {
  const ResumeEntry(this.channel, this.lastSeq);

  final String channel;
  final int lastSeq;

  Map<String, Object?> toJson() => {'ch': channel, 'last_seq': lastSeq};

  @override
  bool operator ==(Object other) =>
      other is ResumeEntry && other.channel == channel && other.lastSeq == lastSeq;

  @override
  int get hashCode => Object.hash(channel, lastSeq);

  @override
  String toString() => 'ResumeEntry($channel, $lastSeq)';
}

/// Keeps the last applied `seq` per resumable channel (`m:*` and `r:*`), docs/protocol.md
/// section 10.
///
/// - Events on other channels, or without a seq, always apply. Per-player messages (`ans.ack`,
///   `match.settled`) come without a seq, so they never cause gaps.
/// - A snapshot (`match.snapshot`, `room.state`) applies and resets the channel to its seq, unless
///   its seq is lower than the last one applied: a stale snapshot is a duplicate.
/// - A channel seen for the first time starts at 0, so its first event must be seq 1 or a
///   snapshot; anything else is a gap and gets a `sync` from 0.
/// - Forgotten channels drop out of the resume list. Late events on them still apply, untracked,
///   until a snapshot starts tracking the channel again.
final class ChannelTracker {
  final Map<String, int> _lastSeq = {};
  final Set<String> _forgotten = {};

  static const _maxForgotten = 64;

  /// Whether [channel] carries a `seq` that can be resumed.
  static bool isResumable(String channel) => channel.startsWith('m:') || channel.startsWith('r:');

  /// Whether [event] carries a channel's full state.
  static bool isSnapshot(ServerEvent event) =>
      event is MatchSnapshotEvent || event is RoomStateEvent;

  /// Decides what to do with [event], and records its seq when it applies.
  SeqDecision accept(ServerEvent event) =>
      acceptSeq(event.channel, event.seq, snapshot: isSnapshot(event));

  /// [accept] for a raw channel and seq.
  SeqDecision acceptSeq(String? channel, int? seq, {bool snapshot = false}) {
    if (channel == null || seq == null || !isResumable(channel)) return SeqDecision.apply;
    if (snapshot) {
      final last = _lastSeq[channel];
      if (last != null && seq < last) return SeqDecision.duplicate;
      _forgotten.remove(channel);
      _lastSeq[channel] = seq;
      return SeqDecision.apply;
    }
    if (_forgotten.contains(channel)) return SeqDecision.apply;
    final last = _lastSeq.putIfAbsent(channel, () => 0);
    if (seq <= last) return SeqDecision.duplicate;
    if (seq > last + 1) return SeqDecision.gap;
    _lastSeq[channel] = seq;
    return SeqDecision.apply;
  }

  /// The last applied seq on [channel], or `null` if it isn't tracked.
  int? lastSeq(String channel) => _lastSeq[channel];

  /// Whether [channel] is tracked (and so part of [resumeList]).
  bool isTracked(String channel) => _lastSeq.containsKey(channel);

  /// The tracked channels, oldest first.
  Iterable<String> get channels => _lastSeq.keys;

  /// Starts tracking [channel] from seq 0 if it isn't tracked yet, for example right after
  /// `mm.found`, so a drop before the first snapshot still resumes it.
  void track(String channel) {
    if (!isResumable(channel)) return;
    _forgotten.remove(channel);
    _lastSeq.putIfAbsent(channel, () => 0);
  }

  /// Stops tracking [channel], for example once a match is over and settled.
  void forget(String channel) {
    if (_lastSeq.remove(channel) == null && !isResumable(channel)) return;
    _forgotten.add(channel);
    if (_forgotten.length > _maxForgotten) _forgotten.remove(_forgotten.first);
  }

  /// The `hello.resume` list: every tracked channel with its last applied seq.
  List<ResumeEntry> resumeList() => [
    for (final MapEntry(key: channel, value: seq) in _lastSeq.entries) ResumeEntry(channel, seq),
  ];
}
