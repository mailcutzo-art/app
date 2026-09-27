@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

/// A local WebSocket server; [onSocket] plays the server side.
Future<HttpServer> serve(void Function(WebSocket socket) onSocket) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (request.uri.path != '/v1/ws') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    onSocket(await WebSocketTransformer.upgrade(request));
  });
  return server;
}

Uri wsUri(HttpServer server) => Uri.parse('ws://127.0.0.1:${server.port}/v1/ws');

void main() {
  test('opens a socket, exchanges text frames and reports the close code', () async {
    final server = await serve((socket) {
      socket.listen((Object? frame) {
        socket.add('echo:$frame');
        unawaited(socket.close(4409, 'Playing on another device'));
      });
    });
    addTearDown(() => server.close(force: true));

    final socket = await WebSocketChannelConnector(wsUri(server)).connect();
    final frames = <Object?>[];
    final done = Completer<void>();
    socket.frames.listen(frames.add, onDone: done.complete);
    socket.send('hello');
    await done.future.timeout(const Duration(seconds: 5));

    expect(frames, ['echo:hello']);
    expect(socket.closeCode, 4409);
    expect(socket.closeReason, 'Playing on another device');
    socket.send('ignored after close');
    await socket.close();
  });

  test('fails when the handshake takes longer than the connect timeout', () async {
    // Accepts TCP connections but never answers the HTTP upgrade.
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    silent.listen(held.add);
    addTearDown(() async {
      for (final socket in held) {
        socket.destroy();
      }
      await silent.close();
    });

    final connector = WebSocketChannelConnector(
      Uri.parse('ws://127.0.0.1:${silent.port}/v1/ws'),
      connectTimeout: const Duration(milliseconds: 200),
    );
    final watch = Stopwatch()..start();

    await expectLater(connector.connect(), throwsA(isA<TimeoutException>()));
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('fails when nothing is listening', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final connector = WebSocketChannelConnector(Uri.parse('ws://127.0.0.1:$port/v1/ws'));

    await expectLater(connector.connect(), throwsA(anything));
  });

  test('RealtimeConnection completes a real handshake over it', () async {
    final hellos = <Map<String, Object?>>[];
    final server = await serve((socket) {
      socket.listen((Object? text) {
        final message = jsonDecode(text! as String) as Map<String, Object?>;
        final data = message['d']! as Map<String, Object?>;
        switch (message['t']) {
          case 'hello':
            hellos.add(data);
            socket.add(
              jsonEncode({
                'v': 1,
                't': 'welcome',
                'ch': 'u',
                'd': {
                  'user_id': 'u1',
                  'server_ms': DateTime.now().millisecondsSinceEpoch,
                  'hb_s': 10,
                  'active': <Object?>[],
                },
              }),
            );
          case 'clock.ping':
            socket.add(
              jsonEncode({
                'v': 1,
                't': 'clock.pong',
                'd': {'c0': data['c0'], 's': DateTime.now().millisecondsSinceEpoch},
              }),
            );
          case 'mm.cancel':
            socket.add(
              jsonEncode({
                'v': 1,
                't': 'ack',
                'd': {'ref': message['id']},
              }),
            );
        }
      });
    });
    addTearDown(() => server.close(force: true));
    final network = StreamController<bool>.broadcast();
    addTearDown(network.close);

    final connection = RealtimeConnection(
      fetchTicket: () async => 'real-ticket',
      connector: WebSocketChannelConnector(wsUri(server)),
      networkAvailable: network.stream,
      build: 57,
      platform: 'android',
    );
    addTearDown(connection.dispose);
    final open = connection.states.firstWhere((s) => s is Open);
    connection.acquire('test');
    await open.timeout(const Duration(seconds: 5));

    expect(hellos.single['ticket'], 'real-ticket');
    final ack = await connection.request('mm.cancel', {});
    expect(ack.reply, isA<AckEvent>());
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(connection.serverClock.isSynced, isTrue);
    expect(
      (connection.serverClock.nowServerMs() - DateTime.now().millisecondsSinceEpoch).abs(),
      lessThan(1000),
    );
  });
}
