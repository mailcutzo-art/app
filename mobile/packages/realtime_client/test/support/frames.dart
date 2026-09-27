import 'dart:convert';

import 'package:realtime_client/realtime_client.dart';

/// A server frame `{v, t, ch, seq, ts, d}`.
Map<String, Object?> frame(
  String type, [
  Map<String, Object?> data = const {},
  String? ch,
  int? seq,
  int? ts,
]) => {'v': 1, 't': type, 'ch': ?ch, 'seq': ?seq, 'ts': ?ts, 'd': data};

/// Decodes [frame] the way the connection does.
ServerEvent decodeFrame(Map<String, Object?> frame) => ServerEvent.decode(jsonEncode(frame));

/// A decoded event, for tests that don't need a socket.
ServerEvent event(
  String type, [
  Map<String, Object?> data = const {},
  String? ch,
  int? seq,
  int? ts,
]) => decodeFrame(frame(type, data, ch, seq, ts));

/// A player card as the server sends it.
Map<String, Object?> card(String uid) => {
  'uid': uid,
  'name': 'Player $uid',
  'avatar': 'fox',
  'level': 4,
};

/// The payload of `welcome`.
Map<String, Object?> welcomeData({
  String userId = 'u1',
  int serverMs = 1790000000000,
  int hbS = 10,
  List<Map<String, Object?>> active = const [],
}) => {'conn_id': 'k9', 'user_id': userId, 'server_ms': serverMs, 'hb_s': hbS, 'active': active};
