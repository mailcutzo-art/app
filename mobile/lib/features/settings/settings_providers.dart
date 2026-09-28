import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/env.dart';
import '../../core/auth/google_auth.dart';
import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import '../../core/storage/prefs.dart';
import 'data/settings_models.dart';
import 'data/settings_repository.dart';

/// Keys for settings kept on this phone only.
abstract final class SettingsPrefs {
  static const theme = 'settings.theme';
  static const haptics = 'settings.haptics';
  static const sounds = 'settings.sounds';
}

/// The shared preferences, or null where none were provided (some tests): settings then live in
/// memory only.
SharedPreferences? _prefs(Ref ref) {
  try {
    return ref.watch(sharedPrefsProvider);
  } on Object {
    return null;
  }
}

/// Light, dark or the system's choice, kept on this phone and applied by `QuizApp`.
final themeModeProvider = NotifierProvider<ThemeModeSetting, ThemeMode>(ThemeModeSetting.new);

class ThemeModeSetting extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final saved = _prefs(ref)?.getString(SettingsPrefs.theme);
    return ThemeMode.values.where((mode) => mode.name == saved).firstOrNull ?? ThemeMode.system;
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await _prefs(ref)?.setString(SettingsPrefs.theme, mode.name);
  }
}

/// Touch feedback on this phone: haptic ticks (on by default) and click sounds (off).
@immutable
class TouchPrefs {
  const TouchPrefs({this.haptics = true, this.sounds = false});

  final bool haptics;
  final bool sounds;
}

final touchPrefsProvider = NotifierProvider<TouchPrefsSetting, TouchPrefs>(TouchPrefsSetting.new);

class TouchPrefsSetting extends Notifier<TouchPrefs> {
  @override
  TouchPrefs build() {
    final prefs = _prefs(ref);
    return TouchPrefs(
      haptics: prefs?.getBool(SettingsPrefs.haptics) ?? true,
      sounds: prefs?.getBool(SettingsPrefs.sounds) ?? false,
    );
  }

  Future<void> setHaptics({required bool on}) async {
    state = TouchPrefs(haptics: on, sounds: state.sounds);
    await _prefs(ref)?.setBool(SettingsPrefs.haptics, on);
  }

  Future<void> setSounds({required bool on}) async {
    state = TouchPrefs(haptics: state.haptics, sounds: on);
    await _prefs(ref)?.setBool(SettingsPrefs.sounds, on);
  }
}

/// A setting stored on the server: loaded once, changed optimistically, and put back (with the
/// error rethrown for the screen to show) when the server refuses.
abstract class ServerSetting<T> extends AsyncNotifier<T> {
  Future<T> load();
  Future<T> store(T value);

  @override
  Future<T> build() {
    // Someone else signing in on this phone gets their own settings.
    ref.watch(currentUserIdProvider);
    return load();
  }

  /// Saves [value], showing it at once.
  Future<void> save(T value) async {
    final before = state.value;
    state = AsyncData(value);
    try {
      final stored = await store(value);
      if (ref.mounted) state = AsyncData(stored);
    } on AppFailure {
      if (ref.mounted && before != null) state = AsyncData(before);
      rethrow;
    }
  }
}

final notificationSettingsProvider =
    AsyncNotifierProvider.autoDispose<NotificationSettingsNotifier, NotificationSettings>(
      NotificationSettingsNotifier.new,
      retry: (_, _) => null,
    );

class NotificationSettingsNotifier extends ServerSetting<NotificationSettings> {
  @override
  Future<NotificationSettings> load() => ref.read(settingsRepositoryProvider).notifications();

  @override
  Future<NotificationSettings> store(NotificationSettings value) =>
      ref.read(settingsRepositoryProvider).saveNotifications(value);
}

final privacySettingsProvider =
    AsyncNotifierProvider.autoDispose<PrivacySettingsNotifier, PrivacySettings>(
      PrivacySettingsNotifier.new,
      retry: (_, _) => null,
    );

class PrivacySettingsNotifier extends ServerSetting<PrivacySettings> {
  @override
  Future<PrivacySettings> load() => ref.read(settingsRepositoryProvider).privacy();

  @override
  Future<PrivacySettings> store(PrivacySettings value) =>
      ref.read(settingsRepositoryProvider).savePrivacy(value);
}

final appSettingsProvider = AsyncNotifierProvider.autoDispose<AppSettingsNotifier, AppSettings>(
  AppSettingsNotifier.new,
  retry: (_, _) => null,
);

class AppSettingsNotifier extends ServerSetting<AppSettings> {
  @override
  Future<AppSettings> load() => ref.read(settingsRepositoryProvider).app();

  @override
  Future<AppSettings> store(AppSettings value) =>
      ref.read(settingsRepositoryProvider).saveApp(value);
}

/// Signed-in devices.
final devicesProvider = FutureProvider.autoDispose<List<DeviceSession>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(settingsRepositoryProvider).sessions();
}, retry: (_, _) => null);

/// Signs in again for a fresh proof before deleting the account: Google where it's set up,
/// otherwise dev login in development builds. Throws `SignInCancelled` when the user closes the
/// account picker.
typedef Reauthenticate = Future<SignInProof> Function();

final reauthenticateProvider = Provider<Reauthenticate>((ref) {
  final env = ref.watch(appEnvProvider);
  final google = ref.watch(googleAuthProvider);
  return () async {
    if (google.isConfigured) return SignInProof.google(await google.idToken());
    if (env.devLoginAvailable) return const SignInProof.dev();
    throw const ValidationFailure('Signing in again isn\'t set up for this build.');
  };
});
