import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';

import '../support/fakes.dart';

void main() {
  ApiClient client(FakeAdapter adapter) =>
      ApiClient(Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter);

  test('the last failed request id comes from the error envelope', () async {
    final api = client(
      FakeAdapter(
        (options) => options.path == '/ok'
            ? jsonBody({'ok': true})
            : jsonBody({
                'error': {'code': 'INTERNAL_ERROR', 'message': 'Oops', 'request_id': 'req-42'},
              }, status: 500),
      ),
    );
    expect(api.lastErrorRequestId, isNull);

    await expectLater(api.get('/broken'), throwsA(isA<ServerFailure>()));
    expect(api.lastErrorRequestId, 'req-42');

    await api.get('/ok');
    expect(api.lastErrorRequestId, 'req-42', reason: 'a success doesn\'t clear the reference');
  });

  test('without an envelope, the X-Request-ID header is used', () async {
    final api = client(
      FakeAdapter(
        (_) => jsonBody(
          'bad gateway',
          status: 502,
          headers: {
            'x-request-id': ['hdr-7'],
          },
        ),
      ),
    );
    await expectLater(api.get('/x'), throwsA(isA<ServerFailure>()));
    expect(api.lastErrorRequestId, 'hdr-7');
  });

  test('conflicts and validation errors carry the envelope details', () async {
    final api = client(
      FakeAdapter(
        (options) => jsonBody({
          'error': {
            'code': 'HANDLE_CHANGE_TOO_SOON',
            'message': 'Not yet',
            'details': {'next_change_at': '2026-10-20T00:00:00Z'},
          },
        }, status: options.path == '/conflict' ? 409 : 422),
      ),
    );
    for (final path in ['/conflict', '/invalid']) {
      try {
        await api.patch(path);
        fail('expected a failure');
      } on AppFailure catch (failure) {
        expect(failure.code, 'HANDLE_CHANGE_TOO_SOON');
        expect(failure.details['next_change_at'], '2026-10-20T00:00:00Z');
      }
    }
  });
}
