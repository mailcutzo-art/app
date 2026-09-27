import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/debug/debug_screen.dart' show sharedPrefsProvider;
import '../device/app_build.dart';
import '../network/api_client.dart';
import '../network/app_failure.dart';
import '../network/server_signals.dart';

export '../device/app_build.dart' show appBuildProvider;

/// Server-driven switches from `GET /v1/config`.
@immutable
class AppConfig {
  const AppConfig({
    this.minBuild = 0,
    this.maintenance = false,
    this.maintenanceMessage,
    this.features = const {},
  });

  factory AppConfig.fromJson(Object? json) => switch (json) {
    {'min_build': final int minBuild, 'maintenance': final bool maintenance} &&
        final Map<dynamic, dynamic> map =>
      AppConfig(
        minBuild: minBuild,
        maintenance: maintenance,
        maintenanceMessage: switch (map['maintenance_message']) {
          final String message when message.trim().isNotEmpty => message.trim(),
          _ => null,
        },
        features: {
          if (map['features'] case final Map<dynamic, dynamic> flags)
            for (final MapEntry(:key, :value) in flags.entries)
              if (key is String && value is bool) key: value,
        },
      ),
    _ => throw const FormatException('Unexpected config response'),
  };

  final int minBuild;
  final bool maintenance;
  final String? maintenanceMessage;
  final Map<String, bool> features;

  bool feature(String name) => features[name] ?? false;

  Map<String, Object?> toJson() => {
    'min_build': minBuild,
    'maintenance': maintenance,
    'maintenance_message': maintenanceMessage,
    'features': features,
  };

  @override
  bool operator ==(Object other) =>
      other is AppConfig &&
      other.minBuild == minBuild &&
      other.maintenance == maintenance &&
      other.maintenanceMessage == maintenanceMessage &&
      mapEquals(other.features, features);

  @override
  int get hashCode => Object.hash(minBuild, maintenance, maintenanceMessage, features.length);
}

/// Loads the config at start. It never blocks the app: offline or on errors it
/// falls back to the last config that loaded, or to defaults.
class ConfigController extends AsyncNotifier<AppConfig> {
  static const _cacheKey = 'config.last';

  @override
  Future<AppConfig> build() async {
    try {
      return await _fetch();
    } on AppFailure {
      // 426 and 503 MAINTENANCE were already reported by the API client.
      return _readCache() ?? const AppConfig();
    } on FormatException {
      return _readCache() ?? const AppConfig();
    }
  }

  /// Fetches the config again; the maintenance screen polls this. Only a fresh
  /// answer from the server can end maintenance.
  Future<void> recheck() async {
    try {
      final config = await _fetch();
      state = AsyncData(config);
      if (!config.maintenance) ref.read(serverSignalsProvider.notifier).maintenanceOver();
    } on AppFailure {
      // Still unreachable or still in maintenance: keep showing the screen.
    } on FormatException {
      // Ignore a malformed answer; the next check may succeed.
    }
  }

  Future<AppConfig> _fetch() async {
    final config = AppConfig.fromJson(
      await ref.read(apiClientProvider).get('/v1/config', auth: false),
    );
    _writeCache(config);
    return config;
  }

  AppConfig? _readCache() {
    try {
      final raw = ref.read(sharedPrefsProvider).getString(_cacheKey);
      return raw == null ? null : AppConfig.fromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  void _writeCache(AppConfig config) {
    try {
      ref.read(sharedPrefsProvider).setString(_cacheKey, jsonEncode(config.toJson()));
    } on Object {
      // Caching is best effort.
    }
  }
}

final configProvider = AsyncNotifierProvider<ConfigController, AppConfig>(
  ConfigController.new,
  retry: (_, _) => null,
);

/// What the whole app is allowed to show right now.
enum AppGate { open, updateRequired, maintenance }

final appGateProvider = Provider<AppGate>((ref) {
  final signals = ref.watch(serverSignalsProvider);
  final config = ref.watch(configProvider).value;
  final build = ref.watch(appBuildProvider).value ?? 0;
  return decideGate(signals: signals, config: config, build: build);
});

/// Pure gate rule: an update beats maintenance, and neither blocks while the
/// config is unknown (offline first start).
AppGate decideGate({required ServerSignals signals, AppConfig? config, required int build}) {
  if (signals.updateRequired) return AppGate.updateRequired;
  if (config != null && build > 0 && build < config.minBuild) return AppGate.updateRequired;
  if (signals.maintenance || (config?.maintenance ?? false)) return AppGate.maintenance;
  return AppGate.open;
}
