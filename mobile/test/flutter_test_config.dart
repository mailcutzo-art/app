import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Loads the app font so widget tests lay text out as on a phone. The
/// default test font draws every glyph as a wide square, which overflows
/// phone-width rows that fit fine in real use.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final jakarta = FontLoader('packages/design_system/PlusJakartaSans');
  for (final weight in ['400Regular', '500Medium', '600SemiBold', '700Bold', '800ExtraBold']) {
    final file = File('packages/design_system/fonts/PlusJakartaSans_$weight.ttf');
    jakarta.addFont(file.readAsBytes().then(ByteData.sublistView));
  }
  await jakarta.load();
  // About and the version row read the app's package info.
  PackageInfo.setMockInitialValues(
    appName: 'Quiz Arena',
    packageName: 'app.quiz',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );
  await testMain();
}
