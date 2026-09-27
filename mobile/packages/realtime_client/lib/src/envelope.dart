import 'dart:collection';
import 'dart:convert';

import 'json.dart';

/// The protocol version this client speaks (`v` in every frame, `proto` in `hello`).
const int protocolVersion = 1;

/// The longest client message id the server accepts.
const int maxMessageIdLength = 36;

/// One decoded server frame: `{v, t, id, ch, seq, ts, d}` (docs/protocol.md section 2).
///
/// Decoding only validates the envelope. [ServerEvent.fromEnvelope] turns the payload into a
/// typed event.
final class Envelope {
  const Envelope({
    required this.type,
    this.id,
    this.channel,
    this.seq,
    this.ts,
    this.data = const {},
  });

  /// Decodes one WebSocket frame.
  ///
  /// Throws a [FormatException] for anything that is not a text frame holding a JSON object with
  /// `v: 1` and a non-empty `t`, or whose envelope fields have the wrong types. The caller counts
  /// that as a protocol error.
  factory Envelope.decode(Object? frame) {
    if (frame is! String) {
      throw const FormatException('Expected a UTF-8 text frame');
    }
    final Object? json;
    try {
      json = jsonDecode(frame);
    } on FormatException catch (error) {
      throw FormatException('Frame is not valid JSON: ${error.message}');
    }
    return Envelope.fromJson(json);
  }

  /// Validates an already decoded frame.
  factory Envelope.fromJson(Object? json) {
    final frame = JsonObject.from(json, 'frame');
    final version = frame.integer('v');
    if (version != protocolVersion) {
      throw FormatException('Unsupported protocol version $version (expected $protocolVersion)');
    }
    final type = frame.string('t');
    if (type.isEmpty) throw const FormatException('frame: "t" must not be empty');
    final seq = frame.optInt('seq');
    if (seq != null && seq < 0) throw FormatException('frame: negative seq $seq');
    return Envelope(
      type: type,
      id: frame.optString('id'),
      channel: frame.optString('ch'),
      seq: seq,
      ts: frame.optInt('ts'),
      data: UnmodifiableMapView(frame.optObject('d')?.map ?? const {}),
    );
  }

  /// `t`: the message type, for example `q.show`.
  final String type;

  /// `id`: only set on client messages. Servers echo it as `ref` in the payload instead.
  final String? id;

  /// `ch`: the channel the event belongs to (`u`, `m:<id>`, `r:<id>` or `t:<id>`).
  final String? channel;

  /// `seq`: the per-channel sequence number, on resumable channels only.
  final int? seq;

  /// `ts`: server time in Unix milliseconds when the event was produced.
  final int? ts;

  /// `d`: the payload. Read-only.
  final Map<String, Object?> data;

  @override
  String toString() => [
    'Envelope($type',
    if (channel != null) ' ch=$channel',
    if (seq != null) ' seq=$seq',
    ')',
  ].join();
}

/// Encodes a client message as `{v, t, id, d}`.
///
/// Throws an [ArgumentError] if [id] is empty or longer than [maxMessageIdLength].
String encodeClientMessage(String type, String id, [Map<String, Object?> data = const {}]) {
  if (id.isEmpty || id.length > maxMessageIdLength) {
    throw ArgumentError.value(id, 'id', 'must be 1 to $maxMessageIdLength characters');
  }
  return jsonEncode({'v': protocolVersion, 't': type, 'id': id, 'd': data});
}

/// Hands out client message ids `c1`, `c2`, … for one connection.
///
/// Ids only need to be unique per connection, so every connection starts again at `c1`. A message
/// that is resent with its original id (an unacknowledged answer) [reserve]s that id first, so
/// the counter skips it.
final class MessageIds {
  int _counter = 0;
  final Set<String> _reserved = {};

  /// The next unused id.
  String next() {
    String id;
    do {
      id = 'c${++_counter}';
    } while (_reserved.contains(id));
    return id;
  }

  /// Marks a caller-supplied [id] as used on this connection, so [next] never returns it.
  void reserve(String id) => _reserved.add(id);
}
