import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../auth/token_store.dart';

/// Identifies this installation to the server (one device session per
/// install). Contains no hardware identifiers.
@immutable
class DeviceInfo {
  const DeviceInfo({
    required this.installId,
    required this.platform,
    required this.appVersion,
    required this.build,
  });

  final String installId;
  final String platform;
  final String appVersion;
  final int build;

  Map<String, Object> toJson() => {
    'install_id': installId,
    'platform': platform,
    'app_version': appVersion,
    'build': build,
  };
}

final deviceInfoProvider = FutureProvider<DeviceInfo>((ref) async {
  final storage = ref.watch(secureStorageProvider);
  const key = 'device.install_id';
  var installId = await storage.read(key: key);
  if (installId == null) {
    installId = _randomId();
    await storage.write(key: key, value: installId);
  }
  final package = await PackageInfo.fromPlatform();
  return DeviceInfo(
    installId: installId,
    platform: kIsWeb ? 'web' : Platform.operatingSystem,
    appVersion: package.version,
    build: int.tryParse(package.buildNumber) ?? 0,
  );
});

/// Random 128-bit id, hex encoded.
String _randomId() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
