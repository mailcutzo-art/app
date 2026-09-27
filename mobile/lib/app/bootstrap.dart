import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/debug/debug_screen.dart';
import 'app.dart';
import 'env.dart';

Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerLicenses();

  final prefs = await SharedPreferences.getInstance();
  var env = AppEnv.fromDefines();
  final override = prefs.getString(DebugPrefs.apiBaseUrl);
  if (env.isDev && override != null) env = env.copyWith(apiBaseUrl: override);

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    // Crash reporting hooks in here once a provider is chosen.
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
    return true;
  };

  runApp(
    ProviderScope(
      overrides: [
        appEnvProvider.overrideWithValue(env),
        sharedPrefsProvider.overrideWithValue(prefs),
      ],
      child: const QuizApp(),
    ),
  );
}

/// Licenses for bundled assets that don't come from pub packages.
void _registerLicenses() {
  LicenseRegistry.addLicense(() async* {
    final ofl = await rootBundle.loadString('packages/design_system/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['Plus Jakarta Sans'], ofl);
    yield const LicenseEntryWithLineBreaks(['AnimateIcons (icon motions, adapted)'], _mit);
  });
}

const _mit = '''MIT License

Copyright (c) Avijit Dey (AnimateIcons, https://animateicons.in)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.''';
