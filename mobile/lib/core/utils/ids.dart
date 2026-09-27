import 'dart:math';

final _random = Random.secure();

/// Random id of [bytes] bytes (128 bits by default), hex encoded. Used for
/// idempotency keys and client-side answer ids.
String randomHexId([int bytes = 16]) =>
    List.generate(bytes, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
