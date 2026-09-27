import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test/support/fonts.dart';

/// Loads real fonts so golden images show text instead of the test font, and
/// tolerates sub-pixel anti-aliasing differences between machines.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadDesignSystemFonts(packageRoot: '..');
  final current = goldenFileComparator;
  if (current is LocalFileComparator) {
    goldenFileComparator = _TolerantComparator(current.basedir.resolve('config.dart'));
  }
  await testMain();
}

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

  /// Fraction of differing pixels accepted (0.3%).
  static const _tolerance = 0.003;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= _tolerance) {
      if (!result.passed) {
        debugPrint('Golden $golden differs by ${(result.diffPercent * 100).toStringAsFixed(3)}%');
      }
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}
