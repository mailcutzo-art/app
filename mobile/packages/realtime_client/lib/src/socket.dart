/// One open WebSocket, as the connection manager sees it.
abstract interface class RealtimeSocket {
  /// Incoming frames: a `String` for text frames, a `List<int>` for binary ones. The stream ends
  /// when the socket closes; [closeCode] is set by then.
  Stream<Object?> get frames;

  /// Sends a text frame. Does nothing once the socket is closed.
  void send(String text);

  /// Closes the socket. Safe to call more than once.
  Future<void> close([int? code, String? reason]);

  /// The close code the peer sent, or `null` if the connection dropped without one.
  int? get closeCode;

  /// The close reason the peer sent.
  String? get closeReason;
}

/// Opens WebSockets to the realtime endpoint (`wss://<host>/v1/ws`).
abstract interface class WebSocketConnector {
  /// Opens a new socket. Completes once the WebSocket handshake is done, and throws if it fails.
  /// The ticket is never part of the URL; it goes in `hello`.
  Future<RealtimeSocket> connect();
}
