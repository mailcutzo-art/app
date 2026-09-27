import 'package:dio/dio.dart';

/// Every error the UI can see. Messages are written for people; raw server or
/// exception text never reaches the screen.
sealed class AppFailure implements Exception {
  const AppFailure(this.message, {this.code});

  final String message;

  /// Machine-readable code from the server envelope, when there is one.
  final String? code;

  bool get isRetryable => false;

  @override
  String toString() => '$runtimeType(${code ?? ''}: $message)';
}

final class NetworkFailure extends AppFailure {
  const NetworkFailure() : super('You\'re offline. Check your connection and try again.');

  @override
  bool get isRetryable => true;
}

final class TimeoutFailure extends AppFailure {
  const TimeoutFailure() : super('The server is taking too long. Please try again.');

  @override
  bool get isRetryable => true;
}

final class UnauthorizedFailure extends AppFailure {
  const UnauthorizedFailure({super.code}) : super('Your session has ended. Please sign in again.');
}

final class ForbiddenFailure extends AppFailure {
  const ForbiddenFailure(super.message, {super.code});
}

final class NotFoundFailure extends AppFailure {
  const NotFoundFailure(super.message, {super.code});
}

final class ConflictFailure extends AppFailure {
  const ConflictFailure(super.message, {super.code});
}

final class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message, {super.code, this.fields = const {}});

  /// Field name → problem, for inline form errors.
  final Map<String, String> fields;
}

final class RateLimitedFailure extends AppFailure {
  const RateLimitedFailure({this.retryAfter, super.code})
    : super('Too many attempts. Please wait a moment.');

  final Duration? retryAfter;

  @override
  bool get isRetryable => true;
}

final class UpgradeRequiredFailure extends AppFailure {
  const UpgradeRequiredFailure() : super('Please update the app to continue.');
}

final class MaintenanceFailure extends AppFailure {
  const MaintenanceFailure() : super('We\'re doing quick maintenance. Please try again soon.');

  @override
  bool get isRetryable => true;
}

final class ServerFailure extends AppFailure {
  const ServerFailure({super.code}) : super('Something went wrong on our side. Please try again.');

  @override
  bool get isRetryable => true;
}

final class CancelledFailure extends AppFailure {
  const CancelledFailure() : super('Cancelled.');
}

final class UnexpectedFailure extends AppFailure {
  const UnexpectedFailure() : super('Something went wrong. Please try again.');

  @override
  bool get isRetryable => true;
}

/// Maps transport errors and the server's `{"error": {...}}` envelope to an
/// [AppFailure].
AppFailure failureFromDio(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.transformTimeout:
      return const TimeoutFailure();
    case DioExceptionType.connectionError:
      return const NetworkFailure();
    case DioExceptionType.cancel:
      return const CancelledFailure();
    case DioExceptionType.badCertificate:
      return const NetworkFailure();
    case DioExceptionType.badResponse:
      return _fromResponse(e.response);
    case DioExceptionType.unknown:
      final inner = e.error;
      if (inner is AppFailure) return inner;
      return const NetworkFailure();
  }
}

AppFailure _fromResponse(Response<dynamic>? response) {
  final status = response?.statusCode ?? 0;
  final (code, message, details) = _envelope(response?.data);
  final text = message ?? 'Something went wrong. Please try again.';
  switch (status) {
    case 400:
    case 422:
      return ValidationFailure(text, code: code, fields: _fieldErrors(details));
    case 401:
      return UnauthorizedFailure(code: code);
    case 403:
      return ForbiddenFailure(text, code: code);
    case 404:
      return NotFoundFailure(text, code: code);
    case 409:
      return ConflictFailure(text, code: code);
    case 426:
      return const UpgradeRequiredFailure();
    case 429:
      final seconds = int.tryParse(response?.headers.value('retry-after') ?? '');
      return RateLimitedFailure(
        code: code,
        retryAfter: seconds == null ? null : Duration(seconds: seconds),
      );
    case 503:
      return code == 'MAINTENANCE' ? const MaintenanceFailure() : ServerFailure(code: code);
    default:
      return status >= 500 ? ServerFailure(code: code) : const UnexpectedFailure();
  }
}

(String?, String?, Object?) _envelope(Object? data) => switch (data) {
  {
    'error':
        {'code': final String code, 'message': final String message} &&
        final Map<dynamic, dynamic> error,
  } =>
    (code, message, error['details']),
  _ => (null, null, null),
};

Map<String, String> _fieldErrors(Object? details) {
  if (details is! Map) return const {};
  final fields = details['fields'];
  if (fields is! Map) return const {};
  return {
    for (final MapEntry(:key, :value) in fields.entries)
      if (key is String && value is String) key: value,
  };
}
