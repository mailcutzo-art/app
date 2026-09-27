import 'dart:convert';

import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

void main() {
  group('Envelope.decode', () {
    test('reads every envelope field of a server frame', () {
      final envelope = Envelope.decode(
        '{"v":1,"t":"q.show","ch":"m:01929c2e","seq":41,"ts":1790000000123,"d":{"q":1}}',
      );

      expect(envelope.type, 'q.show');
      expect(envelope.channel, 'm:01929c2e');
      expect(envelope.seq, 41);
      expect(envelope.ts, 1790000000123);
      expect(envelope.data, {'q': 1});
      expect(envelope.id, isNull);
    });

    test('treats a missing payload as empty and ignores unknown envelope fields', () {
      final envelope = Envelope.decode('{"v":1,"t":"ping","x":"later","ch":"u"}');

      expect(envelope.data, isEmpty);
      expect(envelope.seq, isNull);
    });

    test('accepts integral doubles for integer fields', () {
      final envelope = Envelope.decode('{"v":1.0,"t":"x","seq":41.0,"ts":5.0,"d":{}}');

      expect(envelope.seq, 41);
      expect(envelope.ts, 5);
    });

    test('keeps the payload read-only', () {
      final envelope = Envelope.decode('{"v":1,"t":"x","d":{"a":1}}');

      expect(() => envelope.data['a'] = 2, throwsUnsupportedError);
    });

    final badFrames = <String, Object?>{
      'a binary frame': utf8.encode('{"v":1,"t":"ping","d":{}}'),
      'null': null,
      'invalid JSON': '{"v":1,"t":',
      'a JSON array': '[1,2]',
      'a JSON string': '"hello"',
      'a missing version': '{"t":"ping","d":{}}',
      'version 2': '{"v":2,"t":"ping","d":{}}',
      'a string version': '{"v":"1","t":"ping","d":{}}',
      'a missing type': '{"v":1,"d":{}}',
      'an empty type': '{"v":1,"t":"","d":{}}',
      'a numeric type': '{"v":1,"t":7,"d":{}}',
      'a string seq': '{"v":1,"t":"x","seq":"41","d":{}}',
      'a fractional seq': '{"v":1,"t":"x","seq":4.5,"d":{}}',
      'a negative seq': '{"v":1,"t":"x","seq":-1,"d":{}}',
      'a numeric channel': '{"v":1,"t":"x","ch":5,"d":{}}',
      'a list payload': '{"v":1,"t":"x","d":[1]}',
      'a string payload': '{"v":1,"t":"x","d":"{}"}',
    };
    for (final MapEntry(key: name, value: frame) in badFrames.entries) {
      test('rejects $name as a protocol error', () {
        expect(() => Envelope.decode(frame), throwsFormatException);
      });
    }
  });

  group('ServerEvent.decode', () {
    test('passes unknown message types through as UnknownEvent', () {
      final event = ServerEvent.decode('{"v":1,"t":"lb.update","ch":"u","d":{"rows":[]}}');

      expect(event, isA<UnknownEvent>());
      expect(event.type, 'lb.update');
      expect(event.channel, 'u');
      expect(event.envelope.data, {'rows': <Object?>[]});
    });

    test('ignores unknown payload fields of known types', () {
      final event = ServerEvent.decode('{"v":1,"t":"ping","d":{"n":7,"new_field":{"x":1}}}');

      expect(event, isA<PingEvent>().having((e) => e.n, 'n', 7));
    });

    test('rejects a known type with a missing required field', () {
      expect(() => ServerEvent.decode('{"v":1,"t":"ping","d":{}}'), throwsFormatException);
    });

    test('rejects a malformed envelope before looking at the type', () {
      expect(() => ServerEvent.decode('{"v":3,"t":"ping","d":{"n":1}}'), throwsFormatException);
    });
  });

  group('encodeClientMessage', () {
    test('encodes {v, t, id, d}', () {
      final json = jsonDecode(encodeClientMessage('ans.submit', 'c7', {'q': 3, 'opt': 'k2P9x'}));

      expect(json, {
        'v': 1,
        't': 'ans.submit',
        'id': 'c7',
        'd': {'q': 3, 'opt': 'k2P9x'},
      });
    });

    test('sends an empty payload as {}', () {
      expect(jsonDecode(encodeClientMessage('mm.cancel', 'c2')), containsPair('d', isEmpty));
    });

    test('accepts caller-supplied ids up to 36 characters', () {
      final id = 'a' * maxMessageIdLength;

      expect(jsonDecode(encodeClientMessage('x', id)), containsPair('id', id));
      expect(() => encodeClientMessage('x', '${id}b'), throwsArgumentError);
      expect(() => encodeClientMessage('x', ''), throwsArgumentError);
    });
  });

  group('MessageIds', () {
    test('counts c1, c2, … and restarts for each connection', () {
      final first = MessageIds();
      expect([first.next(), first.next(), first.next()], ['c1', 'c2', 'c3']);

      final second = MessageIds();
      expect(second.next(), 'c1');
    });

    test('skips ids reserved for resent messages', () {
      final ids = MessageIds()
        ..reserve('c2')
        ..reserve('c3');

      expect([ids.next(), ids.next(), ids.next()], ['c1', 'c4', 'c5']);
    });
  });
}
