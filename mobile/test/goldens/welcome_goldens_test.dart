import 'package:design_system/design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/features/auth/sign_in_screen.dart';

import '../support/battle.dart';
import '../support/fakes.dart';

/// Golden screenshots of the welcome screen on a notched phone (390 × 844),
/// under a light and a dark system theme: both show the dark welcome.
///
/// Update with `flutter test --update-goldens test/goldens/welcome_goldens_test.dart`.
void main() {
  setUpAll(() {
    final current = goldenFileComparator;
    if (current is LocalFileComparator) {
      goldenFileComparator = _TolerantComparator(
        current.basedir.resolve('welcome_goldens_test.dart'),
      );
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('welcome, ${brightness.name} system theme', (tester) async {
      tester.view
        ..physicalSize = const Size(390 * 2, 844 * 2)
        ..devicePixelRatio = 2
        ..padding = const FakeViewPadding(top: 47 * 2, bottom: 34 * 2)
        ..viewPadding = const FakeViewPadding(top: 47 * 2, bottom: 34 * 2);
      addTearDown(tester.view.reset);
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      // The resting composition, after the entrance.
      reduceMotion(tester);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appEnvProvider.overrideWithValue(
              const AppEnv(
                flavor: Flavor.prod,
                apiBaseUrl: 'http://api.test',
                googleServerClientId: 'web-client-id',
              ),
            ),
            sessionProvider.overrideWith(() => FakeSessionController(const SignedOut())),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            home: const SignInScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(SignInScreen),
        matchesGoldenFile('welcome/${brightness.name}/welcome.png'),
      );
    });
  }
}

/// Allows the tiny anti-aliasing differences between machines.
class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

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
