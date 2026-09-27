import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'socket.dart';

/// The real [WebSocketConnector], built on `web_socket_channel` (works on the VM, Flutter and the
/// web).
final class WebSocketChannelConnector implements WebSocketConnector {
  WebSocketChannelConnector(
    this.uri, {
    this.connectTimeout = const Duration(seconds: 10),
    this.protocols,
  });

  /// For example `wss://rt.example.com/v1/ws`.
  final Uri uri;

  /// How long the TCP, TLS and WebSocket handshakes may take together.
  final Duration connectTimeout;
  final Iterable<String>? protocols;

  @override
  Future<RealtimeSocket> connect() async {
    final channel = WebSocketChannel.connect(uri, protocols: protocols);
    try {
      await channel.ready.timeout(connectTimeout);
    } on Object {
      // Abandon the attempt. If the handshake still finishes later, the channel closes itself
      // because its sink is already closed.
      unawaited(_closeQuietly(channel));
      rethrow;
    }
    return _ChannelSocket(channel);
  }
}

Future<void> _closeQuietly(WebSocketChannel channel) async {
  try {
    await channel.sink.close();
  } on Object {
    // Nothing to do: the socket is gone either way.
  }
}

final class _ChannelSocket implements RealtimeSocket {
  _ChannelSocket(this._channel);

  final WebSocketChannel _channel;
  bool _closed = false;

  @override
  Stream<Object?> get frames => _channel.stream.map((Object? frame) => frame);

  @override
  void send(String text) {
    if (_closed) return;
    try {
      _channel.sink.add(text);
    } on StateError {
      _closed = true;
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel.sink.close(code, reason);
    } on Object {
      // Already closed by the peer, or the socket died.
    }
  }

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;
}
