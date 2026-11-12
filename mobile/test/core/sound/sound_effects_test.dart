import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/sound/sound_effects.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every effect has its sound file', () {
    for (final sfx in Sfx.values) {
      expect(File('assets/${sfx.asset}').existsSync(), isTrue, reason: sfx.asset);
    }
  });

  test('nothing plays with sounds off, and a failing player never throws', () async {
    var asked = 0;
    final off = AudioSoundEffects(() {
      asked++;
      return false;
    });
    off.play(Sfx.correct);
    expect(asked, 1);

    // No audio plugin in tests: the sound is skipped, quietly.
    final on = AudioSoundEffects(() => true);
    on.play(Sfx.win);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await on.dispose();
  });
}
