import 'dart:io';

import 'package:flutter/services.dart';

/// Registers the design system font (and the Roboto fallback shipped with the
/// Flutter SDK) so golden images render real glyphs.
///
/// [packageRoot] is the design_system package directory relative to the
/// current test's working directory.
Future<void> loadDesignSystemFonts({String packageRoot = '.'}) async {
  final jakarta = FontLoader('packages/design_system/PlusJakartaSans');
  for (final weight in ['400Regular', '500Medium', '600SemiBold', '700Bold', '800ExtraBold']) {
    jakarta.addFont(_bytes('$packageRoot/fonts/PlusJakartaSans_$weight.ttf'));
  }
  await jakarta.load();

  final materialFonts = _materialFontsDir();
  if (materialFonts != null) {
    final roboto = FontLoader('Roboto');
    for (final name in ['Roboto-Regular', 'Roboto-Medium', 'Roboto-Bold']) {
      final file = File('${materialFonts.path}/$name.ttf');
      if (file.existsSync()) roboto.addFont(_bytes(file.path));
    }
    await roboto.load();
  }
}

Future<ByteData> _bytes(String path) async {
  final data = await File(path).readAsBytes();
  return ByteData.sublistView(data);
}

/// `<flutter>/bin/cache/artifacts/material_fonts`, located from the running
/// flutter_tester binary (`<flutter>/bin/cache/artifacts/engine/<platform>/`).
Directory? _materialFontsDir() {
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    final candidate = Directory('${dir.path}/material_fonts');
    if (candidate.existsSync()) return candidate;
    dir = dir.parent;
  }
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final candidate = Directory('$root/bin/cache/artifacts/material_fonts');
    if (candidate.existsSync()) return candidate;
  }
  return null;
}
