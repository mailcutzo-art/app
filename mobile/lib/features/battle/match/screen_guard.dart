import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Protects a live-game screen: keeps the screen on, and on Android blocks screenshots, screen
/// sharing and Circle to Search (`FLAG_SECURE`). Screens call [protect] when they appear and
/// [release] when they go; overlapping screens are counted, so the last one out switches it off.
abstract interface class ScreenGuard {
  Future<void> protect();

  Future<void> release();
}

/// The real guard: `wakelock_plus`, and a small method channel implemented in `MainActivity`.
/// Elsewhere (iOS, the web, tests) the secure flag is a no-op.
class PlatformScreenGuard implements ScreenGuard {
  PlatformScreenGuard({bool? android})
    : _android = android ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const channel = MethodChannel('quiz_app/screen_guard');

  final bool _android;
  int _holders = 0;

  @override
  Future<void> protect() async {
    if (_holders++ > 0) return;
    await _quietly(WakelockPlus.enable);
    if (_android) await _quietly(() => channel.invokeMethod<void>('setSecure', true));
  }

  @override
  Future<void> release() async {
    if (_holders == 0 || --_holders > 0) return;
    await _quietly(WakelockPlus.disable);
    if (_android) await _quietly(() => channel.invokeMethod<void>('setSecure', false));
  }

  static Future<void> _quietly(Future<void> Function() call) async {
    try {
      await call();
    } on Object catch (error) {
      // A missing plugin (web, tests) must never break the game.
      debugPrint('Screen guard: $error');
    }
  }
}

final screenGuardProvider = Provider<ScreenGuard>((ref) => PlatformScreenGuard());
