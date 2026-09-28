import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/network/app_failure.dart';

DioException _response(int status, {Object? body, Map<String, List<String>>? headers}) {
  final options = RequestOptions(path: '/x');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<Object?>(
      requestOptions: options,
      statusCode: status,
      data: body,
      headers: Headers.fromMap(headers ?? {}),
    ),
  );
}

Map<String, Object?> _envelope(String code, String message, [Object? details]) => {
  'error': {'code': code, 'message': message, 'details': details, 'request_id': 'r1'},
};

void main() {
  test('transport errors map to friendly retryable failures', () {
    final options = RequestOptions(path: '/x');
    expect(
      failureFromDio(DioException(requestOptions: options, type: DioExceptionType.connectionError)),
      isA<NetworkFailure>().having((f) => f.isRetryable, 'retryable', isTrue),
    );
    expect(
      failureFromDio(DioException(requestOptions: options, type: DioExceptionType.receiveTimeout)),
      isA<TimeoutFailure>(),
    );
    expect(
      failureFromDio(DioException(requestOptions: options, type: DioExceptionType.cancel)),
      isA<CancelledFailure>(),
    );
  });

  test('validation errors keep the server message and field details', () {
    final failure = failureFromDio(
      _response(
        422,
        body: _envelope('VALIDATION_FAILED', 'Check the highlighted fields.', {
          'fields': {'handle': 'That username is taken', 'n': 3},
        }),
      ),
    );
    expect(failure, isA<ValidationFailure>());
    failure as ValidationFailure;
    expect(failure.message, 'Check the highlighted fields.');
    expect(failure.code, 'VALIDATION_FAILED');
    expect(failure.fields, {'handle': 'That username is taken'});
  });

  test('status codes map to specific failures', () {
    expect(failureFromDio(_response(401)), isA<UnauthorizedFailure>());
    expect(failureFromDio(_response(403, body: _envelope('BANNED', 'x'))), isA<ForbiddenFailure>());
    expect(
      failureFromDio(_response(404, body: _envelope('NOT_FOUND', 'x'))),
      isA<NotFoundFailure>(),
    );
    expect(
      failureFromDio(_response(410, body: _envelope('INVITE_EXPIRED', 'x'))),
      isA<NotFoundFailure>().having((f) => f.code, 'code', 'INVITE_EXPIRED'),
    );
    expect(failureFromDio(_response(409, body: _envelope('TAKEN', 'x'))), isA<ConflictFailure>());
    expect(failureFromDio(_response(426)), isA<UpgradeRequiredFailure>());
    expect(
      failureFromDio(_response(503, body: _envelope('MAINTENANCE', 'x'))),
      isA<MaintenanceFailure>(),
    );
    expect(failureFromDio(_response(500)), isA<ServerFailure>());
  });

  test('rate limits carry Retry-After', () {
    final failure = failureFromDio(
      _response(
        429,
        headers: {
          'retry-after': ['7'],
        },
      ),
    );
    expect(
      failure,
      isA<RateLimitedFailure>().having(
        (f) => f.retryAfter,
        'retryAfter',
        const Duration(seconds: 7),
      ),
    );
  });

  test('a malformed body never leaks raw text', () {
    final failure = failureFromDio(_response(400, body: '<html>stack trace</html>'));
    expect(failure.message, isNot(contains('stack')));
  });
}
