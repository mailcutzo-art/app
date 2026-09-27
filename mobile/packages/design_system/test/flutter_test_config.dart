import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/fonts.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadDesignSystemFonts();
  await testMain();
}
